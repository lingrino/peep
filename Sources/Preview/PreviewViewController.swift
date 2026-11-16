import AppKit
import QuickLookUI
import os

// SCAFFOLD: experiment to learn which events reach a view-based QL preview on this macOS.
let log = Logger(subsystem: "com.lingrino.peep", category: "preview")

final class ProbeTextView: NSTextView {
    override func keyDown(with event: NSEvent) {
        log.notice("keyDown chars=\(event.charactersIgnoringModifiers ?? "", privacy: .public) mods=\(event.modifierFlags.rawValue)")
        super.keyDown(with: event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        log.notice("performKeyEquivalent chars=\(event.charactersIgnoringModifiers ?? "", privacy: .public) mods=\(event.modifierFlags.rawValue)")
        return super.performKeyEquivalent(with: event)
    }
    override func mouseDown(with event: NSEvent) {
        log.notice("mouseDown window=\(String(describing: self.window), privacy: .public) key=\(self.window?.isKeyWindow ?? false) fr=\(String(describing: self.window?.firstResponder), privacy: .public)")
        super.mouseDown(with: event)
    }
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func becomeFirstResponder() -> Bool {
        log.notice("becomeFirstResponder")
        return super.becomeFirstResponder()
    }
}

@objc(PeepPreviewController)
final class PreviewViewController: NSViewController, @preconcurrency QLPreviewingController {
    private var textView: ProbeTextView!

    override func loadView() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        scroll.hasVerticalScroller = true
        scroll.autoresizingMask = [.width, .height]
        let tv = ProbeTextView(frame: scroll.bounds)
        tv.isEditable = false
        tv.isSelectable = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.autoresizingMask = [.width]
        tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        scroll.documentView = tv
        textView = tv
        let root = NSView(frame: scroll.frame)
        root.autoresizingMask = [.width, .height]
        scroll.frame = NSRect(x: 0, y: 0, width: 800, height: 570)
        let field = NSSearchField(frame: NSRect(x: 10, y: 572, width: 300, height: 24))
        field.autoresizingMask = [.minYMargin]
        field.target = self
        field.action = #selector(searchChanged(_:))
        root.addSubview(scroll)
        root.addSubview(field)
        view = root
        log.notice("loadView pid=\(getpid())")
    }

    @objc func searchChanged(_ sender: NSSearchField) {
        log.notice("search field: \(sender.stringValue, privacy: .public)")
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        log.notice("viewDidAppear window=\(String(describing: self.view.window), privacy: .public)")
        view.window?.makeFirstResponder(textView)
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        log.notice("prepare \(url.lastPathComponent, privacy: .public) main=\(Thread.isMainThread)")
        let s = (try? String(contentsOf: url, encoding: .utf8)) ?? "<unreadable>"
        textView.string = "PEEP SCAFFOLD\n\n" + s
        handler(nil)
    }
}
