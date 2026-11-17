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
    /// nanotime of the last left mouse-down in a Quick Look panel showing a Peep preview (or of
    /// the mouse-up ending that press): links open only right after one.
    private var lastPanelClick: UInt64 = 0
    private var pressInPanel = false
    private var previews: [Preview] = []
    private var tap: CFMachPort?
    private var panelCache: (pid: pid_t, at: UInt64, rect: CGRect?) = (0, 0, nil)
    /// Finder is the frontmost app: its Quick Look panel gets the copy-path button whatever
    /// previewer shows the file (the path then comes from Finder's selection).
    private(set) var finderFront = false

    func start() {
        // Accessibility calls (the copy-path button's) are served on the target app's main
        // thread and wait up to 6 s by default when it is busy; they run on this thread, which
        // also serves the event tap, so every keystroke system-wide would wait with them. Cap
        // them process-wide (the system-wide element's timeout is the default for all).
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        Agent.log.notice("agent start trusted=\(AXIsProcessTrustedWithOptions(opts))")
        finderFront = NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder"
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification,
                                                          object: nil, queue: .main) { n in
            let finder = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == "com.apple.finder"
            MainActor.assumeIsolated {
                AgentCore.shared.finderFront = finder
                AgentCore.shared.titleButton.soon()
            }
        }
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
        // Only our own extension (same signing certificate) may connect; fail closed.
        guard requirement.withCString({ xpc_connection_set_peer_code_signing_requirement(peer, $0) }) == 0 else {
            Agent.log.error("peer requirement not set; connection refused")
            xpc_connection_cancel(peer)
            return
        }
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
            guard let s = xpc_dictionary_get_string(msg, "url"), let reply = xpc_dictionary_create_reply(msg) else { return }
            nonisolated(unsafe) let r = reply
            nonisolated(unsafe) let peerConn = peer
            guard let url = URL(string: String(cString: s)) else { xpc_connection_send_message(peer, r); return }
            RemoteFetch.shared.fetch(url) { data in   // policy and limits: see RemoteFetch
                if let data { data.withUnsafeBytes { xpc_dictionary_set_data(r, "data", $0.baseAddress!, data.count) } }
                xpc_connection_send_message(peerConn, r)
            }
        case "open":
            // Only right after a click in the panel: the extension handles untrusted documents,
            // and opening is the one thing it can ask for that acts outside a preview.
            guard nanotime() &- lastPanelClick < 3_000_000_000 else {
                Agent.log.notice("open refused: no recent click in the Quick Look panel")
                return
            }
            lastPanelClick = 0   // one click, one link
            if let s = xpc_dictionary_get_string(msg, "url"), let url = URL(string: String(cString: s)) {
                LinkPolicy.open(url)
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
        if titleButton.active {
            if type == .leftMouseDown { titleButton.mouseDown(at: event.location) }
            if type == .leftMouseUp { titleButton.mouseUp() }
        }
        // In Finder a key or click may open, close or move the Quick Look panel to another
        // file, whatever previewer shows it (Peep's previews also report their state).
        if finderFront && (type == .keyDown || type == .leftMouseUp) { titleButton.soon() }
        if previews.isEmpty { return Unmanaged.passUnretained(event) }
        if type == .leftMouseUp {
            // A press that began in the panel ends here: links open on mouse-up, ~0.5 s later
            // in the extension, however long the press was.
            if pressInPanel { lastPanelClick = nanotime(); pressInPanel = false }
            return Unmanaged.passUnretained(event)
        }
        if type == .leftMouseDown {
            pressInPanel = false
            if event.getIntegerValueField(.mouseEventClickState) == 1 { forwardClick(event) }
            return Unmanaged.passUnretained(event)   // never consumed: Quick Look still delivers it (late)
        }
        if type != .keyDown { return Unmanaged.passUnretained(event) }
        // Most keys can't be intercepted: skip the window-list query (~0.2 ms) for them.
        if !event.flags.contains(.maskCommand) && !previews.contains(where: \.find) { return Unmanaged.passUnretained(event) }
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

    /// The frontmost app's Quick Look panel and the Peep preview in it, if it is one (fresh,
    /// not cached).
    func frontPanel() -> (pid: pid_t, panel: CGRect, preview: Preview?)? {
        guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let panel = quickLookPanel(of: front) else { return nil }
        panelCache = (front, nanotime(), panel)
        return (front, panel, target())
    }

    /// The visible Peep preview shown in the frontmost app's Quick Look panel, if any.
    private func target() -> Preview? {
        guard let front = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let now = nanotime()
        if panelCache.pid != front || now - panelCache.at > 250_000_000 {
            panelCache = (front, now, quickLookPanel(of: front))
        }
        guard let panel = panelCache.rect else { return nil }
        // The preview whose size best matches the panel (the panel adds a title bar); every
        // preview asks for the same size, so ties are normal: the most recently updated wins.
        var best: Preview?
        var bestScore = CGFloat.infinity
        for p in previews where p.visible {
            let dw = abs(p.size.width - panel.width), dh = abs(p.size.height - panel.height)
            if dw > 60 || dh > 120 { continue }
            let score = dw + dh
            if score < bestScore || (score == bestScore && p.seen > best!.seen) { bestScore = score; best = p }
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
        lastPanelClick = nanotime()
        pressInPanel = true
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
