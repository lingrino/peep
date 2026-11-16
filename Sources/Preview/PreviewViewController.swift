import AppKit
import QuickLookUI
import os

let log = Logger(subsystem: "com.lingrino.peep", category: "preview")

/// Milliseconds between this process's start and the monotonic instant `t` (from `nanotime`).
func processAgeMs(at t: UInt64) -> Double {
    var kp = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    guard sysctl(&mib, 4, &kp, &size, nil, 0) == 0 else { return -1 }
    let st = kp.kp_proc.p_un.__p_starttime
    let startWall = Double(st.tv_sec) + Double(st.tv_usec) / 1e6
    let nowWall = Date().timeIntervalSince1970 - Double(nanotime() - t) / 1e9
    return (nowWall - startWall) * 1000
}

/// Quick Look principal class. One instance per visible preview (Finder's column preview and
/// the spacebar panel each get their own); the extension process is reused across previews.
@objc(PeepPreviewController)
final class PreviewViewController: NSViewController, @preconcurrency QLPreviewingController {
    private var preview: PreviewView!
    private var agentID: UInt64 = 0
    private var visible = false
    private var reportedSize = CGSize.zero

    override func loadView() {
        ImageStore.remoteFetch = { url, done in AgentClient.shared.fetch(url, done) }
        preview = PreviewView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view = preview
        agentID = AgentClient.shared.register({ [weak self] code, chars, mods in
            self?.preview.handleKey(code: code, chars: chars, mods: mods)
        }, click: { [weak self] point, panel, ts in
            self?.earlyClick(point, panel, ts)
        })
        preview.onLateMouseDown = { [weak self] e in self?.calibrate(e) }
        preview.onStateChange = { [weak self] in self?.report() }
        preview.onExternalLink = { url in AgentClient.shared.open(url) }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        #if PEEP_DIAG
        Diag.log.notice("shown \(((self.preview.document?.path ?? "-") as NSString).lastPathComponent, privacy: .public)")
        #endif
        visible = true
        report()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        visible = false
        report()
        AgentClient.shared.unregister(agentID)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if visible && view.bounds.size != reportedSize { report() }
    }

    // MARK: - Early clicks

    /// Where this preview sits inside the Quick Look panel (offset of its top-left from the
    /// panel's). Measured from the first click Quick Look delivers; until then a guess:
    /// centered horizontally, bottom margin equal to the side margins.
    private static var panelInset: CGPoint?
    /// Recent clicks forwarded by the agent (timestamp, point in the panel).
    private var forwarded: [(ts: TimeInterval, point: CGPoint)] = []

    /// A click the agent saw ~0.5 s before Quick Look will deliver it (see Agent.forwardClick).
    private func earlyClick(_ point: CGPoint, _ panel: CGSize, _ ts: TimeInterval) {
        forwarded.append((ts, point))
        if forwarded.count > 8 { forwarded.removeFirst() }
        let vs = view.bounds.size
        let side = max(0, (panel.width - vs.width) / 2)
        let inset = PreviewViewController.panelInset ?? CGPoint(x: side, y: panel.height - vs.height - side)
        preview.earlyClick(at: CGPoint(x: point.x - inset.x, y: point.y - inset.y), timestamp: ts)
    }

    /// The late copy of a forwarded click: its exact position in our view fixes the inset.
    private func calibrate(_ e: NSEvent) {
        guard let i = forwarded.firstIndex(where: { abs($0.ts - e.timestamp) < 0.01 }) else { return }
        let local = preview.convert(e.locationInWindow, from: nil)
        let inset = CGPoint(x: forwarded[i].point.x - local.x, y: forwarded[i].point.y - local.y)
        forwarded.remove(at: i)
        if PreviewViewController.panelInset != inset {
            PreviewViewController.panelInset = inset
            log.debug("panel inset \(inset.x, format: .fixed(precision: 1)),\(inset.y, format: .fixed(precision: 1))")
        }
    }

    /// Tells the keyboard agent what this preview needs (see Agent.shouldIntercept).
    private func report() {
        reportedSize = view.bounds.size
        AgentClient.shared.sendState(id: agentID, size: reportedSize, visible: visible,
                                     find: preview.isFinding, selection: preview.documentView.hasSelection,
                                     matches: preview.hasMatches, path: preview.document?.path ?? "")
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        let t0 = nanotime()
        #if PEEP_DIAG
        Diag.log.notice("prepare begin \(url.lastPathComponent, privacy: .public)")
        #endif
        let doc = Document.open(path: url.path)
        let preferred = preferredSize()
        preferredContentSize = preferred
        // Lay out at the size Quick Look is about to give the panel, not the transient one it
        // has now (avoids a second markdown layout). Finder's small column-view preview pane
        // keeps its own size.
        if view.bounds.width >= 400 && view.bounds.size != preferred {
            view.setFrameSize(preferred)
            view.layoutSubtreeIfNeeded()
        }
        preview.show(doc)
        // Draw the first screen of tiles now, so the layers already hold content when Quick
        // Look composites the remote view (saves a display cycle).
        preview.displayIfNeeded()
        handler(nil)
        let ms = Double(nanotime() - t0) / 1e6
        log.notice("prepare \(url.lastPathComponent, privacy: .public): \(doc.timingSummary, privacy: .public) | total \(ms, format: .fixed(precision: 2))ms")
        if PreviewViewController.firstPrepare {
            // Cold start: how long the process existed before our first preview began.
            PreviewViewController.firstPrepare = false
            log.notice("cold start: first prepare began \(processAgeMs(at: t0), format: .fixed(precision: 1))ms after process start")
        }
    }

    private static var firstPrepare = true

    /// One panel size for every preview. Quick Look resizes its panel to each preview's
    /// preferred size, and resizing while stepping through files with the panel open (arrow
    /// keys) stalled this process's main thread 430-480 ms at a time: ViewBridge tears down the
    /// previous preview's service window with a synchronous WindowServer round trip, which
    /// waited out the resize. Sized per file (code fitted its content) the panel also jumped
    /// around. Wide enough for the symbol sidebar (shown from 780 pt).
    private func preferredSize() -> NSSize {
        let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
        return NSSize(width: min(980, (screen.width * 0.7).rounded()), height: (screen.height * 0.8).rounded())
    }
}
