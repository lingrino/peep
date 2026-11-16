import AppKit
import Darwin

/// Monotonic nanoseconds (for pipeline timing).
@inline(__always) public func nanotime() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

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
        let file: LoadedFile
        do {
            file = try FileLoader.load(path: path, limit: maxBytes)
        } catch {
            return message("Couldn't read this file.", fileSize: 0)
        }
        mark("read")
        let decoded = Decoder.decode(file.raw, truncated: file.truncated)
        mark("decode")
        guard case .text(let text, _, _) = decoded else {
            return Document(kind: .binary, content: MessageContent("Binary file", detail: byteCount(file.fileSize)),
                            fileSize: file.fileSize, truncated: false)
        }
        let name = (path as NSString).lastPathComponent
        let head = UnsafeBufferPointer(start: text.base, count: min(text.count, 512))
        let lang = Language.detect(fileName: name, head: head)
        mark("detect")
        if lang == .markdown {
            let md = MarkdownParser.parse(text)
            mark("parse")
            let content = MarkdownContent(doc: md, baseDir: URL(fileURLWithPath: path).deletingLastPathComponent())
            let doc = Document(kind: .markdown, content: content, fileSize: file.fileSize, truncated: file.truncated)
            doc.timings = times
            doc.path = path
            return doc
        }
        let lines = LineIndex(text)
        mark("lines")
        // Big files: lex a prefix now (first paint cost independent of file size) and the
        // whole file on a background P-core; tokens are swapped in when ready.
        let prefixEnd = text.count <= progressiveThreshold ? text.count
            : lines.start(min(lines.count - 1, lines.line(containing: progressivePrefix) + 1))
        let tokens = TokenStream(expectedBytes: prefixEnd)
        lang.lex(text.base, 0, prefixEnd, tokens)
        mark("lex")
        let content = CodeContent(text: text, lines: lines, tokens: tokens, language: lang, typography: typography)
        mark("content")
        let doc = Document(kind: .code(lang), content: content, fileSize: file.fileSize, truncated: file.truncated)
        doc.timings = times
        doc.path = path
        if prefixEnd < text.count {
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

    /// Files above this size are lexed progressively (prefix now, rest in background).
    static let progressiveThreshold = 1 << 20
    static let progressivePrefix = 256 << 10

    /// Called on the main thread when background work changes what should be drawn.
    public var onUpdate: (() -> Void)?

    static func message(_ s: String, fileSize: Int) -> Document {
        Document(kind: .error(s), content: MessageContent(s, detail: ""), fileSize: fileSize, truncated: false)
    }

    static func byteCount(_ n: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
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
