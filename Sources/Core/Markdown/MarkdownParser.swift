import Darwin

/// Markdown source -> MarkdownDocument (rendered text + runs + blocks).
public enum MarkdownParser {
    public static func parse(_ src: TextBuffer) -> MarkdownDocument {
        // Working buffers for both passes in one stack allocation (falls back to the heap if
        // the stack is short); buffers that outgrow it move to the heap.
        withUnsafeTemporaryAllocation(byteCount: 12 << 10 + min(2 * src.count, 48 << 10), alignment: 16) { buf in
            var arena = Arena(buf)
            let inl = InlineParser(sourceCount: src.count, &arena)
            let bp = BlockParser(UnsafePointer(src.base), src.count, inl, &arena)
            return parse(bp, inl)
        }
    }

    static func parse(_ bp: BlockParser, _ inl: InlineParser) -> MarkdownDocument {
        let p = bp.p
        bp.run()
        var blocks: [MDBlock] = []
        blocks.reserveCapacity(bp.blocks.count)
        var tables: [MDTable] = []
        var headings: [MDHeading] = []
        var headingCount = 0
        for k in 0..<bp.blocks.count where bp.blocks[k].kind == .heading { headingCount += 1 }
        headings.reserveCapacity(headingCount)

        for bi in 0..<bp.blocks.count {
            let pb = bp.blocks[bi]
            var b = MDBlock(kind: pb.kind)
            b.level = pb.level
            b.quoteDepth = pb.quoteDepth
            b.listDepth = pb.listDepth
            b.marker = pb.marker
            b.markerNumber = pb.markerNumber
            b.tight = isTight(bp, pb, bi)
            b.textStart = Int32(inl.out.count)
            b.runStart = Int32(inl.runs.count)
            let lines = bp.lines.p + 2 * Int(pb.lineStart)
            switch pb.kind {
            case .paragraph, .heading:
                var (s, n) = inl.joinLines(p, lines, Int(pb.lineCount), trailingNewline: false)
                // Trailing whitespace of the last line is never significant.
                while n > 0 && (s[n - 1] == 0x20 || s[n - 1] == 0x09) { n -= 1 }
                inl.blockAlign = inl.alignStack.last ?? .left
                inl.blockHeading = 0
                inl.parse(s, n)
                b.align = inl.blockAlign
            case .html:
                let (s, n) = inl.joinLines(p, lines, Int(pb.lineCount), trailingNewline: false)
                inl.blockAlign = inl.alignStack.last ?? .left
                inl.blockHeading = 0
                inl.sawRule = false
                inl.parse(s, n)
                trimTrailingWhitespace(inl, from: Int(b.textStart))
                trimLeadingWhitespace(inl, from: Int(b.textStart), runsFrom: Int(b.runStart))
                b.align = inl.blockAlign
                if inl.blockHeading > 0 { b.kind = .heading; b.level = inl.blockHeading }
                else { b.kind = .paragraph }
                if inl.out.count == Int(b.textStart) {
                    if inl.sawRule { b.kind = .rule } else { continue }   // comments-only block
                }
            case .code:
                // Straight into the rendered text.
                for k in 0..<Int(pb.lineCount) {
                    let s = Int(lines[2 * k]), e = Int(lines[2 * k + 1])
                    if k > 0 { inl.out.append(0x0A) }
                    if e > s { inl.out.appendPadded(p + s, e - s) }
                }
                if pb.infoEnd > pb.infoStart {
                    // First word of the info string ("swift", "js {.line-numbers}", "rust,ignore").
                    var a = Int(pb.infoStart)
                    let ie = Int(pb.infoEnd)
                    while a < ie && (p[a] == 0x20 || p[a] == 0x7B || p[a] == 0x2C) { a += 1 }
                    var z = a
                    while z < ie && p[z] != 0x20 && p[z] != 0x7B && p[z] != 0x2C { z += 1 }
                    b.language = Language.named(p + a, z - a) ?? .plain
                    b.output = z - a == 6 && p[a] == 0x6F && p[a + 1] == 0x75 && p[a + 2] == 0x74
                        && p[a + 3] == 0x70 && p[a + 4] == 0x75 && p[a + 5] == 0x74   // "output"
                }
            case .rule:
                break
            case .table:
                b.table = Int32(tables.count)
                tables.append(table(bp, pb, inl))
            case .footnote:
                break
            }
            b.textEnd = Int32(inl.out.count)
            b.runEnd = Int32(inl.runs.count)
            if b.kind == .heading {
                let title = inl.out.string(Int(b.textStart), Int(b.textEnd))
                b.heading = Int32(headings.count)
                headings.append(MDHeading(level: Int(b.level), title: headingTitle(title, b, inl),
                                          block: blocks.count))
            }
            inl.out.append(0x0A)   // block separator
            blocks.append(b)
        }
        let doc = inl.finish()
        doc.blocks = blocks
        doc.tables = tables
        doc.headings = headings
        return doc
    }

    /// Heading text for the outline: images contribute their alt text; leading/trailing
    /// spaces and line breaks (`<br>`) are trimmed.
    static func headingTitle(_ title: String, _ b: MDBlock, _ inl: InlineParser) -> String {
        // U+FFFC (image placeholder) is EF BF BC in UTF-8. Search the bytes: String.contains
        // is a generic Unicode search, and the Character walk below is slower than parsing the
        // heading. (Checking for any 0xEF byte also hit every emoji with a variation selector.)
        let p = inl.out.p + Int(b.textStart), n = Int(b.textEnd - b.textStart)
        if memmem(p, n, "\u{FFFC}", 3) == nil {
            // Only a space or newline byte at either end can make a " "/"\n" Character there.
            if n == 0 || (p[0] != 0x20 && p[0] != 0x0A && p[n - 1] != 0x20 && p[n - 1] != 0x0A) { return title }
            return title.trimmingSpaces()
        }
        var alts: [String] = []
        for r in Int(b.runStart)..<inl.runs.count {
            let run = inl.runs[r]
            if run.style.contains(.image) && run.start < b.textEnd {
                let a = inl.images[Int(run.ref)].alt
                alts.append(inl.strings.string(Int(a.start), Int(a.end)))
            }
        }
        var it = alts.makeIterator()
        var out = ""
        for ch in title { if ch == "\u{FFFC}" { out += it.next() ?? "" } else { out.append(ch) } }
        return out.trimmingSpaces()
    }

    /// "Tight" = no paragraph gap before this block: inside a tight list, except the first
    /// block of a list that doesn't itself sit in a tight list.
    static func isTight(_ bp: BlockParser, _ pb: PendingBlock, _ bi: Int) -> Bool {
        guard pb.list >= 0 else { return false }
        let l = bp.lists[Int(pb.list)]
        if l.loose { return false }
        if pb.firstInItem && Int(l.firstBlock) == bi {
            return l.parent >= 0 && !bp.lists[Int(l.parent)].loose
        }
        return true
    }

    static func trimTrailingWhitespace(_ inl: InlineParser, from start: Int) {
        while inl.out.count > start, inl.out.last == 0x20 || inl.out.last == 0x0A || inl.out.last == 0x09 {
            inl.out.count -= 1
        }
        let end = Int32(inl.out.count)
        while inl.runs.count > 0, inl.runs.last.end > end {
            if inl.runs.last.start >= end { inl.runs.removeLast() } else { inl.runs.last.end = end }
        }
    }

    /// HTML blocks collapse leading whitespace (e.g. "<p>\n  <img>").
    static func trimLeadingWhitespace(_ inl: InlineParser, from start: Int, runsFrom: Int) {
        var k = start
        let o = inl.out.p
        while k < inl.out.count, o[k] == 0x20 || o[k] == 0x0A || o[k] == 0x09 { k += 1 }
        let n = k - start
        if n == 0 { return }
        memmove(o + start, o + k, inl.out.count - k)
        inl.out.count -= n
        // Shift this block's runs, dropping any that became empty. (Earlier runs are untouched
        // and never empty.)
        var w = runsFrom
        for r in runsFrom..<inl.runs.count {
            var run = inl.runs[r]
            run.start = max(Int32(start), run.start - Int32(n))
            run.end -= Int32(n)
            if run.end > run.start { inl.runs[w] = run; w += 1 }
        }
        inl.runs.count = w
    }

    static func table(_ bp: BlockParser, _ pb: PendingBlock, _ inl: InlineParser) -> MDTable {
        let cols = Int(pb.alignCount)
        var cells: [MDCell] = []
        cells.reserveCapacity(cols * Int(pb.lineCount))
        let p = bp.p
        for r in 0..<Int(pb.lineCount) {
            let li = (Int(pb.lineStart) + r) * 2
            let parts = inl.splitCells(p, Int(bp.lines[li]), Int(bp.lines[li + 1]))
            for c in 0..<cols {
                if c > 0 { inl.out.append(0x09) }
                var cell = MDCell(textStart: Int32(inl.out.count), textEnd: 0, runStart: Int32(inl.runs.count), runEnd: 0)
                if c < parts {
                    var s = Int(inl.cells[2 * c]), e = Int(inl.cells[2 * c + 1])
                    while s < e && (p[s] == 0x20 || p[s] == 0x09) { s += 1 }
                    while e > s && (p[e - 1] == 0x20 || p[e - 1] == 0x09) { e -= 1 }
                    // `\|` inside cells is a literal pipe; the inline parser handles the escape.
                    inl.parse(p + s, e - s)
                }
                cell.textEnd = Int32(inl.out.count)
                cell.runEnd = Int32(inl.runs.count)
                cells.append(cell)
            }
            if r < Int(pb.lineCount) - 1 { inl.out.append(0x0A) }
        }
        let aligns = Array(UnsafeBufferPointer(start: bp.aligns.p + Int(pb.alignStart), count: cols))
        return MDTable(columns: cols, aligns: aligns, cells: cells)
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
