import Darwin

/// JSON parsed into ranges over the source text: no strings are copied or unescaped until
/// asked for, so multi-megabyte values (base64 images in notebooks) cost one vector scan.
/// Nodes are struct-of-arrays; children are linked lists (`first`, `next`). An object's
/// children alternate key, value.
public struct JSONTree {
    public enum Kind: UInt8 { case null, bool, number, string, array, object }

    let text: TextBuffer
    var kind: [UInt8] = []
    var start: [Int32] = [], end: [Int32] = []   // strings: the bytes between the quotes
    var first: [Int32] = [], next: [Int32] = []
    var escaped: [Bool] = []                     // string contains backslash escapes
    public private(set) var root: Int32 = -1

    /// Nil for invalid JSON (or nesting deeper than `maxDepth`).
    public static func parse(_ t: TextBuffer, maxDepth: Int = 256) -> JSONTree? {
        var tree = JSONTree(text: t)
        var i = 0
        guard let r = tree.value(&i, depth: 0, maxDepth: maxDepth) else { return nil }
        tree.root = r
        return tree
    }

    private init(text: TextBuffer) { self.text = text }

    private mutating func node(_ k: Kind, _ s: Int, _ e: Int, escaped esc: Bool = false) -> Int32 {
        kind.append(k.rawValue); start.append(Int32(s)); end.append(Int32(e))
        first.append(-1); next.append(-1); escaped.append(esc)
        return Int32(kind.count - 1)
    }

    @inline(__always) private func ws(_ i: inout Int) {
        let p = text.base, n = text.count
        while i < n && (p[i] == 0x20 || p[i] == 0x0A || p[i] == 0x0D || p[i] == 0x09) { i += 1 }
    }

    private mutating func value(_ i: inout Int, depth: Int, maxDepth: Int) -> Int32? {
        let p = text.base, n = text.count
        ws(&i)
        guard i < n, depth <= maxDepth else { return nil }
        switch p[i] {
        case 0x22:
            return string(&i)
        case 0x7B, 0x5B:
            let isObject = p[i] == 0x7B
            let me = node(isObject ? .object : .array, i, i)
            i += 1
            var last: Int32 = -1
            func link(_ c: Int32) {
                if last >= 0 { next[Int(last)] = c } else { first[Int(me)] = c }
                last = c
            }
            ws(&i)
            if i < n && p[i] == (isObject ? 0x7D : 0x5D) { i += 1; end[Int(me)] = Int32(i); return me }
            while true {
                if isObject {
                    ws(&i)
                    guard i < n, p[i] == 0x22, let k = string(&i) else { return nil }
                    link(k)
                    ws(&i)
                    guard i < n, p[i] == 0x3A else { return nil }
                    i += 1
                }
                guard let v = value(&i, depth: depth + 1, maxDepth: maxDepth) else { return nil }
                link(v)
                ws(&i)
                guard i < n else { return nil }
                if p[i] == 0x2C { i += 1; continue }
                if p[i] == (isObject ? 0x7D : 0x5D) { i += 1; end[Int(me)] = Int32(i); return me }
                return nil
            }
        case 0x74: return literal(&i, "true", .bool)
        case 0x66: return literal(&i, "false", .bool)
        case 0x6E: return literal(&i, "null", .null)
        default:
            let s = i
            while i < n, case let c = p[i], (c >= 0x30 && c <= 0x39) || c == 0x2D || c == 0x2B || c == 0x2E || c == 0x65 || c == 0x45 { i += 1 }
            return i > s ? node(.number, s, i) : nil
        }
    }

    private mutating func literal(_ i: inout Int, _ word: StaticString, _ k: Kind) -> Int32? {
        let len = word.utf8CodeUnitCount
        guard i + len <= text.count, memcmp(text.base + i, word.utf8Start, len) == 0 else { return nil }
        i += len
        return node(k, i - len, i)
    }

    /// At a quote. Scans 16 bytes at a time for the closing quote or a backslash.
    private mutating func string(_ i: inout Int) -> Int32? {
        let p = text.base, n = text.count
        let s = i + 1
        var k = s
        var esc = false
        while true {
            k = findAny(p, k, n, 0x22, 0x5C, 0x22, 0x5C)
            if k >= n { return nil }
            if p[k] == 0x5C { esc = true; k += 2; continue }
            break
        }
        i = k + 1
        return node(.string, s, k, escaped: esc)
    }

    // MARK: - Queries

    public func kindOf(_ v: Int32) -> Kind { Kind(rawValue: kind[Int(v)]) ?? .null }

    /// Value for `key` in an object (keys compared as raw bytes).
    public func member(_ obj: Int32?, _ key: StaticString) -> Int32? {
        guard let obj, obj >= 0, kindOf(obj) == .object else { return nil }
        var k = first[Int(obj)]
        let len = key.utf8CodeUnitCount
        while k >= 0 {
            let v = next[Int(k)]
            if end[Int(k)] - start[Int(k)] == Int32(len) && memcmp(text.base + Int(start[Int(k)]), key.utf8Start, len) == 0 { return v }
            k = v >= 0 ? next[Int(v)] : -1
        }
        return nil
    }

    /// Elements of an array (empty for anything else).
    public func elements(_ arr: Int32?) -> [Int32] {
        guard let arr, arr >= 0, kindOf(arr) == .array else { return [] }
        var out: [Int32] = []
        var k = first[Int(arr)]
        while k >= 0 { out.append(k); k = next[Int(k)] }
        return out
    }

    /// Raw source bytes of a node (strings: without the quotes, escapes not decoded).
    public func raw(_ v: Int32) -> UnsafeBufferPointer<UInt8> {
        UnsafeBufferPointer(start: text.base + Int(start[Int(v)]), count: Int(end[Int(v)] - start[Int(v)]))
    }

    public func isEscaped(_ v: Int32) -> Bool { escaped[Int(v)] }

    /// Appends a string's decoded UTF-8 (escapes, \u surrogate pairs) to `out`.
    func appendString(_ v: Int32, to out: inout ByteOutput) {
        let r = raw(v)
        guard escaped[Int(v)], let p = r.baseAddress else { if let b = r.baseAddress { out.bytes(b, r.count) }; return }
        var i = 0
        let n = r.count
        while i < n {
            let c = p[i]
            if c != 0x5C { out.byte(c); i += 1; continue }
            guard i + 1 < n else { break }
            let e = p[i + 1]
            i += 2
            switch e {
            case 0x6E: out.byte(0x0A)
            case 0x74: out.byte(0x09)
            case 0x72: out.byte(0x0D)
            case 0x62: out.byte(0x08)
            case 0x66: out.byte(0x0C)
            case 0x75:
                guard var u = hex4(p, i, n) else { continue }
                i += 4
                if u >= 0xD800 && u < 0xDC00, i + 6 <= n, p[i] == 0x5C, p[i + 1] == 0x75, let lo = hex4(p, i + 2, n),
                   lo >= 0xDC00 && lo < 0xE000 {
                    u = 0x10000 + ((u - 0xD800) << 10) + (lo - 0xDC00)
                    i += 6
                }
                utf8(u, &out)
            default: out.byte(e)   // \" \\ \/
            }
        }
    }

    /// A string, or an array of strings concatenated (notebook "source"/"text" fields).
    func appendText(_ v: Int32?, to out: inout ByteOutput) {
        guard let v, v >= 0 else { return }
        switch kindOf(v) {
        case .string: appendString(v, to: &out)
        case .array: for e in elements(v) where kindOf(e) == .string { appendString(e, to: &out) }
        default: break
        }
    }

    public func string(_ v: Int32?) -> String? {
        guard let v, v >= 0, kindOf(v) == .string else { return nil }
        var o = ByteOutput(capacity: Int(end[Int(v)] - start[Int(v)]) + 16)
        appendString(v, to: &o)
        let t = o.finish()
        return t.string(0, t.count)
    }

    private func hex4(_ p: UnsafePointer<UInt8>, _ i: Int, _ n: Int) -> UInt32? {
        guard i + 4 <= n else { return nil }
        var v: UInt32 = 0
        for k in 0..<4 {
            let c = p[i + k]
            let d: UInt32
            switch c {
            case 0x30...0x39: d = UInt32(c - 0x30)
            case 0x41...0x46: d = UInt32(c - 0x37)
            case 0x61...0x66: d = UInt32(c - 0x57)
            default: return nil
            }
            v = v << 4 | d
        }
        return v
    }

    private func utf8(_ u: UInt32, _ out: inout ByteOutput) {
        switch u {
        case ..<0x80: out.byte(UInt8(u))
        case ..<0x800: out.byte(UInt8(0xC0 | u >> 6)); out.byte(UInt8(0x80 | u & 0x3F))
        case 0xD800..<0xE000: out.string("\u{FFFD}")   // lone surrogate
        case ..<0x10000:
            out.byte(UInt8(0xE0 | u >> 12)); out.byte(UInt8(0x80 | u >> 6 & 0x3F)); out.byte(UInt8(0x80 | u & 0x3F))
        default:
            out.byte(UInt8(0xF0 | u >> 18)); out.byte(UInt8(0x80 | u >> 12 & 0x3F))
            out.byte(UInt8(0x80 | u >> 6 & 0x3F)); out.byte(UInt8(0x80 | u & 0x3F))
        }
    }
}
