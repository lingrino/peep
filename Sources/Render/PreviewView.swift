import AppKit

/// Root view of a preview: a scroll view around the DocumentView, plus overlays (find bar,
/// markdown outline). Used by both the Quick Look extension and the host app's viewer.
public final class PreviewView: NSView {
    public let scrollView = NSScrollView()
    public let documentView = DocumentView(frame: .zero)
    public private(set) var document: Document?
    private var lastWidth: CGFloat = 0
    private(set) var outline: OutlineView?
    /// Outline entry chosen by a click or link, kept highlighted while the view stays where
    /// the jump left it. An entry near the end can't scroll to the top, and the scroll
    /// position alone names an earlier entry: such clicks looked like they did nothing.
    private var pinned: (index: Int, scrollY: CGFloat)?
    private var notice: NoticeView?
    /// Links that leave the document (http, mailto, other files). In-document anchors are
    /// handled here.
    public var onExternalLink: ((String) -> Void)?

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
        documentView.onLink = { [weak self] l in self?.handleLink(l) }
        documentView.onMouseDownEvent = { [weak self] e in _ = self?.lateMouseDown(e) }
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func clipBoundsChanged() {
        documentView.updateTiles()
        updateOutlineCurrent()
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
        let showOutline = outline != nil && bounds.width >= 780
        if let o = outline {
            o.isHidden = !showOutline
            o.frame = NSRect(x: 0, y: 0, width: OutlineView.width, height: bounds.height)
        }
        scrollView.frame = showOutline ? NSRect(x: OutlineView.width, y: 0, width: bounds.width - OutlineView.width, height: bounds.height) : bounds
        if isFinding { positionFindBar() }
        if let n = notice {
            let s = n.fittingSize
            let area = scrollView.frame
            // At the top for documents opened at their end (logs), so it never covers the last line.
            let y = document?.startAtEnd == true ? area.minY + 14 : area.maxY - s.height - 14
            n.frame = NSRect(x: area.midX - s.width / 2, y: y, width: s.width, height: s.height)
        }
    }

    private func updateOutlineCurrent() {
        guard let o = outline, !o.isHidden, let c = document?.content else { return }
        let y = scrollView.contentView.bounds.minY
        if let p = pinned {
            if abs(y - p.scrollY) < 0.5 { o.setCurrent(heading: p.index); return }
            pinned = nil
        }
        o.setCurrent(heading: max(0, c.outlineIndex(atY: y + 40)))
    }

    /// Scrolls outline entry `i` to the top (as far as the document allows), marks it current
    /// and flashes it, so every jump shows where it landed.
    public func jumpToOutline(_ i: Int) {
        guard let span = document?.content.outlineSpan(i) else { return }
        reveal(span, outlineIndex: i)
    }

    private func reveal(_ span: (top: CGFloat, height: CGFloat), outlineIndex i: Int?) {
        documentView.scrollToTop(y: span.top - 12)
        let y = scrollView.contentView.bounds.minY
        if let i {
            pinned = (i, y)
            if let o = outline, !o.isHidden { o.setCurrent(heading: i) }
        }
        documentView.flash(top: span.top, height: span.height)
    }

    /// Sidebar for Markdown headings and code declarations, whenever there is at least one
    /// (whatever the document's length: the owner wants it always there).
    private func installOutline(_ c: DocumentContent) {
        let entries = c.outlineEntries
        guard !entries.isEmpty else { return }
        let o = OutlineView(frame: NSRect(x: 0, y: 0, width: OutlineView.width, height: bounds.height))
        o.setEntries(entries)
        o.lateClickHandled = { [weak self] e in self?.lateMouseDown(e) ?? false }
        o.onSelect = { [weak self] i in self?.jumpToOutline(i) }
        addSubview(o, positioned: .below, relativeTo: scrollView)
        outline = o
        needsLayout = true
    }

    /// Background work changed the content's entries (full lex of a big file).
    private func refreshOutline() {
        guard let c = document?.content else { return }
        pinned = nil
        if let o = outline {
            o.setEntries(c.outlineEntries)
            updateOutlineCurrent()
        } else {
            installOutline(c)
            if outline != nil {
                layoutSubtreeIfNeeded()
                clipFrameChanged()
            }
        }
    }

    private func handleLink(_ l: String) {
        if l.hasPrefix("#") {
            guard let c = document?.content, let span = c.anchorSpan(l) else { return }
            let i = c.outlineIndex(atY: span.top)
            // Headings also become the current outline entry; footnotes and references don't.
            reveal(span, outlineIndex: i >= 0 && c.outlineSpan(i)?.top == span.top ? i : nil)
            return
        }
        if let u = URL(string: l), u.scheme != nil { onExternalLink?(l); return }
        // Relative path: resolve against the document's directory.
        guard let path = document?.path else { return }
        var rel = l
        var fragment = ""
        if let h = rel.firstIndex(of: "#") { fragment = String(rel[h...]); rel = String(rel[..<h]) }
        if rel.isEmpty { handleLink(fragment); return }
        let base = URL(fileURLWithPath: path).deletingLastPathComponent()
        let target = base.appendingPathComponent(rel.removingPercentEncoding ?? rel).standardizedFileURL
        onExternalLink?(target.absoluteString)
    }

    public func show(_ doc: Document) {
        document = doc
        pinned = nil
        doc.onUpdate = { [weak self] in
            self?.documentView.invalidateAll()
            self?.refreshOutline()
        }
        doc.onContentReplaced = { [weak self, weak doc] in
            guard let self, let doc else { return }
            self.documentView.contentDidChangeLayout()
            if self.isFinding { _ = self.find(self.findBar.queryString) }   // offsets past the old end
            self.refreshOutline()
            self.showNotice(doc.notice)   // background work can add one (formatting capped)
        }
        outline?.removeFromSuperview()
        outline = nil
        if let md = doc.content as? MarkdownContent {
            md.onNeedsLayout = { [weak self, weak md] in
                md?.relayout()
                self?.documentView.contentDidChangeLayout()
            }
            md.onLayoutChanged = { [weak self] in
                self?.documentView.contentDidChangeLayout()
                self?.updateOutlineCurrent()
            }
            needsLayout = true
        }
        installOutline(doc.content)
        showNotice(doc.notice)
        documentView.onSelectionChange = { [weak self] in self?.onStateChange?() }
        if isFinding { closeFind() }
        layoutSubtreeIfNeeded()
        lastWidth = scrollView.contentView.bounds.width
        documentView.setContent(doc.content, width: lastWidth)
        // Before the first draw, so only the tiles at the end are ever rendered.
        if doc.startAtEnd { documentView.scrollToTop(y: .greatestFiniteMagnitude) }
    }

    private func showNotice(_ text: String?) {
        if notice?.string == text { return }
        notice?.removeFromSuperview()
        notice = nil
        if let text {
            let n = NoticeView(text)
            addSubview(n)
            notice = n
            needsLayout = true
        }
    }

    // MARK: - Early clicks

    /// Every mouse-down Quick Look delivers (~0.5 s late), before it is handled.
    public var onLateMouseDown: ((NSEvent) -> Void)?
    /// Timestamps of clicks already handled through `earlyClick`.
    private var earlyHandled: [TimeInterval] = []

    /// A click reported by the keyboard agent before Quick Look delivers it. `local` is in
    /// this view's coordinates. Table-of-contents clicks are handled now; everything else
    /// waits for the real event (drags, selection and links need the full event stream).
    public func earlyClick(at local: CGPoint, timestamp: TimeInterval) {
        guard let o = outline, !o.isHidden, o.frame.contains(local), o.click(at: convert(local, to: o)) else { return }
        renderLog.debug("early click handled \((ProcessInfo.processInfo.systemUptime - timestamp) * 1000, format: .fixed(precision: 1))ms after the event")
        earlyHandled.append(timestamp)
        if earlyHandled.count > 8 { earlyHandled.removeFirst() }
    }

    /// True if this (late) mouse-down was already handled early.
    private func lateMouseDown(_ e: NSEvent) -> Bool {
        onLateMouseDown?(e)
        guard let i = earlyHandled.firstIndex(where: { abs($0 - e.timestamp) < 0.01 }) else { return false }
        earlyHandled.remove(at: i)
        return true
    }

    // MARK: - Find

    private var matches: MatchList?
    public private(set) var currentMatch = -1
    public private(set) lazy var findBar: FindBar = {
        let b = FindBar(frame: NSRect(x: 0, y: 0, width: 360, height: 32))
        b.isHidden = true
        b.onChange = { [weak self] in self?.runFind() }
        b.onNext = { [weak self] in self?.findNext(true) }
        b.onPrev = { [weak self] in self?.findNext(false) }
        b.onClose = { [weak self] in self?.closeFind() }
        b.onActivate = { [weak self] in self?.openFind(prefill: false) }
        addSubview(b)
        return b
    }()

    /// True while the find bar is open and should receive typing.
    public private(set) var isFinding = false
    public var hasMatches: Bool { (matches?.count ?? 0) > 0 }

    /// Find/selection state changed (the extension reports it to the keyboard agent).
    public var onStateChange: (() -> Void)?

    public func openFind(prefill: Bool = true) {
        let bar = findBar
        if !isFinding {
            isFinding = true
            bar.isHidden = false
            positionFindBar()
            if prefill, documentView.hasSelection, let doc = document {
                let (s, e) = documentView.selectedRange
                if e - s < 200 {
                    let t = doc.content.copyText(s, e)
                    if !t.contains("\n") { bar.setQuery(t, selectAll: true) }
                }
            }
        }
        bar.selectAllText()
        bar.startEditing()
        if !bar.query.isEmpty { runFind() }
        onStateChange?()
    }

    public func closeFind() {
        guard isFinding else { return }
        isFinding = false
        findBar.stopEditing()
        findBar.isHidden = true
        // Leave the current match selected (so ⌘C copies it), drop the highlights.
        if let m = matches, currentMatch >= 0 { documentView.select(m.start(currentMatch), m.end(currentMatch)) }
        clearFind()
        onStateChange?()
    }

    private func positionFindBar() {
        let w = min(380, max(240, bounds.width - 24))
        findBar.frame = NSRect(x: bounds.width - w - 12, y: 10, width: w, height: 32)
    }

    private func runFind() {
        let q = findBar.queryString
        if q.isEmpty {
            clearFind()
            findBar.setStatus("", failed: false)
        } else {
            let n = find(q)
            findBar.setStatus(n == 0 ? "No matches" : "\(currentMatch + 1) of \(n)", failed: n == 0)
        }
        onStateChange?()
    }

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
        if isFinding { findBar.setStatus("\(currentMatch + 1) of \(m.count)", failed: false) }
    }

    public func clearFind() {
        matches = nil
        currentMatch = -1
        documentView.setMatches(UnsafeBufferPointer(start: nil, count: 0), current: -1)
    }

    // MARK: - Keys (forwarded by the agent)

    /// Handles a key event forwarded from the keyboard agent. `mods` are CGEventFlags bits.
    public func handleKey(code: UInt16, chars: String, mods: UInt64) {
        let cmd = mods & 0x100000 != 0, shift = mods & 0x20000 != 0, opt = mods & 0x80000 != 0
        if cmd {
            switch code {
            case 3: openFind()                                                  // ⌘F
            case 5: findNext(!shift)                                            // ⌘G / ⇧⌘G
            case 0: if isFinding { findBar.selectAllText() } else { documentView.selectAll() }
            case 8:                                                             // ⌘C
                if isFinding, let t = findBar.selectedText { copyString(t) } else { documentView.copy(nil) }
            case 7:                                                             // ⌘X
                if isFinding, let t = findBar.selectedText { copyString(t); findBar.deleteBackward(word: false, line: false) }
            case 9:                                                             // ⌘V
                if isFinding, let s = NSPasteboard.general.string(forType: .string) {
                    findBar.insert(s.replacingOccurrences(of: "\n", with: " "))
                }
            case 51: findBar.deleteBackward(word: false, line: true)            // ⌘⌫
            case 123: findBar.moveCaret(-1, toEnd: true)                        // ⌘←
            case 124: findBar.moveCaret(1, toEnd: true)                         // ⌘→
            default: break
            }
            onStateChange?()
            return
        }
        guard isFinding else { return }
        switch code {
        case 53: closeFind()                                                    // esc
        case 36, 76: findNext(!shift)                                           // return
        case 51: findBar.deleteBackward(word: opt, line: false)                 // ⌫
        case 117: findBar.deleteForward()                                       // ⌦
        case 123: findBar.moveCaret(-1, word: opt)                              // ←
        case 124: findBar.moveCaret(1, word: opt)                               // →
        case 125: findNext(true)                                                // ↓
        case 126: findNext(false)                                               // ↑
        case 48: break                                                          // tab
        default:
            let printable = chars.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value) }
            if !printable.isEmpty { findBar.insert(String(String.UnicodeScalarView(printable))) }
        }
    }

    private func copyString(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
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

/// Small pill at the bottom of the preview ("First 64 MB of 1.2 GB"). Only created when a
/// document has a notice, so ordinary previews pay nothing. Self-drawn: a visual-effect view
/// would not render in `peep-dev render` bitmaps, and one string needs no text field.
final class NoticeView: NSView {
    private let text: NSAttributedString
    var string: String { text.string }

    init(_ s: String) {
        text = NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override var fittingSize: NSSize { NSSize(width: ceil(text.size().width) + 24, height: 22) }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2)
        NSColor.windowBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
        let h = text.size().height
        text.draw(at: NSPoint(x: 12, y: (bounds.height - h) / 2))
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }   // never blocks selection/scrolling
}
