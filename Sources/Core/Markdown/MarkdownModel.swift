/// Parsed markdown, already flattened for rendering.
///
/// `text` is the *rendered* plain text (what a reader sees, without markup): it is what
/// find searches, what selection indexes, and what copy returns. Blocks and style runs are
/// ranges over it. There is no tree: container context (quotes, lists) is stored per block.
public final class MarkdownDocument: @unchecked Sendable {
    public var text: TextBuffer
    public var blocks: [MDBlock] = []
    public var runs: [MDRun] = []
    public var links: [String] = []
    public var images: [MDImage] = []
    public var tables: [MDTable] = []
    public var headings: [MDHeading] = []

    init(text: TextBuffer) { self.text = text }
}

public enum MDBlockKind: UInt8, Sendable {
    case paragraph
    case heading      // level in `level`
    case code         // fenced/indented; `language` set for fenced with info string
    case rule
    case table        // `table` indexes `tables`
    case html         // raw HTML rendered as its text content
    case footnote     // footnote definition body (rendered at the end)
}

/// One leaf block. Containers it sits in are described by `quoteDepth` and `list*` fields.
public struct MDBlock: Sendable {
    public var kind: MDBlockKind
    public var level: UInt8 = 0            // heading level 1...6
    public var quoteDepth: UInt8 = 0       // number of enclosing block quotes
    public var listDepth: UInt8 = 0        // number of enclosing list items
    /// Marker to draw for this block, set only on the first block of a list item.
    public var marker: MDMarker = .none
    public var markerNumber: Int32 = 0     // for ordered lists
    /// No vertical space before this block (tight list items).
    public var tight = false
    public var align: MDAlign = .left      // from <p align=...>
    public var textStart: Int32 = 0
    public var textEnd: Int32 = 0
    public var runStart: Int32 = 0
    public var runEnd: Int32 = 0
    public var language: Language = .plain // code blocks
    public var table: Int32 = -1
    /// Index in `headings` for heading blocks.
    public var heading: Int32 = -1
}

public enum MDMarker: UInt8, Sendable {
    case none, bullet, ordered, taskOpen, taskDone
}

public enum MDAlign: UInt8, Sendable { case left, center, right }

/// Inline style bits.
public struct MDStyle: OptionSet, Sendable {
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
public struct MDRun: Sendable {
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
    public var slug: String
    public var block: Int
}
