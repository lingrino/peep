import AppKit

/// Markdown table of contents shown as a sidebar (headings up to H3), with the section at
/// the top of the viewport highlighted. Shown only when the document has enough headings
/// and the preview is wide enough (see PreviewView).
@MainActor
final class OutlineView: NSView {
    struct Item {
        var level: Int
        var title: String
        var line: CTLine?
    }

    private let edge = CALayer()   // hairline separating the sidebar from the document
    private let scroll = NSScrollView()
    private let list = OutlineList()
    fileprivate(set) var items: [Item] = []
    var onSelect: ((Int) -> Void)?

    static let width: CGFloat = 230

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        // A plain layer color, not NSVisualEffectView: nothing is behind the sidebar to blur,
        // and the effect view cost ~14ms of compositing in offscreen first-paint measurements.
        wantsLayer = true
        layer?.addSublayer(edge)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.documentView = list
        list.owner = self
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        scroll.frame = bounds.insetBy(dx: 0, dy: 0)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        edge.frame = CGRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height)
        CATransaction.commit()
        list.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(bounds.height, list.contentHeight))
    }

    /// Entries deeper than one level below the shallowest (or than H3) are left out.
    func setEntries(_ es: [OutlineEntry]) {
        let minLevel = es.map(\.level).min() ?? 1
        let keep = max(3, minLevel + 1)
        items = es.filter { $0.level <= keep }.map { Item(level: $0.level - minLevel, title: $0.title) }
        indexMap = es.indices.filter { es[$0].level <= keep }
        list.current = -1
        list.needsDisplay = true
        needsLayout = true
    }

    /// Maps outline rows to heading indices in the document.
    private(set) var indexMap: [Int] = []

    func setCurrent(heading: Int) {
        let row = indexMap.lastIndex { $0 <= heading } ?? -1
        if row != list.current {
            // Repaint just the two rows whose highlight changed (a full redraw on every
            // section change while scrolling cost 1.5-4 ms on long outlines).
            if list.current >= 0 { list.setNeedsDisplay(list.rowRect(list.current)) }
            list.current = row
            if row >= 0 { list.setNeedsDisplay(list.rowRect(row)) }
            if row >= 0 { list.scrollToVisible(list.rowRect(row).insetBy(dx: 0, dy: -24)) }
        }
    }

    /// Asked first for every delivered mouse-down; true = already handled (early click).
    var lateClickHandled: ((NSEvent) -> Bool)?

    @discardableResult
    fileprivate func clicked(row: Int) -> Bool {
        guard row >= 0 && row < indexMap.count else { return false }
        onSelect?(indexMap[row])
        return true
    }

    /// A click at `p` (this view's coordinates) reported early by the agent. True if it hit a row.
    func click(at p: CGPoint) -> Bool {
        let lp = list.convert(p, from: self)
        guard list.visibleRect.contains(lp) else { return false }
        return clicked(row: list.row(at: lp))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        edge.backgroundColor = NSColor.separatorColor.cgColor
    }
}

@MainActor
final class OutlineList: NSView {
    weak var owner: OutlineView?
    var current = -1
    let rowHeight: CGFloat = 24
    let top: CGFloat = 14

    override var isFlipped: Bool { true }
    var contentHeight: CGFloat { top * 2 + CGFloat(owner?.items.count ?? 0) * rowHeight + 20 }

    func rowRect(_ i: Int) -> NSRect {
        NSRect(x: 8, y: top + 20 + CGFloat(i) * rowHeight, width: bounds.width - 16, height: rowHeight)
    }

    private static let titleFont = NSFont.systemFont(ofSize: 12.5, weight: .medium)
    private static let itemFont = NSFont.systemFont(ofSize: 12)
    /// Lines take their color from the context, so appearance changes need no rebuild.
    private static func line(_ s: String, font: NSFont, kern: CGFloat = 0) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [
            .font: font, .kern: kern,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]))
    }
    private lazy var header = OutlineList.line("CONTENTS", font: .systemFont(ofSize: 10.5, weight: .semibold), kern: 0.6)
    private lazy var ellipsis = OutlineList.line("…", font: OutlineList.itemFont)

    /// Rows are Core Text lines built on first draw and drawn with CTLineDraw: the first
    /// frame of a 197-heading outline took 6 ms through NSAttributedString.draw (TextKit).
    override func draw(_ dirtyRect: NSRect) {
        guard let owner, let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)   // flipped view
        if dirtyRect.minY < top + 20 {
            ctx.setFillColor(NSColor.tertiaryLabelColor.cgColor)
            ctx.textPosition = CGPoint(x: 18, y: top + 10)
            CTLineDraw(header, ctx)
        }
        let n = owner.items.count
        if n == 0 { return }
        let first = max(0, Int((dirtyRect.minY - top - 20) / rowHeight))
        let last = min(n - 1, Int((dirtyRect.maxY - top - 20) / rowHeight))
        if first > last { return }
        for i in first...last {
            let r = rowRect(i)
            let level = owner.items[i].level
            let isCurrent = i == current
            if isCurrent {
                NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
                NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
            }
            let font = level == 0 ? OutlineList.titleFont : OutlineList.itemFont
            let x = r.minX + 10 + CGFloat(level) * 12
            let line: CTLine
            if let l = owner.items[i].line { line = l } else {
                var l = OutlineList.line(owner.items[i].title, font: font)
                let avail = Double(r.maxX - x - 6)
                if CTLineGetTypographicBounds(l, nil, nil, nil) > avail {
                    l = CTLineCreateTruncatedLine(l, avail, .end, ellipsis) ?? l
                }
                owner.items[i].line = l
                line = l
            }
            let color: NSColor = isCurrent ? .controlAccentColor : level == 0 ? .labelColor : .secondaryLabelColor
            ctx.setFillColor(color.cgColor)
            ctx.textPosition = CGPoint(x: x, y: r.midY + (font.ascender + font.descender) / 2)
            CTLineDraw(line, ctx)
        }
    }

    func row(at p: CGPoint) -> Int { Int(((p.y - top - 20) / rowHeight).rounded(.down)) }

    override func mouseDown(with event: NSEvent) {
        if owner?.lateClickHandled?(event) == true { return }
        owner?.clicked(row: row(at: convert(event.locationInWindow, from: nil)))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
