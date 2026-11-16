/// Markdown source -> MarkdownDocument (rendered text + runs + blocks).
public enum MarkdownParser {
    public static func parse(_ src: TextBuffer) -> MarkdownDocument {
        let p = UnsafePointer(src.base)
        let bp = BlockParser(p, src.count)
        bp.run()
        let ctx = InlineContext(refs: bp.refs)
        ctx.text.bytes.reserveCapacity(src.count)
        var blocks: [MDBlock] = []
        blocks.reserveCapacity(bp.blocks.count)
        var tables: [MDTable] = []
        var headings: [MDHeading] = []
        var slugs: [String: Int] = [:]
        var scratch: [UInt8] = []

        /// Content lines of a pending block joined by "\n" into `scratch`.
        func gather(_ b: PendingBlock) {
            scratch.removeAll(keepingCapacity: true)
            for k in 0..<Int(b.lineCount) {
                let li = (Int(b.lineStart) + k) * 2
                let s = Int(bp.lines[li]), e = Int(bp.lines[li + 1])
                if k > 0 { scratch.append(0x0A) }
                scratch.append(contentsOf: UnsafeBufferPointer(start: p + s, count: e - s))
            }
        }

        for (bi, pb) in bp.blocks.enumerated() {
            var b = MDBlock(kind: pb.kind)
            b.level = pb.level
            b.quoteDepth = pb.quoteDepth
            b.listDepth = pb.listDepth
            b.marker = pb.marker
            b.markerNumber = pb.markerNumber
            b.tight = isTight(bp, pb, bi)
            b.textStart = Int32(ctx.text.count)
            b.runStart = Int32(ctx.runs.count)
            switch pb.kind {
            case .paragraph, .heading:
                gather(pb)
                // Trailing whitespace of the last line is never significant.
                while let l = scratch.last, l == 0x20 || l == 0x09 { scratch.removeLast() }
                ctx.blockAlign = .left
                ctx.blockHeading = 0
                scratch.withUnsafeBufferPointer { InlineParser.parse($0.baseAddress ?? p, $0.count, ctx) }
                b.align = ctx.blockAlign
            case .html:
                gather(pb)
                ctx.blockAlign = .left
                ctx.blockHeading = 0
                ctx.sawRule = false
                scratch.withUnsafeBufferPointer { InlineParser.parse($0.baseAddress ?? p, $0.count, ctx) }
                trimTrailingWhitespace(ctx, from: Int(b.textStart))
                trimLeadingWhitespace(ctx, from: Int(b.textStart), runsFrom: Int(b.runStart))
                b.align = ctx.blockAlign
                if ctx.blockHeading > 0 { b.kind = .heading; b.level = ctx.blockHeading }
                else { b.kind = .paragraph }
                if ctx.text.count == Int(b.textStart) {
                    if ctx.sawRule { b.kind = .rule } else { continue }   // comments-only block
                }
            case .code:
                // Straight into the rendered text (no scratch copy).
                for k in 0..<Int(pb.lineCount) {
                    let li = (Int(pb.lineStart) + k) * 2
                    let s = Int(bp.lines[li]), e = Int(bp.lines[li + 1])
                    if k > 0 { ctx.text.append(0x0A) }
                    ctx.text.bytes.append(contentsOf: UnsafeBufferPointer(start: p + s, count: e - s))
                }
                if pb.info.1 > pb.info.0 {
                    // First word of the info string ("swift", "js {.line-numbers}", "rust,ignore").
                    var a = Int(pb.info.0)
                    let ie = Int(pb.info.1)
                    while a < ie && (p[a] == 0x20 || p[a] == 0x7B || p[a] == 0x2C) { a += 1 }
                    var z = a
                    while z < ie && p[z] != 0x20 && p[z] != 0x7B && p[z] != 0x2C { z += 1 }
                    b.language = Language.named(p + a, z - a) ?? .plain
                }
            case .rule:
                break
            case .table:
                b.table = Int32(tables.count)
                tables.append(table(bp, pb, ctx))
            case .footnote:
                break
            }
            b.textEnd = Int32(ctx.text.count)
            b.runEnd = Int32(ctx.runs.count)
            if b.kind == .heading {
                let title = String(decoding: ctx.text.bytes[Int(b.textStart)..<Int(b.textEnd)], as: UTF8.self)
                var slug = slugify(title)
                if let n = slugs[slug] { slugs[slug] = n + 1; slug += "-\(n + 1)" } else { slugs[slug] = 0 }
                b.heading = Int32(headings.count)
                headings.append(MDHeading(level: Int(b.level), title: headingTitle(title, b, ctx),
                                          slug: slug, block: blocks.count))
            }
            ctx.text.append(0x0A)   // block separator
            blocks.append(b)
        }
        let doc = MarkdownDocument(text: ctx.text.bytes.withUnsafeBytes { TextBuffer(copying: $0) })
        doc.blocks = blocks
        doc.runs = ctx.runs
        doc.links = ctx.links
        doc.images = ctx.images
        doc.tables = tables
        doc.headings = headings
        return doc
    }

    /// "Tight" = no paragraph gap before this block: inside a tight list, except the first
    /// block of a list that doesn't itself sit in a tight list.
    /// Heading text for the outline: images contribute their alt text.
    static func headingTitle(_ title: String, _ b: MDBlock, _ ctx: InlineContext) -> String {
        // U+FFFC (image placeholder) is EF BF BC in UTF-8; a byte scan is far cheaper than
        // String.contains (generic Unicode search).
        if !title.utf8.contains(0xEF) { return title }
        var alts = ctx.runs[Int(b.runStart)..<ctx.runs.count].filter { $0.style.contains(.image) && $0.start < b.textEnd }
            .map { ctx.images[Int($0.ref)].alt }.makeIterator()
        var out = ""
        for ch in title { if ch == "\u{FFFC}" { out += alts.next() ?? "" } else { out.append(ch) } }
        return out.trimmingSpaces()
    }

    static func isTight(_ bp: BlockParser, _ pb: PendingBlock, _ bi: Int) -> Bool {
        guard pb.list >= 0 else { return false }
        let l = bp.lists[Int(pb.list)]
        if l.loose { return false }
        if pb.firstInItem && l.firstBlock == bi {
            return l.parent >= 0 && !bp.lists[Int(l.parent)].loose
        }
        return true
    }

    static func trimTrailingWhitespace(_ ctx: InlineContext, from start: Int) {
        while ctx.text.count > start, let l = ctx.text.bytes.last, l == 0x20 || l == 0x0A || l == 0x09 {
            ctx.text.bytes.removeLast()
        }
        while let r = ctx.runs.last, Int(r.end) > ctx.text.count {
            if Int(r.start) >= ctx.text.count { ctx.runs.removeLast() } else { ctx.runs[ctx.runs.count - 1].end = Int32(ctx.text.count) }
        }
    }

    /// HTML blocks collapse leading whitespace (e.g. "<p>\n  <img>").
    static func trimLeadingWhitespace(_ ctx: InlineContext, from start: Int, runsFrom: Int) {
        var k = start
        while k < ctx.text.count, ctx.text.bytes[k] == 0x20 || ctx.text.bytes[k] == 0x0A || ctx.text.bytes[k] == 0x09 { k += 1 }
        let n = k - start
        if n == 0 { return }
        ctx.text.bytes.removeSubrange(start..<k)
        for r in runsFrom..<ctx.runs.count {
            ctx.runs[r].start = max(Int32(start), ctx.runs[r].start - Int32(n))
            ctx.runs[r].end -= Int32(n)
        }
        ctx.runs.removeAll { $0.end <= $0.start }
    }

    static func table(_ bp: BlockParser, _ pb: PendingBlock, _ ctx: InlineContext) -> MDTable {
        let cols = pb.aligns.count
        var cells: [MDCell] = []
        let p = bp.p
        for r in 0..<Int(pb.lineCount) {
            let li = (Int(pb.lineStart) + r) * 2
            let parts = InlineParser.splitCells(p, Int(bp.lines[li]), Int(bp.lines[li + 1]))
            for c in 0..<cols {
                if c > 0 { ctx.text.append(0x09) }
                var cell = MDCell(textStart: Int32(ctx.text.count), textEnd: 0, runStart: Int32(ctx.runs.count), runEnd: 0)
                if c < parts.count {
                    var (s, e) = parts[c]
                    while s < e && (p[s] == 0x20 || p[s] == 0x09) { s += 1 }
                    while e > s && (p[e - 1] == 0x20 || p[e - 1] == 0x09) { e -= 1 }
                    // `\|` inside cells is a literal pipe; the inline parser handles the escape.
                    InlineParser.parse(p + s, e - s, ctx)
                }
                cell.textEnd = Int32(ctx.text.count)
                cell.runEnd = Int32(ctx.runs.count)
                cells.append(cell)
            }
            if r < Int(pb.lineCount) - 1 { ctx.text.append(0x0A) }
        }
        return MDTable(columns: cols, aligns: pb.aligns, cells: cells)
    }

    /// GitHub-style heading anchor: lowercase, drop punctuation except - and _, spaces -> -.
    public static func slugify(_ s: String) -> String {
        // ASCII fast path on bytes (headings are almost always ASCII); Character iteration
        // does a Unicode property lookup per character.
        var bytes: [UInt8] = []
        bytes.reserveCapacity(s.utf8.count)
        for c in s.utf8 {
            switch c {
            case 0x41...0x5A: bytes.append(c | 0x20)
            case 0x61...0x7A, 0x30...0x39, 0x2D, 0x5F: bytes.append(c)
            case 0x20: bytes.append(0x2D)
            case 0x80...: return slugifyUnicode(s)
            default: break
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func slugifyUnicode(_ s: String) -> String {
        var out = ""
        for ch in s.lowercased() {
            if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" { out.append(ch) }
            else if ch == " " { out.append("-") }
        }
        return out
    }
}

extension String {
    func trimmingSpaces() -> String {
        var s = Substring(self)
        while let f = s.first, f == " " || f == "\n" { s = s.dropFirst() }
        while let l = s.last, l == " " || l == "\n" { s = s.dropLast() }
        return String(s)
    }
}
