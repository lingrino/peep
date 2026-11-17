import AppKit
import ApplicationServices
import os

/// A copy-path button just after the title of a Quick Look panel: any previewer's file in
/// Finder's panel, a Peep preview's in any app's.
///
/// The title bar belongs to Quick Look (another process), so the button is a tiny window of
/// the agent's, floating just above the panel and placed from the title text's Accessibility
/// frame. It is non-activating and never key: Finder keeps the keyboard and the panel stays
/// open. It follows the panel once input pauses after preview changes (state messages) and
/// keys or clicks in Finder, after drags and resizes (mouse up), and on a slow poll; it hides
/// while the panel is dragged or resized.
@MainActor
final class TitleButton {
    private var panel: NSPanel?
    private var view: CopyPathView?
    private var timer: Timer?
    private var dragging = false
    private var lastPanel = CGRect.null
    private var scheduled = false
    private var lastPoke: UInt64 = 0

    /// Shown, or hidden for a drag that will bring it back: mouse events matter.
    var active: Bool { dragging || panel?.isVisible == true }

    /// Something changed (a preview's state, a key or click in Finder): re-place once input
    /// pauses, then twice more while the panel's zoom or resize settles. Placing asks Finder
    /// (Accessibility, served on its main thread) for the title's frame; per key repeat while
    /// stepping through files that would compete with Finder's own work.
    func soon() {
        lastPoke = nanotime()
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { MainActor.assumeIsolated { self.settle() } }
    }

    private func settle() {
        let quiet = nanotime() - lastPoke
        if quiet < 90_000_000 {
            DispatchQueue.main.asyncAfter(deadline: .now() + .nanoseconds(Int(100_000_000 - quiet))) { MainActor.assumeIsolated { self.settle() } }
            return
        }
        scheduled = false
        update()
        for delay in [0.2, 0.45] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { self.update() } }
        }
    }

    func mouseDown(at p: CGPoint) {
        guard let w = panel, w.isVisible, !lastPanel.isNull, lastPanel.contains(p) || lastPanel.insetBy(dx: -6, dy: -6).contains(p) else { return }
        // A press on the title bar or an edge starts a move or resize: hide until mouse up.
        let onButton = w.frame.contains(NSPoint(x: p.x, y: TitleButton.flip(p.y)))
        let titleBar = p.y < lastPanel.minY + 34
        let edge = !lastPanel.insetBy(dx: 6, dy: 6).contains(p)
        if !onButton && (titleBar || edge) { dragging = true; w.orderOut(nil) }
    }

    func mouseUp() {
        guard dragging else { return }
        dragging = false
        soon()
    }

    func update() {
        guard !dragging else { return }
        guard let (pid, panelRect, preview) = AgentCore.shared.frontPanel() else { hide(); return }
        // A Peep preview reports its file; any other previewer's file is Finder's selection.
        let path = preview?.path ?? ""
        guard !path.isEmpty || AgentCore.shared.finderFront else {
            Agent.log.debug("title button: no path for the frontmost app's panel")
            hide(); return
        }
        guard let title = TitleButton.title(pid: pid, panel: panelRect) else {
            Agent.log.debug("title button: no title element in panel \(String(describing: panelRect), privacy: .public)")
            hide(); return
        }
        let size: CGFloat = 20
        // A narrow panel (a small image) truncates its title against its controls: no room.
        guard title.room >= size + 8 else { hide(); return }
        lastPanel = panelRect
        // After the title, vertically centered on it (AX and CG: top-left origin; AppKit: bottom-left).
        let x = title.frame.maxX + 4, yTop = title.frame.midY - size / 2
        let frame = NSRect(x: x, y: TitleButton.flip(yTop + size), width: size, height: size)
        let w = panel ?? makePanel()
        let name = title.text
        view?.resolve = path.isEmpty ? { TitleButton.finderSelection(pid: pid, named: name) } : { path }
        if w.frame != frame { w.setFrame(frame, display: false) }
        if !w.isVisible { w.orderFrontRegardless() }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                MainActor.assumeIsolated {
                    // Not while input is still arriving (soon() places once it pauses).
                    if nanotime() - self.lastPoke > 300_000_000 && !self.scheduled { self.update() }
                }
            }
        }
    }

    private func hide() {
        panel?.orderOut(nil)
        if !dragging { timer?.invalidate(); timer = nil; lastPanel = .null }
    }

    private func makePanel() -> NSPanel {
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 20, height: 20), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        w.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)   // above the QL panel
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.hidesOnDeactivate = false
        w.becomesKeyOnlyIfNeeded = true
        w.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        let v = CopyPathView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
        w.contentView = v
        panel = w
        view = v
        return w
    }

    /// Top-left-origin y (AX, CG) to AppKit's bottom-left origin on the main screen.
    static func flip(_ y: CGFloat) -> CGFloat { (NSScreen.screens.first?.frame.height ?? 0) - y }

    /// The title text in the Quick Look panel matching `panel`: its frame (top-left origin),
    /// string (the file's name) and the free space after it, up to the first title bar control.
    static func title(pid: pid_t, panel: CGRect) -> (frame: CGRect, text: String, room: CGFloat)? {
        let app = AXUIElementCreateApplication(pid)
        guard let windows: [AXUIElement] = value(app, kAXWindowsAttribute) else { return nil }
        for w in windows {
            guard let f = frame(w), abs(f.minX - panel.minX) < 2, abs(f.minY - panel.minY) < 2,
                  abs(f.width - panel.width) < 2 else { continue }
            guard let t = findTitle(w, below: f.minY + 34, depth: 0) else { return nil }
            let controls = firstControl(w, after: t.frame.maxX - 1, below: f.minY + 34, depth: 0) ?? f.maxX
            return (t.frame, t.text, controls - t.frame.maxX)
        }
        return nil
    }

    /// Left edge of the leftmost title bar button right of `x` (share, open, rotate...).
    private static func firstControl(_ e: AXUIElement, after x: CGFloat, below maxY: CGFloat, depth: Int) -> CGFloat? {
        guard depth < 4, let children: [AXUIElement] = value(e, kAXChildrenAttribute) else { return nil }
        var best: CGFloat?
        for c in children {
            guard let f = frame(c), f.minY < maxY else { continue }
            if let role: String = value(c, kAXRoleAttribute), role == kAXButtonRole as String || role == kAXMenuButtonRole as String {
                if f.minX > x { best = min(best ?? .infinity, f.minX) }
            } else if let m = firstControl(c, after: x, below: maxY, depth: depth + 1) {
                best = min(best ?? .infinity, m)
            }
        }
        return best
    }

    private static func findTitle(_ e: AXUIElement, below maxY: CGFloat, depth: Int) -> (frame: CGRect, text: String)? {
        guard depth < 4, let children: [AXUIElement] = value(e, kAXChildrenAttribute) else { return nil }
        for c in children {
            if let role: String = value(c, kAXRoleAttribute), role == kAXStaticTextRole as String,
               let f = frame(c), f.minY < maxY, f.width > 0 { return (f, value(c, kAXValueAttribute) ?? "") }
        }
        for c in children {
            if let f = frame(c), f.minY > maxY { continue }   // the title is in the title bar
            if let t = findTitle(c, below: maxY, depth: depth + 1) { return t }
        }
        return nil
    }

    /// The path of the file Finder's Quick Look panel shows when another previewer shows it:
    /// the selected Finder item (Accessibility gives each a file reference URL) named like the
    /// panel's title. Asked only when the button is clicked.
    static func finderSelection(pid: pid_t, named name: String) -> String? {
        let app = AXUIElementCreateApplication(pid)
        var paths: [String] = []
        // Column view: the focused element is the active column's list. List view: the focus
        // is the Quick Look panel itself; search the browser window (the sidebar has a
        // selection too, hence the name match).
        if let f: AXUIElement = value(app, kAXFocusedUIElementAttribute) { selectedFiles(f, &paths, depth: 2) }
        if let p = pick(paths, name) { return p }
        let windows: [AXUIElement] = value(app, kAXWindowsAttribute) ?? []
        let main: AXUIElement? = value(app, kAXMainWindowAttribute)
            ?? windows.first { (value($0, kAXSubroleAttribute) as String?) == kAXStandardWindowSubrole as String }
        if let main { selectedFiles(main, &paths, depth: 10) }
        if let p = pick(paths, name) { return p }
        Agent.log.debug("title button: \(paths.count) selected files in Finder, none named like the panel's title")
        return nil
    }

    private static func pick(_ paths: [String], _ name: String) -> String? {
        if name.isEmpty { return paths.count == 1 ? paths[0] : nil }
        if let p = paths.first(where: { ($0 as NSString).lastPathComponent == name }) { return p }
        // Extension hidden in the title: only when one selected file fits (notes.md and
        // notes.txt both selected would be a guess).
        let fits = paths.filter { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension == name }
        return fits.count == 1 ? fits[0] : nil
    }

    /// Paths of the selected items of every list, outline or browser under `e`.
    private static func selectedFiles(_ e: AXUIElement, _ out: inout [String], depth: Int) {
        var selected: [AXUIElement] = value(e, kAXSelectedChildrenAttribute) ?? []
        if selected.isEmpty { selected = value(e, kAXSelectedRowsAttribute) ?? [] }
        for item in selected.prefix(200) {
            if let p = fileURL(in: item, depth: 0)?.path, !out.contains(p) { out.append(p) }
        }
        guard selected.isEmpty, depth > 0, let children: [AXUIElement] = value(e, kAXChildrenAttribute) else { return }
        for c in children { selectedFiles(c, &out, depth: depth - 1) }
    }

    /// The first file URL on an element or its descendants (Finder puts it on the name field).
    private static func fileURL(in e: AXUIElement, depth: Int) -> URL? {
        if let u: URL = value(e, kAXURLAttribute), u.isFileURL { return (u as NSURL).filePathURL ?? u }
        guard depth < 3, let children: [AXUIElement] = value(e, kAXChildrenAttribute) else { return nil }
        for c in children { if let u = fileURL(in: c, depth: depth + 1) { return u } }
        return nil
    }

    private static func value<T>(_ e: AXUIElement, _ attr: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success else { return nil }
        return v as? T
    }

    private static func frame(_ e: AXUIElement) -> CGRect? {
        guard let pv: AXValue = value(e, kAXPositionAttribute), let sv: AXValue = value(e, kAXSizeAttribute) else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(pv, .cgPoint, &p), AXValueGetValue(sv, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }
}

/// The button: a copy icon (a checkmark for a moment after copying), highlighted on hover.
final class CopyPathView: NSView {
    /// The path to copy, looked up when clicked (nil: unknown, nothing copied).
    var resolve: () -> String? = { nil }
    private var hover = false
    private var copiedUntil: TimeInterval = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        toolTip = "Copy path"
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hover = false; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        let path = resolve() ?? ""
        Agent.log.debug("title button: click (path \(path.isEmpty ? "unknown" : "found", privacy: .public))")
        guard !path.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        copiedUntil = ProcessInfo.processInfo.systemUptime + 1.2
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.25) { [weak self] in self?.needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        if hover {
            NSColor.labelColor.withAlphaComponent(0.1).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5).fill()
        }
        let copied = ProcessInfo.processInfo.systemUptime < copiedUntil
        let cfg = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [copied ? .systemGreen : (hover ? .labelColor : .secondaryLabelColor)]))
        guard let img = NSImage(systemSymbolName: copied ? "checkmark" : "doc.on.doc", accessibilityDescription: "Copy path")?
            .withSymbolConfiguration(cfg) else { return }
        let s = img.size
        img.draw(in: NSRect(x: (bounds.width - s.width) / 2, y: (bounds.height - s.height) / 2, width: s.width, height: s.height))
    }
}
