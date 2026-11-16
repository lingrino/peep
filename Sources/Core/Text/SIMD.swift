// Small SIMD vocabulary shared by the scanners.
//
// Codegen notes (verified with `swiftc -O -emit-assembly`, see Scripts/asm.sh):
//  - `nibbles(_:)` lowers to exactly `cmeq` + `shrn #4` + `fmov`: the NEON replacement for
//    x86 movemask. Each input lane becomes 4 bits of the UInt64.
//  - Do NOT use `any()`, `min()`, `max()` or `wrappedSum()` on SIMD values in hot loops: they
//    compile to out-of-line stdlib calls. Test `nibbles(...) != 0` instead.

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

/// Lanes whose byte has the high bit set (non-ASCII).
@inline(__always)
func highBitNibbles(_ v: V16) -> UInt64 {
    nibbles(unsafeBitCast(v, to: SIMD16<Int8>.self) .< 0)
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
