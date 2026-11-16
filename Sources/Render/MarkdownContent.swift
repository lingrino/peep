import AppKit
import CoreText
import os

let renderLog = Logger(subsystem: "com.lingrino.peep", category: "render")

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
    let m = MDMetrics()
    let fonts = FontBook()

    struct LBlock {
        var y: CGFloat
        var h: CGFloat
        var box0: Int
        var boxN: Int
    }

    private(set) var blocks: [LBlock] = []
    private(set) var boxes: [TextBox] = []
    private var decos: [PlacedDeco] = []
    private(set) var headingY: [CGFloat] = []
    public private(set) var lastLayoutNanos: UInt64 = 0

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

    /// Progressive layout: blocks are laid out synchronously until ~two screens of content
    /// exist (first paint never waits for the whole document), the rest get estimated
    /// heights, and a background pass lays out everything in parallel and swaps it in.
    /// Queries that need exact geometry below the fold call `finishLayout()`.
    func relayout() {
        let t0 = nanotime()
        images.start()
        generation &+= 1
        let contentW = min(m.maxWidth, max(200, width - 2 * m.padX))
        let x0 = max(m.padX, ((width - contentW) / 2).rounded())
        let env = LayoutEnv(doc: doc, palette: palette, m: m, fonts: fonts,
                            imageSizes: images.sizes(maxWidth: max(40, contentW)), x0: x0, contentW: contentW)
        let n = doc.blocks.count
        var results = [BlockLayout]()
        results.reserveCapacity(n)
        var y: CGFloat = 0
        var k = 0
        while k < n && y < syncHeight {
            let r = MarkdownLayout.block(k, env)
            y += r.height + m.gap
            results.append(r)
            k += 1
        }
        if k == n {
            pending = nil
            stack(results, x0: x0)
            lastLayoutNanos = nanotime() - t0
            renderLog.debug("md layout w=\(self.width) all \(n) blocks \(Double(self.lastLayoutNanos) / 1e6)ms")
            return
        }
        for i in k..<n { results.append(MarkdownLayout.estimate(i, env)) }
        stack(results, x0: x0)
        lastLayoutNanos = nanotime() - t0
        renderLog.debug("md layout w=\(self.width) sync \(k)/\(n) blocks \(Double(self.lastLayoutNanos) / 1e6)ms")

        // Background: everything after the prefix, in parallel -- started after this main
        // thread turn, i.e. after the first frame is drawn. The layout threads hold Core
        // Text's per-font shaping lock most of the time; a first draw competing with them took
        // 21ms instead of ~3ms (900 KB changelog).
        let job = PendingLayout(first: k, count: n - k, x0: x0, prefix: results[0..<k], env: env)
        pending = job
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.start(job) } }
    }

    private func start(_ job: PendingLayout) {
        guard pending === job, !job.started else { return }
        job.started = true
        let gen = generation
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            job.run()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == gen, self.pending === job else { return }
                    self.adopt(job)
                    self.onLayoutChanged?()
                }
            }
        }
    }

    /// Content laid out synchronously before first paint (points): the viewport plus a
    /// little, so the first frame is exact and nothing more is done before it.
    private var syncHeight: CGFloat = 1200

    public func setViewportHeight(_ h: CGFloat) { syncHeight = max(400, h + 160) }

    private var generation = 0
    private var pending: PendingLayout?

    /// Called after background layout lands (resize + repaint, no relayout).
    public var onLayoutChanged: (() -> Void)?

    public func willShow(_ rect: CGRect) {
        guard let job = pending, job.first < blocks.count else { return }
        if rect.maxY > blocks[job.first].y { finishLayout() }
    }

    /// Blocks until background layout is done and adopts it (exact geometry everywhere).
    public func finishLayout() {
        guard let job = pending else { return }
        if job.started { job.wait() } else { job.started = true; job.run() }   // not started: run here, in parallel
        adopt(job)
        onLayoutChanged?()
    }

    private func adopt(_ job: PendingLayout) {
        guard pending === job else { return }
        pending = nil
        var all = Array(job.prefix)
        all.append(contentsOf: job.results)
        stack(all, x0: job.x0)
    }

    /// Places laid-out blocks vertically and adds the decorations that depend on neighbors.
    private func stack(_ results: [BlockLayout], x0: CGFloat) {
        blocks.removeAll(keepingCapacity: true)
        boxes.removeAll(keepingCapacity: true)
        decos.removeAll(keepingCapacity: true)
        headingY = [CGFloat](repeating: 0, count: doc.headings.count)
        var y = m.padTop
        var maxRight = x0
        var prevQuote: UInt8 = 0
        for (bi, b) in doc.blocks.enumerated() {
            let r = results[bi]
            if bi > 0 {
                var g = b.tight ? m.tightGap : m.gap
                if b.kind == .heading { g = max(g, m.body * (b.level <= 2 ? 1.9 : 1.5)) }
                y += g
            }
            let top = y
            let box0 = boxes.count
            for box in r.boxes { box.place(top: top); boxes.append(box) }
            for d in r.decos { decos.append(PlacedDeco(minY: d.minY + top, maxY: d.maxY + top, deco: d.deco.offset(top))) }
            y = top + r.height
            maxRight = max(maxRight, r.right)
            if b.kind == .heading && b.heading >= 0 { headingY[Int(b.heading)] = top }

            // List marker beside the block's first line.
            if b.marker != .none, let fb = r.firstBaseline {
                let base = top + fb
                let indent = CGFloat(b.quoteDepth) * m.quoteIndent + CGFloat(b.listDepth) * m.listIndent
                let mx = x0 + indent - 8
                switch b.marker {
                case .bullet:
                    decos.append(PlacedDeco(minY: base - m.body, maxY: base, deco: .bullet(CGPoint(x: mx - 4, y: base - m.body * 0.32), Int(b.listDepth))))
                case .ordered:
                    let l = CTLineCreateWithAttributedString(NSAttributedString(string: "\(b.markerNumber).", attributes: [
                        .font: fonts.font(m.body), .foregroundColor: palette.secondaryText]))
                    decos.append(PlacedDeco(minY: base - m.body, maxY: base + 4, deco: .label(l, CGPoint(x: mx, y: base))))
                case .taskOpen, .taskDone:
                    let s = m.body * 0.95
                    decos.append(PlacedDeco(minY: base - s, maxY: base, deco: .check(CGRect(x: mx - s, y: base - s * 0.88, width: s, height: s), b.marker == .taskDone)))
                case .none: break
                }
            }
            // Quote bars span the block and the gap above it when the previous block was quoted too.
            if b.quoteDepth > 0 {
                for q in 0..<Int(b.quoteDepth) {
                    let qx = x0 + CGFloat(q) * m.quoteIndent
                    let from = q < Int(prevQuote) && bi > 0 ? top - (b.tight ? m.tightGap : m.gap) : top
                    decos.append(PlacedDeco(minY: from, maxY: y, deco: .fill(CGRect(x: qx, y: from, width: 3, height: y - from), .border, 1.5)))
                }
            }
            prevQuote = b.quoteDepth
            blocks.append(LBlock(y: top, h: y - top, box0: box0, boxN: boxes.count - box0))
        }
        size = CGSize(width: max(width, maxRight + m.padX), height: y + m.padTop * 1.5)
        decos.sort { $0.minY < $1.minY }
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
        func color(_ r: DecoRole) -> CGColor {
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
            if r.width < 2 || r.height < 2 { return }
            let path = CGPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 6, cornerHeight: 6, transform: nil)
            ctx.setFillColor(palette.blockBackground)
            ctx.addPath(path)
            ctx.fillPath()
            if images.failed(index) {
                // Like a browser: keep the reserved space, show the alt text.
                ctx.setStrokeColor(palette.border)
                ctx.setLineWidth(1)
                ctx.addPath(path)
                ctx.strokePath()
                let alt = images.alt(index)
                if !alt.isEmpty && r.height >= 18 {
                    let line = CTLineCreateWithAttributedString(NSAttributedString(string: alt, attributes: [
                        .font: fonts.font(m.body - 1), .foregroundColor: palette.secondaryText]))
                    let w = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                    if w < r.width - 8 {
                        ctx.textPosition = CGPoint(x: r.midX - w / 2, y: r.midY + 4)
                        CTLineDraw(line, ctx)
                    }
                }
            }
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
        if pending != nil && (box(containing: start).map { boxes[$0].end < start } ?? true) { finishLayout() }
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
        finishLayout()
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
