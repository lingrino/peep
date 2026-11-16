import Darwin
import _Builtin_intrinsics.arm.neon

/// Byte offsets of line starts, found with a SIMD newline scan.
///
/// Line `i` covers bytes `[start(i), end(i))`, where `end` excludes the `\n` and a `\r`
/// before it. A trailing newline does not create an extra empty line (GitHub convention);
/// an empty text has one empty line. Offsets are UInt32: texts are capped well below 4 GiB.
public final class LineIndex: @unchecked Sendable {
    /// `count + 1` entries; `starts[count]` is the start of a virtual line after the end.
    public let starts: UnsafeMutablePointer<UInt32>
    public let count: Int
    let text: UnsafePointer<UInt8>
    /// Widest line in display columns (tabs expanded to `tabWidth`, UTF-8 sequences = 1).
    public private(set) var maxColumns: Int = 0

    public static let tabWidth = 4

    public init(_ buffer: TextBuffer) {
        let p = UnsafePointer(buffer.base)
        let n = buffer.count
        text = p
        // Initial guess: one line per 32 bytes; grows by doubling.
        var cap = max(64, n >> 5)
        var s = UnsafeMutablePointer<UInt32>.allocate(capacity: cap + 1)
        s[0] = 0
        var c = 1
        var i = 0
        // 64 bytes per iteration -> one 64-bit newline mask (bit k = byte i+k), then
        // "flatten" (simdjson): write 4 offsets unconditionally and advance by popcount, so
        // the common 0-4 newlines per block take no data-dependent branches.
        let nl = splat(0x0A)
        let weights = V16(1, 2, 4, 8, 16, 32, 64, 128, 1, 2, 4, 8, 16, 32, 64, 128)
        while i < n {
            if c + 64 > cap {
                let ncap = cap * 2
                let ns = UnsafeMutablePointer<UInt32>.allocate(capacity: ncap + 1)
                ns.update(from: s, count: c)
                s.deallocate()
                s = ns
                cap = ncap
            }
            let a = unsafeBitCast(load16(p + i) .== nl, to: V16.self) & weights
            let b = unsafeBitCast(load16(p + i + 16) .== nl, to: V16.self) & weights
            let d = unsafeBitCast(load16(p + i + 32) .== nl, to: V16.self) & weights
            let e = unsafeBitCast(load16(p + i + 48) .== nl, to: V16.self) & weights
            let r = vpaddq_u8(vpaddq_u8(a, b), vpaddq_u8(d, e))
            var m = unsafeBitCast(vpaddq_u8(r, r), to: SIMD2<UInt64>.self)[0]
            if m != 0 {
                let k = m.nonzeroBitCount
                let base = UInt32(truncatingIfNeeded: i + 1)
                s[c] = base &+ UInt32(m.trailingZeroBitCount); m &= m &- 1
                s[c + 1] = base &+ UInt32(m.trailingZeroBitCount); m &= m &- 1
                s[c + 2] = base &+ UInt32(m.trailingZeroBitCount); m &= m &- 1
                s[c + 3] = base &+ UInt32(m.trailingZeroBitCount); m &= m &- 1
                var w = c + 4
                while m != 0 {
                    s[w] = base &+ UInt32(m.trailingZeroBitCount)
                    m &= m &- 1
                    w &+= 1
                }
                c &+= k
            }
            i &+= 64
        }
        // Drop newlines found in the zero padding (impossible: padding is 0x00) and any
        // past the end; then drop a final start == n (trailing newline -> no extra line).
        while c > 1 && Int(s[c - 1]) > n { c -= 1 }
        // The sentinel is one past the (virtual) newline ending the last line: `n` if the
        // text ends with "\n" (which then adds no extra line), else `n + 1`.
        if c > 1 && Int(s[c - 1]) == n {
            c -= 1
            s[c] = UInt32(truncatingIfNeeded: n)
        } else {
            s[c] = UInt32(truncatingIfNeeded: n + 1)
        }
        starts = s
        count = c
        maxColumns = computeMaxColumns()
    }

    deinit { starts.deallocate() }

    @inline(__always) public func start(_ line: Int) -> Int { Int(starts[line]) }

    /// End of line content (excludes `\n` and a preceding `\r`).
    @inline(__always) public func end(_ line: Int) -> Int {
        var e = Int(starts[line + 1]) - 1
        if e > Int(starts[line]) && text[e - 1] == 0x0D { e -= 1 }
        return e
    }

    /// Line containing byte `offset` (offsets at a newline belong to the line it ends).
    public func line(containing offset: Int) -> Int {
        // Largest i with starts[i] <= offset.
        var lo = 0, hi = count - 1
        let o = UInt32(truncatingIfNeeded: offset)
        while lo < hi {
            let mid = (lo + hi + 1) >> 1
            if starts[mid] <= o { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    /// Display columns of `[start, end)`: tabs advance to the next multiple of `tabWidth`,
    /// UTF-8 continuation bytes take no column.
    public static func columns(_ p: UnsafePointer<UInt8>, _ start: Int, _ end: Int) -> Int {
        let len = end - start
        if len <= 0 { return 0 }
        let q = p + start
        // Common case: plain ASCII with no tabs.
        var hasSpecial = false
        var i = 0
        while i < len {
            let v = load16(q + i)
            var m = highBitNibbles(v) | nibbles(v .== splat(0x09))
            if i + 16 > len { m &= (1 << UInt64(4 * (len - i))) &- 1 }
            if m != 0 { hasSpecial = true; break }
            i &+= 16
        }
        if !hasSpecial { return len }
        var col = 0
        for k in 0..<len {
            let b = q[k]
            if b == 0x09 { col += tabWidth - col % tabWidth }
            else if b & 0xC0 != 0x80 { col += 1 }
        }
        return col
    }

    private func computeMaxColumns() -> Int {
        // Byte length * tabWidth bounds a line's columns, so most lines are skipped without
        // looking at their bytes once a wide line has been found.
        var best = 0
        for l in 0..<count {
            let s = start(l), e = end(l)
            let bytes = e - s
            if bytes <= best { continue }
            if bytes * LineIndex.tabWidth <= best { continue }
            best = max(best, LineIndex.columns(text, s, e))
        }
        return best
    }
}
