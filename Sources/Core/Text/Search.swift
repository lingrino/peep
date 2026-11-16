import Darwin

/// Growable list of match ranges stored flat as [start0, end0, start1, end1, ...] (UInt32).
public final class MatchList: @unchecked Sendable {
    public private(set) var flat: UnsafeMutablePointer<UInt32>
    public private(set) var count = 0      // number of matches
    private var cap: Int

    public init(capacity: Int = 64) {
        cap = max(16, capacity)
        flat = .allocate(capacity: 2 * cap)
    }

    deinit { flat.deallocate() }

    @inline(__always) func append(_ s: Int, _ e: Int) {
        if count == cap {
            let ncap = cap * 2
            let n = UnsafeMutablePointer<UInt32>.allocate(capacity: 2 * ncap)
            n.update(from: flat, count: 2 * count)
            flat.deallocate()
            flat = n
            cap = ncap
        }
        flat[2 * count] = UInt32(truncatingIfNeeded: s)
        flat[2 * count + 1] = UInt32(truncatingIfNeeded: e)
        count &+= 1
    }

    public var buffer: UnsafeBufferPointer<UInt32> { UnsafeBufferPointer(start: flat, count: 2 * count) }
    @inline(__always) public func start(_ i: Int) -> Int { Int(flat[2 * i]) }
    @inline(__always) public func end(_ i: Int) -> Int { Int(flat[2 * i + 1]) }

    /// Index of the first match starting at or after `offset` (wrapping to 0).
    public func index(atOrAfter offset: Int) -> Int {
        var lo = 0, hi = count
        let o = UInt32(truncatingIfNeeded: offset)
        while lo < hi {
            let mid = (lo + hi) >> 1
            if flat[2 * mid] < o { lo = mid + 1 } else { hi = mid }
        }
        return lo == count ? 0 : lo
    }
}

/// Substring search over UTF-8 text.
///
/// SIMD first/last-byte filter (W. Muła, "SIMD-friendly algorithms for substring searching"):
/// for each 16 candidate positions compare the needle's first byte at i and last byte at
/// i+k-1 in parallel; only positions where both match are verified byte by byte. ASCII
/// letters are case-folded with two vector ops when searching case-insensitively.
public enum Search {
    /// Smart case: case-sensitive iff the query contains an uppercase ASCII letter.
    public static func isCaseSensitive(_ query: [UInt8]) -> Bool {
        query.contains { $0 >= 0x41 && $0 <= 0x5A }
    }

    public static func find(_ text: TextBuffer, _ query: [UInt8], caseSensitive: Bool,
                            limit: Int = 5_000_000) -> MatchList {
        let out = MatchList(capacity: 256)
        let k = query.count
        let n = text.count
        if k == 0 || k > n { return out }
        let p = UnsafePointer(text.base)
        let fold = !caseSensitive
        let needle: [UInt8] = fold ? query.map { $0 >= 0x41 && $0 <= 0x5A ? $0 | 0x20 : $0 } : query
        needle.withUnsafeBufferPointer { nb in
            let q = nb.baseAddress!
            let first = splat(q[0]), last = splat(q[k - 1])
            let lastPos = n - k            // last valid start
            var i = 0
            var nextAllowed = 0            // matches don't overlap
            while i <= lastPos {
                var a = load16(p + i)
                var b = load16(p + i + k - 1)
                if fold { a = lowerASCII(a); b = lowerASCII(b) }
                var m = laneBits((a .== first) .& (b .== last))
                while m != 0 {
                    let pos = i + (m.trailingZeroBitCount >> 2)
                    m &= m &- 1
                    if pos > lastPos { break }
                    if pos < nextAllowed { continue }
                    if verify(p + pos, q, k, fold) {
                        out.append(pos, pos + k)
                        nextAllowed = pos + k
                        if out.count >= limit { return }
                    }
                }
                i &+= 16
            }
        }
        return out
    }

    /// Compares bytes 1..<k-1 (first/last already matched).
    @inline(__always)
    static func verify(_ s: UnsafePointer<UInt8>, _ q: UnsafePointer<UInt8>, _ k: Int, _ fold: Bool) -> Bool {
        if k <= 2 { return true }
        if !fold { return memcmp(s + 1, q + 1, k - 2) == 0 }
        var j = 1
        while j + 16 <= k - 1 {
            if nibbles(lowerASCII(load16(s + j)) .!= load16(q + j)) != 0 { return false }
            j &+= 16
        }
        while j < k - 1 {
            var c = s[j]
            if c >= 0x41 && c <= 0x5A { c |= 0x20 }
            if c != q[j] { return false }
            j &+= 1
        }
        return true
    }
}
