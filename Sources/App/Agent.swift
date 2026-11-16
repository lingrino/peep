import AppKit
import ApplicationServices
@preconcurrency import CoreGraphics
import Security
@preconcurrency import XPC
import os

/// The keyboard agent: Quick Look extensions never receive key events (the panel never
/// becomes key), so this launchd agent watches keystrokes with an Accessibility-enabled
/// event tap and forwards the ones meant for a visible Peep preview over XPC.
///
/// Interception is deliberately narrow (see `shouldIntercept`): nothing is swallowed unless
/// a Peep preview is showing in the frontmost app's Quick Look panel.
///
/// Wire protocol (XPC dictionaries, key "t" = message type):
///   extension -> agent  "state": id, w, h, visible, find, sel, matches, path
///                       "open":  url        (open a link; sandboxed extensions can't)
///                       "fetch": url -> reply {data} (remote images; QL's sandbox blocks network)
///   agent -> extension  "key":   id, code, chars, mods
enum Agent {
    static let label = "com.lingrino.peep.agent"
    static let log = Logger(subsystem: "com.lingrino.peep", category: "agent")

    @MainActor static func run() -> Never {
        let app = NSApplication.shared
        // Accessory, not prohibited: the copy-path button is a (never key, non-activating) window.
        app.setActivationPolicy(.accessory)
        AgentCore.shared.start()
        app.run()
        exit(0)
    }
}

/// Everything runs on the main thread: XPC handlers target the main queue and the event tap
/// is a main run loop source, so no locking is needed.
@MainActor
final class AgentCore {
    static let shared = AgentCore()

    struct Preview {
        var id: UInt64
        var size: CGSize
        var visible: Bool
        var find: Bool
        var selection: Bool
        var matches: Bool
        var conn: xpc_connection_t
        var seen: UInt64   // nanotime of last update (most recent wins ties)
        var path: String
    }

    private var listener: xpc_connection_t?
    nonisolated static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: c)
    }()
    private var previews: [Preview] = []
    private var tap: CFMachPort?
    private var panelCache: (pid: pid_t, at: UInt64, rect: CGRect?) = (0, 0, nil)

    func start() {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        Agent.log.notice("agent start trusted=\(AXIsProcessTrustedWithOptions(opts))")
        startListener()
        installTapWhenTrusted()
    }

    // MARK: - XPC

    private func startListener() {
        let l = xpc_connection_create_mach_service(Agent.label, DispatchQueue.main, UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER))
        let requirement = peerRequirement()
        xpc_connection_set_event_handler(l) { peer in
            guard xpc_get_type(peer) == XPC_TYPE_CONNECTION else { return }
            MainActor.assumeIsolated { AgentCore.shared.accept(peer, requirement: requirement) }
        }
        xpc_connection_resume(l)
        listener = l
    }

    private func accept(_ peer: xpc_connection_t, requirement: String) {
        // Only our own extension (same signing certificate) may connect.
        _ = requirement.withCString { xpc_connection_set_peer_code_signing_requirement(peer, $0) }
        // Peers don't inherit the listener's queue; everything here assumes the main thread.
        xpc_connection_set_target_queue(peer, DispatchQueue.main)
        xpc_connection_set_event_handler(peer) { msg in
            MainActor.assumeIsolated { AgentCore.shared.handle(msg, from: peer) }
        }
        xpc_connection_resume(peer)
    }

    private func handle(_ msg: xpc_object_t, from peer: xpc_connection_t) {
        if xpc_get_type(msg) == XPC_TYPE_ERROR {
            previews.removeAll { $0.conn === peer }
            titleButton.update()
            return
        }
        guard xpc_get_type(msg) == XPC_TYPE_DICTIONARY, let t = xpc_dictionary_get_string(msg, "t") else { return }
        switch String(cString: t) {
        case "state":
            let id = xpc_dictionary_get_uint64(msg, "id")
            let p = Preview(id: id,
                            size: CGSize(width: xpc_dictionary_get_double(msg, "w"), height: xpc_dictionary_get_double(msg, "h")),
                            visible: xpc_dictionary_get_bool(msg, "visible"),
                            find: xpc_dictionary_get_bool(msg, "find"),
                            selection: xpc_dictionary_get_bool(msg, "sel"),
                            matches: xpc_dictionary_get_bool(msg, "matches"),
                            conn: peer, seen: nanotime(),
                            path: xpc_dictionary_get_string(msg, "path").map { String(cString: $0) } ?? "")
            if let k = previews.firstIndex(where: { $0.id == id && $0.conn === peer }) {
                if p.visible { previews[k] = p } else { previews.remove(at: k) }
            } else if p.visible {
                previews.append(p)
            }
            titleButton.soon()
        case "fetch":
            guard let s = xpc_dictionary_get_string(msg, "url"), let url = URL(string: String(cString: s)),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  let reply = xpc_dictionary_create_reply(msg) else { return }
            nonisolated(unsafe) let r = reply
            nonisolated(unsafe) let peerConn = peer
            var req = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 15)
            req.setValue("Peep (Quick Look)", forHTTPHeaderField: "User-Agent")
            AgentCore.session.dataTask(with: req) { data, resp, _ in
                let ok = (resp as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
                if ok, let data, data.count <= 25 << 20 {
                    data.withUnsafeBytes { xpc_dictionary_set_data(r, "data", $0.baseAddress!, data.count) }
                }
                xpc_connection_send_message(peerConn, r)
            }.resume()
        case "open":
            if let s = xpc_dictionary_get_string(msg, "url"), let url = URL(string: String(cString: s)),
               ["http", "https", "mailto", "file"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }
        default:
            break
        }
    }

    /// Code requirement for peers: our own designated requirement with the extension's
    /// identifier (same certificate). Ad-hoc builds fall back to the identifier alone.
    private func peerRequirement() -> String {
        let fallback = "identifier \"com.lingrino.peep.preview\""
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return fallback }
        var req: SecRequirement?
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopyDesignatedRequirement(staticCode, [], &req) == errSecSuccess, let req else { return fallback }
        var str: CFString?
        guard SecRequirementCopyString(req, [], &str) == errSecSuccess, let s = str as String?,
              s.contains("certificate"), s.contains("identifier \"com.lingrino.peep\"") else { return fallback }
        return s.replacingOccurrences(of: "identifier \"com.lingrino.peep\"", with: fallback)
    }

    // MARK: - Event tap

    private func installTapWhenTrusted() {
        if AXIsProcessTrusted(), installTap() { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MainActor.assumeIsolated { AgentCore.shared.installTapWhenTrusted() }
        }
    }

    private func installTap() -> Bool {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: { _, type, event, _ in
            MainActor.assumeIsolated { AgentCore.shared.tapped(type, event) }
        }, userInfo: nil) else {
            Agent.log.error("tapCreate failed")
            return false
        }
        tap = t
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, t, 0), .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        Agent.log.notice("event tap installed")
        return true
    }

    /// Runs for every keystroke and mouse-down system-wide: the no-preview path must stay trivial.
    private func tapped(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if previews.isEmpty { return Unmanaged.passUnretained(event) }
        if type == .leftMouseUp { titleButton.mouseUp(); return Unmanaged.passUnretained(event) }
        if type == .leftMouseDown {
            titleButton.mouseDown(at: event.location)
            if event.getIntegerValueField(.mouseEventClickState) == 1 { forwardClick(event) }
            return Unmanaged.passUnretained(event)   // never consumed: Quick Look still delivers it (late)
        }
        if type != .keyDown { return Unmanaged.passUnretained(event) }
        let t = target()
        if event.flags.contains(.maskCommand) {
            // Debug aid (no characters are ever logged): why a ⌘-key was or wasn't taken.
            Agent.log.debug("cmd key \(event.getIntegerValueField(.keyboardEventKeycode)) panel=\(String(describing: self.panelCache.rect), privacy: .public) previews=\(self.previews.map { "\($0.id):\(Int($0.size.width))x\(Int($0.size.height))\($0.visible ? "" : "(hidden)")" }.joined(separator: ","), privacy: .public) target=\(t.map { String($0.id) } ?? "none", privacy: .public)")
        }
        guard let target = t, shouldIntercept(event, target) else { return Unmanaged.passUnretained(event) }
        send(event, to: target)
        return nil
    }

    private func shouldIntercept(_ e: CGEvent, _ p: Preview) -> Bool {
        let f = e.flags
        let code = e.getIntegerValueField(.keyboardEventKeycode)
        let cmd = f.contains(.maskCommand), ctrl = f.contains(.maskControl)
        if cmd {
            switch code {
            case 3: return !ctrl                                // ⌘F
            case 5: return p.find || p.matches                  // ⌘G / ⇧⌘G
            case 0: return true                                 // ⌘A
            case 8: return p.selection || p.find                // ⌘C
            case 9, 7, 6: return p.find                         // ⌘V ⌘X ⌘Z
            case 51, 123, 124, 117: return p.find               // ⌘⌫ ⌘← ⌘→ ⌘⌦
            default: return false
            }
        }
        if ctrl { return false }
        return p.find   // while finding, every plain/option/shift key edits the query
    }

    let titleButton = TitleButton()

    /// The panel and Peep preview the title button belongs to (fresh, not cached).
    func panelAndPreview() -> (pid: pid_t, panel: CGRect, preview: Preview)? {
        guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let panel = quickLookPanel(of: front) else { return nil }
        panelCache = (front, nanotime(), panel)
        guard let p = target() else { return nil }
        return (front, panel, p)
    }

    /// The visible Peep preview shown in the frontmost app's Quick Look panel, if any.
    private func target() -> Preview? {
        guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let now = nanotime()
        if panelCache.pid != front || now - panelCache.at > 250_000_000 {
            panelCache = (front, now, quickLookPanel(of: front))
        }
        guard let panel = panelCache.rect else { return nil }
        // The preview whose size best matches the panel (the panel adds a title bar).
        var best: Preview?
        var bestScore = CGFloat.infinity
        for p in previews where p.visible {
            let dw = abs(p.size.width - panel.width), dh = abs(p.size.height - panel.height)
            if dw > 60 || dh > 120 { continue }
            let score = dw + dh - CGFloat(p.seen % 1000) * 1e-9
            if score < bestScore { bestScore = score; best = p }
        }
        return best
    }

    /// Bounds of an on-screen floating-level window (the QL panel) owned by `pid`.
    private func quickLookPanel(of pid: pid_t) -> CGRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        for w in list {
            guard (w[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid,
                  let layer = w[kCGWindowLayer as String] as? Int, layer == Int(CGWindowLevelForKey(.floatingWindow)),
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let width = b["Width"], let height = b["Height"], width > 200, height > 150 else { continue }
            return CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: width, height: height)
        }
        return nil
    }

    /// Quick Look hands clicks to the extension only after the double-click interval (~510 ms,
    /// measured against this tap). Forwarding single clicks in the panel lets the extension act
    /// on them at once; it matches the late copy by its original timestamp and ignores it.
    private func forwardClick(_ e: CGEvent) {
        guard let p = target(), let panel = panelCache.rect, panel.contains(e.location),
              let ts = NSEvent(cgEvent: e)?.timestamp else { return }
        let msg = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(msg, "t", "click")
        xpc_dictionary_set_uint64(msg, "id", p.id)
        xpc_dictionary_set_double(msg, "x", e.location.x - panel.minX)   // from the panel's top-left
        xpc_dictionary_set_double(msg, "y", e.location.y - panel.minY)
        xpc_dictionary_set_double(msg, "pw", panel.width)
        xpc_dictionary_set_double(msg, "ph", panel.height)
        xpc_dictionary_set_double(msg, "ts", ts)
        xpc_connection_send_message(p.conn, msg)
    }

    private func send(_ e: CGEvent, to p: Preview) {
        var len = 0
        var buf = [UniChar](repeating: 0, count: 8)
        e.keyboardGetUnicodeString(maxStringLength: 8, actualStringLength: &len, unicodeString: &buf)
        let chars = String(utf16CodeUnits: buf, count: len)
        let msg = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(msg, "t", "key")
        xpc_dictionary_set_uint64(msg, "id", p.id)
        xpc_dictionary_set_uint64(msg, "code", UInt64(e.getIntegerValueField(.keyboardEventKeycode)))
        xpc_dictionary_set_uint64(msg, "mods", e.flags.rawValue)
        xpc_dictionary_set_string(msg, "chars", chars)
        xpc_connection_send_message(p.conn, msg)
    }
}

/// A copy-path button just after the title of a Quick Look panel showing a Peep preview.
///
/// The title bar belongs to Quick Look (another process), so the button is a tiny window of
/// the agent's, floating just above the panel and placed from the title text's Accessibility
/// frame. It is non-activating and never key: Finder keeps the keyboard and the panel stays
/// open. It follows the panel on preview changes (state messages), after drags and resizes
/// (mouse up), and on a slow poll; it hides while the panel is dragged or resized.
@MainActor
final class TitleButton {
    private var panel: NSPanel?
    private var view: CopyPathView?
    private var timer: Timer?
    private var dragging = false
    private var lastPanel = CGRect.null

    /// Re-place a few times while the panel settles (it zooms open), then keep polling slowly.
    func soon() {
        update()
        for delay in [0.12, 0.3, 0.55] {
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
        guard let (pid, panelRect, preview) = AgentCore.shared.panelAndPreview(), !preview.path.isEmpty else {
            Agent.log.debug("title button: no Peep preview in the frontmost app's panel")
            hide(); return
        }
        guard let title = TitleButton.titleFrame(pid: pid, panel: panelRect) else {
            Agent.log.debug("title button: no title element in panel \(String(describing: panelRect), privacy: .public)")
            hide(); return
        }
        lastPanel = panelRect
        let size: CGFloat = 20
        // After the title, vertically centered on it (AX and CG: top-left origin; AppKit: bottom-left).
        let x = title.maxX + 4, yTop = title.midY - size / 2
        let frame = NSRect(x: x, y: TitleButton.flip(yTop + size), width: size, height: size)
        let w = panel ?? makePanel()
        view?.path = preview.path
        if w.frame != frame { w.setFrame(frame, display: false) }
        if !w.isVisible { w.orderFrontRegardless() }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in MainActor.assumeIsolated { self.update() } }
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

    /// The title text's frame in the Quick Look panel matching `panel` (top-left origin).
    static func titleFrame(pid: pid_t, panel: CGRect) -> CGRect? {
        let app = AXUIElementCreateApplication(pid)
        guard let windows: [AXUIElement] = value(app, kAXWindowsAttribute) else { return nil }
        for w in windows {
            guard let f = frame(w), abs(f.minX - panel.minX) < 2, abs(f.minY - panel.minY) < 2,
                  abs(f.width - panel.width) < 2 else { continue }
            return findTitle(w, below: f.minY + 34, depth: 0)
        }
        return nil
    }

    private static func findTitle(_ e: AXUIElement, below maxY: CGFloat, depth: Int) -> CGRect? {
        guard depth < 4, let children: [AXUIElement] = value(e, kAXChildrenAttribute) else { return nil }
        for c in children {
            if let role: String = value(c, kAXRoleAttribute), role == kAXStaticTextRole as String,
               let f = frame(c), f.minY < maxY, f.width > 0 { return f }
        }
        for c in children {
            if let f = frame(c), f.minY > maxY { continue }   // the title is in the title bar
            if let t = findTitle(c, below: maxY, depth: depth + 1) { return t }
        }
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
    var path = ""
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
        Agent.log.debug("title button: click (path \(self.path.isEmpty ? "empty" : "set", privacy: .public))")
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
