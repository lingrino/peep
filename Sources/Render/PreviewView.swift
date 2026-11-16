import AppKit

/// Root view of a preview: a scroll view around the DocumentView, plus overlays (find bar,
/// markdown outline). Used by both the Quick Look extension and the host app's viewer.
public final class PreviewView: NSView {
    public let scrollView = NSScrollView()
    public let documentView = DocumentView(frame: .zero)
    public private(set) var document: Document?
    private var lastWidth: CGFloat = 0
    private var outline: OutlineView?
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
    }

    private func updateOutlineCurrent() {
        guard let o = outline, !o.isHidden, let md = document?.content as? MarkdownContent else { return }
        let top = scrollView.contentView.bounds.minY + 40
        var cur = -1
        for (i, y) in md.headingY.enumerated() where y <= top { cur = i }
        o.setCurrent(heading: max(0, cur))
    }

    private func handleLink(_ l: String) {
        if l.hasPrefix("#") {
            if let y = document?.content.anchorY(l) { documentView.scrollToTop(y: y - 12) }
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
        doc.onUpdate = { [weak self] in self?.documentView.invalidateAll() }
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
            if md.doc.headings.count >= 3 {
                let o = OutlineView(frame: NSRect(x: 0, y: 0, width: OutlineView.width, height: bounds.height))
                o.setHeadings(md.doc.headings)
                o.onSelect = { [weak self, weak md] i in
                    guard let md else { return }
                    md.finishLayout()
                    guard i < md.headingY.count else { return }
                    self?.documentView.scrollToTop(y: md.headingY[i] - 12)
                }
                addSubview(o, positioned: .below, relativeTo: scrollView)
                outline = o
            }
            needsLayout = true
        }
        documentView.onSelectionChange = { [weak self] in self?.onStateChange?() }
        if isFinding { closeFind() }
        layoutSubtreeIfNeeded()
        lastWidth = scrollView.contentView.bounds.width
        documentView.setContent(doc.content, width: lastWidth)
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
