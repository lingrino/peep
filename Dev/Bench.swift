import AppKit

// peep-dev: benchmarks. Timings are best of N unless noted; compare builds with
// Scripts/compare.sh (alternating runs of a baseline and the current tree).

@MainActor
func bench(_ args: [String]) {
    var files: [String] = []
    var iterations = 20
    var i = 0
    while i < args.count {
        if args[i] == "--iterations" { i += 1; iterations = Int(args[i]) ?? 20 } else { files.append(args[i]) }
        i += 1
    }
    for f in files {
        var best: [String: UInt64] = [:]
        var order: [String] = []
        var size = 0
        for _ in 0..<iterations {
            let d = Document.open(path: f)
            size = d.fileSize
            for (k, v) in d.timings {
                if best[k] == nil { order.append(k) }
                best[k] = min(best[k] ?? .max, v)
            }
        }
        let total = order.reduce(0) { $0 + best[$1]! }
        let mbps = Double(size) / (Double(total) / 1e9) / 1e6
        print("\((f as NSString).lastPathComponent) (\(size) B): " + order.map { "\($0) \(String(format: "%.3f", Double(best[$0]!) / 1e6))" }.joined(separator: " ")
              + String(format: " | total %.3fms (%.0f MB/s)", Double(total) / 1e6, mbps))
    }
}

/// Lex one file N times (for profiling the lexer alone).
@MainActor
func lexbench(_ args: [String]) {
    let path = args[0]
    let n = args.count > 1 ? Int(args[1]) ?? 100 : 100
    let f = try! FileLoader.load(path: path, limit: 1 << 30)
    guard case .text(let text, _, _) = Decoder.decode(f.raw) else { return }
    let lang = Language.detect(fileName: (path as NSString).lastPathComponent, head: UnsafeBufferPointer(start: text.base, count: min(512, text.count)))
    var best = UInt64.max
    var count = 0
    for _ in 0..<n {
        let t0 = nanotime()
        let out = TokenStream(expectedBytes: text.count)
        lang.lex(text.base, 0, text.count, out)
        best = min(best, nanotime() - t0)
        count = out.count
    }
    let lt0 = nanotime()
    var lc = 0
    for _ in 0..<n { lc = LineIndex(text).count }
    let lineNs = (nanotime() - lt0) / UInt64(n)
    print("\(lang.name): \(count) tokens, best \(String(format: "%.3f", Double(best) / 1e6))ms = \(String(format: "%.0f", Double(text.count) / Double(best) * 1e3)) MB/s; lines \(lc) in \(String(format: "%.3f", Double(lineNs) / 1e6))ms")
}

/// Markdown parse only, repeated (for profiling the parser).
@MainActor
func parsebench(_ args: [String]) {
    let n = args.count > 1 ? Int(args[1]) ?? 200 : 200
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: args[0], isDirectory: &isDir), isDir.boolValue {
        parsebenchCorpus(args[0], n)
        return
    }
    let f = try! FileLoader.load(path: args[0], limit: 1 << 30)
    guard case .text(let text, _, _) = Decoder.decode(f.raw) else { return }
    var best = UInt64.max
    for _ in 0..<n {
        let t0 = nanotime()
        _ = MarkdownParser.parse(text)
        best = min(best, nanotime() - t0)
    }
    print(String(format: "parse %.3fms (%.0f MB/s)", Double(best) / 1e6, Double(text.count) / Double(best) * 1e3))
}

/// Corpus mode: best-of-N parse time per .md file, aggregated by size (total bytes / total
/// time, so big files don't hide small-file overhead), plus the slowest files.
@MainActor
func parsebenchCorpus(_ dir: String, _ n: Int) {
    let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".md") }.sorted()
    var buckets: [(String, Int, Int, UInt64, Int)] = [("< 2 KB", 0, 2 << 10, 0, 0), ("2-8 KB", 2 << 10, 8 << 10, 0, 0),
                                                       ("8-64 KB", 8 << 10, 64 << 10, 0, 0), (">= 64 KB", 64 << 10, .max, 0, 0)]
    var rates: [(Double, String, Int)] = []
    for name in files {
        guard let f = try? FileLoader.load(path: dir + "/" + name, limit: 1 << 30),
              case .text(let text, _, _) = Decoder.decode(f.raw), text.count > 0 else { continue }
        var best = UInt64.max
        for _ in 0..<n {
            let t0 = nanotime()
            _ = MarkdownParser.parse(text)
            best = min(best, nanotime() - t0)
        }
        for k in buckets.indices where text.count >= buckets[k].1 && text.count < buckets[k].2 {
            buckets[k].3 += best
            buckets[k].4 += text.count
        }
        rates.append((Double(text.count) / Double(best) * 1e3, name, text.count))
    }
    for b in buckets where b.3 > 0 {
        print(String(format: "%-9@ %8d bytes  %7.0f MB/s", b.0 as NSString, b.4, Double(b.4) / Double(b.3) * 1e3))
    }
    rates.sort { $0.0 < $1.0 }
    print("slowest:")
    for r in rates.prefix(8) { print(String(format: "  %6.0f MB/s  %7d B  %@", r.0, r.2, r.1 as NSString)) }
}

/// Markdown parse + layout timing, repeated (for profiling).
@MainActor
func mdbench(_ args: [String]) {
    let n = args.count > 1 ? Int(args[1]) ?? 20 : 20
    let f = try! FileLoader.load(path: args[0], limit: 1 << 30)
    guard case .text(let text, _, _) = Decoder.decode(f.raw) else { return }
    var parse = UInt64.max, layout = UInt64.max
    for _ in 0..<n {
        let t0 = nanotime()
        let md = MarkdownParser.parse(text)
        let t1 = nanotime()
        let c = MarkdownContent(doc: md, baseDir: nil)
        _ = c.setPalette(.light)
        _ = c.layout(width: 800)
        let t2 = nanotime()
        parse = min(parse, t1 - t0); layout = min(layout, t2 - t1)
    }
    print(String(format: "parse %.2fms (%.0f MB/s), layout %.2fms", Double(parse) / 1e6, Double(text.count) / Double(parse) * 1e3, Double(layout) / 1e6))
}

/// Main-thread cost of each stage up to the first drawn frame (what Quick Look waits for),
/// best of N runs. Background layout keeps running and is not counted.
@MainActor
func firstPaint(_ args: [String]) {
    let size = NSSize(width: 980, height: 800)
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    let view = PreviewView(frame: NSRect(origin: .zero, size: size))
    window.contentView = view
    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    for f in args {
        var best = [UInt64](repeating: .max, count: 4)
        for _ in 0..<10 {
            var t = nanotime()
            var lap = [UInt64]()
            func mark() { let n = nanotime(); lap.append(n - t); t = n }
            let doc = Document.open(path: f); mark()
            view.show(doc); mark()
            view.layoutSubtreeIfNeeded(); mark()
            view.cacheDisplay(in: view.bounds, to: rep); mark()
            for i in 0..<4 { best[i] = min(best[i], lap[i]) }
            (doc.content as? MarkdownContent)?.finishLayout()   // don't overlap the next run
        }
        let ms = best.map { String(format: "%.2f", Double($0) / 1e6) }
        print("\((f as NSString).lastPathComponent): open \(ms[0]) show \(ms[1]) layout \(ms[2]) draw \(ms[3]) ms")
        // Markdown: what happens after the first frame (background layout lands on main).
        let doc = Document.open(path: f)
        view.show(doc)
        view.layoutSubtreeIfNeeded()
        view.cacheDisplay(in: view.bounds, to: rep)
        if let md = doc.content as? MarkdownContent, md.isLayoutPending {
            let t0 = nanotime()
            while md.isLayoutPending { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.001)) }
            let b = md.lastBackground
            print(String(format: "  settled after %.1f ms: background %.1f ms; main thread adopt %.2f ms + update %.2f ms",
                         Double(nanotime() - t0) / 1e6, Double(b.0) / 1e6, Double(b.1) / 1e6, Double(b.2) / 1e6))
        }
    }
}

/// Find timings: raw `Search.find` and the full preview path (matches + highlight + reveal),
/// best of 5 per query. Typing in the find bar runs the full path once per keystroke.
@MainActor
func findBench(_ args: [String]) {
    let size = NSSize(width: 980, height: 800)
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    let view = PreviewView(frame: NSRect(origin: .zero, size: size))
    window.contentView = view
    let doc = Document.open(path: args[0])
    view.show(doc)
    (doc.content as? MarkdownContent)?.finishLayout()
    let text = doc.content.text
    print("\((args[0] as NSString).lastPathComponent): \(text.count) bytes")
    for q in args.dropFirst() {
        let qb = Array(q.utf8)
        var raw = UInt64.max, full = UInt64.max
        var n = 0
        for _ in 0..<5 {
            var t = nanotime()
            n = Search.find(text, qb, caseSensitive: Search.isCaseSensitive(qb)).count
            raw = min(raw, nanotime() - t)
            t = nanotime()
            _ = view.find(q)
            full = min(full, nanotime() - t)
            view.clearFind()
        }
        print(String(format: "  %-12@ %8d matches  search %7.2fms (%5.1f GB/s)  full %7.2fms", "\"\(q)\"" as NSString, n,
                     Double(raw) / 1e6, Double(text.count) / Double(raw), Double(full) / 1e6))
    }
}

/// What showing a preview costs in a real on-screen window: open, show, layout, display, and
/// the Core Animation commit (what Quick Look's panel waits for before it appears).
@MainActor
func showCost(_ args: [String]) {
    let window = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: 980, height: 800),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    let view = PreviewView(frame: NSRect(x: 0, y: 0, width: 980, height: 800))
    window.contentView = view
    window.orderFrontRegardless()
    for f in args {
        var best = [UInt64](repeating: .max, count: 5)
        for _ in 0..<5 {
            var t = nanotime()
            var lap = [UInt64]()
            func mark() { let n = nanotime(); lap.append(n - t); t = n }
            let doc = Document.open(path: f); mark()
            view.show(doc); mark()
            view.layoutSubtreeIfNeeded(); mark()
            window.displayIfNeeded(); mark()
            CATransaction.flush(); mark()
            for i in 0..<5 { best[i] = min(best[i], lap[i]) }
            (doc.content as? MarkdownContent)?.finishLayout()
        }
        let ms = best.map { String(format: "%.2f", Double($0) / 1e6) }
        print("\((f as NSString).lastPathComponent): open \(ms[0]) show \(ms[1]) layout \(ms[2]) display \(ms[3]) commit \(ms[4]) ms; outline \(view.outline?.items.count ?? 0) rows")
        // Quick Look resizes the view as its panel opens, while background layout runs.
        let doc = Document.open(path: f)
        // Prepared at a smaller size than the panel opens at (taller: past the synchronous prefix).
        window.setContentSize(NSSize(width: 980, height: 500))
        view.frame = NSRect(x: 0, y: 0, width: 980, height: 500)
        view.show(doc)
        view.layoutSubtreeIfNeeded(); window.displayIfNeeded(); CATransaction.flush()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02))   // background layout is running now
        let t0 = nanotime()
        window.setContentSize(NSSize(width: 1040, height: 840))
        view.frame = NSRect(x: 0, y: 0, width: 1040, height: 840)
        view.layoutSubtreeIfNeeded(); window.displayIfNeeded(); CATransaction.flush()
        print(String(format: "  grow 500 -> 840 pt tall during background layout: %.2f ms", Double(nanotime() - t0) / 1e6))
        (doc.content as? MarkdownContent)?.finishLayout()
        window.setContentSize(NSSize(width: 980, height: 800))
        view.frame = NSRect(x: 0, y: 0, width: 980, height: 800)
    }
}

/// Table-of-contents clicks: jump to each heading and draw what becomes visible. Prints the
/// worst and median click cost (scroll + tile draws) and tiles drawn per click.
@MainActor
func jumpBench(_ args: [String]) {
    let size = NSSize(width: 990, height: 760)
    let window = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: size.width, height: size.height),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    let view = PreviewView(frame: NSRect(origin: .zero, size: size))
    window.contentView = view
    window.orderFrontRegardless()
    for f in args {
        let doc = Document.open(path: f)
        view.show(doc)
        (doc.content as? MarkdownContent)?.finishLayout()
        let n = doc.content.outlineEntries.count
        guard n > 0, let o = view.outline else { print("\((f as NSString).lastPathComponent): no outline"); continue }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        for t in view.documentView.subviews { t.layer?.displayIfNeeded() }
        var times: [Double] = [], draws: [Int] = []
        var wrongRow = 0
        let flashes = view.documentView.flashCount
        let order = (0..<n).map { ($0 * 7919) % max(1, n) }   // scattered jumps, like real clicks
        for i in order {
            let before = view.documentView.tileDrawStats
            let t0 = nanotime()
            view.jumpToOutline(i)
            view.displayIfNeeded()
            // Offscreen windows don't display layer-backed tiles on their own.
            for t in view.documentView.subviews { t.layer?.displayIfNeeded() }
            times.append(Double(nanotime() - t0) / 1e6)
            draws.append(view.documentView.tileDrawStats.count - before.count)
            // The clicked entry (or the row standing for it) must be the highlighted one.
            if o.currentRow != (o.indexMap.lastIndex { $0 <= i } ?? -1) { wrongRow += 1 }
        }
        times.sort()
        let med = times.isEmpty ? 0 : times[times.count / 2]
        print(String(format: "%@: %d jumps, median %.2fms, worst %.2fms, tiles/jump %.1f, flashed %d, wrong row %d",
                     (f as NSString).lastPathComponent, times.count, med, times.last ?? 0,
                     Double(draws.reduce(0, +)) / Double(max(1, draws.count)),
                     view.documentView.flashCount - flashes, wrongRow))
    }
}
