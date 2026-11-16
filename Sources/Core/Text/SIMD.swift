import _Builtin_intrinsics.arm.neon

// Small SIMD vocabulary shared by the scanners.
//
// Codegen notes (verified with `swiftc -O -emit-assembly`, see Scripts/asm.sh):
//  - `nibbles(_:)` lowers to exactly `cmeq` + `shrn #4` + `fmov`: the NEON replacement for
//    x86 movemask. Each input lane becomes 4 bits of the UInt64.
//  - Do NOT use `any()`, `min()`, `max()` or `wrappedSum()` on SIMD values in hot loops: they
//    compile to out-of-line stdlib calls. Test `nibbles(...) != 0` instead.
//  - Do NOT compare a SIMD value against a scalar (`v .< 0`): that overload is scalarized.
//    Always compare against a splatted vector.

public typealias V16 = SIMD16<UInt8>

@inline(__always)
func load16(_ p: UnsafePointer<UInt8>) -> V16 {
    UnsafeRawPointer(p).loadUnaligned(as: V16.self)
}

/// 4 bits per lane, set when the lane's mask is true. Lane index of the lowest set lane is
/// `m.trailingZeroBitCount >> 2`.
@inline(__always)
func nibbles(_ m: SIMDMask<SIMD16<Int8>>) -> UInt64 {
    let w = unsafeBitCast(m, to: SIMD8<UInt16>.self)
    return unsafeBitCast(SIMD8<UInt8>(truncatingIfNeeded: w &>> 4), to: UInt64.self)
}

/// One bit per lane (the top bit of each nibble), for iterating set lanes with `m &= m - 1`.
@inline(__always)
func laneBits(_ m: SIMDMask<SIMD16<Int8>>) -> UInt64 {
    nibbles(m) & 0x8888_8888_8888_8888
}

/// Lanes whose byte has the high bit set (non-ASCII). Compiles to `cmlt #0` + `shrn`.
/// NOTE: compare against a *vector* (`SIMD16(repeating: 0)`), never a scalar literal: the
/// scalar-rhs overloads compile to a per-lane loop through the stack (30x slower).
@inline(__always)
func highBitNibbles(_ v: V16) -> UInt64 {
    nibbles(unsafeBitCast(v, to: SIMD16<Int8>.self) .< SIMD16<Int8>(repeating: 0))
}

@inline(__always)
func splat(_ b: UInt8) -> V16 { V16(repeating: b) }

/// ASCII lowercase of a vector (only A-Z change).
@inline(__always)
func lowerASCII(_ v: V16) -> V16 {
    // (v - 'A') < 26  <=>  'A' <= v <= 'Z'; OR 0x20 there.
    let isUpper = (v &- splat(0x41)) .< splat(26)
    return v | V16(repeating: 0).replacing(with: 0x20, where: isUpper)
}

extension UnsafePointer where Pointee == UInt8 {
    /// True if all bytes in `[0, n)` are ASCII. Reads in 64-byte blocks; requires readable
    /// memory up to the next 64-byte block past `n` (TextBuffer padding guarantees it).
    @inline(__always)
    func isASCII(_ n: Int) -> Bool {
        var i = 0
        while i + 64 <= n {
            let v = load16(self + i) | load16(self + i + 16) | load16(self + i + 32) | load16(self + i + 48)
            if highBitNibbles(v) != 0 { return false }
            i &+= 64
        }
        while i + 16 <= n {
            if highBitNibbles(load16(self + i)) != 0 { return false }
            i &+= 16
        }
        while i < n {
            if self[i] >= 0x80 { return false }
            i &+= 1
        }
        return true
    }
}

/// Membership test for an arbitrary byte set, 16 bytes at a time, via two NEON table
/// lookups (Muła's nibble-table technique): `(LO[b & 15] & HI[b >> 4]) != 0`.
///
/// Built from a predicate: bytes with the same high nibble share one "group" bitmask of low
/// nibbles; each distinct group gets one bit. Works for any set with ≤ 8 distinct groups,
/// which covers identifier/whitespace classes in practice (the initializer checks).
public struct NibbleSet: @unchecked Sendable {
    let lo: V16
    let hi: V16

    public init(_ contains: (UInt8) -> Bool) {
        var groups: [UInt16] = []
        var hiBits = [UInt8](repeating: 0, count: 16)
        var loBits = [UInt8](repeating: 0, count: 16)
        for h in 0..<16 {
            var set: UInt16 = 0
            for l in 0..<16 where contains(UInt8(h << 4 | l)) { set |= 1 << UInt16(l) }
            if set == 0 { continue }
            var g = groups.firstIndex(of: set) ?? -1
            if g < 0 { groups.append(set); g = groups.count - 1 }
            precondition(g < 8, "byte set needs more than 8 nibble groups")
            hiBits[h] |= 1 << UInt8(g)
        }
        for (g, set) in groups.enumerated() {
            for l in 0..<16 where set & (1 << UInt16(l)) != 0 { loBits[l] |= 1 << UInt8(g) }
        }
        lo = V16(loBits)
        hi = V16(hiBits)
    }

    /// 0xFF in lanes whose byte is in the set, else 0x00. (`tbl` x2 + `cmtst`.)
    @inline(__always)
    func match(_ v: V16) -> V16 {
        vtstq_u8(vqtbl1q_u8(lo, v & splat(0x0F)), vqtbl1q_u8(hi, v &>> 4))
    }

    /// Index of the first byte at or after `i` that is NOT in the set (≤ `end`).
    /// Relies on readable padding past `end`.
    @inline(__always)
    func skip(_ p: UnsafePointer<UInt8>, _ i: Int, _ end: Int) -> Int {
        var j = i
        while j < end {
            let m = nibblesOf(~match(load16(p + j)))
            if m != 0 { return min(j + (m.trailingZeroBitCount >> 2), end) }
            j &+= 16
        }
        return end
    }
}

/// `nibbles` for a raw 0x00/0xFF lane vector.
@inline(__always)
func nibblesOf(_ v: V16) -> UInt64 {
    let w = unsafeBitCast(v, to: SIMD8<UInt16>.self)
    return unsafeBitCast(SIMD8<UInt8>(truncatingIfNeeded: w &>> 4), to: UInt64.self)
}
