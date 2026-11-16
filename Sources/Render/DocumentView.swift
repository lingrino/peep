import AppKit

/// What a DocumentView displays. Implemented by CodeContent and MarkdownContent.
///
/// Geometry is in "content space": origin at the top-left of the content area (right of the
/// gutter), y down. Text offsets index `text` (UTF-8 bytes).
@MainActor
public protocol DocumentContent: AnyObject {
    var size: CGSize { get }
    var gutterWidth: CGFloat { get }
    /// The selectable/searchable text (for code: the file; for markdown: rendered text).
    var text: TextBuffer { get }
    /// Re-layout for a new viewport width. Returns true if `size` changed.
    func layout(width: CGFloat) -> Bool
    /// Draws content intersecting `rect` (content space). The context is flipped (y down)
    /// with the text matrix already flipped for Core Text.
    func draw(_ ctx: CGContext, rect: CGRect, palette: Palette, highlights: Highlights)
    func drawGutter(_ ctx: CGContext, rect: CGRect, palette: Palette)
    /// Nearest text offset to a point (content space).
    func offset(at point: CGPoint) -> Int
    /// Bounding rect (content space) of the text range's first line/fragment, for scrolling.
    func rect(for start: Int, _ end: Int) -> CGRect
    /// Vertical extent (minY, maxY) covering the range, for minimal invalidation.
    func verticalExtent(_ start: Int, _ end: Int) -> (CGFloat, CGFloat)
    func wordRange(at offset: Int) -> (Int, Int)
    func lineRange(at offset: Int) -> (Int, Int)
    /// Plain-text representation of a range for the pasteboard.
    func copyText(_ start: Int, _ end: Int) -> String
    /// Link target at a point, if any.
    func link(at point: CGPoint) -> String?
    /// Appearance changed. Return true if the content re-laid out (colors baked into layout).
    func setPalette(_ p: Palette) -> Bool
    /// Y of a named anchor (markdown heading slug), for in-document links.
    func anchorY(_ name: String) -> CGFloat?
    /// About to show `rect` (content space): finish any deferred layout it needs.
    func willShow(_ rect: CGRect)
}

extension DocumentContent {
    public func copyText(_ start: Int, _ end: Int) -> String { text.string(start, end) }
    public func drawGutter(_ ctx: CGContext, rect: CGRect, palette: Palette) {}
    public func link(at point: CGPoint) -> String? { nil }
    public func setPalette(_ p: Palette) -> Bool { false }
    public func anchorY(_ name: String) -> CGFloat? { nil }
    public func willShow(_ rect: CGRect) {}
}

/// Selection and find state handed to the content's draw call.
public struct Highlights {
    public var selStart = 0
    public var selEnd = 0
    /// Sorted, non-overlapping match ranges as [start0, end0, start1, end1, ...].
    public var matches: UnsafeBufferPointer<UInt32> = UnsafeBufferPointer(start: nil, count: 0)
    public var current = -1
    public var matchCount: Int { matches.count / 2 }

    /// Index of the first match whose end is > offset.
    public func firstMatch(endingAfter offset: Int) -> Int {
        var lo = 0, hi = matchCount
        let o = UInt32(truncatingIfNeeded: offset)
        while lo < hi {
            let mid = (lo + hi) >> 1
            if matches[2 * mid + 1] <= o { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}

/// One cached rectangle of rendered document. Layer-backed and opaque; draws only when
/// created/recycled or explicitly invalidated, so scrolling just moves existing layers.
final class TileView: NSView {
    weak var owner: DocumentView?
    var gutter = false
    var col = 0, row = 0

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let owner, let ctx = NSGraphicsContext.current?.cgContext else { return }
        owner.render(tile: self, ctx: ctx, dirty: dirtyRect)
    }
}

/// Scrollable, selectable document surface built from tiles.
public final class DocumentView: NSView {
    public static let tileSize: CGFloat = 512

    public private(set) var content: DocumentContent?
    var palette: Palette = .light
    var highlights = Highlights()
    /// Selection anchor/head (text offsets). Selection is [min, max).
    public private(set) var anchor = 0
    public private(set) var head = 0
    private var granularity = 0          // 1 click: chars, 2: words, 3: lines
    private var granularAnchor = (0, 0)  // range of the word/line clicked first

    private var tiles: [TileView] = []
    private var gutterTiles: [TileView] = []
    private let gutterView = GutterContainer()
    private var lastTiledRect = CGRect.null

    /// Called when the selection changes (the find controller and agent want to know).
    public var onSelectionChange: (() -> Void)?
    /// Called on link clicks with the target string.
    public var onLink: ((String) -> Void)?

    public override var isFlipped: Bool { true }
    public override var isOpaque: Bool { true }
    public override var acceptsFirstResponder: Bool { false }   // never steal Finder's keys
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        gutterView.wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError() }

    var scrollView: NSScrollView? { enclosingScrollView }

    // MARK: - Content

    /// When content was set (for first-paint timing), 0 once the first tile has drawn.
    private var contentSetAt: UInt64 = 0
    private var tilesDrawnSinceSet = 0
    private var drawNanos: UInt64 = 0

    public func setContent(_ c: DocumentContent, width: CGFloat) {
        contentSetAt = nanotime()
        tilesDrawnSinceSet = 0
        drawNanos = 0
        content = c
        anchor = 0; head = 0
        palette = Palette.current(for: self)
        _ = c.setPalette(palette)
        _ = c.layout(width: max(100, width - c.gutterWidth))
        resize()
        for t in tiles { t.removeFromSuperview() }
        for t in gutterTiles { t.removeFromSuperview() }
        tiles.removeAll(); gutterTiles.removeAll()
        lastTiledRect = .null
        if let sv = scrollView {
            if c.gutterWidth > 0 {
                if gutterView.superview == nil { sv.addFloatingSubview(gutterView, for: .horizontal) }
            } else {
                gutterView.removeFromSuperview()
            }
            sv.contentView.scroll(to: .zero)
            sv.reflectScrolledClipView(sv.contentView)
        }
        updateTiles()
    }

    /// The content re-laid out on its own (e.g. images arrived): resize and repaint.
    public func contentDidChangeLayout() {
        resize()
        updateTiles()
        invalidateAll()
    }

    /// Re-runs layout for the current viewport width (markdown rewraps; code is unaffected).
    func relayout() {
        guard let c = content, let sv = scrollView else { return }
        if c.layout(width: max(100, sv.contentView.bounds.width - c.gutterWidth)) {
            resize()
            invalidateAll()
        }
    }

    func resize() {
        guard let c = content else { return }
        let vis = scrollView?.contentView.bounds.size ?? bounds.size
        let w = max(vis.width, c.size.width + c.gutterWidth)
        let h = max(vis.height, c.size.height)
        if w != bounds.width || h != bounds.height {
            // Tile frames depend on the document size: re-place (and redraw) all of them.
            for t in tiles { t.row = -1; t.col = -1 }
            for t in gutterTiles { t.row = -1; t.col = -1 }
        }
        setFrameSize(NSSize(width: w, height: h))
        gutterView.frame = NSRect(x: 0, y: 0, width: c.gutterWidth, height: h)
        gutterView.isHidden = c.gutterWidth == 0
    }

    public override func resizeSubviews(withOldSize oldSize: NSSize) {}

    // MARK: - Tiles

    /// Ensures tiles cover the visible rect plus a margin; recycles the rest.
    func updateTiles() {
        guard let c = content, let sv = scrollView else { return }
        let vis = sv.contentView.bounds
        if vis != cursorRectsFor {
            // Quick Look's remote window doesn't re-ask for cursor rects after resizes or
            // scrolls the way a normal window does; without this the I-beam rect keeps the
            // size of the first (pre-sizing) visible rect, a few hundred points.
            cursorRectsFor = vis
            window?.invalidateCursorRects(for: self)
        }
        let ts = DocumentView.tileSize
        let margin = ts / 2
        let want = vis.insetBy(dx: -margin, dy: -margin).intersection(bounds)
        if want.isNull || want.isEmpty { return }
        c.willShow(want.offsetBy(dx: -c.gutterWidth, dy: 0))
        let c0 = Int(want.minX / ts), c1 = Int((want.maxX - 0.5) / ts)
        let r0 = Int(want.minY / ts), r1 = Int((want.maxY - 0.5) / ts)
        let gw = c.gutterWidth

        func place(_ list: inout [TileView], gutter: Bool, cols: ClosedRange<Int>, parent: NSView) {
            var needed = Set<Int>()   // packed (row << 20 | col)
            for r in r0...r1 { for cc in cols { needed.insert(r << 20 | cc) } }
            var free: [TileView] = []
            for t in list {
                let k = t.row << 20 | t.col
                if needed.contains(k) { needed.remove(k) } else { free.append(t) }
            }
            for k in needed {
                let t: TileView
                if let f = free.popLast() { t = f } else {
                    t = TileView(frame: .zero)
                    t.owner = self
                    t.gutter = gutter
                    t.wantsLayer = true
                    t.layerContentsRedrawPolicy = .onSetNeedsDisplay
                    t.clipsToBounds = true
                    parent.addSubview(t)
                    list.append(t)
                }
                t.row = k >> 20
                t.col = k & 0xFFFFF
                let x = gutter ? 0 : CGFloat(t.col) * ts
                t.frame = NSRect(x: x, y: CGFloat(t.row) * ts,
                                 width: gutter ? gw : min(ts, bounds.width - x),
                                 height: min(ts, bounds.height - CGFloat(t.row) * ts))
                t.needsDisplay = true
            }
            // Free tiles beyond what we keep around get dropped (bounded memory).
            if free.count > 8 {
                let drop = Set(free.dropFirst(8).map { ObjectIdentifier($0) })
                list.removeAll { t in
                    if drop.contains(ObjectIdentifier(t)) { t.removeFromSuperview(); return true }
                    return false
                }
            }
            for t in free.prefix(8) { t.frame = .zero }
        }
        place(&tiles, gutter: false, cols: c0...c1, parent: self)
        if gw > 0 { place(&gutterTiles, gutter: true, cols: 0...0, parent: gutterView) }
        lastTiledRect = want
    }

    func invalidateAll() {
        for t in tiles where !t.frame.isEmpty { t.needsDisplay = true }
        for t in gutterTiles where !t.frame.isEmpty { t.needsDisplay = true }
    }

    /// Invalidates content tiles intersecting a vertical band (content space y).
    func invalidate(minY: CGFloat, maxY: CGFloat) {
        for t in tiles where !t.frame.isEmpty && t.frame.maxY >= minY && t.frame.minY <= maxY {
            t.setNeedsDisplay(NSRect(x: 0, y: max(0, minY - t.frame.minY), width: t.bounds.width,
                                     height: min(t.bounds.height, maxY - minY + 2)))
        }
    }

    func render(tile: TileView, ctx: CGContext, dirty: NSRect) {
        guard let c = content else { return }
        let t0 = nanotime()
        defer {
            if contentSetAt != 0 {
                drawNanos += nanotime() - t0
                tilesDrawnSinceSet += 1
                // Log once the first screenful of tiles is done (next runloop turn).
                if tilesDrawnSinceSet == 1 {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.contentSetAt != 0 else { return }
                        renderLog.debug("first paint: \(self.tilesDrawnSinceSet) tiles drawn in \(Double(self.drawNanos) / 1e6)ms, \(Double(nanotime() - self.contentSetAt) / 1e6)ms after setContent")
                        self.contentSetAt = 0
                    }
                }
            }
        }
        let origin = tile.frame.origin
        ctx.setFillColor(palette.background)
        ctx.fill(dirty)
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        if tile.gutter {
            ctx.saveGState()
            ctx.translateBy(x: 0, y: -origin.y)
            c.drawGutter(ctx, rect: dirty.offsetBy(dx: 0, dy: origin.y), palette: palette)
            ctx.restoreGState()
        } else {
            let gw = c.gutterWidth
            ctx.saveGState()
            ctx.translateBy(x: -origin.x + gw, y: -origin.y)
            var h = highlights
            h.selStart = min(anchor, head)
            h.selEnd = max(anchor, head)
            c.draw(ctx, rect: dirty.offsetBy(dx: origin.x - gw, dy: origin.y), palette: palette, highlights: h)
            ctx.restoreGState()
        }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyPalette()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyPalette()
    }

    private func applyPalette() {
        let p = Palette.current(for: self)
        if p === palette { return }
        palette = p
        if content?.setPalette(p) == true { resize() }
        invalidateAll()
    }

    // MARK: - Selection

    public var selectedRange: (Int, Int) { (min(anchor, head), max(anchor, head)) }
    public var hasSelection: Bool { anchor != head }

    public func select(_ start: Int, _ end: Int) {
        setSelection(anchor: start, head: end)
    }

    public func selectAll() {
        guard let c = content else { return }
        setSelection(anchor: 0, head: c.text.count)
    }

    private func setSelection(anchor a: Int, head h: Int) {
        guard let c = content else { return }
        let (o0, o1) = selectedRange
        anchor = a; head = h
        let (n0, n1) = selectedRange
        if (o0, o1) == (n0, n1) { return }
        // Repaint the symmetric difference of old and new selections.
        if o0 == o1 && n0 == n1 { return }
        let lo = min(o0 == o1 ? n0 : o0, n0 == n1 ? o0 : n0)
        let hi = max(o0 == o1 ? n1 : o1, n0 == n1 ? o1 : n1)
        if o0 == n0 && o1 != n1 {
            let (a, b) = c.verticalExtent(min(o1, n1), max(o1, n1)); invalidate(minY: a, maxY: b)
        } else if o1 == n1 && o0 != n0 {
            let (a, b) = c.verticalExtent(min(o0, n0), max(o0, n0)); invalidate(minY: a, maxY: b)
        } else {
            let (a, b) = c.verticalExtent(lo, hi); invalidate(minY: a, maxY: b)
        }
        onSelectionChange?()
    }

    func contentPoint(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: p.x - (content?.gutterWidth ?? 0), y: p.y)
    }

    public override func mouseDown(with event: NSEvent) {
        guard let c = content else { return }
        let p = contentPoint(event)
        if event.clickCount == 1, let link = c.link(at: p), !event.modifierFlags.contains(.shift) {
            pendingLink = link
        } else {
            pendingLink = nil
        }
        let o = c.offset(at: p)
        granularity = min(event.clickCount, 3)
        switch granularity {
        case 2:
            let w = c.wordRange(at: o); granularAnchor = w
            setSelection(anchor: w.0, head: w.1)
        case 3:
            let l = c.lineRange(at: o); granularAnchor = l
            setSelection(anchor: l.0, head: l.1)
        default:
            if event.modifierFlags.contains(.shift) { setSelection(anchor: anchor, head: o) }
            else { setSelection(anchor: o, head: o) }
        }
    }

    private var pendingLink: String?
    private var cursorRectsFor = CGRect.null

    public override func mouseDragged(with event: NSEvent) {
        guard let c = content else { return }
        pendingLink = nil
        autoscroll(with: event)
        let o = c.offset(at: contentPoint(event))
        switch granularity {
        case 2, 3:
            let r = granularity == 2 ? c.wordRange(at: o) : c.lineRange(at: o)
            if o < granularAnchor.0 { setSelection(anchor: granularAnchor.1, head: r.0) }
            else { setSelection(anchor: granularAnchor.0, head: max(r.1, granularAnchor.1)) }
        default:
            setSelection(anchor: anchor, head: o)
        }
    }

    public override func mouseUp(with event: NSEvent) {
        if let l = pendingLink, !hasSelection { onLink?(l) }
        pendingLink = nil
    }

    /// One I-beam rect over the visible area. No pointing hand over links: Quick Look's view
    /// service drops NSCursor.set(), shows the arrow where cursor rects overlap, and applies a
    /// rect's cursor only when the mouse *enters* it, with exit/enter of adjacent rects in no
    /// fixed order (so moving between text and link rects often leaves the arrow). Measured
    /// with NSCursor.currentSystem sampling; see AGENTS.md.
    public override func resetCursorRects() {
        addCursorRect(visibleRect, cursor: .iBeam)
    }

    public override func menu(for event: NSEvent) -> NSMenu? {
        let m = NSMenu()
        let copy = NSMenuItem(title: "Copy", action: #selector(copy(_:)), keyEquivalent: "c")
        copy.target = self
        copy.isEnabled = hasSelection
        m.addItem(copy)
        let all = NSMenuItem(title: "Select All", action: #selector(selectAllAction(_:)), keyEquivalent: "a")
        all.target = self
        m.addItem(all)
        return m
    }

    @objc public func copy(_ sender: Any?) {
        guard let c = content, hasSelection else { return }
        let (s, e) = selectedRange
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(c.copyText(s, e), forType: .string)
    }

    @objc func selectAllAction(_ sender: Any?) { selectAll() }

    // MARK: - Find highlights & scrolling

    public func setMatches(_ m: UnsafeBufferPointer<UInt32>, current: Int) {
        highlights.matches = m
        highlights.current = current
        invalidateAll()
    }

    /// Scrolls so the range is visible, centering it vertically if it was off screen.
    public func reveal(_ start: Int, _ end: Int) {
        guard let c = content, let sv = scrollView else { return }
        var r = c.rect(for: start, end)
        r.origin.x += c.gutterWidth
        let vis = sv.contentView.bounds
        var target = vis.origin
        let gw = c.gutterWidth
        if r.minY < vis.minY + 8 || r.maxY > vis.maxY - 8 {
            target.y = r.midY - vis.height / 2
        }
        if r.minX < vis.minX + gw + 8 || r.maxX > vis.maxX - 8 {
            target.x = r.minX - gw - vis.width / 3
        }
        target.x = max(0, min(target.x, bounds.width - vis.width))
        target.y = max(0, min(target.y, bounds.height - vis.height))
        if target != vis.origin {
            sv.contentView.scroll(to: target)
            sv.reflectScrolledClipView(sv.contentView)
        }
    }

    public func scrollToTop(y: CGFloat) {
        guard let sv = scrollView else { return }
        let vis = sv.contentView.bounds
        let target = CGPoint(x: vis.minX, y: max(0, min(y, bounds.height - vis.height)))
        sv.contentView.scroll(to: target)
        sv.reflectScrolledClipView(sv.contentView)
    }
}

/// Holds the gutter tiles; floats horizontally (stays put when scrolling sideways).
final class GutterContainer: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
