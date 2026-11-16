/// What a span of text *is*; the theme decides how it looks. Kept small (< 64) so per-kind
/// style tables stay tiny and `UInt8` storage works.
public enum TokenKind: UInt8, CaseIterable, Sendable {
    case plain = 0
    case comment
    case keyword
    case type
    case function
    case string
    case escape        // escapes and interpolation delimiters inside strings
    case number
    case constant      // true/false/nil, ALL_CAPS identifiers, enum-ish constants
    case builtin       // self/this/super and well-known builtins
    case variable      // $shell, @ruby, %perl-ish sigils
    case property      // .member, JSON/YAML keys, CSS properties
    case attribute     // @decorators, #[attrs], annotations
    case preprocessor  // #include, #define, macros!
    case operatorKind
    case punctuation
    case tag           // HTML/XML element names
    case attrName      // HTML/XML attribute names
    case regex
    case heading       // markdown headings, ini/toml [sections]
    case emphasis
    case strong
    case link
    case code          // inline code in prose formats
    case listMarker
    case quote
    case inserted      // diff +
    case deleted       // diff -
    case meta          // diff headers/hunks, front matter fences, doctype
    case label
    case invalid
}

/// Token stream in struct-of-arrays form: `ends[i]` is the exclusive end byte offset of token
/// `i` and `kinds[i]` its kind. Token `i` starts at `ends[i-1]` (or 0), so tokens tile the
/// text exactly and adjacent tokens never share a kind (they are merged on append).
///
/// Lexers only report interesting spans via `add(_:_:_:)`; gaps become `.plain`.
public final class TokenStream: @unchecked Sendable {
    public private(set) var ends: UnsafeMutablePointer<UInt32>
    public private(set) var kinds: UnsafeMutablePointer<UInt8>
    public private(set) var count = 0
    private var capacity: Int
    /// End of the last token (the stream covers `[0, covered)`).
    public private(set) var covered = 0

    /// Declarations seen while lexing (the code outline): name range, `.function`/`.type`,
    /// and where the declaration's title starts (its keyword, e.g. "func", or the name).
    public private(set) var symbolStart: [UInt32] = []
    public private(set) var symbolEnd: [UInt32] = []
    public private(set) var symbolKind: [UInt8] = []
    public private(set) var symbolTitleStart: [UInt32] = []

    public func addSymbol(_ start: Int, _ end: Int, _ kind: TokenKind, titleStart: Int) {
        symbolStart.append(UInt32(truncatingIfNeeded: start))
        symbolEnd.append(UInt32(truncatingIfNeeded: end))
        symbolKind.append(kind.rawValue)
        symbolTitleStart.append(UInt32(truncatingIfNeeded: titleStart))
    }

    public init(expectedBytes: Int) {
        capacity = max(256, expectedBytes / 6)
        ends = .allocate(capacity: capacity)
        kinds = .allocate(capacity: capacity)
    }

    deinit {
        ends.deallocate()
        kinds.deallocate()
    }

    @inline(never)
    private func grow() {
        let ncap = capacity * 2
        let ne = UnsafeMutablePointer<UInt32>.allocate(capacity: ncap)
        let nk = UnsafeMutablePointer<UInt8>.allocate(capacity: ncap)
        ne.update(from: ends, count: count)
        nk.update(from: kinds, count: count)
        ends.deallocate()
        kinds.deallocate()
        ends = ne
        kinds = nk
        capacity = ncap
    }

    @inline(__always)
    func push(_ end: Int, _ kind: UInt8) {
        if count > 0 && kinds[count &- 1] == kind {
            ends[count &- 1] = UInt32(truncatingIfNeeded: end)
        } else {
            if count == capacity { grow() }
            ends[count] = UInt32(truncatingIfNeeded: end)
            kinds[count] = kind
            count &+= 1
        }
        covered = end
    }

    /// Marks `[start, end)` as `kind`. Spans should be added in order; any part of a span
    /// that overlaps already-covered text is dropped, so the stream stays monotonic even if
    /// a lexer misbehaves.
    @inline(__always)
    public func add(_ start: Int, _ end: Int, _ kind: TokenKind) {
        if end <= start || end <= covered { return }
        if start > covered { push(start, TokenKind.plain.rawValue) }
        push(end, kind.rawValue)
    }

    /// Extends coverage to `end` with plain text.
    public func finish(_ end: Int) {
        if end > covered { push(end, TokenKind.plain.rawValue) }
    }

    /// Index of the first token whose end is > `offset` (the token containing `offset`).
    public func first(after offset: Int) -> Int {
        var lo = 0, hi = count
        let o = UInt32(truncatingIfNeeded: offset)
        while lo < hi {
            let mid = (lo + hi) >> 1
            if ends[mid] <= o { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    @inline(__always) public func start(_ i: Int) -> Int { i == 0 ? 0 : Int(ends[i - 1]) }
    @inline(__always) public func end(_ i: Int) -> Int { Int(ends[i]) }
    @inline(__always) public func kind(_ i: Int) -> TokenKind { TokenKind(rawValue: kinds[i]) ?? .plain }
}
