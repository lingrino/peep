/// A declaration for the code outline sidebar.
public struct CodeSymbol: Sendable {
    public let level: Int
    public let title: String
    public let line: Int
}

/// Turns the declarations recorded while lexing into outline entries: the title runs from
/// the declaring keyword to the name ("struct Foo", "func (r *T) Method"), and the level is
/// the line's indentation ranked among all symbols (top level, members, nested).
public enum CodeOutline {
    public static func symbols(_ text: TextBuffer, _ lines: LineIndex, _ tokens: TokenStream, max: Int = 5000) -> [CodeSymbol] {
        let n = Swift.min(tokens.symbolStart.count, max)
        if n == 0 { return [] }
        let p = text.base
        var raw: [(indent: Int, title: String, line: Int)] = []
        raw.reserveCapacity(n)
        var lastLine = -1
        for k in 0..<n {
            let s = Int(tokens.symbolStart[k]), e = Int(tokens.symbolEnd[k])
            var t = Int(tokens.symbolTitleStart[k])
            if t > s || s - t > 200 { t = s }
            let line = lines.line(containing: s)
            if line == lastLine { continue }   // one entry per line
            lastLine = line
            // Indentation of the declaration's line (tabs as 4 columns).
            var c = lines.start(line), indent = 0
            while c < e && (p[c] == 0x20 || p[c] == 0x09) { indent += p[c] == 0x09 ? 4 : 1; c += 1 }
            // Types keep their keyword ("struct Foo", "extension Array"); functions are just
            // the name, or "Type.name" for Go methods (the receiver's type, from its parens).
            var bytes: [UInt8] = []
            if tokens.symbolKind[k] == TokenKind.type.rawValue {
                var space = false
                for i in t..<e {
                    let b = p[i]
                    if b == 0x22 { continue }   // HCL labels: resource "aws_s3_bucket" "assets"
                    if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D { space = !bytes.isEmpty; continue }
                    if space { bytes.append(0x20); space = false }
                    bytes.append(b)
                }
                dropIfNotExists(&bytes)
            } else {
                if t < s, let close = (t..<s).last(where: { p[$0] == 0x29 }) {
                    var a = close
                    while a > t && !isIdent(p[a - 1]) { a -= 1 }
                    var z = a
                    while z > t && isIdent(p[z - 1]) { z -= 1 }
                    if z < a { bytes.append(contentsOf: UnsafeBufferPointer(start: p + z, count: a - z)); bytes.append(0x2E) }
                }
                bytes.append(contentsOf: UnsafeBufferPointer(start: p + s, count: e - s))
                // Swift initializers and subscripts (keyword tokens, unlike `def init` or a
                // method named init) are all named alike: add argument labels, as Xcode does
                // ("init(name:count:)", "init?(coder:)").
                if (bytes.elementsEqual("init".utf8) || bytes.elementsEqual("subscript".utf8))
                    && tokens.kind(tokens.first(after: s)) == .keyword {
                    labels(p, e, text.count, &bytes)
                }
            }
            let title = String(decoding: bytes, as: UTF8.self)
            // One-line clauses of one function on adjacent lines (Elixir, Erlang) are one
            // entry; overloads further apart stay separate.
            if let last = raw.last, last.title == title && last.indent == indent && line - last.line <= 1 { continue }
            raw.append((indent, title, line))
        }
        let levels = Array(Set(raw.map(\.indent))).sorted()
        @inline(__always) func isIdent(_ c: UInt8) -> Bool {
            (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || (c >= 0x30 && c <= 0x39) || c == 0x5F || c >= 0x80
        }
        var rank: [Int: Int] = [:]
        for (i, v) in levels.enumerated() { rank[v] = Swift.min(i, 3) }
        return raw.map { CodeSymbol(level: rank[$0.indent] ?? 0, title: $0.title, line: $0.line) }
    }

    /// SQL: "TABLE IF NOT EXISTS users" -> "TABLE users".
    static func dropIfNotExists(_ b: inout [UInt8]) {
        let pat = Array(" if not exists".utf8)
        guard b.count > pat.count else { return }
        for i in 0...(b.count - pat.count) where b[i] == 0x20 {
            var ok = true
            for j in 1..<pat.count where b[i + j] | 0x20 != pat[j] { ok = false; break }
            if ok { b.removeSubrange(i..<(i + pat.count)); return }
        }
    }

    /// Appends `?`/`!` and "(label:label:)" for the parameter list after `i`: each
    /// parameter's first word (its argument label, `_` included). Nothing if there's no list.
    static func labels(_ p: UnsafePointer<UInt8>, _ i: Int, _ end: Int, _ out: inout [UInt8]) {
        var k = i
        let limit = Swift.min(end, i + 1024)
        if k < limit && (p[k] == 0x3F || p[k] == 0x21) { out.append(p[k]); k += 1 }
        while k < limit && (p[k] == 0x20 || p[k] == 0x09) { k += 1 }
        if k < limit && p[k] == 0x3C {   // generic parameters
            var d = 0
            while k < limit { if p[k] == 0x3C { d += 1 } else if p[k] == 0x3E { d -= 1; if d == 0 { k += 1; break } }; k += 1 }
        }
        guard k < limit, p[k] == 0x28 else { return }
        var sig: [UInt8] = [0x28]
        var depth = 0
        var expectLabel = true
        while k < limit {
            let c = p[k]
            switch c {
            case 0x28, 0x5B, 0x3C: depth += 1
            case 0x29, 0x5D, 0x3E:
                if c == 0x3E && p[k - 1] == 0x2D { break }   // `->` in a closure type
                depth -= 1
                if depth == 0 { sig.append(0x29); out.append(contentsOf: sig); return }
            case 0x2C: if depth == 1 { expectLabel = true }
            default:
                if expectLabel && depth == 1 && (CLike.isIdentByte(c) || c >= 0x80) {
                    var z = k
                    while z < limit && (CLike.isIdentByte(p[z]) || p[z] >= 0x80) { z += 1 }
                    sig.append(contentsOf: UnsafeBufferPointer(start: p + k, count: z - k))
                    sig.append(0x3A)
                    expectLabel = false
                    k = z
                    continue
                }
            }
            k += 1
        }
    }
}
