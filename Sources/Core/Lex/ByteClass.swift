/// 256-entry byte classification tables. One load + mask per byte in lexer hot loops.
public struct ByteClass: @unchecked Sendable {
    public static let identStart: UInt8 = 1
    public static let identCont: UInt8 = 2
    public static let digit: UInt8 = 4
    public static let space: UInt8 = 8      // space, tab, \r, \n, \f, \v
    public static let hex: UInt8 = 16
    public static let upper: UInt8 = 32
    public static let lower: UInt8 = 64

    /// Pointer into a leaked 256-byte table (tables live for the process lifetime).
    public let table: UnsafePointer<UInt8>
    /// SIMD membership tests for identifier-continue and whitespace bytes (16 at a time).
    public let identSet: NibbleSet
    public let spaceSet: NibbleSet

    /// Standard table: identifiers are [A-Za-z_][A-Za-z0-9_]* plus every byte >= 0x80 (so
    /// UTF-8 identifiers stay one token without decoding). `extraIdent`/`extraStart` add
    /// language-specific characters (`$` in JS, `-` in CSS/Lisp, `?`/`!` in Ruby...).
    public init(extraIdent: String = "", extraStart: String = "") {
        let t = UnsafeMutablePointer<UInt8>.allocate(capacity: 256)
        t.initialize(repeating: 0, count: 256)
        for b in 0..<256 {
            var c: UInt8 = 0
            let u = UInt8(b)
            switch u {
            case 0x41...0x5A: c = ByteClass.identStart | ByteClass.identCont | ByteClass.upper
            case 0x61...0x7A: c = ByteClass.identStart | ByteClass.identCont | ByteClass.lower
            case 0x30...0x39: c = ByteClass.identCont | ByteClass.digit | ByteClass.hex
            case 0x5F: c = ByteClass.identStart | ByteClass.identCont
            case 0x20, 0x09, 0x0A, 0x0D, 0x0C, 0x0B: c = ByteClass.space
            case 0x80...0xFF: c = ByteClass.identStart | ByteClass.identCont
            default: c = 0
            }
            if (0x41...0x46).contains(u) || (0x61...0x66).contains(u) { c |= ByteClass.hex }
            t[b] = c
        }
        for b in extraIdent.utf8 { t[Int(b)] |= ByteClass.identCont }
        for b in extraStart.utf8 { t[Int(b)] |= ByteClass.identStart | ByteClass.identCont }
        table = UnsafePointer(t)
        identSet = NibbleSet { t[Int($0)] & ByteClass.identCont != 0 }
        spaceSet = NibbleSet { t[Int($0)] & ByteClass.space != 0 }
    }

    @inline(__always) public subscript(_ b: UInt8) -> UInt8 { table[Int(b)] }
    @inline(__always) public func isIdentStart(_ b: UInt8) -> Bool { table[Int(b)] & ByteClass.identStart != 0 }
    @inline(__always) public func isIdent(_ b: UInt8) -> Bool { table[Int(b)] & ByteClass.identCont != 0 }
    @inline(__always) public func isDigit(_ b: UInt8) -> Bool { table[Int(b)] & ByteClass.digit != 0 }
    @inline(__always) public func isSpace(_ b: UInt8) -> Bool { table[Int(b)] & ByteClass.space != 0 }
    @inline(__always) public func isHex(_ b: UInt8) -> Bool { table[Int(b)] & ByteClass.hex != 0 }

    public static let standard = ByteClass()
}

/// SIMD "find first of up to 4 bytes" over `[i, end)`. Returns `end` if none found.
/// Reads in 16-byte blocks and may look past `end` (padded buffers make that safe).
@inline(__always)
func findAny(_ p: UnsafePointer<UInt8>, _ i: Int, _ end: Int, _ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) -> Int {
    var j = i
    let va = splat(a), vb = splat(b), vc = splat(c), vd = splat(d)
    while j < end {
        let v = load16(p + j)
        let m = nibbles((v .== va) .| (v .== vb) .| (v .== vc) .| (v .== vd))
        if m != 0 {
            let k = j + (m.trailingZeroBitCount >> 2)
            return k < end ? k : end
        }
        j &+= 16
    }
    return end
}

/// End of the line containing `i` (index of the `\n`, or `end`).
@inline(__always)
func lineEnd(_ p: UnsafePointer<UInt8>, _ i: Int, _ end: Int) -> Int {
    findAny(p, i, end, 0x0A, 0x0A, 0x0A, 0x0A)
}

@inline(__always)
func matches(_ p: UnsafePointer<UInt8>, _ i: Int, _ end: Int, _ s: StaticString) -> Bool {
    let n = s.utf8CodeUnitCount
    if i + n > end { return false }
    let q = s.utf8Start
    for k in 0..<n where p[i + k] != q[k] { return false }
    return true
}
