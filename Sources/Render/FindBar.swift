import AppKit

/// Floating find bar (top-right of the preview).
///
/// Quick Look previews never get keyboard focus, so this is not an NSTextField: the agent
/// forwards keystrokes and `PreviewView.handleKey` edits `query` directly. The field draws
/// its own text, selection and blinking caret.
@MainActor
public final class FindBar: NSView {
    public private(set) var query: [Character] = []
    var caret = 0
    var allSelected = false
    public var queryString: String { String(query) }

    var onChange: (() -> Void)?
    var onNext: (() -> Void)?
    var onPrev: (() -> Void)?
    var onClose: (() -> Void)?
    var onActivate: (() -> Void)?

    private let background = NSVisualEffectView()
    private let field = QueryField()
    private let count = NSTextField(labelWithString: "")
    private let prev = NSButton()
    private let next = NSButton()
    private let close = NSButton()
    private let icon = NSImageView()
    private var blink: Timer?

    public override var isFlipped: Bool { true }

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        background.material = .popover
        background.blendingMode = .withinWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.cornerCurve = .continuous
        background.layer?.borderWidth = 0.5
        background.layer?.borderColor = NSColor.separatorColor.cgColor
        addSubview(background)
        shadow = {
            let s = NSShadow()
            s.shadowBlurRadius = 8
            s.shadowOffset = NSSize(width: 0, height: -2)
            s.shadowColor = NSColor.black.withAlphaComponent(0.18)
            return s
        }()

        icon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Find")
        icon.contentTintColor = .secondaryLabelColor
        icon.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        addSubview(icon)

        field.bar = self
        addSubview(field)

        count.font = .systemFont(ofSize: 11, weight: .regular)
        count.textColor = .secondaryLabelColor
        count.alignment = .right
        count.lineBreakMode = .byClipping
        addSubview(count)

        for (b, name, action, tip) in [(prev, "chevron.up", #selector(prevClicked), "Previous (⇧⌘G)"),
                                       (next, "chevron.down", #selector(nextClicked), "Next (⌘G)"),
                                       (close, "xmark.circle.fill", #selector(closeClicked), "Done (Esc)")] {
            b.image = NSImage(systemSymbolName: name, accessibilityDescription: tip)
            b.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
            b.isBordered = false
            b.bezelStyle = .regularSquare
            b.imagePosition = .imageOnly
            b.contentTintColor = .secondaryLabelColor
            b.target = self
            b.action = action
            b.toolTip = tip
            addSubview(b)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    public override func layout() {
        super.layout()
        let h = bounds.height
        background.frame = bounds
        icon.frame = NSRect(x: 10, y: (h - 16) / 2, width: 16, height: 16)
        close.frame = NSRect(x: bounds.width - 28, y: (h - 20) / 2, width: 20, height: 20)
        next.frame = NSRect(x: close.frame.minX - 22, y: (h - 20) / 2, width: 20, height: 20)
        prev.frame = NSRect(x: next.frame.minX - 20, y: (h - 20) / 2, width: 20, height: 20)
        count.frame = NSRect(x: prev.frame.minX - 84, y: (h - 15) / 2, width: 80, height: 15)
        field.frame = NSRect(x: 32, y: 4, width: count.frame.minX - 36, height: h - 8)
    }

    @objc private func prevClicked() { onPrev?() }
    @objc private func nextClicked() { onNext?() }
    @objc private func closeClicked() { onClose?() }

    func setStatus(_ s: String, failed: Bool) {
        count.stringValue = s
        count.textColor = failed ? .systemRed : .secondaryLabelColor
    }

    // MARK: - Editing (driven by forwarded key events)

    func setQuery(_ s: String, selectAll: Bool) {
        query = Array(s)
        caret = query.count
        allSelected = selectAll && !query.isEmpty
        changed()
    }

    func insert(_ s: String) {
        if allSelected { query.removeAll(); caret = 0; allSelected = false }
        let chars = Array(s)
        query.insert(contentsOf: chars, at: caret)
        caret += chars.count
        changed()
    }

    func deleteBackward(word: Bool, line: Bool) {
        if allSelected { query.removeAll(); caret = 0; allSelected = false; changed(); return }
        guard caret > 0 else { return }
        var start = caret - 1
        if line { start = 0 }
        else if word {
            while start > 0 && query[start].isWhitespace { start -= 1 }
            while start > 0 && !query[start - 1].isWhitespace && !query[start - 1].isPunctuation { start -= 1 }
        }
        query.removeSubrange(start..<caret)
        caret = start
        changed()
    }

    func deleteForward() {
        if allSelected { query.removeAll(); caret = 0; allSelected = false; changed(); return }
        guard caret < query.count else { return }
        query.remove(at: caret)
        changed()
    }

    func moveCaret(_ delta: Int, toEnd: Bool = false, word: Bool = false) {
        if allSelected {
            allSelected = false
            caret = delta < 0 ? 0 : query.count
        } else if toEnd {
            caret = delta < 0 ? 0 : query.count
        } else if word {
            var c = caret
            if delta < 0 {
                while c > 0 && query[c - 1].isWhitespace { c -= 1 }
                while c > 0 && !query[c - 1].isWhitespace { c -= 1 }
            } else {
                while c < query.count && query[c].isWhitespace { c += 1 }
                while c < query.count && !query[c].isWhitespace { c += 1 }
            }
            caret = c
        } else {
            caret = max(0, min(query.count, caret + delta))
        }
        restartBlink()
    }

    func selectAllText() {
        allSelected = !query.isEmpty
        field.needsDisplay = true
    }

    var selectedText: String? { allSelected ? queryString : nil }

    private func changed() {
        restartBlink()
        onChange?()
    }

    // MARK: - Caret

    func startEditing() {
        isHidden = false
        restartBlink()
    }

    func stopEditing() {
        blink?.invalidate()
        blink = nil
        field.caretOn = false
        field.needsDisplay = true
    }

    private func restartBlink() {
        field.caretOn = true
        field.needsDisplay = true
        blink?.invalidate()
        blink = Timer.scheduledTimer(withTimeInterval: 0.53, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let f = self?.field else { return }
                f.caretOn.toggle()
                f.needsDisplay = true
            }
        }
    }

    public override func mouseDown(with event: NSEvent) { onActivate?() }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Draws the query text, select-all highlight, placeholder and caret.
@MainActor
final class QueryField: NSView {
    weak var bar: FindBar?
    var caretOn = false

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let bar else { return }
        let font = NSFont.systemFont(ofSize: 13)
        let text = bar.queryString
        let y = (bounds.height - (font.ascender - font.descender)) / 2 - 0.5
        if text.isEmpty {
            NSAttributedString(string: "Find", attributes: [.font: font, .foregroundColor: NSColor.placeholderTextColor])
                .draw(at: NSPoint(x: 0, y: y))
        } else {
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.labelColor]
            let full = NSAttributedString(string: text, attributes: attrs)
            let width = full.size().width
            // Keep the caret visible for long queries by shifting left.
            let caretX = NSAttributedString(string: String(bar.query.prefix(bar.caret)), attributes: attrs).size().width
            let shift = max(0, caretX - bounds.width + 4)
            if bar.allSelected {
                NSColor.selectedTextBackgroundColor.setFill()
                NSRect(x: -shift, y: 2, width: width, height: bounds.height - 4).fill()
            }
            full.draw(at: NSPoint(x: -shift, y: y))
            if caretOn && !bar.allSelected {
                NSColor.controlAccentColor.setFill()
                NSRect(x: caretX - shift, y: 4, width: 1.5, height: bounds.height - 8).fill()
            }
            return
        }
        if caretOn {
            NSColor.controlAccentColor.setFill()
            NSRect(x: 0, y: 4, width: 1.5, height: bounds.height - 8).fill()
        }
    }

    override func mouseDown(with event: NSEvent) { bar?.onActivate?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
