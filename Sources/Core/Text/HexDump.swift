/// xxd-style hex dump for binary files: "00000000: 4865 6c6c ...  Hello world.....".
/// Rendered as text so the code view's selection, copy and search all just work.
public enum HexDump {
    public static let limit = 64 << 10   // bytes dumped (a preview, not an editor)

    public static func render(_ raw: TextBuffer, limit: Int) -> TextBuffer {
        let n = min(raw.count, limit)
        let lines = (n + 15) / 16
        let lineLen = 10 + 40 + 1 + 16 + 1   // offset+": ", 8 groups "xxxx ", space, ascii, "\n"
        var out = [UInt8]()
        out.reserveCapacity(lines * lineLen + 80)
        let hex = Array("0123456789abcdef".utf8)
        let p = raw.base
        for l in 0..<lines {
            let off = l * 16
            for k in stride(from: 28, through: 0, by: -4) { out.append(hex[(off >> k) & 15]) }
            out.append(0x3A); out.append(0x20)
            for i in 0..<16 {
                if off + i < n {
                    let b = Int(p[off + i])
                    out.append(hex[b >> 4]); out.append(hex[b & 15])
                } else {
                    out.append(0x20); out.append(0x20)
                }
                if i & 1 == 1 { out.append(0x20) }
            }
            out.append(0x20)
            for i in 0..<min(16, n - off) {
                let b = p[off + i]
                out.append(b >= 0x20 && b < 0x7F ? b : 0x2E)
            }
            out.append(0x0A)
        }
        if raw.count > n {
            out.append(contentsOf: "\n… \(raw.count - n) more bytes not shown\n".utf8)
        }
        return out.withUnsafeBytes { TextBuffer(copying: $0) }
    }

    /// Colors offsets as comments and the ASCII column as strings.
    public static func lex(_ p: UnsafePointer<UInt8>, _ start: Int, _ end: Int, _ out: TokenStream) {
        var i = start
        while i < end {
            let le = lineEnd(p, i, end)
            if le - i >= 10 && p[i + 8] == 0x3A {
                out.add(i, i + 9, .comment)
                if le - i > 51 { out.add(i + 51, le, .string) }
            }
            i = le + 1
        }
    }
}
