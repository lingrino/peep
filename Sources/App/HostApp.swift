import AppKit
@preconcurrency import ServiceManagement

/// The app the user sees when opening Peep.app: setup status for the three moving parts
/// (Quick Look extension, keyboard agent, Accessibility permission) and a viewer that opens
/// any file with the same renderer as the Quick Look preview.
///
/// `Peep --register` (used by Scripts/build.sh) re-registers the agent and exits.
enum HostApp {
    @MainActor static func run() -> Never {
        if CommandLine.arguments.contains("--register") {
            registerAgent(force: true)
            exit(0)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.mainMenu = mainMenu()
        app.run()
        exit(0)
    }

    /// The keyboard agent is a classic per-user LaunchAgent (~/Library/LaunchAgents), not an
    /// SMAppService agent: SMAppService pins the executable's cdhash in a launch constraint,
    /// which locally-signed builds (no Team ID) violate on every rebuild.
    static var agentPlistPath: String {
        NSHomeDirectory() + "/Library/LaunchAgents/\(Agent.label).plist"
    }

    static var agentPlist: [String: Any] {
        [
            "Label": Agent.label,
            "ProgramArguments": [Bundle.main.executablePath ?? "/Applications/Peep.app/Contents/MacOS/Peep"],
            "MachServices": [Agent.label: true],
            "RunAtLoad": true,
            "KeepAlive": true,
            "ProcessType": "Interactive",
            "AssociatedBundleIdentifiers": ["com.lingrino.peep"],
        ]
    }

    static func agentLoaded() -> Bool {
        launchctl(["print", "gui/\(getuid())/\(Agent.label)"]) == 0
    }

    /// Installs (or refreshes) the LaunchAgent plist and (re)loads it.
    @MainActor static func registerAgent(force: Bool) {
        // Clean up an older SMAppService registration of the same label, if any.
        try? SMAppService.agent(plistName: "\(Agent.label).plist").unregister()
        let path = agentPlistPath
        let data = try? PropertyListSerialization.data(fromPropertyList: agentPlist, format: .xml, options: 0)
        let existing = FileManager.default.contents(atPath: path)
        let changed = existing != data
        if changed {
            try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: path, contents: data)
        }
        if force || changed || !agentLoaded() {
            _ = launchctl(["bootout", "gui/\(getuid())/\(Agent.label)"])
            _ = launchctl(["bootstrap", "gui/\(getuid())", path])
        }
    }

    @discardableResult
    static func launchctl(_ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    @MainActor static func mainMenu() -> NSMenu {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Peep", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Peep", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Peep", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem()
        main.addItem(fileItem)
        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Open…", action: #selector(AppDelegate.openDocument(_:)), keyEquivalent: "o")
        file.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = file

        let editItem = NSMenuItem()
        main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(ViewerWindow.copyText(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Select All", action: #selector(ViewerWindow.selectAllText(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Find…", action: #selector(ViewerWindow.findText(_:)), keyEquivalent: "f")
        edit.addItem(withTitle: "Find Next", action: #selector(ViewerWindow.findNextText(_:)), keyEquivalent: "g")
        let prev = NSMenuItem(title: "Find Previous", action: #selector(ViewerWindow.findPreviousText(_:)), keyEquivalent: "g")
        prev.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(prev)
        editItem.submenu = edit

        let windowItem = NSMenuItem()
        main.addItem(windowItem)
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = window
        NSApplication.shared.windowsMenu = window
        return main
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var status: StatusWindow?
    var viewers: [ViewerWindow] = []
    private var openedFiles = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        HostApp.registerAgent(force: false)
        if !openedFiles { showStatus() }
        NSApplication.shared.activate()
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        openedFiles = true
        for f in filenames { open(path: f) }
        sender.reply(toOpenOrPrint: .success)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showStatus() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func showStatus() {
        if status == nil { status = StatusWindow() }
        status?.refresh()
        status?.makeKeyAndOrderFront(nil)
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { for u in panel.urls { open(path: u.path) } }
    }

    func open(path: String) {
        let w = ViewerWindow(path: path)
        viewers.append(w)
        w.makeKeyAndOrderFront(nil)
    }
}

/// Setup status. Utilitarian: three rows, each with a state and a fix-it button.
@MainActor
final class StatusWindow: NSWindow {
    private let stack = NSStackView()
    private var timer: Timer?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 460, height: 260), styleMask: [.titled, .closable, .miniaturizable],
                   backing: .buffered, defer: false)
        title = "Peep"
        isReleasedWhenClosed = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 20, right: 22)
        contentView = stack
        center()
        // Permission changes happen in System Settings; poll while visible.
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if self?.isVisible == true { self?.refresh() } }
        }
        registerForDraggedTypes([.fileURL])
    }

    func refresh() {
        for v in stack.arrangedSubviews { v.removeFromSuperview() }
        let header = NSTextField(labelWithString: "Peep")
        header.font = .systemFont(ofSize: 20, weight: .semibold)
        let sub = NSTextField(wrappingLabelWithString: "Quick Look previews for source code and Markdown. Select a file in Finder and press Space; ⌘F searches inside the preview.")
        sub.textColor = .secondaryLabelColor
        sub.preferredMaxLayoutWidth = 416
        stack.addArrangedSubview(header)
        stack.addArrangedSubview(sub)

        let extOK = Self.extensionEnabled()
        stack.addArrangedSubview(row("Quick Look extension", ok: extOK, detail: extOK ? "Enabled" : "Not enabled",
                                     button: extOK ? nil : ("Open Settings", #selector(openExtensionSettings))))
        let agentOK = HostApp.agentLoaded()
        stack.addArrangedSubview(row("Keyboard agent", ok: agentOK, detail: agentOK ? "Running at login" : "Not running",
                                     button: agentOK ? nil : ("Start", #selector(enableAgent))))
        let axOK = AXIsProcessTrusted()
        stack.addArrangedSubview(row("Accessibility (for ⌘F, ⌘C, ⌘A in previews)", ok: axOK, detail: axOK ? "Granted" : "Not granted",
                                     button: axOK ? nil : ("Open Settings", #selector(openAccessibility))))
        let open = NSButton(title: "Open a File…", target: NSApp.delegate, action: #selector(AppDelegate.openDocument(_:)))
        stack.addArrangedSubview(open)
    }

    private func row(_ title: String, ok: Bool, detail: String, button: (String, Selector)?) -> NSView {
        let dot = NSImageView(image: NSImage(systemSymbolName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
                                             accessibilityDescription: nil)!)
        dot.contentTintColor = ok ? .systemGreen : .systemOrange
        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 13, weight: .medium)
        let d = NSTextField(labelWithString: detail)
        d.textColor = .secondaryLabelColor
        d.font = .systemFont(ofSize: 12)
        let texts = NSStackView(views: [t, d])
        texts.orientation = .vertical
        texts.alignment = .leading
        texts.spacing = 1
        var views: [NSView] = [dot, texts]
        if let (label, action) = button {
            let b = NSButton(title: label, target: self, action: action)
            b.controlSize = .small
            views.append(b)
        }
        let r = NSStackView(views: views)
        r.spacing = 10
        r.alignment = .centerY
        return r
    }

    static func extensionEnabled() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        p.arguments = ["-m", "-i", "com.lingrino.peep.preview"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return out.trimmingCharacters(in: .whitespaces).hasPrefix("+")
    }

    @objc private func openExtensionSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences")!)
    }

    @objc private func enableAgent() {
        HostApp.registerAgent(force: true)
        refresh()
    }

    @objc private func openAccessibility() {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] else { return false }
        for u in urls { (NSApp.delegate as? AppDelegate)?.open(path: u.path) }
        return true
    }
}

/// A normal window showing a file with the preview renderer. Here the window *is* key, so
/// menu shortcuts drive the same handlers the keyboard agent drives in Quick Look.
@MainActor
final class ViewerWindow: NSWindow {
    let preview: PreviewView

    init(path: String) {
        let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        preview = PreviewView(frame: NSRect(x: 0, y: 0, width: min(1000, screen.width * 0.7), height: screen.height * 0.8))
        super.init(contentRect: preview.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
                   backing: .buffered, defer: false)
        title = (path as NSString).lastPathComponent
        representedURL = URL(fileURLWithPath: path)
        isReleasedWhenClosed = false
        contentView = preview
        preview.onExternalLink = { s in
            if let u = URL(string: s), u.scheme != nil { NSWorkspace.shared.open(u) }
        }
        preview.show(Document.open(path: path))
        center()
        setFrameAutosaveName("PeepViewer")
    }

    /// Typing goes to the find bar while it is open (same path as forwarded keys in QL).
    override func keyDown(with event: NSEvent) {
        if preview.isFinding {
            preview.handleKey(code: event.keyCode, chars: event.characters ?? "", mods: UInt64(event.modifierFlags.rawValue))
        } else if event.keyCode == 53 {
            performClose(nil)
        } else {
            super.keyDown(with: event)
        }
    }

    @objc func copyText(_ sender: Any?) { preview.handleKey(code: 8, chars: "c", mods: 0x100000) }
    @objc func selectAllText(_ sender: Any?) { preview.handleKey(code: 0, chars: "a", mods: 0x100000) }
    @objc func findText(_ sender: Any?) { preview.handleKey(code: 3, chars: "f", mods: 0x100000) }
    @objc func findNextText(_ sender: Any?) { preview.handleKey(code: 5, chars: "g", mods: 0x100000) }
    @objc func findPreviousText(_ sender: Any?) { preview.handleKey(code: 5, chars: "g", mods: 0x100000 | 0x20000) }
}
