import AppKit
import Darwin

/// A file turned into something displayable, plus how long each stage took.
@MainActor
public final class Document {
    public enum Kind { case code(Language), markdown, binary, error(String) }

    public let kind: Kind
    public let content: DocumentContent
    public let fileSize: Int
    public let truncated: Bool
    public var timings: [(String, UInt64)] = []
    public var path: String?
    /// Shown in a small pill at the bottom of the preview (e.g. "First 64 MB of 1.2 GB").
    public var notice: String?
    /// Open scrolled to the end (logs: the newest lines are what you want).
    public var startAtEnd = false

    init(kind: Kind, content: DocumentContent, fileSize: Int, truncated: Bool) {
        self.kind = kind
        self.content = content
        self.fileSize = fileSize
        self.truncated = truncated
    }

    /// Files larger than this are previewed truncated.
    public static let maxBytes = 64 << 20

    /// Loads and prepares a file. Runs on the main thread; every stage is linear-time.
    public static func open(path: String, typography: Typography = .standard) -> Document {
        var times: [(String, UInt64)] = []
        var t = nanotime()
        func mark(_ name: String) {
            let n = nanotime()
            times.append((name, n - t))
            t = n
        }
        var name = (path as NSString).lastPathComponent
        // Archives are listed from their headers, never loaded whole.
        if let kind = ArchiveKind.of(fileName: name) { return openArchive(path: path, name: name, kind: kind, typography: typography) }
        if SQLitePreview.extensions.contains((name as NSString).pathExtension.lowercased()) && SQLitePreview.isSQLite(path: path) {
            return openSQLite(path: path, name: name)
        }
        let isLog = path.lowercased().hasSuffix(".log")
        var file: LoadedFile
        var compressedNotice: String?
        if let (inner, gzip) = SingleFileCompression.inner(of: name) {
            // ".log.gz", "data.json.xz": preview what's inside, decompressed within a budget.
            guard let (buf, more, stored) = SingleFileCompression.load(path: path, gzip: gzip, limit: maxBytes,
                                                                        budgetNanos: decompressBudget) else {
                return message("Couldn't decompress this file.", fileSize: 0)
            }
            name = stored.flatMap { $0.isEmpty ? nil : ($0 as NSString).lastPathComponent } ?? inner
            file = LoadedFile(raw: buf, fileSize: buf.count + (more ? 1 : 0))
            if more { compressedNotice = "First \(byteCount(buf.count)) of the decompressed file" }
        } else {
            do {
                file = try FileLoader.load(path: path, limit: maxBytes, tail: isLog)
            } catch {
                return message("Couldn't read this file.", fileSize: 0)
            }
        }
        mark("read")
        // SQLite under another name (Core Data stores, extensionless files).
        if SQLitePreview.isSQLite(file.raw.base, file.raw.count) && compressedNotice == nil && file.offset == 0 {
            return openSQLite(path: path, name: name)
        }
        let decoded = Decoder.decode(file.raw, truncated: file.truncated)
        mark("decode")
        var text: TextBuffer
        var lang: Language
        switch decoded {
        case .text(let t, _, _):
            text = t
            let head = UnsafeBufferPointer(start: t.base, count: min(t.count, 512))
            lang = Language.detect(fileName: name, head: head)
        case .binary:
            if let xml = binaryPlistAsXML(file.raw) {
                text = xml
                lang = .xml
            } else {
                text = HexDump.render(file.raw, limit: HexDump.limit)
                lang = .hexdump
            }
        }
        mark("detect")
        // Jupyter notebooks render as Markdown (anything that isn't one stays JSON).
        if lang == .json && (name as NSString).pathExtension.lowercased() == "ipynb", let md = Notebook.markdown(text) {
            text = md
            lang = .markdown
            mark("notebook")
        }
        // Minified JSON is re-indented for display (formats that allow comments or are
        // line-structured are left alone).
        var formatted = false
        var unformatted: TextBuffer?   // set when only a prefix was formatted (rest in background)
        if lang == .json && !Document.noReformat.contains((path as NSString).pathExtension.lowercased())
            && JSONFormatter.looksMinified(text) {
            formatted = true
            if text.count > progressiveThreshold {
                // First screens now; the whole file in the background (formatting runs at
                // ~0.9 GB/s: 72 ms for 64 MB is too long to wait for). Cut after a comma.
                var cut = min(text.count, progressivePrefix)
                var c = cut
                while c > cut - 4096 && c > 1 && text.base[c - 1] != 0x2C { c -= 1 }
                if text.base[c - 1] == 0x2C { cut = c }
                unformatted = text
                text = JSONFormatter.format(text, count: cut)
            } else {
                text = JSONFormatter.format(text)
            }
            mark("format")
        }
        var notice: String?
        if lang == .hexdump && file.fileSize > HexDump.limit {
            notice = "First \(byteCount(HexDump.limit)) of \(byteCount(file.fileSize))"
        } else if let c = compressedNotice {
            notice = c
        } else if file.truncated {
            notice = "\(file.offset > 0 ? "Last" : "First") \(byteCount(file.raw.count)) of \(byteCount(file.fileSize))"
        }
        if formatted { notice = notice.map { "Formatted · " + $0 } ?? "Formatted from minified JSON" }
        if lang == .markdown {
            let md = MarkdownParser.parse(text)
            mark("parse")
            let content = MarkdownContent(doc: md, baseDir: URL(fileURLWithPath: path).deletingLastPathComponent())
            let doc = Document(kind: .markdown, content: content, fileSize: file.fileSize, truncated: file.truncated)
            doc.timings = times
            doc.path = path
            doc.notice = notice
            return doc
        }
        let lines = LineIndex(text)
        mark("lines")
        if let raw = unformatted {
            // Prefix is under the progressive threshold: lex it whole, now.
            let tokens = TokenStream(expectedBytes: text.count)
            lang.lex(text.base, 0, text.count, tokens)
            mark("lex")
            let estimate = lines.count * (raw.count / max(1, text.count) + 1) * 2
            let content = CodeContent(text: text, lines: lines, tokens: tokens, language: lang, typography: typography,
                                      lineNumbers: true, lineCountHint: estimate)
            let doc = Document(kind: .code(lang), content: content, fileSize: file.fileSize, truncated: file.truncated)
            doc.timings = times
            doc.path = path
            doc.notice = notice
            let lang = lang
            DispatchQueue.global(qos: .userInitiated).async {
                let t0 = nanotime()
                let full = JSONFormatter.format(raw)
                let fullLines = LineIndex(full)
                let fullTokens = TokenStream(expectedBytes: full.count)
                lang.lex(full.base, 0, full.count, fullTokens)
                let ns = nanotime() - t0
                DispatchQueue.main.async {
                    content.replace(text: full, lines: fullLines, tokens: fullTokens)
                    doc.timings.append(("format-bg", ns))
                    doc.onContentReplaced?()
                }
            }
            return doc
        }
        // Big files: lex a prefix now (first paint cost independent of file size) and the
        // whole file on a background P-core; tokens are swapped in when ready.
        let prefixEnd = text.count <= progressiveThreshold ? text.count
            : lines.start(min(lines.count - 1, lines.line(containing: progressivePrefix) + 1))
        let tokens = TokenStream(expectedBytes: prefixEnd)
        lang.lex(text.base, 0, prefixEnd, tokens)
        mark("lex")
        let content = CodeContent(text: text, lines: lines, tokens: tokens, language: lang, typography: typography,
                                  lineNumbers: lang != .hexdump && file.offset == 0)   // tail loads: numbers would be wrong
        mark("content")
        let doc = Document(kind: .code(lang), content: content, fileSize: file.fileSize, truncated: file.truncated)
        doc.timings = times
        doc.path = path
        doc.notice = notice
        doc.startAtEnd = isLog
        if prefixEnd < text.count {
            let text = text, lang = lang
            DispatchQueue.global(qos: .userInitiated).async {
                let t0 = nanotime()
                let full = TokenStream(expectedBytes: text.count)
                lang.lex(text.base, 0, text.count, full)
                let ns = nanotime() - t0
                DispatchQueue.main.async {
                    content.setTokens(full)
                    doc.timings.append(("lex-bg", ns))
                    doc.onUpdate?()
                }
            }
        }
        return doc
    }

    /// Time allowed for decompressing a single compressed file before the preview shows what
    /// it has (the notice says it's the first part).
    static let decompressBudget: UInt64 = 40_000_000

    static func openSQLite(path: String, name: String) -> Document {
        let t0 = nanotime()
        let (md, notice) = SQLitePreview.markdown(path: path, name: name)
        let t1 = nanotime()
        let parsed = MarkdownParser.parse(TextBuffer(md))
        let t2 = nanotime()
        let content = MarkdownContent(doc: parsed, baseDir: nil)
        var st = stat()
        let size = stat(path, &st) == 0 ? Int(st.st_size) : 0
        let doc = Document(kind: .markdown, content: content, fileSize: size, truncated: false)
        doc.timings = [("sqlite", t1 - t0), ("parse", t2 - t1)]
        doc.path = path
        doc.notice = notice
        return doc
    }

    /// Lists an archive: 25 ms of reading now; a listing that isn't done by then shows what it
    /// has and is replaced when the background pass finishes (big tarballs must be decoded).
    static func openArchive(path: String, name: String, kind: ArchiveKind, typography: Typography) -> Document {
        let t0 = nanotime()
        let listing = ArchiveReader.list(path: path, kind: kind, budgetNanos: 25_000_000)
        let t1 = nanotime()
        // Rendering (folder tree, sort) is ~0.2 µs per entry: huge listings render off the
        // first frame, which shows a one-line placeholder.
        let deferRender = listing.complete && listing.count > 25_000
        var shown = listing
        if deferRender {
            shown = ArchiveListing(kind: kind)
            shown.fileSize = listing.fileSize
            shown.pendingEntries = listing.count
            shown.complete = false
        }
        let (text, tokens) = shown.render(title: name)
        let lines = LineIndex(text)
        let t2 = nanotime()
        let content = CodeContent(text: text, lines: lines, tokens: tokens, language: .plain, typography: typography,
                                  lineNumbers: false)
        let doc = Document(kind: .code(.plain), content: content, fileSize: Int(listing.fileSize), truncated: false)
        doc.timings = [("list", t1 - t0), ("render", t2 - t1)]
        doc.path = path
        if !listing.complete || deferRender {
            DispatchQueue.global(qos: .userInitiated).async {
                let t0 = nanotime()
                let full = deferRender ? listing : ArchiveReader.list(path: path, kind: kind, budgetNanos: 0)
                let (t, k) = full.render(title: name)
                let li = LineIndex(t)
                let ns = nanotime() - t0
                DispatchQueue.main.async {
                    content.replace(text: t, lines: li, tokens: k)
                    doc.timings.append(("list-bg", ns))
                    doc.onContentReplaced?()
                }
            }
        }
        return doc
    }

    /// JSON-family extensions never re-indented: comments (jsonc, json5, editor settings) or
    /// one document per line (jsonl, ndjson).
    static let noReformat: Set<String> = ["jsonc", "json5", "jsonl", "ndjson", "code-workspace",
                                          "sublime-settings", "sublime-project"]

    /// Files above this size are lexed progressively (prefix now, rest in background).
    static let progressiveThreshold = 1 << 20
    static let progressivePrefix = 256 << 10

    /// Called on the main thread when background work changes what should be drawn.
    public var onUpdate: (() -> Void)?
    /// Called on the main thread when the content's text was replaced (sizes changed).
    public var onContentReplaced: (() -> Void)?

    /// Binary property lists (bplist00) shown as their XML form.
    static func binaryPlistAsXML(_ raw: TextBuffer) -> TextBuffer? {
        guard raw.count > 8, memcmp(raw.base, "bplist00", 8) == 0 else { return nil }
        let data = Data(bytesNoCopy: raw.base, count: raw.count, deallocator: .none)
        guard let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let xml = try? PropertyListSerialization.data(fromPropertyList: obj, format: .xml, options: 0) else { return nil }
        return xml.withUnsafeBytes { TextBuffer(copying: $0) }
    }

    static func message(_ s: String, fileSize: Int) -> Document {
        Document(kind: .error(s), content: MessageContent(s, detail: ""), fileSize: fileSize, truncated: false)
    }

    static func byteCount(_ n: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .memory)   // binary units: limits read as 64 KB / 64 MB
    }

    public var timingSummary: String {
        let total = timings.reduce(0) { $0 + $1.1 }
        return timings.map { "\($0.0) \(fmt($0.1))" }.joined(separator: " · ") + " = \(fmt(total))"
    }

    private func fmt(_ ns: UInt64) -> String {
        ns < 1_000_000 ? String(format: "%.0fµs", Double(ns) / 1000) : String(format: "%.2fms", Double(ns) / 1e6)
    }
}

/// A centered message (binary files, errors).
@MainActor
final class MessageContent: DocumentContent {
    let title: String
    let detail: String
    let text: TextBuffer
    var size = CGSize(width: 1, height: 1)
    let gutterWidth: CGFloat = 0
    private var width: CGFloat = 400

    init(_ title: String, detail: String) {
        self.title = title
        self.detail = detail
        text = TextBuffer(title + (detail.isEmpty ? "" : "\n" + detail))
    }

    func layout(width: CGFloat) -> Bool { self.width = width; size = CGSize(width: width, height: 200); return true }

    func draw(_ ctx: CGContext, rect: CGRect, palette: Palette, highlights: Highlights) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor(cgColor: palette.secondaryText) ?? .secondaryLabelColor,
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: title + (detail.isEmpty ? "" : " · " + detail), attributes: attrs))
        let w = CTLineGetTypographicBounds(line, nil, nil, nil)
        ctx.textPosition = CGPoint(x: (width - w) / 2, y: 100)
        CTLineDraw(line, ctx)
    }

    func drawGutter(_ ctx: CGContext, rect: CGRect, palette: Palette) {}
    func offset(at point: CGPoint) -> Int { 0 }
    func rect(for start: Int, _ end: Int) -> CGRect { .zero }
    func verticalExtent(_ start: Int, _ end: Int) -> (CGFloat, CGFloat) { (0, 200) }
    func wordRange(at offset: Int) -> (Int, Int) { (0, 0) }
    func lineRange(at offset: Int) -> (Int, Int) { (0, 0) }
}
