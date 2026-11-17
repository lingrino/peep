import AppKit
import CoreText
import Synchronization
import os

/// Markdown block layout, run in parallel across blocks.
///
/// Each block is laid out independently in *local* coordinates (block top = 0) by
/// `MarkdownLayout.block`, which is nonisolated and touches only immutable inputs (`LayoutEnv`).
/// `MarkdownContent.relayout` lays out the first screen on the main thread and hands the rest
/// to `LayoutPool` (below), which measures blocks in parallel; positions are stacked on the
/// main thread (gaps, quote bars, list markers depend on neighbors). Core Text shaping is most
/// of layout cost, so this scales with P-cores up to Core Text's own locks (see AGENTS.md).

struct MDMetrics: Sendable {
    let body: CGFloat = 13
    var gap: CGFloat { body * 0.95 }
    var tightGap: CGFloat { body * 0.25 }
    let maxWidth: CGFloat = 880
    let padX: CGFloat = 28
    let padTop: CGFloat = 22
    let listIndent: CGFloat = 24
    let quoteIndent: CGFloat = 18
    let codePad: CGFloat = 12
    var codeSize: CGFloat { (body * 0.88).rounded() + 0.5 }

    func headingSize(_ level: UInt8) -> CGFloat {
        switch level {
        case 1: return (body * 1.9).rounded()
        case 2: return (body * 1.5).rounded()
        case 3: return (body * 1.25).rounded()
        case 4: return body + 1
        case 5: return body
        default: return body - 0.5
        }
    }

    func lineGap(_ size: CGFloat, _ multiple: CGFloat = 1.5) -> CGFloat { size * (multiple - 1.2) }
}

/// Fonts and text attributes for one layout thread at a time: `main` for the main thread,
/// `workers[w]` for background worker w.
///
/// Why per thread: Core Text serializes shaping per font *face* (OpenType substitution and
/// positioning take a lock shared by every instance of the face, i.e. every size and weight
/// of `NSFont.systemFont`), so layout threads sharing the system fonts ran one at a time
/// (64% of their time waiting). Fonts made from the font file's bytes are faces of their
/// own with their own locks. Over every size/weight/italic/mono combination used, they lay
/// out identically to the system fonts: glyph positions, widths, line metrics, and fallback
/// (CJK, emoji, Greek, Cyrillic, Korean); Hebrew and Arabic fallback differs by ~1 pt a line.
///
/// Then the bottleneck was Foundation: attributed strings unique their attribute dictionaries
/// in one process-wide table under one lock (and these fonts hash their descriptors, cascade
/// list included). A dictionary that is already uniqued skips it, so each book keeps the
/// dictionaries its runs use (`attributes`), uniqued once.
final class FontBook: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var fonts: [Int: NSFont] = [:]
    private var attrs: [AttrKey: CFDictionary] = [:]
    private var paragraphStyles: [Int: NSParagraphStyle] = [:]
    private var colors: [ObjectIdentifier: CGColor] = [:]

    /// Main-thread layout (synchronous prefix, on-demand blocks, list markers).
    static let main = FontBook()
    /// Background layout: one book per concurrent worker (`PendingLayout.run`).
    /// Performance cores less two: past ~10 threads Core Text's own locks (glyph storage
    /// retain/release) stop throughput from growing (10 MB document: 8 threads 475 ms, 10
    /// 456, 12 463, 16 501), and the spare cores keep Quick Look's panel animation smooth.
    static let workers: [FontBook] = {
        var p: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("hw.perflevel0.physicalcpu", &p, &size, nil, 0) != 0 || p <= 0 {
            p = Int32(ProcessInfo.processInfo.activeProcessorCount)
        }
        return (0..<max(4, Int(p) - 2)).map { _ in FontBook() }
    }()

    func font(_ size: CGFloat, weight: NSFont.Weight = .regular, italic: Bool = false, mono: Bool = false) -> NSFont {
        let key = Int(size * 4) << 8 | Int((weight.rawValue + 1) * 10) << 2 | (italic ? 2 : 0) | (mono ? 1 : 0)
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        if let f = fonts[key] { return f }
        var f = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        if italic, let i = NSFont(descriptor: f.fontDescriptor.withSymbolicTraits(.italic), size: size) { f = i }
        f = FontFiles.ownFace(like: f) ?? f
        fonts[key] = f
        return f
    }

    struct AttrKey: Hashable {
        var font: ObjectIdentifier
        var color: ObjectIdentifier
        var paragraph: Int       // `paragraphStyle` key
        var flags: UInt8         // AttrFlag
        var baseline: Int32      // offset in 1/100 pt
    }

    enum AttrFlag {
        static let inlineCode: UInt8 = 1, kbd: UInt8 = 2, strike: UInt8 = 4
    }

    /// A uniqued attribute dictionary for these attributes (built once per book).
    func attributes(font: NSFont, color: CGColor, paragraph: Int, flags: UInt8 = 0, baseline: CGFloat = 0) -> CFDictionary {
        let key = AttrKey(font: ObjectIdentifier(font), color: ObjectIdentifier(color), paragraph: paragraph,
                          flags: flags, baseline: Int32((baseline * 100).rounded()))
        os_unfair_lock_lock(&lock)
        if let d = attrs[key] { os_unfair_lock_unlock(&lock); return d }
        os_unfair_lock_unlock(&lock)
        var a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: ownColor(color), .paragraphStyle: paragraphStyle(paragraph)]
        if flags & AttrFlag.inlineCode != 0 { a[MDAttr.inlineCode] = true }
        if flags & AttrFlag.kbd != 0 { a[MDAttr.kbd] = true }
        if flags & AttrFlag.strike != 0 { a[MDAttr.strike] = true }
        if key.baseline != 0 { a[ctBaselineOffset] = baseline }
        // As Foundation stores it: read back from an attributed string (uniqued).
        let s = CFAttributedStringCreate(nil, " " as CFString, a as CFDictionary)!
        let d = CFAttributedStringGetAttributes(s, 0, nil)!
        os_unfair_lock_lock(&lock)
        attrs[key] = d
        os_unfair_lock_unlock(&lock)
        return d
    }

    /// This book's own instance of a palette color. Core Text retains and releases every
    /// attribute value per run, as it builds and frees lines; one color object shared by all
    /// layout threads made those atomic refcount updates contend (38% of background layout
    /// in CFRetain/CFRelease on a 10 MB document).
    private func ownColor(_ c: CGColor) -> CGColor {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        if let o = colors[ObjectIdentifier(c)] { return o }
        guard let cs = c.colorSpace, let comps = c.components, let o = CGColor(colorSpace: cs, components: comps) else { return c }
        colors[ObjectIdentifier(c)] = o
        return o
    }

    /// Paragraph style keys: alignment and line height multiple for text, or `codeParagraph`.
    static func paragraphKey(_ align: MDAlign, lineHeight: CGFloat) -> Int { Int(align.rawValue) << 16 | Int((lineHeight * 100).rounded()) }
    static let codeParagraph = -1

    func paragraphStyle(_ key: Int) -> NSParagraphStyle {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        if let p = paragraphStyles[key] { return p }
        let ps = NSMutableParagraphStyle()
        if key == FontBook.codeParagraph {
            ps.lineHeightMultiple = 1.45
            os_unfair_lock_unlock(&lock)
            let tab = 4 * CTFontGetAdvanceForGlyphMonospaced(font(MDMetrics().codeSize, mono: true))
            os_unfair_lock_lock(&lock)
            ps.defaultTabInterval = tab
            ps.tabStops = []
        } else {
            ps.lineHeightMultiple = CGFloat(key & 0xFFFF) / 100
            let align = MDAlign(rawValue: UInt8(key >> 16)) ?? .left
            ps.alignment = align == .center ? .center : align == .right ? .right : .natural
        }
        paragraphStyles[key] = ps
        return ps
    }
}

/// The system font files, mapped once per process.
enum FontFiles {
    nonisolated(unsafe) private static var data: [String: CFData] = [:]
    nonisolated(unsafe) private static var lock = os_unfair_lock()

    /// `f` as a font of its own face, made from its file (nil: file unknown or unreadable;
    /// the caller keeps the shared font).
    static func ownFace(like f: NSFont) -> NSFont? {
        let ct = f as CTFont
        let name = CTFontCopyPostScriptName(ct) as String
        var path = (CTFontCopyAttribute(ct, kCTFontURLAttribute) as? URL)?.path
        if path == nil && name.hasPrefix(".AppleSystemUIFontMonospaced") {
            // The monospaced system font reports no file; it is SF Mono.
            path = name.contains("Italic") ? "/System/Library/Fonts/SFNSMonoItalic.ttf" : "/System/Library/Fonts/SFNSMono.ttf"
        }
        guard let path, let bytes = file(path), let base = CTFontManagerCreateFontDescriptorFromData(bytes) else { return nil }
        var attrs: [CFString: Any] = [kCTFontNameAttribute: name,
                                      // Fall back to the fonts the system font would (emoji, CJK, ...).
                                      kCTFontCascadeListAttribute: CTFontCopyDefaultCascadeListForLanguages(ct, nil) ?? [] as CFArray]
        if let v = CTFontCopyVariation(ct) { attrs[kCTFontVariationAttribute] = v }   // weight, optical size
        let d = CTFontDescriptorCreateCopyWithAttributes(base, attrs as CFDictionary)
        return CTFontCreateWithFontDescriptor(d, CTFontGetSize(ct), nil) as NSFont
    }

    private static func file(_ path: String) -> CFData? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        if let d = data[path] { return d }
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) else { return nil }
        data[path] = d as CFData
        return d as CFData
    }
}

enum DecoRole: Sendable { case border, blockBackground, secondary, text, accent, alert(MDAlert) }

enum Deco: @unchecked Sendable {
    case fill(CGRect, DecoRole, CGFloat)
    case line(CGRect, DecoRole)
    case bullet(CGPoint, Int)                 // center, depth
    case label(CTLine, CGPoint)               // ordered list number, right-aligned origin
    case check(CGRect, Bool)
    case alertIcon(CGRect, MDAlert)

    func offset(_ dy: CGFloat) -> Deco {
        switch self {
        case .fill(let r, let role, let rad): return .fill(r.offsetBy(dx: 0, dy: dy), role, rad)
        case .line(let r, let role): return .line(r.offsetBy(dx: 0, dy: dy), role)
        case .bullet(let p, let d): return .bullet(CGPoint(x: p.x, y: p.y + dy), d)
        case .label(let l, let p): return .label(l, CGPoint(x: p.x, y: p.y + dy))
        case .check(let r, let done): return .check(r.offsetBy(dx: 0, dy: dy), done)
        case .alertIcon(let r, let a): return .alertIcon(r.offsetBy(dx: 0, dy: dy), a)
        }
    }
}

struct PlacedDeco: @unchecked Sendable {
    var minY: CGFloat
    var maxY: CGFloat
    var deco: Deco
}

/// Everything layout needs, immutable for the duration of one relayout.
struct LayoutEnv: @unchecked Sendable {
    let doc: MarkdownDocument
    let palette: Palette
    let m: MDMetrics
    var fonts: FontBook
    let imageSizes: [CGSize]
    let x0: CGFloat
    let contentW: CGFloat
}

struct BlockLayout: @unchecked Sendable {
    var boxes: [TextBox] = []
    var decos: [PlacedDeco] = []
    var height: CGFloat = 0
    var firstBaseline: CGFloat?
    var right: CGFloat = 0
}

/// Background pass over the blocks after the synchronous prefix: lays each one out to
/// measure it and keeps only its height (frames are rebuilt on demand for what is shown).
/// Run in chunks by `LayoutPool`.
final class PendingLayout: @unchecked Sendable {
    let first: Int
    let count: Int
    let env: LayoutEnv
    /// Blocks per chunk: small (~5-10 ms), so cancellation and a newer job taking the
    /// threads over are prompt.
    let chunk: Int
    let chunks: Int
    private let hs: UnsafeMutableBufferPointer<CGFloat>
    private let rs: UnsafeMutableBufferPointer<CGFloat>
    /// Heights and right edges of blocks `first...`; complete once the job is done.
    var heights: UnsafeBufferPointer<CGFloat> { UnsafeBufferPointer(hs) }
    var rights: UnsafeBufferPointer<CGFloat> { UnsafeBufferPointer(rs) }
    private let done = DispatchGroup()
    /// Whether the job was handed to the pool (main thread only).
    var started = false
    /// Called on a pool thread once every chunk is measured (not when cancelled).
    var onDone: (@Sendable () -> Void)?
    // Pool bookkeeping, under the pool's lock.
    fileprivate var claimed = 0
    fileprivate var measured = 0
    fileprivate var isComplete = false
    private let stop = Atomic<Bool>(false)
    private weak var owner: AnyObject?

    init(first: Int, count: Int, env: LayoutEnv, owner: AnyObject) {
        self.first = first
        self.count = count
        self.env = env
        self.owner = owner
        chunk = max(8, min(128, count / 48))
        chunks = (count + chunk - 1) / chunk
        hs = .allocate(capacity: count)
        hs.initialize(repeating: 0)
        rs = .allocate(capacity: count)
        rs.initialize(repeating: 0)
        done.enter()
    }

    deinit {
        hs.deallocate()
        rs.deallocate()
    }

    /// Stops handing out chunks: the content was re-laid out or went away.
    fileprivate func cancel() { stop.store(true, ordering: .relaxed) }
    fileprivate var cancelled: Bool { stop.load(ordering: .relaxed) || owner == nil }

    fileprivate func measure(_ c: Int, _ fonts: FontBook) {
        var e = env
        e.fonts = fonts
        for i in (c * chunk)..<min(count, (c + 1) * chunk) {
            let l = MarkdownLayout.block(first + i, e)
            hs[i] = l.height
            rs[i] = l.right
        }
    }

    fileprivate func complete() {
        if !cancelled { onDone?() }
        onDone = nil
        done.leave()
    }

    /// Blocks until every chunk is measured (or the job was cancelled).
    func wait() { done.wait() }
}

/// Runs background layout jobs on a fixed set of threads (one `FontBook` each), newest job
/// first. Finder's column preview and the Space panel lay out their own copies of a
/// document; with a thread set per job (20 threads on 16 cores) the panel appeared only when
/// the column pane's job finished, ~300 ms after its preview was ready: Quick Look's own work
/// in this process was starved. For the same reason the threads run at default QoS, below
/// user-initiated work (as fast here: 10 MB document 383-408 ms either way; utility QoS
/// threads are throttled: 1.6 s).
final class LayoutPool: @unchecked Sendable {
    static let shared = LayoutPool()
    private var lock = os_unfair_lock()
    private var jobs: [PendingLayout] = []   // newest last
    private var busy = [Bool](repeating: false, count: FontBook.workers.count)

    func submit(_ job: PendingLayout) {
        job.started = true
        var start: [Int] = []
        os_unfair_lock_lock(&lock)
        jobs.append(job)
        for w in busy.indices where !busy[w] {
            busy[w] = true
            start.append(w)
        }
        os_unfair_lock_unlock(&lock)
        for w in start { DispatchQueue.global(qos: .default).async { self.work(w) } }
    }

    /// Makes `job` the next one served (something waits for it).
    func prioritize(_ job: PendingLayout) {
        os_unfair_lock_lock(&lock)
        if let i = jobs.firstIndex(where: { $0 === job }) { jobs.append(jobs.remove(at: i)) }
        os_unfair_lock_unlock(&lock)
    }

    func cancel(_ job: PendingLayout) {
        job.cancel()
        os_unfair_lock_lock(&lock)
        let finish = drop(job)
        os_unfair_lock_unlock(&lock)
        if finish { job.complete() }
    }

    /// Removes a job from the queue; true when it has nothing in flight and must complete
    /// now (lock held).
    private func drop(_ job: PendingLayout) -> Bool {
        if let i = jobs.firstIndex(where: { $0 === job }) { jobs.remove(at: i) }
        guard !job.isComplete, job.measured == job.claimed else { return false }
        job.isComplete = true
        return true
    }

    private func work(_ w: Int) {
        let fonts = FontBook.workers[w]
        var finished: [PendingLayout] = []
        while true {
            var job: PendingLayout?
            var c = 0
            os_unfair_lock_lock(&lock)
            while let j = jobs.last {
                if j.cancelled {
                    if drop(j) { finished.append(j) }
                    continue
                }
                c = j.claimed
                j.claimed += 1
                if j.claimed == j.chunks { jobs.removeLast() }
                job = j
                break
            }
            if job == nil { busy[w] = false }
            os_unfair_lock_unlock(&lock)
            for j in finished { j.complete() }
            finished.removeAll()
            guard let job else { return }

            job.measure(c, fonts)

            os_unfair_lock_lock(&lock)
            job.measured += 1
            let last = !job.isComplete && job.measured == job.claimed && (job.claimed == job.chunks || job.cancelled)
            if last { job.isComplete = true }
            os_unfair_lock_unlock(&lock)
            if last { job.complete() }
        }
    }
}

enum MarkdownLayout {
    /// Cheap height guess for a block not laid out yet (only affects the scroll bar until
    /// the background layout lands).
    static func estimate(_ bi: Int, _ env: LayoutEnv) -> BlockLayout {
        let b = env.doc.blocks[bi]
        let m = env.m
        let bytes = CGFloat(b.textEnd - b.textStart)
        let charsPerLine = max(20, env.contentW / (m.body * 0.5))
        var h: CGFloat
        switch b.kind {
        case .code:
            var lines: CGFloat = 1
            let p = env.doc.text.base
            for i in Int(b.textStart)..<Int(b.textEnd) where p[i] == 0x0A { lines += 1 }
            h = lines * m.codeSize * 1.45 + 2 * m.codePad
        case .heading: h = m.headingSize(b.level) * 1.4 + (b.level <= 2 ? m.body * 0.5 : 0)
        case .rule: h = m.body * 0.8 + 2
        case .table:
            let t = env.doc.tables[Int(b.table)]
            h = CGFloat(t.rows) * (m.body * 1.35 + 14)
        default: h = (bytes / charsPerLine).rounded(.up) * m.body * 1.5
        }
        var out = BlockLayout()
        out.height = max(m.body, h)
        out.right = env.x0 + env.contentW
        if b.marker != .none { out.firstBaseline = m.body }
        return out
    }

    static func block(_ bi: Int, _ env: LayoutEnv) -> BlockLayout {
        let b = env.doc.blocks[bi]
        let m = env.m
        let indent = CGFloat(b.quoteDepth) * m.quoteIndent + CGFloat(b.listDepth) * m.listIndent
        let bx = env.x0 + indent
        let bw = max(60, env.contentW - indent)
        var out = BlockLayout()
        out.right = env.x0 + env.contentW
        var y: CGFloat = 0
        switch b.kind {
        case .paragraph, .html, .alertTitle:
            if b.kind == .alertTitle {
                // Icon and colored title ("Note", "Warning", ...), as GitHub draws them.
                let color = env.palette.alert[Int(b.alert.rawValue)]
                let a = inline(env, b.textStart, b.textEnd, runs: b.runStart..<b.runEnd,
                               font: env.fonts.font(m.body, weight: .semibold), color: color, align: .left)
                let icon = (m.body * 1.15).rounded()
                let box = TextBox(attributed: a, origin: CGPoint(x: bx + icon + 6, y: 0), width: bw - icon - 6,
                                  start: Int(b.textStart), end: Int(b.textEnd), text: env.doc.text, lineGap: m.lineGap(m.body))
                out.boxes.append(box)
                let base = box.baselines.first ?? m.body
                let r = CGRect(x: bx, y: base - m.body * 0.36 - icon / 2, width: icon, height: icon)
                out.decos.append(PlacedDeco(minY: r.minY, maxY: r.maxY, deco: .alertIcon(r, b.alert)))
                y = box.rect.maxY
                break
            }
            // Footnotes: smaller and muted, as on GitHub. Alert bodies keep the text color.
            let size = b.footnote > 0 ? (m.body * 0.92).rounded() : m.body
            let muted = b.footnote > 0 || (b.quoteDepth > 0 && !(b.alert != .none && b.quoteDepth == 1))
            let a = inline(env, b.textStart, b.textEnd, runs: b.runStart..<b.runEnd, font: env.fonts.font(size),
                           color: muted ? env.palette.secondaryText : env.palette.text, align: b.align)
            let box = TextBox(attributed: a, origin: CGPoint(x: bx, y: 0), width: bw, start: Int(b.textStart),
                              end: Int(b.textEnd), text: env.doc.text, lineGap: m.lineGap(size))
            out.boxes.append(box)
            y = box.rect.maxY
        case .heading:
            let size = m.headingSize(b.level)
            let a = inline(env, b.textStart, b.textEnd, runs: b.runStart..<b.runEnd, font: env.fonts.font(size, weight: .semibold),
                           color: b.level == 6 ? env.palette.secondaryText : env.palette.text, align: b.align, lineHeight: 1.25)
            let box = TextBox(attributed: a, origin: CGPoint(x: bx, y: 0), width: bw, start: Int(b.textStart),
                              end: Int(b.textEnd), text: env.doc.text, lineGap: m.lineGap(size, 1.25))
            out.boxes.append(box)
            y = box.rect.maxY
            if b.level <= 2 {
                y += m.body * 0.45
                out.decos.append(PlacedDeco(minY: y, maxY: y + 1, deco: .line(CGRect(x: bx, y: y, width: bw, height: 1), .border)))
                y += 1
            }
        case .code:
            let a = code(env, b)
            let box = TextBox(attributed: a, origin: CGPoint(x: bx + m.codePad, y: m.codePad), width: bw - 2 * m.codePad,
                              start: Int(b.textStart), end: Int(b.textEnd), text: env.doc.text, lineGap: m.lineGap(m.codeSize, 1.45))
            let bg = CGRect(x: bx, y: 0, width: bw, height: box.rect.height + 2 * m.codePad)
            if b.output {   // notebook output: a rule at the left, no fill (code cells keep theirs)
                out.decos.append(PlacedDeco(minY: 0, maxY: bg.maxY, deco: .fill(CGRect(x: bx, y: 0, width: 2, height: bg.height), .border, 1)))
            } else {
                out.decos.append(PlacedDeco(minY: 0, maxY: bg.maxY, deco: .fill(bg, .blockBackground, 6)))
            }
            out.boxes.append(box)
            y = bg.maxY
        case .rule:
            y = m.body * 0.4
            out.decos.append(PlacedDeco(minY: y, maxY: y + 2, deco: .fill(CGRect(x: bx, y: y, width: bw, height: 2), .border, 1)))
            y += 2 + m.body * 0.4
        case .table:
            y = table(env, Int(b.table), x: bx, width: bw, into: &out)
        }
        if b.marker != .none {
            if let first = out.boxes.first, let base = first.baselines.first {
                out.firstBaseline = base
            } else {
                out.firstBaseline = m.body   // empty item: marker on its own line
                y = max(y, m.body * 1.4)
            }
        }
        out.height = y
        return out
    }

    /// Rich text for `[start, end)` of the rendered text with the given runs applied.
    static func inline(_ env: LayoutEnv, _ start: Int32, _ end: Int32, runs: Range<Int32>, font base: NSFont, color: CGColor,
                       align: MDAlign, lineHeight: CGFloat = 1.5) -> NSAttributedString {
        let doc = env.doc
        let book = env.fonts
        let s = doc.text.string(Int(start), Int(end)) as NSString
        let paragraph = FontBook.paragraphKey(align, lineHeight: lineHeight)
        // Each run carries its whole style: one cached (uniqued) attribute dictionary per run,
        // set with CFAttributedStringSetAttributes (see FontBook). Runs don't overlap, except a
        // linked image: its image run, then a link run over the same character (skipped here:
        // the image draws itself, and links are found by offset).
        let a = CFAttributedStringCreateMutable(nil, 0)!
        CFAttributedStringReplaceString(a, CFRange(location: 0, length: 0), s)
        CFAttributedStringSetAttributes(a, CFRange(location: 0, length: s.length),
                                        book.attributes(font: base, color: color, paragraph: paragraph), true)
        if runs.isEmpty { return a as NSAttributedString }
        let map = Utf16Map(doc.text, Int(start), Int(end))
        let size = base.pointSize
        let baseBold = (base.fontDescriptor.symbolicTraits.contains(.bold))
        var lastImage = CFRange(location: -1, length: 0)
        for ri in runs {
            let r = doc.runs[Int(ri)]
            let range = map.range(Int(r.start), Int(r.end), length: s.length)
            if range.length <= 0 { continue }
            let st = r.style
            if range.location == lastImage.location && range.length == lastImage.length { continue }
            if st.contains(.image) {   // rare: a dictionary of its own (size, index)
                lastImage = range
                let sz = Int(r.ref) < env.imageSizes.count ? env.imageSizes[Int(r.ref)] : CGSize(width: 16, height: 16)
                // (With the paragraph style: an image can start the paragraph, whose first
                // character's style sets its alignment.)
                let d: [NSAttributedString.Key: Any] = [.font: base, .foregroundColor: CGColor.clear,
                                                        .paragraphStyle: book.paragraphStyle(paragraph),
                                                        kCTRunDelegateAttributeName as NSAttributedString.Key: runDelegate(width: sz.width, ascent: sz.height),
                                                        MDAttr.image: Int(r.ref)]
                CFAttributedStringSetAttributes(a, range, d as CFDictionary, true)
                continue
            }
            var f = base
            var flags: UInt8 = 0
            if st.contains(.code) || st.contains(.kbd) {
                f = book.font((size * 0.88).rounded() + 0.5, weight: st.contains(.strong) ? .semibold : .regular, mono: true)
                flags |= st.contains(.kbd) ? FontBook.AttrFlag.kbd : FontBook.AttrFlag.inlineCode
            } else if st.contains(.strong) || st.contains(.emphasis) || st.contains(.superscript) || st.contains(.subscriptStyle) {
                let sz = st.contains(.superscript) || st.contains(.subscriptStyle) ? size * 0.75 : size
                f = book.font(sz, weight: st.contains(.strong) || baseBold ? .semibold : .regular, italic: st.contains(.emphasis))
            }
            if st.contains(.strike) { flags |= FontBook.AttrFlag.strike }
            // Baseline offsets are negated: we draw in a flipped context (text matrix y = -1),
            // where Core Text's "up" offset lands below the baseline.
            let baseline: CGFloat = st.contains(.superscript) ? -size * 0.38 : st.contains(.subscriptStyle) ? size * 0.18 : 0
            // Links are found by text offset (MarkdownContent.link(at:)), not by an attribute: a
            // per-link value would make every link's dictionary unique.
            let c = st.contains(.link) ? env.palette.link : color
            CFAttributedStringSetAttributes(a, range, book.attributes(font: f, color: c, paragraph: paragraph, flags: flags, baseline: baseline), true)
        }
        return a as NSAttributedString
    }

    /// Code block: monospaced, syntax colored with the same lexers as code previews.
    static func code(_ env: LayoutEnv, _ b: MDBlock) -> NSAttributedString {
        let doc = env.doc
        let m = env.m
        let s = doc.text.string(Int(b.textStart), Int(b.textEnd))
        let book = env.fonts
        let f = book.font(m.codeSize, mono: true)
        let bold = book.font(m.codeSize, weight: .semibold, mono: true)
        let ns = s as NSString
        let a = CFAttributedStringCreateMutable(nil, 0)!
        CFAttributedStringReplaceString(a, CFRange(location: 0, length: 0), ns)
        CFAttributedStringSetAttributes(a, CFRange(location: 0, length: ns.length),
                                        book.attributes(font: f, color: env.palette.text, paragraph: FontBook.codeParagraph), true)
        if b.language != .plain && b.textEnd > b.textStart {
            let tokens = TokenStream(expectedBytes: Int(b.textEnd - b.textStart))
            // Lex in place: the byte after the block is "\n", which ends every token cleanly.
            b.language.lex(doc.text.base, Int(b.textStart), Int(b.textEnd), tokens)
            let map = Utf16Map(doc.text, Int(b.textStart), Int(b.textEnd))
            var k = tokens.first(after: Int(b.textStart))
            while k < tokens.count && tokens.start(k) < Int(b.textEnd) {
                let kind = tokens.kinds[k]
                if kind != 0 {
                    let ts = max(tokens.start(k), Int(b.textStart)), te = min(tokens.end(k), Int(b.textEnd))
                    let range = map.range(ts, te, length: ns.length)
                    if range.length <= 0 { k += 1; continue }
                    let d = book.attributes(font: env.palette.tokenBold[Int(kind)] ? bold : f, color: env.palette.tokenColors[Int(kind)],
                                            paragraph: FontBook.codeParagraph)
                    CFAttributedStringSetAttributes(a, range, d, true)
                }
                k += 1
            }
        }
        return a as NSAttributedString
    }

    static func runDelegate(width: CGFloat, ascent: CGFloat) -> CTRunDelegate {
        let p = UnsafeMutablePointer<CGSize>.allocate(capacity: 1)
        p.initialize(to: CGSize(width: width, height: ascent))
        var cb = CTRunDelegateCallbacks(version: kCTRunDelegateVersion1, dealloc: { $0.deallocate() },
                                        getAscent: { $0.assumingMemoryBound(to: CGSize.self).pointee.height },
                                        getDescent: { _ in 0 },
                                        getWidth: { $0.assumingMemoryBound(to: CGSize.self).pointee.width })
        return CTRunDelegateCreate(&cb, p)!
    }

    /// GFM table, sized like a browser's automatic table layout: natural (one-line) column
    /// widths if they fit; else every column keeps at least its longest word and the space
    /// left is shared in proportion to how much each column would like beyond that. (A fixed
    /// 80 pt floor squeezed short headers such as "Markdown" until they broke mid-word.)
    static func table(_ env: LayoutEnv, _ ti: Int, x: CGFloat, width: CGFloat, into out: inout BlockLayout) -> CGFloat {
        let t = env.doc.tables[ti]
        let m = env.m
        let cols = t.columns, rows = t.rows
        if cols == 0 || rows == 0 { return 0 }
        let padH: CGFloat = 12, padV: CGFloat = 6
        let headerFont = env.fonts.font(m.body, weight: .semibold), cellFont = env.fonts.font(m.body)
        var strings: [NSAttributedString] = []
        strings.reserveCapacity(t.cells.count)
        var lines: [CTLine] = []
        lines.reserveCapacity(t.cells.count)
        var natural = [CGFloat](repeating: 40, count: cols)
        for (i, c) in t.cells.enumerated() {
            let a = inline(env, c.textStart, c.textEnd, runs: c.runStart..<c.runEnd, font: i < cols ? headerFont : cellFont,
                           color: env.palette.text, align: t.aligns[i % cols], lineHeight: 1.35)
            strings.append(a)
            let line = CTLineCreateWithAttributedString(a)
            lines.append(line)
            natural[i % cols] = max(natural[i % cols], CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) + 2 * padH + 1)
        }
        var widths = natural
        let total = natural.reduce(0, +)
        if total > width {
            // Longest word per column, from the cells' one-line layouts (offsets at spaces: no
            // extra shaping). Capped so one long token (a URL) can't claim most of the width.
            let cap = max(80, width * 0.4)
            var minW = [CGFloat](repeating: 24, count: cols)
            for (i, line) in lines.enumerated() {
                let u = strings[i].string.utf16
                var start = 0, k = 0, longest: CGFloat = 0
                for ch in u {
                    if ch == 0x20 || ch == 0x0A || ch == 0x09 {
                        if k > start {
                            longest = max(longest, CTLineGetOffsetForStringIndex(line, k, nil) - CTLineGetOffsetForStringIndex(line, start, nil))
                        }
                        start = k + 1
                    }
                    k += 1
                }
                if k > start {
                    longest = max(longest, CTLineGetOffsetForStringIndex(line, k, nil) - CTLineGetOffsetForStringIndex(line, start, nil))
                }
                minW[i % cols] = max(minW[i % cols], min(cap, (longest + 2 * padH + 2).rounded(.up)))
            }
            for c in 0..<cols { minW[c] = min(minW[c], natural[c]) }
            let minTotal = minW.reduce(0, +)
            if minTotal >= width {
                widths = minW   // wider than the page: the document scrolls sideways
            } else {
                let flexible = (0..<cols).map { natural[$0] - minW[$0] }
                let flexTotal = max(1, flexible.reduce(0, +))
                let spare = width - minTotal
                for c in 0..<cols { widths[c] = (minW[c] + spare * flexible[c] / flexTotal).rounded(.down) }
            }
        }
        let tableW = widths.reduce(0, +)
        out.right = max(out.right, x + tableW)
        var rowY: CGFloat = 0
        for r in 0..<rows {
            var cx = x
            var rowH: CGFloat = 0
            for c in 0..<cols {
                let i = r * cols + c
                let cell = t.cells[i]
                let box = TextBox(attributed: strings[i], origin: CGPoint(x: cx + padH, y: rowY + padV),
                                  width: widths[c] - 2 * padH, start: Int(cell.textStart), end: Int(cell.textEnd),
                                  text: env.doc.text, lineGap: m.lineGap(m.body, 1.35))
                out.boxes.append(box)
                rowH = max(rowH, box.rect.height + 2 * padV)
                cx += widths[c]
            }
            let rowRect = CGRect(x: x, y: rowY, width: tableW, height: rowH)
            if r % 2 == 0 { out.decos.append(PlacedDeco(minY: rowRect.minY, maxY: rowRect.maxY, deco: .fill(rowRect, .blockBackground, 0))) }
            out.decos.append(PlacedDeco(minY: rowRect.maxY - 0.5, maxY: rowRect.maxY + 0.5,
                                        deco: .line(CGRect(x: x, y: rowRect.maxY - 0.5, width: tableW, height: 1), .border)))
            var vx = x
            for c in 0...cols {
                out.decos.append(PlacedDeco(minY: rowRect.minY, maxY: rowRect.maxY,
                                            deco: .line(CGRect(x: vx - 0.5, y: rowRect.minY, width: 1, height: rowH), .border)))
                if c < cols { vx += widths[c] }
            }
            rowY += rowH
        }
        out.decos.append(PlacedDeco(minY: -0.5, maxY: 0.5, deco: .line(CGRect(x: x, y: -0.5, width: tableW, height: 1), .border)))
        return rowY
    }
}

/// Advance of a monospaced font (used for tab stops).
func CTFontGetAdvanceForGlyphMonospaced(_ f: NSFont) -> CGFloat {
    var g = CGGlyph(0)
    var ch = UniChar(0x20)
    CTFontGetGlyphsForCharacters(f as CTFont, &ch, &g, 1)
    var adv = CGSize.zero
    CTFontGetAdvancesForGlyphs(f as CTFont, .horizontal, &g, &adv, 1)
    return adv.width
}
