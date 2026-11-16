/// Parsed markdown, already flattened for rendering.
///
/// `text` is the *rendered* plain text (what a reader sees, without markup): it is what
/// find searches, what selection indexes, and what copy returns. Blocks and style runs are
/// ranges over it. There is no tree: container context (quotes, lists) is stored per block.
public final class MarkdownDocument: @unchecked Sendable {
    public var text: TextBuffer
    public var blocks: [MDBlock] = []
    public var runs: [MDRun] = []
    /// Link destinations, indexed by `MDRun.ref` of link runs.
    public var links: MDLinks
    /// Images, indexed by `MDRun.ref` of image runs.
    public var images: MDImages
    public var tables: [MDTable] = []
    public var headings: [MDHeading] = []
    /// First block of each footnote (index = number - 1); footnotes follow the main text.
    public var footnoteBlocks: [Int] = []
    /// Text offsets of each footnote's references (index = number - 1), for back-links.
    public var footnoteRefs: [[Int32]] = []

    init(text: TextBuffer, strings: TextBuffer, links: [StrRange], images: [MDImageSpec]) {
        self.text = text
        self.links = MDLinks(store: strings, ranges: links)
        self.images = MDImages(store: strings, specs: images)
    }
}

/// Link destinations stay bytes in one shared store until the renderer asks for one (a click):
/// a `String` per link was a quarter of the parse time of a link-list README.
public struct MDLinks: RandomAccessCollection, Sendable {
    let store: TextBuffer
    let ranges: [StrRange]
    public var startIndex: Int { 0 }
    public var endIndex: Int { ranges.count }
    public subscript(i: Int) -> String { store.string(Int(ranges[i].start), Int(ranges[i].end)) }
}

/// Images as ranges in the string store; `MDImage` values (with Strings) are made on access.
public struct MDImages: RandomAccessCollection, Sendable {
    let store: TextBuffer
    let specs: [MDImageSpec]
    public var startIndex: Int { 0 }
    public var endIndex: Int { specs.count }
    public subscript(i: Int) -> MDImage {
        let s = specs[i]
        var m = MDImage(url: store.string(Int(s.url.start), Int(s.url.end)),
                        alt: store.string(Int(s.alt.start), Int(s.alt.end)))
        m.width = s.width
        m.height = s.height
        if !s.dark.isNone { m.darkURL = store.string(Int(s.dark.start), Int(s.dark.end)) }
        return m
    }
}

struct MDImageSpec: BitwiseCopyable {
    var url: StrRange
    var alt: StrRange
    var dark = StrRange.none
    var width: Float = 0
    var height: Float = 0
}

public enum MDBlockKind: UInt8, Sendable, BitwiseCopyable {
    case paragraph
    case heading      // level in `level`
    case code         // fenced/indented; `language` set for fenced with info string
    case rule
    case table        // `table` indexes `tables`
    case html         // raw HTML rendered as its text content
    case alertTitle   // GitHub alert title ("Note", "Warning"): the alert type is in `alert`
}

/// One leaf block. Containers it sits in are described by `quoteDepth` and `list*` fields.
public struct MDBlock: Sendable {
    public var kind: MDBlockKind
    public var level: UInt8 = 0            // heading level 1...6
    public var quoteDepth: UInt8 = 0       // number of enclosing block quotes
    public var listDepth: UInt8 = 0        // number of enclosing list items
    /// Marker to draw for this block, set only on the first block of a list item.
    public var marker: MDMarker = .none
    /// GitHub alert of the outermost enclosing quote.
    public var alert: MDAlert = .none
    public var markerNumber: Int32 = 0     // for ordered lists
    /// No vertical space before this block (tight list items).
    public var tight = false
    public var align: MDAlign = .left      // from <p align=...>
    /// Number of the footnote this block belongs to (footnotes section), 0 = main text.
    public var footnote: Int16 = 0
    public var textStart: Int32 = 0
    public var textEnd: Int32 = 0
    public var runStart: Int32 = 0
    public var runEnd: Int32 = 0
    public var language: Language = .plain // code blocks
    public var output = false              // code block fenced as ```output (notebook outputs)
    public var table: Int32 = -1
    /// Index in `headings` for heading blocks.
    public var heading: Int32 = -1
}

/// GitHub alert types (`> [!NOTE]` ...).
public enum MDAlert: UInt8, Sendable, BitwiseCopyable {
    case none, note, tip, important, warning, caution

    public var title: String {
        switch self {
        case .none: ""
        case .note: "Note"
        case .tip: "Tip"
        case .important: "Important"
        case .warning: "Warning"
        case .caution: "Caution"
        }
    }
}

public enum MDMarker: UInt8, Sendable, BitwiseCopyable {
    case none, bullet, ordered, taskOpen, taskDone
}

public enum MDAlign: UInt8, Sendable, BitwiseCopyable { case left, center, right }

/// Inline style bits.
public struct MDStyle: OptionSet, Sendable, BitwiseCopyable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }
    public static let emphasis = MDStyle(rawValue: 1)
    public static let strong = MDStyle(rawValue: 2)
    public static let code = MDStyle(rawValue: 4)
    public static let strike = MDStyle(rawValue: 8)
    public static let link = MDStyle(rawValue: 16)
    public static let image = MDStyle(rawValue: 32)
    public static let kbd = MDStyle(rawValue: 64)
    public static let superscript = MDStyle(rawValue: 128)
    public static let subscriptStyle = MDStyle(rawValue: 256)
    public static let footnoteRef = MDStyle(rawValue: 512)
}

/// A styled span of rendered text. Unstyled text has no run.
public struct MDRun: Sendable, BitwiseCopyable {
    public var start: Int32
    public var end: Int32
    public var style: MDStyle
    /// Index into `links` (link runs) or `images` (image runs), else -1.
    public var ref: Int32 = -1
}

public struct MDImage: Sendable {
    public var url: String
    public var alt: String
    public var width: Float = 0      // from HTML attributes, 0 = intrinsic, < 0 = percent of content width
    public var height: Float = 0     // 0 = intrinsic (percent heights are ignored)
    public var darkURL: String?      // <picture> source for dark appearance
}

public struct MDTable: Sendable {
    public var columns: Int
    public var aligns: [MDAlign]
    /// Row-major cells; row 0 is the header. Each cell: text and run ranges.
    public var cells: [MDCell]
    public var rows: Int { columns == 0 ? 0 : cells.count / columns }
}

public struct MDCell: Sendable {
    public var textStart: Int32
    public var textEnd: Int32
    public var runStart: Int32
    public var runEnd: Int32
}

public struct MDHeading: Sendable {
    public var level: Int
    public var title: String
    public var block: Int
}

extension MarkdownDocument {
    /// GitHub-style anchor slugs of `headings` (repeats get -1, -2, ...). Computed on demand:
    /// only in-document links use them, and Unicode slugs (emoji headings in changelogs) cost
    /// more than parsing the rest of the document.
    public func headingSlugs() -> [String] {
        var seen: [String: Int] = [:]
        return headings.map { h in
            let b = blocks[h.block]
            var slug = MarkdownParser.slugify(text.string(Int(b.textStart), Int(b.textEnd)))
            if let n = seen[slug] { seen[slug] = n + 1; slug += "-\(n + 1)" } else { seen[slug] = 0 }
            return slug
        }
    }
}
