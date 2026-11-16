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
                gather(pb)
                ctx.text.bytes.append(contentsOf: scratch)
                if pb.info.1 > pb.info.0 {
                    let info = String(decoding: UnsafeBufferPointer(start: p + Int(pb.info.0), count: Int(pb.info.1 - pb.info.0)), as: UTF8.self)
                    let lang = info.split(whereSeparator: { $0 == " " || $0 == "{" || $0 == "," }).first.map(String.init) ?? ""
                    b.language = Language.named(lang) ?? .plain
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
                headings.append(MDHeading(level: Int(b.level), title: String(title.filter { $0 != "\u{FFFC}" }),
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
        var out = ""
        for ch in s.lowercased() {
            if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" { out.append(ch) }
            else if ch == " " { out.append("-") }
        }
        return out
    }
}
