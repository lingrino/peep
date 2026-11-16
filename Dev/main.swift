import AppKit
import UniformTypeIdentifiers

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
    var wait = 0.0
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
        case "--wait": i += 1; wait = Double(args[i]) ?? 0
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
    (doc.content as? MarkdownContent)?.finishLayout()
    view.layoutSubtreeIfNeeded()
    if wait > 0 { RunLoop.main.run(until: Date(timeIntervalSinceNow: wait)); view.layoutSubtreeIfNeeded() }
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

/// Dynamic UTI for a filename extension: "dyn.a" + base32("?0=6:1=<ext>") with LaunchServices'
/// alphabet. These apply on machines where no installed app declares the extension.
func dynamicUTI(_ ext: String) -> String {
    let alphabet = Array("abcdefghkmnpqrstuvwxyz0123456789")
    var out = "dyn.a"
    var buffer: UInt32 = 0
    var bits = 0
    for b in "?0=6:1=\(ext.lowercased())".utf8 {
        buffer = buffer << 8 | UInt32(b)
        bits += 8
        while bits >= 5 {
            out.append(alphabet[Int((buffer >> UInt32(bits - 5)) & 31)])
            bits -= 5
        }
    }
    if bits > 0 { out.append(alphabet[Int((buffer << UInt32(5 - bits)) & 31)]) }
    return out
}

/// Prints the QLSupportedContentTypes array for the extension's Info.plist.
@MainActor
func types(_ args: [String]) {
    // Checks against values observed from LaunchServices.
    precondition(dynamicUTI("go") == "dyn.ah62d4rv4ge80s52", dynamicUTI("go"))
    precondition(dynamicUTI("rs") == "dyn.ah62d4rv4ge81e62", dynamicUTI("rs"))
    var seen = Set<String>()
    var list: [String] = []
    func add(_ t: String) { if seen.insert(t).inserted { list.append(t) } }
    // Never claim: Apple's rendered previews are what you want for these.
    let exclude: Set<String> = ["public.svg-image", "com.adobe.pdf", "public.rtf"]
    for (_, exts) in Language.extensionTable {
        for e in exts.split(separator: " ").map(String.init) {
            if let t = UTType(filenameExtension: e), !t.isDynamic, !exclude.contains(t.identifier) { add(t.identifier) }
            add(dynamicUTI(e))
        }
    }
    // Archives (listed) and single compressed files (previewed decompressed).
    for e in ArchiveKind.registeredExtensions {
        if let t = UTType(filenameExtension: e), !t.isDynamic, !exclude.contains(t.identifier) { add(t.identifier) }
        add(dynamicUTI(e))
    }
    // Wrapper suffixes (config.yml.dist, Makefile.in): one type each, whatever they wrap.
    for e in Language.wrapperExtensions.sorted() {
        if let t = UTType(filenameExtension: e), !t.isDynamic, !exclude.contains(t.identifier) { add(t.identifier) }
        add(dynamicUTI(e))
    }
    // Extensionless files (Makefile, Dockerfile, .gitignore, scripts) and broad families.
    for t in ["public.data", "public.unix-executable", "public.plain-text", "public.text", "public.source-code",
              "public.script", "public.shell-script", "public.make-source", "public.json", "public.yaml", "public.xml",
              "net.daringfireball.markdown", "public.markdown", "com.apple.property-list", "com.apple.log",
              // Third-party declarations that win over dynamic types when those apps are installed.
              "com.microsoft.typescript", "public.typescript", "public.tsx", "com.netscape.javascript-source",
              "public.toml", "io.toml", "org.vim.toml-file", "com.barebones.bbedit.rust-source", "org.rust-lang.rust",
              "com.barebones.bbedit.go-source", "public.rust-source", "public.go-source", "public.kotlin-source",
              "org.kotlinlang.source", "com.barebones.bbedit.typescript-source", "com.barebones.bbedit.toml-source",
              "com.barebones.bbedit.scss-source", "com.barebones.bbedit.sql-source", "com.barebones.bbedit.lua-source",
              "public.css", "public.scss", "public.sass", "public.less", "dev.svelte", "public.vue", "org.vuejs.vue",
              "net.ia.markdown", "io.typora.markdown", "com.unknown.md", "org.quarto.qmarkdown", "com.rstudio.rmarkdown",
              "com.fishshell.script", "public.zsh-script", "public.bash-script", "public.ruby-script", "public.python-script",
              "public.perl-script", "public.php-script", "org.lua", "org.iso.sql", "com.microsoft.ini", "public.protobuf-source",
              "public.swift-source", "public.c-source", "public.c-header", "public.c-plus-plus-source", "public.c-plus-plus-header",
              "public.objective-c-source", "public.objective-c-plus-plus-source", "com.sun.java-source", "public.patch-file",
              "public.comma-separated-values-text", "public.tab-separated-values-text", "com.apple.xcode.strings-text",
              "com.apple.xcode.configsettings", "com.apple.xcode.entitlements-property-list", "org.videolan.mod",
              "public.mpeg-2-transport-stream", "com.apple.applescript.text", "org.tug", "org.bibtex", "org.asciidoc", "org.orgmode",
              "org.clojure", "org.khronos.glsl.fragment-shader", "com.apple.rez-source", "public.assembly-source"] {
        add(t)
    }
    for t in list where !exclude.contains(t) { print("\t\t\t\t<string>\(t)</string>") }
}

/// Opens, renders (top, middle, bottom) and searches every file under the given paths.
/// Run with CONFIG=debug to turn memory-safety bugs into traps.
@MainActor
func smoke(_ args: [String]) {
    var files: [String] = []
    let fm = FileManager.default
    for a in args {
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: a, isDirectory: &isDir), isDir.boolValue {
            let e = fm.enumerator(atPath: a)
            while let f = e?.nextObject() as? String {
                var d: ObjCBool = false
                let full = a + "/" + f
                if fm.fileExists(atPath: full, isDirectory: &d), !d.boolValue { files.append(full) }
            }
        } else { files.append(a) }
    }
    let size = NSSize(width: 900, height: 700)
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    let view = PreviewView(frame: NSRect(origin: .zero, size: size))
    window.contentView = view
    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    var worst: [(Double, String)] = []
    var total = 0.0
    for (i, f) in files.enumerated() {
        let t0 = nanotime()
        let doc = Document.open(path: f)
        view.show(doc)
        view.layoutSubtreeIfNeeded()
        view.cacheDisplay(in: view.bounds, to: rep)
        let first = Double(nanotime() - t0) / 1e6
        let h = view.documentView.bounds.height
        for y in [h / 2, h] {
            view.documentView.scrollToTop(y: y)
            view.cacheDisplay(in: view.bounds, to: rep)
        }
        if let md = doc.content as? MarkdownContent {
            md.finishLayout()
            let bad = mdGeometryErrors(md)
            if !bad.isEmpty { print("GEOMETRY \(f): \(bad.prefix(3).joined(separator: "; "))") }
        }
        _ = view.find("e")
        view.documentView.selectAll()
        view.cacheDisplay(in: view.bounds, to: rep)
        view.clearFind()
        total += first
        worst.append((first, (f as NSString).lastPathComponent))
        if (i + 1) % 200 == 0 { print("\(i + 1)/\(files.count)") }
    }
    worst.sort { $0.0 > $1.0 }
    print("\(files.count) files, mean first paint \(String(format: "%.2f", total / Double(max(1, files.count))))ms")
    for (t, f) in worst.prefix(8) { print(String(format: "  %7.2fms  %@", t, f)) }
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

/// Differential check for the markdown parser: writes a complete dump of each parsed
/// document (text, blocks, runs, links, images, tables, headings) to `<outdir>/<name>.txt`.
/// Dump a corpus before and after a parser change, then `diff -r before after`.
///   peep-dev mddump <outdir> <files or dirs...>
@MainActor
func mdDump(_ args: [String]) {
    guard args.count >= 2 else { print("usage: mddump <outdir> <files or dirs...>"); exit(2) }
    let outDir = args[0]
    let fm = FileManager.default
    try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)
    var files: [String] = []
    for a in args.dropFirst() {
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: a, isDirectory: &isDir), isDir.boolValue {
            for f in (try? fm.contentsOfDirectory(atPath: a)) ?? [] where f.hasSuffix(".md") || f.hasSuffix(".markdown") {
                files.append(a + "/" + f)
            }
        } else { files.append(a) }
    }
    files.sort()
    var bytes = 0
    for path in files {
        guard let f = try? FileLoader.load(path: path, limit: 1 << 30),
              case .text(let text, _, _) = Decoder.decode(f.raw) else { continue }
        bytes += text.count
        let d = MarkdownParser.parse(text)
        let out = dumpMarkdown(d)
        let name = (path as NSString).lastPathComponent
        try! out.write(toFile: outDir + "/" + name + ".txt", atomically: false, encoding: .utf8)
    }
    print("dumped \(files.count) files (\(bytes) bytes) to \(outDir)")
}

/// Every field of a parsed document, one fact per line. Text is shown per block with
/// control characters escaped, so a diff points at the block that changed.
func dumpMarkdown(_ d: MarkdownDocument) -> String {
    var o = ""
    func esc(_ s: Int, _ e: Int) -> String {
        let s = max(0, min(s, d.text.count)), e = max(s, min(e, d.text.count))
        let str = String(decoding: UnsafeBufferPointer(start: d.text.base + s, count: e - s), as: UTF8.self)
        var r = ""
        for u in str.unicodeScalars {
            switch u {
            case "\n": r += "\\n"
            case "\t": r += "\\t"
            case "\\": r += "\\\\"
            case "\u{FFFC}": r += "\\obj"
            default: r.unicodeScalars.append(u)
            }
        }
        return r
    }
    o += "text \(d.text.count) bytes, \(d.blocks.count) blocks, \(d.runs.count) runs\n"
    var covered = 0
    for (i, b) in d.blocks.enumerated() {
        if Int(b.textStart) != covered { o += "GAP \(covered)..<\(b.textStart): \(esc(covered, Int(b.textStart)))\n" }
        covered = Int(b.textEnd) + 1
        o += "B\(i) \(b.kind) lv\(b.level) q\(b.quoteDepth) l\(b.listDepth) \(b.marker) #\(b.markerNumber) tight=\(b.tight) \(b.align)"
        o += " text \(b.textStart)..<\(b.textEnd) runs \(b.runStart)..<\(b.runEnd)"
        if b.kind == .code { o += " lang=\(b.language.name)" }
        if b.table >= 0 { o += " table=\(b.table)" }
        if b.heading >= 0 { o += " heading=\(b.heading)" }
        o += "\n  |\(esc(Int(b.textStart), Int(b.textEnd)))|\n"
        if Int(b.textEnd) < d.text.count && d.text.base[Int(b.textEnd)] != 0x0A { o += "  NO SEPARATOR\n" }
        for r in Int(b.runStart)..<Int(b.runEnd) {
            let run = d.runs[r]
            o += "  R\(r) \(run.start)..<\(run.end) style=\(run.style.rawValue) ref=\(run.ref) |\(esc(Int(run.start), Int(run.end)))|\n"
        }
    }
    if covered < d.text.count { o += "TAIL \(covered)..<\(d.text.count): \(esc(covered, d.text.count))\n" }
    let blockRuns = d.blocks.reduce(0) { $0 + Int($1.runEnd - $1.runStart) }
    if blockRuns != d.runs.count { o += "RUNS OUTSIDE BLOCKS: \(d.runs.count - blockRuns)\n" }
    for i in 0..<d.links.count { o += "L\(i) \(d.links[i])\n" }
    for (i, m) in d.images.enumerated() {
        o += "I\(i) url=\(m.url) alt=\(m.alt) w=\(m.width) h=\(m.height) dark=\(m.darkURL ?? "-")\n"
    }
    for (i, t) in d.tables.enumerated() {
        o += "T\(i) cols=\(t.columns) aligns=\(t.aligns.map { "\($0)" }.joined(separator: ",")) cells=\(t.cells.count)\n"
        for (c, cell) in t.cells.enumerated() {
            o += "  C\(c) text \(cell.textStart)..<\(cell.textEnd) runs \(cell.runStart)..<\(cell.runEnd) |\(esc(Int(cell.textStart), Int(cell.textEnd)))|\n"
        }
    }
    let slugs = d.headingSlugs()
    for (i, h) in d.headings.enumerated() { o += "H\(i) level=\(h.level) block=\(h.block) slug=\(slugs[i]) title=\(h.title)\n" }
    return o
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

/// Renders the app icon at every iconset size into `dir` (then: iconutil -c icns dir).
@MainActor
func icon(_ args: [String]) {
    let dir = args[0]
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let px = base * scale
            let cs = CGColorSpace(name: CGColorSpace.displayP3)!
            let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            drawIcon(ctx, CGFloat(px))
            let img = ctx.makeImage()!
            let rep = NSBitmapImageRep(cgImage: img)
            let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
            try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: dir + "/" + name))
        }
    }
}

/// The icon: a macOS squircle with a deep indigo gradient and a stylized eye ("peep").
func drawIcon(_ ctx: CGContext, _ s: CGFloat) {
    // Apple's grid: the shape is inset ~10% with a continuous-corner radius of ~22.4%.
    let inset = s * 0.098
    let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let radius = rect.width * 0.2237
    let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).cgPath
    // Drop shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: CGColor(gray: 0, alpha: 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(CGColor(gray: 0.1, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()
    // Background gradient.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    let bg = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.displayP3), colors: [
        CGColor(red: 0.33, green: 0.30, blue: 0.95, alpha: 1), CGColor(red: 0.12, green: 0.09, blue: 0.42, alpha: 1)] as CFArray,
        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: s / 2, y: rect.maxY), end: CGPoint(x: s / 2, y: rect.minY), options: [])
    // Soft top highlight.
    let hl = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.displayP3), colors: [
        CGColor(gray: 1, alpha: 0.22), CGColor(gray: 1, alpha: 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(hl, start: CGPoint(x: s / 2, y: rect.maxY), end: CGPoint(x: s / 2, y: rect.midY), options: [])
    ctx.restoreGState()
    // Eye: almond from two arcs.
    let c = CGPoint(x: s / 2, y: s / 2)
    let w = rect.width * 0.62, h = rect.width * 0.36
    let eye = CGMutablePath()
    eye.move(to: CGPoint(x: c.x - w / 2, y: c.y))
    eye.addQuadCurve(to: CGPoint(x: c.x + w / 2, y: c.y), control: CGPoint(x: c.x, y: c.y + h))
    eye.addQuadCurve(to: CGPoint(x: c.x - w / 2, y: c.y), control: CGPoint(x: c.x, y: c.y - h))
    eye.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.006), blur: s * 0.02, color: CGColor(gray: 0, alpha: 0.3))
    ctx.addPath(eye)
    ctx.setFillColor(CGColor(gray: 0.98, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()
    // Iris + pupil, clipped to the eye.
    ctx.saveGState()
    ctx.addPath(eye)
    ctx.clip()
    let r = h * 0.40
    let iris = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.displayP3), colors: [
        CGColor(red: 0.20, green: 0.85, blue: 0.95, alpha: 1), CGColor(red: 0.05, green: 0.45, blue: 0.85, alpha: 1)] as CFArray,
        locations: [0, 1])!
    ctx.drawRadialGradient(iris, startCenter: CGPoint(x: c.x - r * 0.25, y: c.y + r * 0.25), startRadius: 0,
                           endCenter: c, endRadius: r, options: [])
    ctx.setStrokeColor(CGColor(red: 0.03, green: 0.25, blue: 0.55, alpha: 0.9))
    ctx.setLineWidth(max(1, s * 0.006))
    ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    ctx.setFillColor(CGColor(red: 0.06, green: 0.05, blue: 0.20, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: c.x - r * 0.45, y: c.y - r * 0.45, width: r * 0.9, height: r * 0.9))
    ctx.setFillColor(CGColor(gray: 1, alpha: 0.9))
    ctx.fillEllipse(in: CGRect(x: c.x + r * 0.08, y: c.y + r * 0.12, width: r * 0.28, height: r * 0.28))
    ctx.restoreGState()
    ctx.addPath(eye)
    ctx.setStrokeColor(CGColor(red: 0.10, green: 0.08, blue: 0.35, alpha: 0.35))
    ctx.setLineWidth(max(0.5, s * 0.004))
    ctx.strokePath()
}

/// Dump markdown layout (blocks, boxes) for debugging.
@MainActor
func layoutDump(_ args: [String]) {
    let d = Document.open(path: args[0])
    guard let md = d.content as? MarkdownContent else { print("not markdown"); return }
    _ = md.layout(width: Double(args.count > 1 ? args[1] : "800") ?? 800)
    md.finishLayout()   // final geometry (background layout adopted)
    let bad = mdGeometryErrors(md)
    if !bad.isEmpty { print("GEOMETRY ERRORS:", bad.prefix(10).joined(separator: "; ")) }
    for (i, b) in md.doc.blocks.enumerated() {
        let lb = md.blocks[i]
        let t = md.doc.text.string(Int(b.textStart), min(Int(b.textEnd), Int(b.textStart) + 40))
        print(i, b.kind, "q\(b.quoteDepth) l\(b.listDepth)", String(format: "y=%.0f h=%.0f", lb.y, lb.h), "boxes \(lb.box0)+\(lb.boxN)",
              (lb.box0..<(lb.box0 + lb.boxN)).map { k in let r = md.boxes[k].rect; return String(format: "[%.0f,%.0f %.0fx%.0f lines %d]", r.minX, r.minY, r.width, r.height, md.boxes[k].lines.count) }.joined(),
              String(reflecting: t))
    }
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
        guard let md = doc.content as? MarkdownContent else { print("not markdown"); continue }
        md.finishLayout()
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        for t in view.documentView.subviews { t.layer?.displayIfNeeded() }
        var times: [Double] = [], draws: [Int] = []
        let n = md.headingY.count
        let order = (0..<n).map { ($0 * 7919) % max(1, n) }   // scattered jumps, like real clicks
        for i in order {
            let before = view.documentView.tileDrawStats
            let t0 = nanotime()
            view.documentView.scrollToTop(y: md.headingY[i] - 12)
            view.displayIfNeeded()
            // Offscreen windows don't display layer-backed tiles on their own.
            for t in view.documentView.subviews { t.layer?.displayIfNeeded() }
            times.append(Double(nanotime() - t0) / 1e6)
            draws.append(view.documentView.tileDrawStats.count - before.count)
        }
        times.sort()
        let med = times.isEmpty ? 0 : times[times.count / 2]
        print(String(format: "%@: %d jumps, median %.2fms, worst %.2fms, tiles/jump %.1f",
                     (f as NSString).lastPathComponent, times.count, med, times.last ?? 0,
                     Double(draws.reduce(0, +)) / Double(max(1, draws.count))))
    }
}

/// Boxes whose line baselines fall outside their rect, or that overlap the next block.
@MainActor
func mdGeometryErrors(_ md: MarkdownContent) -> [String] {
    var out: [String] = []
    for (k, b) in md.boxes.enumerated() {
        for y in b.baselines where y < b.rect.minY - 1 || y > b.rect.maxY + 1 {
            out.append(String(format: "box %d baseline %.0f outside %.0f..%.0f", k, y, b.rect.minY, b.rect.maxY))
            break
        }
    }
    for i in md.blocks.indices.dropLast() where md.blocks[i].y + md.blocks[i].h > md.blocks[i + 1].y + 0.5 {
        out.append("block \(i) overlaps next")
    }
    return out
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
    case "layout": layoutDump(Array(args.dropFirst()))
    case "types": types(Array(args.dropFirst()))
    case "smoke": smoke(Array(args.dropFirst()))
    case "firstpaint": firstPaint(Array(args.dropFirst()))
    case "findbench": findBench(Array(args.dropFirst()))
    case "jumpbench": jumpBench(Array(args.dropFirst()))
    case "mdbench": mdbench(Array(args.dropFirst()))
    case "parsebench": parsebench(Array(args.dropFirst()))
    case "mddump": mdDump(Array(args.dropFirst()))
    case "icon": icon(Array(args.dropFirst()))
    default: print("unknown command"); exit(2)
    }
}
