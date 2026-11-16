import AppKit

// peep-dev: developer tool (not shipped). Renders files through the real view stack to PNG
// and benchmarks the pipeline.
//
//   peep-dev render <file> <out.png> [--dark] [--size 900x700] [--scroll 0] [--select a:b] [--find text]
//   peep-dev bench <file>... [--iterations N]
//   peep-dev tokens <file>

@MainActor
func render(_ args: [String]) {
    guard args.count >= 2 else { print("usage: render <file> <out.png> ..."); exit(2) }
    let path = args[0], out = args[1]
    var size = NSSize(width: 900, height: 700)
    var dark = false
    var scrollY: CGFloat = 0
    var select: (Int, Int)?
    var find: String?
    var i = 2
    while i < args.count {
        switch args[i] {
        case "--dark": dark = true
        case "--size":
            i += 1
            let p = args[i].split(separator: "x").compactMap { Double($0) }
            size = NSSize(width: p[0], height: p[1])
        case "--scroll": i += 1; scrollY = CGFloat(Double(args[i]) ?? 0)
        case "--select":
            i += 1
            let p = args[i].split(separator: ":").compactMap { Int($0) }
            select = (p[0], p[1])
        case "--find": i += 1; find = args[i]
        default: print("unknown option \(args[i])"); exit(2)
        }
        i += 1
    }
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let view = PreviewView(frame: NSRect(origin: .zero, size: size))
    window.contentView = view
    let t0 = nanotime()
    let doc = Document.open(path: path)
    view.show(doc)
    if scrollY > 0 { view.documentView.scrollToTop(y: scrollY) }
    if let s = select { view.documentView.select(s.0, s.1) }
    if let f = find { view.find(f) }
    view.layoutSubtreeIfNeeded()
    if ProcessInfo.processInfo.environment["PEEP_DEBUG"] != nil {
        let dv = view.documentView
        print("doc frame", dv.frame, "clip", view.scrollView.contentView.bounds, "subviews", dv.subviews.count, dv.subviews.map { $0.frame })
    }
    let t1 = nanotime()
    guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
    view.cacheDisplay(in: view.bounds, to: rep)
    let t2 = nanotime()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
    print(doc.timingSummary)
    print(String(format: "open+show %.2fms, first draw %.2fms", Double(t1 - t0) / 1e6, Double(t2 - t1) / 1e6))
}

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

@MainActor
func tokens(_ args: [String]) {
    let d = Document.open(path: args[0])
    guard let c = d.content as? CodeContent, let t = c.tokens else { print("not code"); return }
    print("language: \(c.language.name), tokens: \(t.count)")
    for k in 0..<min(t.count, 400) where t.kind(k) != .plain {
        print(t.kind(k), String(reflecting: c.text.string(t.start(k), t.end(k))))
    }
}

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { print("commands: render bench tokens"); exit(2) }
MainActor.assumeIsolated {
    _ = NSApplication.shared
    switch cmd {
    case "render": render(Array(args.dropFirst()))
    case "bench": bench(Array(args.dropFirst()))
    case "tokens": tokens(Array(args.dropFirst()))
    case "lexbench": lexbench(Array(args.dropFirst()))
    default: print("unknown command"); exit(2)
    }
}
