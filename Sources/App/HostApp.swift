import AppKit
import ServiceManagement

// SCAFFOLD host app: registers the keyboard agent and shows status.
enum HostApp {
    @MainActor static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        let service = SMAppService.agent(plistName: "\(Agent.label).plist")
        var status = "agent: \(service.status.rawValue)"
        do {
            try service.register()
            status = "agent registered (status \(service.status.rawValue))"
        } catch {
            status = "agent register error: \(error)"
        }

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 140),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Peep"
        let label = NSTextField(wrappingLabelWithString: "Peep Quick Look extension is installed.\n\(status)")
        label.frame = NSRect(x: 20, y: 20, width: 440, height: 100)
        window.contentView?.addSubview(label)
        window.center()
        window.makeKeyAndOrderFront(nil)
        app.activate()
        app.run()
        exit(0)
    }
}
