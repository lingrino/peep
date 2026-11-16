import AppKit
import UniformTypeIdentifiers

// peep-dev: dumps for debugging and differential checks (tokens, layout, parsed markdown,
// code outline, supported types).

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
    // Archives (listed), single compressed files (previewed decompressed), SQLite.
    for e in ArchiveKind.registeredExtensions + SQLitePreview.extensions.sorted() {
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
        if b.footnote > 0 { o += " footnote=\(b.footnote)" }
        if b.alert != .none { o += " alert=\(b.alert)" }
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
    for (i, r) in d.footnoteRefs.enumerated() { o += "F\(i + 1) block=\(d.footnoteBlocks[i]) refs=\(r)\n" }
    let slugs = d.headingSlugs()
    for (i, h) in d.headings.enumerated() { o += "H\(i) level=\(h.level) block=\(h.block) slug=\(slugs[i]) title=\(h.title)\n" }
    return o
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
        let boxes = md.boxes(ofBlock: i)
        print(i, b.kind, "q\(b.quoteDepth) l\(b.listDepth)", String(format: "y=%.0f h=%.0f", lb.y, lb.h), "boxes \(boxes.count)",
              boxes.map { box in let r = box.rect; return String(format: "[%.0f,%.0f %.0fx%.0f lines %d]", r.minX, r.minY, r.width, r.height, box.lines.count) }.joined(),
              String(reflecting: t))
    }
}

/// The code outline for files: `peep-dev symbols a.swift b.go` (first 60 entries per file;
/// `--all` for every entry).
@MainActor
func symbolsDump(_ args: [String]) {
    let all = args.contains("--all")
    for f in args where f != "--all" {
        let d = Document.open(path: f)
        guard let c = d.content as? CodeContent, let t = c.tokens else { print("\(f): not code"); continue }
        let syms = CodeOutline.symbols(c.text, c.lines, t)
        print("== \((f as NSString).lastPathComponent) (\(c.language.name)): \(syms.count) symbols")
        for s in syms.prefix(all ? syms.count : 60) { print(String(repeating: "  ", count: s.level) + s.title + "  :\(s.line + 1)") }
    }
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
