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
                    if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D { space = !bytes.isEmpty; continue }
                    if space { bytes.append(0x20); space = false }
                    bytes.append(b)
                }
            } else {
                if t < s, let close = (t..<s).last(where: { p[$0] == 0x29 }) {
                    var a = close
                    while a > t && !isIdent(p[a - 1]) { a -= 1 }
                    var z = a
                    while z > t && isIdent(p[z - 1]) { z -= 1 }
                    if z < a { bytes.append(contentsOf: UnsafeBufferPointer(start: p + z, count: a - z)); bytes.append(0x2E) }
                }
                bytes.append(contentsOf: UnsafeBufferPointer(start: p + s, count: e - s))
            }
            raw.append((indent, String(decoding: bytes, as: UTF8.self), line))
        }
        let levels = Array(Set(raw.map(\.indent))).sorted()
        @inline(__always) func isIdent(_ c: UInt8) -> Bool {
            (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || (c >= 0x30 && c <= 0x39) || c == 0x5F || c >= 0x80
        }
        var rank: [Int: Int] = [:]
        for (i, v) in levels.enumerated() { rank[v] = Swift.min(i, 3) }
        return raw.map { CodeSymbol(level: rank[$0.indent] ?? 0, title: $0.title, line: $0.line) }
    }
}
