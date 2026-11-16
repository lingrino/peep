/// Immutable set of ASCII words (1...16 bytes) mapped to a class byte, built once per
/// language. Words are packed little-endian into two UInt64s, so a hit costs one hash, one
/// (usually first-probe) slot read and three integer compares; no string or memcmp.
///
/// The class byte is a `TokenKind` raw value plus optional hint bits (see `KeywordTable.Hint`).
public final class KeywordTable: @unchecked Sendable {
    public enum Hint {
        /// The next identifier names a function/method being declared (`func`, `fn`, `def`).
        public static let declaresFunction: UInt8 = 0x40
        /// The next identifier names a type being declared (`class`, `struct`, `enum`).
        public static let declaresType: UInt8 = 0x80
        public static let kindMask: UInt8 = 0x3F
    }

    private let bits: Int
    private let mask: Int
    private let k0: UnsafeMutablePointer<UInt64>
    private let k1: UnsafeMutablePointer<UInt64>
    private let lens: UnsafeMutablePointer<UInt8>
    private let vals: UnsafeMutablePointer<UInt8>
    public let caseInsensitive: Bool

    /// `groups`: (class byte, space-separated words).
    public init(_ groups: [(UInt8, String)], caseInsensitive: Bool = false) {
        self.caseInsensitive = caseInsensitive
        var words: [([UInt8], UInt8)] = []
        for (v, list) in groups {
            for w in list.split(separator: " ") where !w.isEmpty {
                var b = Array(w.utf8)
                if caseInsensitive { b = b.map { $0 >= 0x41 && $0 <= 0x5A ? $0 | 0x20 : $0 } }
                if b.count > 16 { continue }   // can never match (lookup rejects > 16 bytes)
                words.append((b, v))
            }
        }
        var b = 4
        while (1 << b) < words.count * 3 { b += 1 }
        bits = b
        mask = (1 << b) - 1
        let size = 1 << b
        k0 = .allocate(capacity: size); k0.initialize(repeating: 0, count: size)
        k1 = .allocate(capacity: size); k1.initialize(repeating: 0, count: size)
        lens = .allocate(capacity: size); lens.initialize(repeating: 0, count: size)
        vals = .allocate(capacity: size); vals.initialize(repeating: 0, count: size)
        for (w, v) in words {
            var a: UInt64 = 0, c: UInt64 = 0
            for (i, byte) in w.enumerated() {
                if i < 8 { a |= UInt64(byte) << UInt64(8 * i) } else { c |= UInt64(byte) << UInt64(8 * (i - 8)) }
            }
            var slot = KeywordTable.hash(a, c, w.count, b)
            while lens[slot] != 0 && !(lens[slot] == UInt8(w.count) && k0[slot] == a && k1[slot] == c) {
                slot = (slot + 1) & mask
            }
            k0[slot] = a; k1[slot] = c; lens[slot] = UInt8(w.count); vals[slot] = v
        }
    }

    deinit {
        k0.deallocate(); k1.deallocate(); lens.deallocate(); vals.deallocate()
    }

    @inline(__always)
    static func hash(_ a: UInt64, _ c: UInt64, _ len: Int, _ bits: Int) -> Int {
        let h = (a &* 0x9E37_79B9_7F4A_7C15) ^ (c &* 0xC2B2_AE3D_27D4_EB4F) ^ UInt64(truncatingIfNeeded: len)
        return Int(truncatingIfNeeded: (h &* 0xFF51_AFD7_ED55_8CCD) >> UInt64(64 - bits))
    }

    /// Class byte for the word at `p[0..<len]`, or 0 if it is not in the table.
    /// May read up to 16 bytes from `p` (callers lex padded TextBuffers).
    @inline(__always)
    public func lookup(_ p: UnsafePointer<UInt8>, _ len: Int) -> UInt8 {
        if len > 16 || len == 0 { return 0 }
        var v = load16(p)
        if caseInsensitive { v = lowerASCII(v) }
        let pair = unsafeBitCast(v, to: SIMD2<UInt64>.self)
        var a = pair[0], c = pair[1]
        if len < 8 {
            a &= (1 << UInt64(8 * len)) &- 1
            c = 0
        } else if len < 16 {
            c &= (1 << UInt64(8 * (len - 8))) &- 1
        }
        var slot = KeywordTable.hash(a, c, len, bits)
        while true {
            let l = lens[slot]
            if l == 0 { return 0 }
            if Int(l) == len && k0[slot] == a && k1[slot] == c { return vals[slot] }
            slot = (slot &+ 1) & mask
        }
    }
}
