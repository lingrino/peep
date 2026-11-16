/// Jupyter notebooks (.ipynb, nbformat 4) rendered through the Markdown pipeline: the
/// notebook becomes a Markdown document and gets everything Markdown has (outline, tables,
/// highlighted code, images, search).
///
/// - Markdown cells: as written.
/// - Code cells: fenced in the notebook's language (highlighted).
/// - Outputs: text as plain fenced blocks; PNG/JPEG/GIF/SVG plots as `data:` images; rich
///   text/markdown as Markdown; errors as the traceback with terminal colors removed.
///   HTML outputs (pandas tables) fall back to their text/plain form.
public enum Notebook {
    /// Nil when the JSON isn't an nbformat 4 notebook (the caller shows it as JSON).
    public static func markdown(_ json: TextBuffer) -> TextBuffer? {
        guard let t = JSONTree.parse(json), let cells = t.member(t.root, "cells") else { return nil }
        let meta = t.member(t.root, "metadata")
        let lang = t.string(t.member(t.member(meta, "language_info"), "name"))
            ?? t.string(t.member(t.member(meta, "kernelspec"), "language")) ?? "python"
        var out = ByteOutput(capacity: json.count + 1024)
        var scratch = ByteOutput(capacity: 1 << 16)
        for cell in t.elements(cells) {
            let type = t.string(t.member(cell, "cell_type")) ?? ""
            scratch.count = 0
            t.appendText(t.member(cell, "source"), to: &scratch)
            switch type {
            case "markdown":
                out.bytes(scratch.base, scratch.count)
                out.string("\n\n")
            case "code":
                fence(lang, scratch, &out)
                for o in t.elements(t.member(cell, "outputs")) { output(t, o, &out, &scratch) }
            default:   // raw
                if scratch.count > 0 { fence("", scratch, &out) }
            }
        }
        scratch.base.deallocate()
        return out.finish()
    }

    private static func output(_ t: JSONTree, _ o: Int32, _ out: inout ByteOutput, _ scratch: inout ByteOutput) {
        scratch.count = 0
        switch t.string(t.member(o, "output_type")) ?? "" {
        case "stream":
            t.appendText(t.member(o, "text"), to: &scratch)
            fence("output", scratch, &out)
        case "error":
            let name = t.string(t.member(o, "ename")) ?? "Error", value = t.string(t.member(o, "evalue")) ?? ""
            let tb = t.elements(t.member(o, "traceback"))
            if tb.isEmpty { scratch.string("\(name): \(value)") }
            for (i, line) in tb.enumerated() {
                if i > 0 { scratch.byte(0x0A) }
                t.appendString(line, to: &scratch)
            }
            stripANSI(&scratch)
            fence("output", scratch, &out)
        default:   // execute_result, display_data
            let data = t.member(o, "data")
            for (mime, ext) in [("image/png", "png"), ("image/jpeg", "jpeg"), ("image/gif", "gif")] {
                if let img = mimeMember(t, data, mime) {
                    out.string("![](data:image/\(ext);base64,")
                    appendBase64(t, img, &out)
                    out.string(")\n\n")
                    return
                }
            }
            if let svg = mimeMember(t, data, "image/svg+xml") {
                t.appendText(svg, to: &scratch)
                out.string("![](data:image/svg+xml;base64,")
                base64(scratch, &out)
                out.string(")\n\n")
                return
            }
            if let md = mimeMember(t, data, "text/markdown") {
                t.appendText(md, to: &out)
                out.string("\n\n")
                return
            }
            if let txt = mimeMember(t, data, "text/plain") {
                t.appendText(txt, to: &scratch)
                fence("output", scratch, &out)
            }
        }
    }

    /// `data[mime]` (mime types contain "/" and "+", so look them up by raw bytes).
    private static func mimeMember(_ t: JSONTree, _ data: Int32?, _ mime: String) -> Int32? {
        guard let data, data >= 0, t.kindOf(data) == .object else { return nil }
        var k = t.first[Int(data)]
        let m = Array(mime.utf8)
        while k >= 0 {
            let v = t.next[Int(k)]
            if t.raw(k).elementsEqual(m) { return v }
            k = v >= 0 ? t.next[Int(v)] : -1
        }
        return nil
    }

    /// A fenced block whose fence is longer than any backtick run inside it.
    private static func fence(_ info: String, _ body: ByteOutput, _ out: inout ByteOutput) {
        var run = 0, longest = 0
        for i in 0..<body.count {
            if body.base[i] == 0x60 { run += 1; longest = max(longest, run) } else { run = 0 }
        }
        let ticks = String(repeating: "`", count: max(3, longest + 1))
        out.string(ticks + info + "\n")
        var n = body.count
        while n > 0 && (body.base[n - 1] == 0x0A || body.base[n - 1] == 0x20) { n -= 1 }
        out.bytes(body.base, n)
        out.string("\n" + ticks + "\n\n")
    }

    /// Base64 from a JSON string or array of strings, without the line breaks notebooks
    /// put in it (a newline would end the Markdown link destination).
    private static func appendBase64(_ t: JSONTree, _ v: Int32, _ out: inout ByteOutput) {
        let parts = t.kindOf(v) == .array ? t.elements(v) : [v]
        for s in parts where t.kindOf(s) == .string {
            let r = t.raw(s)
            guard let p = r.baseAddress else { continue }
            if !t.isEscaped(s) { out.bytes(p, r.count); continue }
            var i = 0
            while i < r.count {
                if p[i] == 0x5C { i += 2; continue }   // \n and friends: never base64 data
                out.byte(p[i]); i += 1
            }
        }
    }

    private static func base64(_ b: ByteOutput, _ out: inout ByteOutput) {
        let a = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
        var i = 0
        let n = b.count, p = b.base
        while i + 3 <= n {
            let v = UInt32(p[i]) << 16 | UInt32(p[i + 1]) << 8 | UInt32(p[i + 2])
            out.byte(a[Int(v >> 18)]); out.byte(a[Int(v >> 12 & 63)]); out.byte(a[Int(v >> 6 & 63)]); out.byte(a[Int(v & 63)])
            i += 3
        }
        if n - i == 1 {
            let v = UInt32(p[i]) << 16
            out.byte(a[Int(v >> 18)]); out.byte(a[Int(v >> 12 & 63)]); out.string("==")
        } else if n - i == 2 {
            let v = UInt32(p[i]) << 16 | UInt32(p[i + 1]) << 8
            out.byte(a[Int(v >> 18)]); out.byte(a[Int(v >> 12 & 63)]); out.byte(a[Int(v >> 6 & 63)]); out.byte(0x3D)
        }
    }

    /// Removes terminal color sequences (ESC [ ... letter) in place.
    private static func stripANSI(_ b: inout ByteOutput) {
        var w = 0, r = 0
        let p = b.base
        while r < b.count {
            if p[r] == 0x1B && r + 1 < b.count && p[r + 1] == 0x5B {
                r += 2
                while r < b.count && !(p[r] >= 0x40 && p[r] <= 0x7E) { r += 1 }
                r += 1
                continue
            }
            p[w] = p[r]; w += 1; r += 1
        }
        b.count = w
    }
}
