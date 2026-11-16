import AppKit

/// Root view of a preview: a scroll view around the DocumentView, plus overlays (find bar,
/// markdown outline). Used by both the Quick Look extension and the host app's viewer.
public final class PreviewView: NSView {
    public let scrollView = NSScrollView()
    public let documentView = DocumentView(frame: .zero)
    public private(set) var document: Document?
    private var lastWidth: CGFloat = 0

    public override var isFlipped: Bool { true }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = documentView
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.contentView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsChanged),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(clipFrameChanged),
                                               name: NSView.frameDidChangeNotification, object: scrollView.contentView)
        addSubview(scrollView)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func clipBoundsChanged() {
        documentView.updateTiles()
    }

    @objc private func clipFrameChanged() {
        let w = scrollView.contentView.bounds.width
        if abs(w - lastWidth) >= 1 {
            lastWidth = w
            documentView.relayout()
        }
        documentView.updateTiles()
    }

    public override func layout() {
        super.layout()
        scrollView.frame = bounds
    }

    public func show(_ doc: Document) {
        document = doc
        doc.onUpdate = { [weak self] in self?.documentView.invalidateAll() }
        layoutSubtreeIfNeeded()
        lastWidth = scrollView.contentView.bounds.width
        documentView.setContent(doc.content, width: lastWidth)
    }

    // MARK: - Find

    private var matches: MatchList?
    public private(set) var currentMatch = -1

    /// Runs a search and highlights all matches; reveals the first match at/after the
    /// selection start. Returns the match count.
    @discardableResult
    public func find(_ query: String) -> Int {
        guard let doc = document else { return 0 }
        let q = Array(query.utf8)
        let m = Search.find(doc.content.text, q, caseSensitive: Search.isCaseSensitive(q))
        matches = m
        currentMatch = m.count == 0 ? -1 : m.index(atOrAfter: documentView.selectedRange.0)
        documentView.setMatches(m.buffer, current: currentMatch)
        if currentMatch >= 0 { documentView.reveal(m.start(currentMatch), m.end(currentMatch)) }
        return m.count
    }

    public func findNext(_ forward: Bool = true) {
        guard let m = matches, m.count > 0 else { return }
        currentMatch = forward ? (currentMatch + 1) % m.count : (currentMatch - 1 + m.count) % m.count
        documentView.setMatches(m.buffer, current: currentMatch)
        documentView.reveal(m.start(currentMatch), m.end(currentMatch))
    }

    public func clearFind() {
        matches = nil
        currentMatch = -1
        documentView.setMatches(UnsafeBufferPointer(start: nil, count: 0), current: -1)
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        Palette.current(for: self).background.withNSColor { $0.setFill() }
        dirtyRect.fill()
    }
}

extension CGColor {
    func withNSColor(_ body: (NSColor) -> Void) { if let c = NSColor(cgColor: self) { body(c) } }
}
