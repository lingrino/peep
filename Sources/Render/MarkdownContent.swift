import AppKit
import CoreText

/// Rendered markdown: blocks laid out top to bottom with Core Text (TextBox per paragraph,
/// heading, code block and table cell) plus drawn decorations (rules, quote bars, list
/// markers, code backgrounds, table grid). Text colors are baked into the attributed strings,
/// so an appearance change re-runs layout (cheap); decorations look colors up at draw time.
@MainActor
public final class MarkdownContent: DocumentContent {
    public let doc: MarkdownDocument
    public var text: TextBuffer { doc.text }
    public let gutterWidth: CGFloat = 0
    public private(set) var size = CGSize.zero
    let baseDir: URL?
    var palette: Palette = .light
    private var width: CGFloat = 0
    let images: ImageStore

    // Metrics (points). Body size follows the user's preference (Peek used 12-13).
    let body: CGFloat = 13
    var gap: CGFloat { body * 0.95 }                 // between blocks
    var tightGap: CGFloat { body * 0.25 }            // between items of a tight list
    let maxWidth: CGFloat = 880
    let padX: CGFloat = 28
    let padTop: CGFloat = 22
    let listIndent: CGFloat = 24
    let quoteIndent: CGFloat = 18
    let codePad: CGFloat = 12

    struct LBlock {
        var y: CGFloat
        var h: CGFloat
        var box0: Int
        var boxN: Int
    }

    enum Role { case border, blockBackground, secondary, text, accent }
    enum Deco {
        case fill(CGRect, Role, CGFloat)
        case stroke(CGRect, Role, CGFloat)
        case line(CGRect, Role)
        case bullet(CGPoint, Int)                 // center, depth
        case label(CTLine, CGPoint)               // ordered list number, right-aligned origin
        case check(CGRect, Bool)
    }

    private(set) var blocks: [LBlock] = []
    private(set) var boxes: [TextBox] = []
    private var decos: [(minY: CGFloat, maxY: CGFloat, deco: Deco)] = []
    private(set) var headingY: [CGFloat] = []

    /// Called when async work (images) needs a relayout.
    public var onNeedsLayout: (() -> Void)?

    public init(doc: MarkdownDocument, baseDir: URL?) {
        self.doc = doc
        self.baseDir = baseDir
        images = ImageStore(doc.images, baseDir: baseDir)
        images.onLoad = { [weak self] in self?.onNeedsLayout?() }
    }

    public func setPalette(_ p: Palette) -> Bool {
        if p === palette { return false }
        palette = p
        images.dark = p.isDark
        if width > 0 { relayout() }
        return true
    }

    public func layout(width w: CGFloat) -> Bool {
        if w == width && !blocks.isEmpty { return false }
        width = w
        relayout()
        return true
    }

    // MARK: - Layout

    func relayout() {
        images.start()
        blocks.removeAll(keepingCapacity: true)
        boxes.removeAll(keepingCapacity: true)
        decos.removeAll(keepingCapacity: true)
        headingY = [CGFloat](repeating: 0, count: doc.headings.count)
        let contentW = min(maxWidth, max(200, width - 2 * padX))
        let x0 = max(padX, ((width - contentW) / 2).rounded())
        var y = padTop
        var maxRight = x0 + contentW
        var prevQuote: UInt8 = 0
        for (bi, b) in doc.blocks.enumerated() {
            let indent = CGFloat(b.quoteDepth) * quoteIndent + CGFloat(b.listDepth) * listIndent
            let bx = x0 + indent
            let bw = max(60, contentW - indent)
            if bi > 0 {
                var g = b.tight ? tightGap : gap
                if b.kind == .heading { g = max(g, body * (b.level <= 2 ? 1.9 : 1.5)) }
                y += g
            }
            let top = y
            let box0 = boxes.count
            switch b.kind {
            case .paragraph, .html, .footnote:
                let a = inline(b.textStart, b.textEnd, runs: b.runStart..<b.runEnd, font: font(body),
                               color: b.quoteDepth > 0 ? palette.secondaryText : palette.text, align: b.align)
                let box = TextBox(attributed: a, origin: CGPoint(x: bx, y: y), width: bw, start: Int(b.textStart),
                                  end: Int(b.textEnd), text: doc.text, lineGap: lineGap(body))
                boxes.append(box)
                y = box.rect.maxY
            case .heading:
                let size = headingSize(b.level)
                let a = inline(b.textStart, b.textEnd, runs: b.runStart..<b.runEnd,
                               font: font(size, weight: .semibold),
                               color: b.level == 6 ? palette.secondaryText : palette.text, align: b.align, lineHeight: 1.25)
                let box = TextBox(attributed: a, origin: CGPoint(x: bx, y: y), width: bw, start: Int(b.textStart),
                                  end: Int(b.textEnd), text: doc.text, lineGap: lineGap(size, 1.25))
                boxes.append(box)
                y = box.rect.maxY
                if b.heading >= 0 { headingY[Int(b.heading)] = top }
                if b.level <= 2 {
                    y += body * 0.45
                    decos.append((y, y + 1, .line(CGRect(x: bx, y: y, width: bw, height: 1), .border)))
                    y += 1
                }
            case .code:
                let a = code(b)
                let box = TextBox(attributed: a, origin: CGPoint(x: bx + codePad, y: y + codePad), width: bw - 2 * codePad,
                                  start: Int(b.textStart), end: Int(b.textEnd), text: doc.text, lineGap: lineGap(codeSize, 1.45))
                let bg = CGRect(x: bx, y: y, width: bw, height: box.rect.height + 2 * codePad)
                decos.append((bg.minY, bg.maxY, .fill(bg, .blockBackground, 6)))
                boxes.append(box)
                y = bg.maxY
            case .rule:
                y += body * 0.4
                decos.append((y, y + 2, .fill(CGRect(x: bx, y: y, width: bw, height: 2), .border, 1)))
                y += 2 + body * 0.4
            case .table:
                y = table(Int(b.table), x: bx, y: y, width: bw, right: &maxRight)
            }

            // List marker beside the block's first line.
            if b.marker != .none, let first = boxes.indices.contains(box0) ? boxes[box0] : nil, boxes.count > box0 {
                let base = first.baselines.first ?? (top + body)
                let mx = bx - 8
                switch b.marker {
                case .bullet:
                    decos.append((base - body, base, .bullet(CGPoint(x: mx - 4, y: base - body * 0.32), Int(b.listDepth))))
                case .ordered:
                    let l = CTLineCreateWithAttributedString(NSAttributedString(string: "\(b.markerNumber).", attributes: [
                        .font: font(body), .foregroundColor: palette.secondaryText]))
                    decos.append((base - body, base + 4, .label(l, CGPoint(x: mx, y: base))))
                case .taskOpen, .taskDone:
                    let s = body * 0.95
                    decos.append((base - s, base, .check(CGRect(x: mx - s, y: base - s * 0.88, width: s, height: s), b.marker == .taskDone)))
                case .none: break
                }
            } else if b.marker != .none {
                // Empty list item: marker on its own line.
                let base = y + body
                if b.marker == .bullet { decos.append((y, base, .bullet(CGPoint(x: bx - 12, y: base - body * 0.32), Int(b.listDepth)))) }
                y += body * 1.4
            }

            // Quote bars span the block and the gap above it when the previous block was quoted too.
            if b.quoteDepth > 0 {
                for q in 0..<Int(b.quoteDepth) {
                    let qx = x0 + CGFloat(q) * quoteIndent + CGFloat(b.listDepth) * 0
                    let from = q < Int(prevQuote) && bi > 0 ? top - (b.tight ? tightGap : gap) : top
                    decos.append((from, y, .fill(CGRect(x: qx, y: from, width: 3, height: y - from), .border, 1.5)))
                }
            }
            prevQuote = b.quoteDepth
            blocks.append(LBlock(y: top, h: y - top, box0: box0, boxN: boxes.count - box0))
        }
        size = CGSize(width: max(width, maxRight + padX), height: y + padTop * 1.5)
        decos.sort { $0.minY < $1.minY }
    }

    var codeSize: CGFloat { (body * 0.88).rounded() + 0.5 }

    func headingSize(_ level: UInt8) -> CGFloat {
        switch level {
        case 1: return (body * 1.9).rounded()
        case 2: return (body * 1.5).rounded()
        case 3: return (body * 1.25).rounded()
        case 4: return body + 1
        case 5: return body
        default: return body - 0.5
        }
    }

    func lineGap(_ size: CGFloat, _ multiple: CGFloat = 1.5) -> CGFloat { size * (multiple - 1.2) }

    // MARK: - Fonts

    private var fontCache: [Int: NSFont] = [:]

    /// Fonts keyed by size/weight/italic/mono (a handful per document).
    func font(_ size: CGFloat, weight: NSFont.Weight = .regular, italic: Bool = false, mono: Bool = false) -> NSFont {
        let key = Int(size * 4) << 8 | Int((weight.rawValue + 1) * 10) << 2 | (italic ? 2 : 0) | (mono ? 1 : 0)
        if let f = fontCache[key] { return f }
        var f = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        if italic {
            let d = f.fontDescriptor.withSymbolicTraits(.italic)
            f = NSFont(descriptor: d, size: size) ?? f
        }
        fontCache[key] = f
        return f
    }

    // MARK: - Attributed strings

    /// Rich text for `[start, end)` of the rendered text with the given runs applied.
    func inline(_ start: Int32, _ end: Int32, runs: Range<Int32>, font base: NSFont, color: CGColor,
                align: MDAlign, lineHeight: CGFloat = 1.5) -> NSAttributedString {
        let s = doc.text.string(Int(start), Int(end))
        let ps = NSMutableParagraphStyle()
        ps.lineHeightMultiple = lineHeight
        ps.alignment = align == .center ? .center : align == .right ? .right : .natural
        let a = NSMutableAttributedString(string: s, attributes: [.font: base, .foregroundColor: color, .paragraphStyle: ps])
        let map = Utf16Map(doc.text, Int(start), Int(end))
        let size = base.pointSize
        let weight: NSFont.Weight = (base.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any])?[.weight]
            .flatMap { $0 as? CGFloat }.map { NSFont.Weight($0) } ?? .regular
        for ri in runs {
            let r = doc.runs[Int(ri)]
            let range = NSRange(location: map[Int(r.start)], length: map[Int(r.end)] - map[Int(r.start)])
            if range.length <= 0 { continue }
            let st = r.style
            if st.contains(.image) {
                let (w, h) = images.size(Int(r.ref), maxWidth: max(40, width - 2 * padX))
                a.addAttribute(kCTRunDelegateAttributeName as NSAttributedString.Key, value: runDelegate(width: w, ascent: h), range: range)
                a.addAttribute(MDAttr.image, value: Int(r.ref), range: range)
                a.addAttribute(.foregroundColor, value: CGColor.clear, range: range)
                continue
            }
            var f = base
            if st.contains(.code) || st.contains(.kbd) {
                f = font((size * 0.88).rounded() + 0.5, weight: st.contains(.strong) ? .semibold : .regular, mono: true)
                a.addAttribute(st.contains(.kbd) ? MDAttr.kbd : MDAttr.inlineCode, value: true, range: range)
            } else if st.contains(.strong) || st.contains(.emphasis) || st.contains(.superscript) || st.contains(.subscriptStyle) {
                let sz = st.contains(.superscript) || st.contains(.subscriptStyle) ? size * 0.75 : size
                f = font(sz, weight: st.contains(.strong) ? .semibold : weight, italic: st.contains(.emphasis))
            }
            a.addAttribute(.font, value: f, range: range)
            // Baseline offsets are negated: we draw in a flipped context (text matrix y = -1),
            // where Core Text's "up" offset lands below the baseline.
            if st.contains(.superscript) { a.addAttribute(ctBaselineOffset, value: -size * 0.38, range: range) }
            if st.contains(.subscriptStyle) { a.addAttribute(ctBaselineOffset, value: size * 0.18, range: range) }
            if st.contains(.strike) { a.addAttribute(MDAttr.strike, value: true, range: range) }
            if st.contains(.link) {
                a.addAttribute(.foregroundColor, value: palette.link, range: range)
                a.addAttribute(MDAttr.link, value: Int(r.ref), range: range)
            }
        }
        return a
    }

    /// Code block: monospaced, syntax colored with the same lexers as code previews.
    func code(_ b: MDBlock) -> NSAttributedString {
        let s = doc.text.string(Int(b.textStart), Int(b.textEnd))
        let f = font(codeSize, mono: true)
        let bold = font(codeSize, weight: .semibold, mono: true)
        let ps = NSMutableParagraphStyle()
        ps.lineHeightMultiple = 1.45
        ps.defaultTabInterval = 4 * (" " as NSString).size(withAttributes: [.font: f]).width
        ps.tabStops = []
        let a = NSMutableAttributedString(string: s, attributes: [.font: f, .foregroundColor: palette.text, .paragraphStyle: ps])
        if b.language != .plain && b.textEnd > b.textStart {
            let tokens = TokenStream(expectedBytes: Int(b.textEnd - b.textStart))
            // Lex in place: the text after the block is "\n", which ends every token cleanly.
            b.language.lex(doc.text.base, Int(b.textStart), Int(b.textEnd), tokens)
            let map = Utf16Map(doc.text, Int(b.textStart), Int(b.textEnd))
            var k = tokens.first(after: Int(b.textStart))
            while k < tokens.count && tokens.start(k) < Int(b.textEnd) {
                let kind = tokens.kinds[k]
                if kind != 0 {
                    let ts = max(tokens.start(k), Int(b.textStart)), te = min(tokens.end(k), Int(b.textEnd))
                    let range = NSRange(location: map[ts], length: map[te] - map[ts])
                    a.addAttribute(.foregroundColor, value: palette.tokenColors[Int(kind)], range: range)
                    if palette.tokenBold[Int(kind)] { a.addAttribute(.font, value: bold, range: range) }
                }
                k += 1
            }
        }
        return a
    }

    private func runDelegate(width: CGFloat, ascent: CGFloat) -> CTRunDelegate {
        let p = UnsafeMutablePointer<CGSize>.allocate(capacity: 1)
        p.initialize(to: CGSize(width: width, height: ascent))
        var cb = CTRunDelegateCallbacks(version: kCTRunDelegateVersion1, dealloc: { $0.deallocate() },
                                        getAscent: { $0.assumingMemoryBound(to: CGSize.self).pointee.height },
                                        getDescent: { _ in 0 },
                                        getWidth: { $0.assumingMemoryBound(to: CGSize.self).pointee.width })
        return CTRunDelegateCreate(&cb, p)!
    }

    // MARK: - Tables

    private func table(_ ti: Int, x: CGFloat, y: CGFloat, width: CGFloat, right: inout CGFloat) -> CGFloat {
        let t = doc.tables[ti]
        let cols = t.columns, rows = t.rows
        if cols == 0 || rows == 0 { return y }
        let padH: CGFloat = 12, padV: CGFloat = 6
        let headerFont = font(body, weight: .semibold), cellFont = font(body)
        // Attributed strings and natural (single-line) widths.
        var strings: [NSAttributedString] = []
        var natural = [CGFloat](repeating: 40, count: cols)
        for (i, c) in t.cells.enumerated() {
            let a = inline(c.textStart, c.textEnd, runs: c.runStart..<c.runEnd, font: i < cols ? headerFont : cellFont,
                           color: palette.text, align: t.aligns[i % cols], lineHeight: 1.35)
            strings.append(a)
            let line = CTLineCreateWithAttributedString(a)
            natural[i % cols] = max(natural[i % cols], CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) + 2 * padH + 1)
        }
        // Fit: natural widths if they fit, else shrink wide columns proportionally (min 80).
        var widths = natural
        let total = natural.reduce(0, +)
        if total > width {
            let minW: CGFloat = 80
            let flexible = natural.map { max(0, $0 - minW) }.reduce(0, +)
            let excess = total - width
            for c in 0..<cols where natural[c] > minW {
                widths[c] = natural[c] - excess * (natural[c] - minW) / max(1, flexible)
                widths[c] = max(minW, widths[c].rounded(.down))
            }
        }
        let tableW = widths.reduce(0, +)
        right = max(right, x + tableW)
        var rowY = y
        for r in 0..<rows {
            var cx = x
            var rowH: CGFloat = 0
            let first = boxes.count
            for c in 0..<cols {
                let i = r * cols + c
                let cell = t.cells[i]
                let box = TextBox(attributed: strings[i], origin: CGPoint(x: cx + padH, y: rowY + padV),
                                  width: widths[c] - 2 * padH, start: Int(cell.textStart), end: Int(cell.textEnd),
                                  text: doc.text, lineGap: lineGap(body, 1.35))
                boxes.append(box)
                rowH = max(rowH, box.rect.height + 2 * padV)
                cx += widths[c]
            }
            _ = first
            let rowRect = CGRect(x: x, y: rowY, width: tableW, height: rowH)
            if r == 0 || r % 2 == 0 {
                decos.append((rowRect.minY, rowRect.maxY, .fill(rowRect, .blockBackground, 0)))
            }
            // Grid lines.
            decos.append((rowRect.maxY - 0.5, rowRect.maxY + 0.5, .line(CGRect(x: x, y: rowRect.maxY - 0.5, width: tableW, height: 1), .border)))
            var vx = x
            for c in 0...cols {
                decos.append((rowRect.minY, rowRect.maxY, .line(CGRect(x: vx - 0.5, y: rowRect.minY, width: 1, height: rowH), .border)))
                if c < cols { vx += widths[c] }
            }
            rowY += rowH
        }
        decos.append((y - 0.5, y + 0.5, .line(CGRect(x: x, y: y - 0.5, width: tableW, height: 1), .border)))
        return rowY
    }

    // MARK: - Drawing

    public func draw(_ ctx: CGContext, rect: CGRect, palette: Palette, highlights: Highlights) {
        // Decorations (sorted by minY; skip those that end above the rect).
        for d in decos {
            if d.minY > rect.maxY { break }
            if d.maxY < rect.minY { continue }
            drawDeco(d.deco, ctx, palette)
        }
        // Text boxes of blocks intersecting the rect.
        var bi = firstBlock(atOrBelow: rect.minY)
        while bi < blocks.count && blocks[bi].y <= rect.maxY {
            let b = blocks[bi]
            for k in b.box0..<(b.box0 + b.boxN) {
                boxes[k].draw(ctx, rect: rect, palette: palette, highlights: highlights, content: self)
            }
            bi += 1
        }
    }

    private func drawDeco(_ d: Deco, _ ctx: CGContext, _ p: Palette) {
        func color(_ r: Role) -> CGColor {
            switch r {
            case .border: p.border
            case .blockBackground: p.blockBackground
            case .secondary: p.secondaryText
            case .text: p.text
            case .accent: p.link
            }
        }
        switch d {
        case .fill(let r, let role, let radius):
            ctx.setFillColor(color(role))
            if radius > 0 {
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
                ctx.fillPath()
            } else { ctx.fill(r) }
        case .stroke(let r, let role, let radius):
            ctx.setStrokeColor(color(role))
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.strokePath()
        case .line(let r, let role):
            ctx.setFillColor(color(role))
            ctx.fill(r)
        case .bullet(let c, let depth):
            let r: CGFloat = 2.6
            let rect = CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)
            ctx.setFillColor(p.secondaryText)
            ctx.setStrokeColor(p.secondaryText)
            switch (depth - 1) % 3 {
            case 0: ctx.fillEllipse(in: rect)
            case 1: ctx.setLineWidth(1); ctx.strokeEllipse(in: rect.insetBy(dx: 0.5, dy: 0.5))
            default: ctx.fill(rect.insetBy(dx: 0.3, dy: 0.3))
            }
        case .label(let line, let origin):
            let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            ctx.textPosition = CGPoint(x: origin.x - w, y: origin.y)
            CTLineDraw(line, ctx)
        case .check(let r, let done):
            let path = CGPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 3, cornerHeight: 3, transform: nil)
            if done {
                ctx.setFillColor(NSColor.controlAccentColor.cgColor)
                ctx.addPath(path)
                ctx.fillPath()
                ctx.setStrokeColor(.white)
                ctx.setLineWidth(1.6)
                ctx.setLineCap(.round)
                ctx.setLineJoin(.round)
                ctx.move(to: CGPoint(x: r.minX + r.width * 0.25, y: r.minY + r.height * 0.52))
                ctx.addLine(to: CGPoint(x: r.minX + r.width * 0.43, y: r.minY + r.height * 0.70))
                ctx.addLine(to: CGPoint(x: r.minX + r.width * 0.76, y: r.minY + r.height * 0.32))
                ctx.strokePath()
            } else {
                ctx.setStrokeColor(p.secondaryText)
                ctx.setLineWidth(1)
                ctx.addPath(path)
                ctx.strokePath()
            }
        }
    }

    func drawImage(_ index: Int, in r: CGRect, ctx: CGContext) {
        guard let img = images.image(index) else {
            ctx.setFillColor(palette.blockBackground)
            ctx.fill(r)
            return
        }
        // The context is flipped: draw the CGImage upside down so it appears upright.
        ctx.saveGState()
        ctx.translateBy(x: r.minX, y: r.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
        ctx.restoreGState()
    }

    // MARK: - Geometry queries

    /// First block whose bottom is at or below y.
    func firstBlock(atOrBelow y: CGFloat) -> Int {
        var lo = 0, hi = blocks.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if blocks[mid].y + blocks[mid].h < y { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Box containing a text offset (boxes are in text order).
    func box(containing o: Int) -> Int? {
        var lo = 0, hi = boxes.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if boxes[mid].end < o { lo = mid + 1 } else { hi = mid }
        }
        return lo < boxes.count ? lo : (boxes.isEmpty ? nil : boxes.count - 1)
    }

    public func offset(at p: CGPoint) -> Int {
        if boxes.isEmpty { return 0 }
        let bi = firstBlock(atOrBelow: p.y)
        if bi >= blocks.count { return text.count }
        let b = blocks[bi]
        if b.boxN == 0 {
            // Rule or empty block: snap to the next box.
            return boxes.indices.first { boxes[$0].rect.minY >= b.y }.map { boxes[$0].start } ?? text.count
        }
        if p.y < b.y { return boxes[b.box0].start }
        // Nearest box in the block (tables: the cell under the point).
        var best = b.box0
        var bestD = CGFloat.infinity
        for k in b.box0..<(b.box0 + b.boxN) {
            let r = boxes[k].rect
            let dx = p.x < r.minX ? r.minX - p.x : p.x > r.maxX ? p.x - r.maxX : 0
            let dy = p.y < r.minY ? r.minY - p.y : p.y > r.maxY ? p.y - r.maxY : 0
            let d = dx + dy * 4
            if d < bestD { bestD = d; best = k }
        }
        return boxes[best].offset(at: p)
    }

    public func rect(for start: Int, _ end: Int) -> CGRect {
        guard let k = box(containing: start) else { return .zero }
        return boxes[k].rect(for: start, end)
    }

    public func verticalExtent(_ start: Int, _ end: Int) -> (CGFloat, CGFloat) {
        guard let a = box(containing: start), let b = box(containing: max(start, end)) else { return (0, size.height) }
        // Table rows share a y-band: widen to the containing blocks.
        let ya = boxes[a].rect.minY, yb = boxes[b].rect.maxY
        let ba = firstBlock(atOrBelow: ya), bb = firstBlock(atOrBelow: yb)
        let top = ba < blocks.count ? min(ya, blocks[ba].y) : ya
        let bottom = bb < blocks.count ? max(yb, blocks[bb].y + blocks[bb].h) : yb
        return (top - 2, bottom + 2)
    }

    public func wordRange(at o: Int) -> (Int, Int) {
        let p = text.base
        let n = text.count
        if o >= n { return (n, n) }
        let cc = ByteClass.standard
        var a = o, b = o
        if cc.isIdent(p[o]) {
            while a > 0 && cc.isIdent(p[a - 1]) { a -= 1 }
            while b < n && cc.isIdent(p[b]) { b += 1 }
        } else {
            b = o + 1
            while b < n && p[b] & 0xC0 == 0x80 { b += 1 }
        }
        return (a, b)
    }

    public func lineRange(at o: Int) -> (Int, Int) {
        guard let k = box(containing: o) else { return (o, o) }
        return (boxes[k].start, min(text.count, boxes[k].end + 1))
    }

    public func copyText(_ start: Int, _ end: Int) -> String {
        // Images copy as their alt text.
        var s = text.string(start, end)
        if s.contains("\u{FFFC}") {
            var out = ""
            var img = doc.runs.filter { $0.style.contains(.image) && Int($0.start) >= start && Int($0.end) <= end }.makeIterator()
            for ch in s {
                if ch == "\u{FFFC}" { out += img.next().map { doc.images[Int($0.ref)].alt } ?? "" } else { out.append(ch) }
            }
            s = out
        }
        return s
    }

    public func link(at p: CGPoint) -> String? {
        let bi = firstBlock(atOrBelow: p.y)
        guard bi < blocks.count else { return nil }
        let b = blocks[bi]
        for k in b.box0..<(b.box0 + b.boxN) where boxes[k].rect.insetBy(dx: -2, dy: -2).contains(p) {
            if let run = boxes[k].run(at: p), let idx = (CTRunGetAttributes(run) as NSDictionary)[MDAttr.link] as? Int {
                return doc.links[idx]
            }
        }
        return nil
    }

    public func anchorY(_ name: String) -> CGFloat? {
        let n = name.hasPrefix("#") ? String(name.dropFirst()) : name
        let key = n.removingPercentEncoding ?? n
        guard let i = doc.headings.firstIndex(where: { $0.slug == key || $0.slug == key.lowercased() }) else { return nil }
        return headingY[i]
    }
}

let ctBaselineOffset = NSAttributedString.Key(kCTBaselineOffsetAttributeName as String)

/// UTF-8 offset -> UTF-16 index within a range (identity for ASCII ranges).
struct Utf16Map {
    let start: Int
    let table: [Int]?

    init(_ text: TextBuffer, _ start: Int, _ end: Int) {
        self.start = start
        let p = text.base + start
        if UnsafePointer(p).isASCII(end - start) { table = nil; return }
        var t = [Int](repeating: 0, count: end - start + 1)
        var u = 0
        for i in 0..<(end - start) {
            t[i] = u
            let c = p[i]
            if c & 0xC0 != 0x80 { u += c >= 0xF0 ? 2 : 1 }
        }
        t[end - start] = u
        table = t
    }

    subscript(o: Int) -> Int { table.map { $0[o - start] } ?? (o - start) }
}
