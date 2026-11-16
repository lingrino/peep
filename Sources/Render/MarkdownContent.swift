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
    let fonts = FontBook.main

    /// Vertical geometry of one block. Kept for every block; cheap (no Core Text objects).
    struct LBlock {
        var y: CGFloat        // top, content space
        var h: CGFloat        // exact for blocks below `exactCount`, else an estimate
        var gap: CGFloat      // space above the block (0 for the first)
        var right: CGFloat    // rightmost content x
    }

    /// A block's Core Text layout (boxes placed at `top`, decorations in content space).
    /// Built only for blocks that are drawn or queried, and dropped again far from the
    /// viewport: keeping a 10 MB document laid out whole took ~800 MB of frames, and freeing
    /// them stalled the main thread 0.2-0.35 s whenever the preview moved on.
    struct Built: @unchecked Sendable {
        var layout: BlockLayout   // boxes placed absolutely, decos block-local
        var top: CGFloat          // where `layout` and `decos` are placed (NaN: not yet)
        var decos: [PlacedDeco]   // the block's decorations plus list marker and quote bars
    }

    private(set) var blocks: [LBlock] = []
    private var built: [Built?] = []
    /// Indices of the built blocks (eviction).
    private var builtList: [Int] = []
    private(set) var headingY: [CGFloat] = []
    private var headingHeight: [CGFloat] = []
    /// Block index of each heading (`doc.headings` order).
    private lazy var headingBlock: [Int] = {
        var out = [Int](repeating: -1, count: doc.headings.count)
        for (bi, b) in doc.blocks.enumerated() where b.kind == .heading && b.heading >= 0 { out[Int(b.heading)] = bi }
        return out
    }()
    public private(set) var lastLayoutNanos: UInt64 = 0

    /// Called when async work (images) needs a relayout.
    public var onNeedsLayout: (() -> Void)?

    isolated deinit {
        if let p = pending { LayoutPool.shared.cancel(p) }
    }

    public init(doc: MarkdownDocument, baseDir: URL?) {
        self.doc = doc
        self.baseDir = baseDir
        images = ImageStore(Array(doc.images), baseDir: baseDir)
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

    /// Progressive layout. Blocks are laid out synchronously until the viewport is covered
    /// (first paint never waits for the whole document); the rest get estimated heights. A
    /// background pass then measures every remaining block in parallel and swaps in the exact
    /// heights: it keeps only heights, so geometry is exact everywhere while Core Text frames
    /// exist only for blocks near what was shown (`placed`). Queries that need exact geometry
    /// below the laid-out prefix call `finishLayout()`.
    func relayout() {
        let t0 = nanotime()
        images.start()
        generation &+= 1
        if let p = pending { LayoutPool.shared.cancel(p) }
        pending = nil
        let contentW = min(m.maxWidth, max(200, width - 2 * m.padX))
        let x0 = max(m.padX, ((width - contentW) / 2).rounded())
        let env = LayoutEnv(doc: doc, palette: palette, m: m, fonts: fonts,
                            imageSizes: images.sizes(maxWidth: max(40, contentW)), x0: x0, contentW: contentW)
        layoutEnv = env
        let n = doc.blocks.count
        dropBuilt()
        built = [Built?](repeating: nil, count: n)
        var bl = [LBlock]()
        bl.reserveCapacity(n)
        for k in 0..<n { bl.append(LBlock(y: 0, h: 0, gap: gapAbove(k), right: x0 + contentW)) }
        var y: CGFloat = 0
        var k = 0
        while k < n && y < syncHeight {
            let r = MarkdownLayout.block(k, env)
            bl[k].h = r.height
            bl[k].right = r.right
            y += bl[k].gap + r.height
            built[k] = Built(layout: r, top: .nan, decos: [])
            builtList.append(k)
            k += 1
        }
        exactCount = k
        for i in k..<n { bl[i].h = MarkdownLayout.estimate(i, env).height }
        blocks = bl
        restack()
        lastLayoutNanos = nanotime() - t0
        renderLog.debug("md layout w=\(self.width) sync \(k)/\(n) blocks \(Double(self.lastLayoutNanos) / 1e6)ms")
        if k == n { return }

        // Background: measure everything after the prefix, in parallel -- started after this
        // main thread turn, i.e. after the first frame is drawn. The layout threads hold Core
        // Text's per-font shaping lock most of the time; a first draw competing with them took
        // 21ms instead of ~3ms (900 KB changelog).
        let job = PendingLayout(first: k, count: n - k, env: env, owner: self)
        pending = job
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.start(job) } }
    }

    private func start(_ job: PendingLayout) {
        guard pending === job, !job.started else { return }
        let gen = generation
        let t0 = nanotime()
        job.onDone = { [weak self] in
            let ran = nanotime() - t0
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.generation == gen, self.pending === job else { return }
                    let t1 = nanotime()
                    self.adopt(job)
                    let t2 = nanotime()
                    self.onLayoutChanged?()
                    self.lastBackground = (ran, t2 - t1, nanotime() - t2)
                    renderLog.debug("md background layout: \(job.count) blocks in \(Double(ran) / 1e6)ms; main thread: adopt \(Double(t2 - t1) / 1e6)ms, update \(Double(nanotime() - t2) / 1e6)ms")
                }
            }
        }
        LayoutPool.shared.submit(job)
    }

    /// Content laid out synchronously before first paint (points): the viewport plus a
    /// little, so the first frame is exact and nothing more is done before it.
    private var syncHeight: CGFloat = 1200

    public func setViewportHeight(_ h: CGFloat) { syncHeight = max(400, h + 160) }

    private var generation = 0
    private var pending: PendingLayout?
    var isLayoutPending: Bool { pending != nil }
    /// Last background layout: (threads, adopt on main, update on main) in ns.
    private(set) var lastBackground: (UInt64, UInt64, UInt64) = (0, 0, 0)

    /// Called after background layout lands (resize + repaint, no relayout).
    public var onLayoutChanged: (() -> Void)?

    /// Blocks `0..<exactCount` have exact heights (all of them once background layout landed);
    /// the rest are estimates.
    private var exactCount = 0
    private var layoutEnv: LayoutEnv?

    /// The visible rect reached estimated geometry: lay out just enough more blocks (in order,
    /// on this thread) to cover it, instead of waiting for the whole background job. Waiting
    /// stalled Quick Look's panel 0.5-2.5 s on a 10 MB document when it opened taller than
    /// the preview was prepared at. The job keeps running; its heights fill in the rest.
    public func willShow(_ rect: CGRect) {
        let n = blocks.count
        if exactCount < n, let env = layoutEnv, rect.maxY > blocks[exactCount].y - blocks[exactCount].gap {
            let target = rect.maxY + 160
            // Far into estimated geometry (a scroller drag): the parallel pass beats laying
            // out thousands of blocks here one by one.
            if firstBlock(atOrBelow: target) - exactCount > 1000 {
                finishLayout()
            } else {
                var k = exactCount
                var y = blocks[k].y - blocks[k].gap   // bottom of the exact prefix
                while k < n && y < target {
                    let r = MarkdownLayout.block(k, env)
                    blocks[k].h = r.height
                    blocks[k].right = r.right
                    y += blocks[k].gap + r.height
                    if built[k] == nil { builtList.append(k) }
                    built[k] = Built(layout: r, top: .nan, decos: [])
                    k += 1
                }
                exactCount = k
                restack()
                onLayoutChanged?()
            }
        }
        evictFar(from: rect)
    }

    /// Blocks until background layout is done and adopts it (exact geometry everywhere).
    public func finishLayout() {
        guard let job = pending else { return }
        if job.started { LayoutPool.shared.prioritize(job) } else { start(job) }
        job.wait()
        adopt(job)
        onLayoutChanged?()
    }

    private func adopt(_ job: PendingLayout) {
        guard pending === job else { return }
        pending = nil
        // Blocks laid out here meanwhile (willShow) keep their own heights: identical, but the
        // boxes already built from them must match their block exactly.
        let hs = job.heights, rs = job.rights
        for k in max(job.first, exactCount)..<blocks.count {
            blocks[k].h = hs[k - job.first]
            blocks[k].right = rs[k - job.first]
        }
        exactCount = blocks.count
        restack()
    }

    private func gapAbove(_ k: Int) -> CGFloat {
        if k == 0 { return 0 }
        let b = doc.blocks[k]
        var g = b.tight ? m.tightGap : m.gap
        if b.kind == .heading { g = max(g, m.body * (b.level <= 2 ? 1.9 : 1.5)) }
        if doc.blocks[k - 1].kind == .alertTitle { g = m.body * 0.4 }   // title sits on its body
        return g
    }

    /// Positions every block from the heights (O(blocks), no Core Text). Built blocks are
    /// re-placed lazily (`placed`).
    private func restack() {
        var y = m.padTop
        var maxRight = layoutEnv?.x0 ?? 0
        blocks.withUnsafeMutableBufferPointer { bp in
            for k in bp.indices {
                y += bp[k].gap
                bp[k].y = y
                y += bp[k].h
                maxRight = max(maxRight, bp[k].right)
            }
        }
        size = CGSize(width: max(width, maxRight + m.padX), height: y + m.padTop * 1.5)
        headingY = headingBlock.map { $0 >= 0 ? blocks[$0].y : 0 }
        headingHeight = headingBlock.map { $0 >= 0 ? blocks[$0].h : 0 }
    }

    /// Block `k`'s layout, built if needed and placed at its current top. Callers make sure
    /// the block's geometry is exact (`k < exactCount`).
    @discardableResult
    private func placed(_ k: Int) -> Built {
        if let b = built[k], b.top == blocks[k].y { return b }
        let r: BlockLayout
        if let b = built[k] { r = b.layout } else { r = MarkdownLayout.block(k, layoutEnv!); builtList.append(k) }
        let b = place(r, k)
        built[k] = b
        return b
    }

    /// Places a block's layout at its top and adds the decorations that depend on neighbors.
    private func place(_ r: BlockLayout, _ k: Int) -> Built {
        let top = blocks[k].y
        let y = top + r.height
        for box in r.boxes { box.place(top: top) }
        var decos = r.decos.map { PlacedDeco(minY: $0.minY + top, maxY: $0.maxY + top, deco: $0.deco.offset(top)) }
        let b = doc.blocks[k]
        let x0 = layoutEnv?.x0 ?? m.padX
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
            let prevQuote = k > 0 ? doc.blocks[k - 1].quoteDepth : 0
            let prevAlert = k > 0 ? doc.blocks[k - 1].alert : .none
            for q in 0..<Int(b.quoteDepth) {
                let qx = x0 + CGFloat(q) * m.quoteIndent
                // An alert's bar is its color, and doesn't join a neighboring quote's.
                let alert = q == 0 ? b.alert : .none
                let joins = q < Int(prevQuote) && k > 0 && !(q == 0 && (b.kind == .alertTitle || b.alert != prevAlert))
                let from = joins ? top - (b.tight ? m.tightGap : m.gap) : top
                let role: DecoRole = alert == .none ? .border : .alert(alert)
                decos.append(PlacedDeco(minY: from, maxY: y, deco: .fill(CGRect(x: qx, y: from, width: 3, height: y - from), role, 0)))   // square: segments meet seamlessly
            }
        }
        return Built(layout: r, top: top, decos: decos)
    }

    /// Drops built blocks far from the visible rect once many are built (find stepping or
    /// scrolling through a long document builds one screen at a time).
    private func evictFar(from vis: CGRect) {
        guard builtList.count > 1500 else { return }
        let reach = 4 * max(vis.height, 600)
        let lo = vis.minY - reach, hi = vis.maxY + reach
        var keep: [Int] = []
        var trash: [Built] = []
        for k in builtList {
            if blocks[k].y + blocks[k].h >= lo && blocks[k].y <= hi { keep.append(k) }
            else if let b = built[k] { trash.append(b); built[k] = nil }
        }
        builtList = keep
        Self.release(trash)
    }

    private func dropBuilt() {
        let old = built
        built = []
        builtList.removeAll()
        Self.release(old)
    }

    /// Frees Core Text objects off the main thread (thousands of frames take tens of ms).
    nonisolated private static func release<T: Sendable>(_ x: T) {
        DispatchQueue.global(qos: .utility).async { withExtendedLifetime(x) {} }
    }

    /// Boxes of block `k` with exact geometry (debug tools).
    func boxes(ofBlock k: Int) -> [TextBox] {
        if k >= exactCount { finishLayout() }
        return placed(k).layout.boxes
    }

    // MARK: - Drawing

    public func draw(_ ctx: CGContext, rect: CGRect, palette: Palette, highlights: Highlights) {
        // Blocks intersecting the rect, plus those just below it: quote bars reach up into the
        // gap above their block. Blocks with estimated geometry aren't drawn (their tiles are
        // redrawn once it's exact).
        var bi = firstBlock(atOrBelow: rect.minY)
        var end = bi
        while end < exactCount && blocks[end].y - blocks[end].gap <= rect.maxY { end += 1 }
        guard bi < end else { return }
        var list: [Built] = []
        list.reserveCapacity(end - bi)
        while bi < end { list.append(placed(bi)); bi += 1 }
        // Decorations first (backgrounds, bars), then text.
        for b in list {
            for d in b.decos where d.maxY >= rect.minY && d.minY <= rect.maxY { drawDeco(d.deco, ctx, palette) }
        }
        for b in list {
            for box in b.layout.boxes {
                box.draw(ctx, rect: rect, palette: palette, highlights: highlights, content: self)
            }
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
            case .alert(let a): p.alert[Int(a.rawValue)]
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
        case .alertIcon(let r, let a):
            drawAlertIcon(a, in: r, ctx: ctx, palette: p)
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

    /// SF Symbol per alert type, tinted, rendered once per appearance.
    private var alertIcons: [Int: CGImage] = [:]

    private func drawAlertIcon(_ a: MDAlert, in r: CGRect, ctx: CGContext, palette p: Palette) {
        let key = Int(a.rawValue) << 1 | (p.isDark ? 1 : 0)
        var img = alertIcons[key]
        if img == nil {
            let name = switch a {
            case .note: "info.circle"
            case .tip: "lightbulb"
            case .important: "exclamationmark.bubble"
            case .warning: "exclamationmark.triangle"
            case .caution: "exclamationmark.octagon"
            case .none: ""
            }
            let color = NSColor(cgColor: p.alert[Int(a.rawValue)]) ?? .labelColor
            let cfg = NSImage.SymbolConfiguration(pointSize: r.height * 0.82, weight: .medium)
                .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
            if let sym = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
                // Rasterized at 3x the box (sharp on Retina tiles), centered in a square.
                let px = Int(r.width * 3)
                if let bm = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                    let s = CGFloat(px) / r.width
                    let fit = min(r.width / sym.size.width, r.height / sym.size.height)
                    let w = sym.size.width * fit, h = sym.size.height * fit
                    NSGraphicsContext.saveGraphicsState()
                    NSGraphicsContext.current = NSGraphicsContext(cgContext: bm, flipped: false)
                    sym.draw(in: CGRect(x: (r.width - w) / 2 * s, y: (r.height - h) / 2 * s, width: w * s, height: h * s))
                    NSGraphicsContext.restoreGraphicsState()
                    img = bm.makeImage()
                }
            }
            alertIcons[key] = img
        }
        guard let img else { return }
        ctx.saveGState()
        ctx.translateBy(x: r.minX, y: r.maxY)   // flipped context: draw upside down
        ctx.scaleBy(x: 1, y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
        ctx.restoreGState()
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

    /// Box containing a text offset: the first box ending at or after it (boxes and blocks
    /// are in text order), with exact geometry.
    func box(containing o: Int) -> TextBox? {
        let n = blocks.count
        let bs = doc.blocks
        var lo = 0, hi = n
        while lo < hi {
            let mid = (lo + hi) >> 1
            if Int(bs[mid].textEnd) < o { lo = mid + 1 } else { hi = mid }
        }
        var k = lo
        while k < n {
            if k >= exactCount { finishLayout() }
            for box in placed(k).layout.boxes where box.end >= o { return box }
            k += 1
        }
        // Past the end: the last box.
        k = n - 1
        while k >= 0 {
            if k >= exactCount { finishLayout() }
            if let box = placed(k).layout.boxes.last { return box }
            k -= 1
        }
        return nil
    }

    public func offset(at p: CGPoint) -> Int {
        let n = blocks.count
        if n == 0 { return 0 }
        let bi = firstBlock(atOrBelow: p.y)
        if bi >= n { return text.count }
        if bi >= exactCount { return Int(doc.blocks[bi].textStart) }
        let boxes = placed(bi).layout.boxes
        if boxes.isEmpty {
            // Rule or empty block: snap to the next box.
            var k = bi + 1
            while k < exactCount {
                if let f = placed(k).layout.boxes.first { return f.start }
                k += 1
            }
            return k < n ? Int(doc.blocks[k].textStart) : text.count
        }
        if p.y < blocks[bi].y { return boxes[0].start }
        // Nearest box in the block (tables: the cell under the point).
        var best = 0
        var bestD = CGFloat.infinity
        for (k, box) in boxes.enumerated() {
            let r = box.rect
            let dx = p.x < r.minX ? r.minX - p.x : p.x > r.maxX ? p.x - r.maxX : 0
            let dy = p.y < r.minY ? r.minY - p.y : p.y > r.maxY ? p.y - r.maxY : 0
            let d = dx + dy * 4
            if d < bestD { bestD = d; best = k }
        }
        return boxes[best].offset(at: p)
    }

    public func rect(for start: Int, _ end: Int) -> CGRect {
        box(containing: start)?.rect(for: start, end) ?? .zero
    }

    public func verticalExtent(_ start: Int, _ end: Int) -> (CGFloat, CGFloat) {
        // The later box first: it may finish layout, which moves nothing above it.
        guard let b = box(containing: max(start, end)), let a = box(containing: start) else { return (0, size.height) }
        // Table rows share a y-band: widen to the containing blocks.
        let ya = a.rect.minY, yb = b.rect.maxY
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
        guard let box = box(containing: o) else { return (o, o) }
        return (box.start, min(text.count, box.end + 1))
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
        guard bi < exactCount else { return nil }
        for box in placed(bi).layout.boxes where box.rect.insetBy(dx: -2, dy: -2).contains(p) {
            if let off = box.characterOffset(at: p), let ref = linkRef(at: off) { return doc.links[ref] }
        }
        return nil
    }

    /// Link (index) of the run covering text offset `off`: runs are in text order, so a binary
    /// search for the last run starting at or before it.
    func linkRef(at off: Int) -> Int? {
        let runs = doc.runs
        var lo = 0, hi = runs.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if Int(runs[mid].start) <= off { lo = mid + 1 } else { hi = mid }
        }
        guard lo > 0 else { return nil }
        let r = runs[lo - 1]
        guard off < Int(r.end), r.style.contains(.link), !r.style.contains(.image), r.ref >= 0 else { return nil }
        return Int(r.ref)
    }

    public var outlineEntries: [OutlineEntry] { doc.headings.map { OutlineEntry(level: $0.level, title: $0.title) } }

    public func outlineSpan(_ i: Int) -> (top: CGFloat, height: CGFloat)? {
        finishLayout()
        return i < headingY.count ? (headingY[i], headingHeight[i]) : nil
    }

    public func outlineIndex(atY y: CGFloat) -> Int {
        var cur = -1
        for (i, hy) in headingY.enumerated() where hy <= y { cur = i }
        return cur
    }

    public func anchorSpan(_ name: String) -> (top: CGFloat, height: CGFloat)? {
        finishLayout()
        let n = name.hasPrefix("#") ? String(name.dropFirst()) : name
        // Footnotes ("fn:N") and references ("fnref:N:k"): ids no heading slug can have.
        if n.hasPrefix("fn:") || n.hasPrefix("fnref:") {
            let parts = n.split(separator: ":").compactMap { Int($0) }
            guard let note = parts.first, note >= 1 else { return nil }
            if n.hasPrefix("fn:") {
                guard note <= doc.footnoteBlocks.count else { return nil }
                let b = blocks[doc.footnoteBlocks[note - 1]]
                return (b.y, b.h)
            }
            guard note <= doc.footnoteRefs.count, parts.count == 2, parts[1] >= 1,
                  parts[1] <= doc.footnoteRefs[note - 1].count else { return nil }
            let off = Int(doc.footnoteRefs[note - 1][parts[1] - 1])
            // The line holding the reference.
            guard let box = box(containing: off) else { return nil }
            let r = box.rect(for: off, off + 1)
            return (r.minY, r.height)
        }
        let key = n.removingPercentEncoding ?? n
        guard let i = doc.headingSlugs().firstIndex(where: { $0 == key || $0 == key.lowercased() }) else { return nil }
        return (headingY[i], headingHeight[i])
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
