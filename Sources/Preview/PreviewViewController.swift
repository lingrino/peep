import AppKit
import QuickLookUI
import os

let log = Logger(subsystem: "com.lingrino.peep", category: "preview")

/// Quick Look principal class. One instance per visible preview (Finder's column preview and
/// the spacebar panel each get their own); the extension process is reused across previews.
@objc(PeepPreviewController)
final class PreviewViewController: NSViewController, @preconcurrency QLPreviewingController {
    private var preview: PreviewView!

    override func loadView() {
        preview = PreviewView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view = preview
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        let t0 = nanotime()
        let doc = Document.open(path: url.path)
        preview.show(doc)
        preferredContentSize = preferredSize(for: doc)
        handler(nil)
        let ms = Double(nanotime() - t0) / 1e6
        log.notice("prepare \(url.lastPathComponent, privacy: .public): \(doc.timingSummary, privacy: .public) | total \(ms, format: .fixed(precision: 2))ms")
    }

    /// Ask Quick Look for a panel that fits the content (it clamps to the screen).
    private func preferredSize(for doc: Document) -> NSSize {
        let c = doc.content
        let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        switch doc.kind {
        case .code:
            let w = min(max(c.size.width + c.gutterWidth + 24, 560), screen.width * 0.7)
            let h = min(max(c.size.height + 8, 240), screen.height * 0.8)
            return NSSize(width: w.rounded(), height: h.rounded())
        case .markdown:
            return NSSize(width: min(980, screen.width * 0.7), height: (screen.height * 0.8).rounded())
        default:
            return NSSize(width: 560, height: 320)
        }
    }
}
