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

    private let effect = NSVisualEffectView()
    private let scroll = NSScrollView()
    private let list = OutlineList()
    private(set) var items: [Item] = []
    var onSelect: ((Int) -> Void)?

    static let width: CGFloat = 230

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        effect.material = .sidebar
        effect.blendingMode = .withinWindow
        effect.state = .active
        addSubview(effect)
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
        effect.frame = bounds
        scroll.frame = bounds.insetBy(dx: 0, dy: 0)
        list.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(bounds.height, list.contentHeight))
    }

    func setHeadings(_ hs: [MDHeading]) {
        let minLevel = hs.map(\.level).min() ?? 1
        items = hs.filter { $0.level <= max(3, minLevel + 1) }.map {
            Item(level: $0.level - minLevel, title: $0.title)
        }
        indexMap = hs.indices.filter { hs[$0].level <= max(3, minLevel + 1) }
        list.current = -1
        list.needsDisplay = true
        needsLayout = true
    }

    /// Maps outline rows to heading indices in the document.
    private(set) var indexMap: [Int] = []

    func setCurrent(heading: Int) {
        let row = indexMap.lastIndex { $0 <= heading } ?? -1
        if row != list.current {
            list.current = row
            list.needsDisplay = true
            if row >= 0 { list.scrollToVisible(list.rowRect(row).insetBy(dx: 0, dy: -24)) }
        }
    }

    fileprivate func clicked(row: Int) {
        guard row >= 0 && row < indexMap.count else { return }
        onSelect?(indexMap[row])
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
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

    override func draw(_ dirtyRect: NSRect) {
        guard let owner else { return }
        let header = NSAttributedString(string: "CONTENTS", attributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold), .foregroundColor: NSColor.tertiaryLabelColor, .kern: 0.6])
        header.draw(at: NSPoint(x: 18, y: top))
        for (i, item) in owner.items.enumerated() {
            let r = rowRect(i)
            if !r.intersects(dirtyRect) { continue }
            let isCurrent = i == current
            if isCurrent {
                NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
                NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
            }
            let font = item.level == 0 ? NSFont.systemFont(ofSize: 12.5, weight: .medium) : NSFont.systemFont(ofSize: 12)
            let color: NSColor = isCurrent ? .controlAccentColor : item.level == 0 ? .labelColor : .secondaryLabelColor
            let ps = NSMutableParagraphStyle()
            ps.lineBreakMode = .byTruncatingTail
            let x = r.minX + 10 + CGFloat(item.level) * 12
            NSAttributedString(string: item.title, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: ps])
                .draw(in: NSRect(x: x, y: r.minY + (rowHeight - 16) / 2, width: r.maxX - x - 6, height: 17))
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let row = Int((p.y - top - 20) / rowHeight)
        owner?.clicked(row: row)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
