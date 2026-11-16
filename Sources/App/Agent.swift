import AppKit
import ApplicationServices
import os

// SCAFFOLD agent: proves the Accessibility grant + event tap work. IPC comes next.
enum Agent {
    static let label = "com.lingrino.peep.agent"
    static let log = Logger(subsystem: "com.lingrino.peep", category: "agent")
    nonisolated(unsafe) static var tap: CFMachPort?

    @MainActor static func run() -> Never {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary  // kAXTrustedCheckOptionPrompt
        let trusted = AXIsProcessTrustedWithOptions(opts)
        log.notice("agent start trusted=\(trusted)")
        installTapWhenTrusted()
        CFRunLoopRun()
        exit(0)
    }

    static func installTapWhenTrusted() {
        if AXIsProcessTrusted(), installTap() { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { installTapWhenTrusted() }
    }

    static func installTap() -> Bool {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                        options: .defaultTap, eventsOfInterest: mask,
                                        callback: { _, type, event, _ in
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let t = Agent.tap { CGEvent.tapEnable(tap: t, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            let flags = event.flags
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if flags.contains(.maskCommand) && code == 3 /* kVK_ANSI_F */ {
                Agent.log.notice("cmd+F seen by agent")
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: nil) else {
            log.error("tapCreate failed")
            return false
        }
        tap = t
        let src = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        log.notice("event tap installed")
        return true
    }
}
