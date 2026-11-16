/// Configuration for the shared "C-family" lexer: everything that is identifiers, numbers,
/// strings, comments and a keyword table. Most languages are just a `CLikeSpec`.
///
/// Options are plain stored properties set once at construction; the engine reads them in
/// rarely-taken branches (special characters), so they cost ~nothing in the hot path.
public final class CLikeSpec: @unchecked Sendable {
    public enum SingleQuote: Sendable { case none, char, string, rustLifetimeOrChar }
    public enum Backtick: Sendable { case none, template, raw, identifier, command }
    public enum Interp: Sendable {
        case none
        case swift        // "\(expr)"
        case dollarBrace  // "${expr}" (and "$ident" when `dollarIdentInterp`)
        case hashBrace    // "#{expr}"
        case braces       // f"{expr}" / $"{expr}" (enabled per string by prefix)
    }

    public let keywords: KeywordTable
    public var chars = ByteClass.standard

    // Comments
    public var slashSlash = true
    public var slashStar = true
    public var nestedBlockComments = false
    public var hashComment = false
    public var dashDashComment = false
    public var semicolonComment = false
    public var percentComment = false
    public var luaLongBrackets = false     // --[[ ]] comments and [[ ]] strings
    public var haskellBlockComment = false // {- -}
    public var ocamlBlockComment = false   // (* *)

    // Strings
    public var doubleQuote = true
    public var singleQuote = SingleQuote.char
    public var backtick = Backtick.none
    public var tripleQuotes = false
    public var multilineStrings = false
    public var interpolation = Interp.none
    public var dollarIdentInterp = false   // "$name" inside strings (Kotlin, Dart, shell-ish)
    public var pythonPrefixes = false      // r b u f rb br fr rf prefixes; f enables {} interp
    public var rustStrings = false         // b"..", r"..", r#".."#, br".."
    public var swiftRawStrings = false     // #"..."#
    public var cppRawStrings = false       // R"delim(...)delim"
    public var csharpStrings = false       // @"..", $"..", $@".."

    // Everything else
    public var hashPreprocessor = false    // # directives at line start (C family)
    public var hashAttribute = false       // #[...] / #![...] (Rust)
    public var atAttribute = false         // @Name (Swift/Java/Kotlin/Python/TS decorators)
    public var atKeywords = false          // @interface, @end (Objective-C): '@' + keyword
    public var dollarVariable = false      // $name, ${name}
    public var atVariable = false          // @ivar, @@cvar (Ruby)
    public var macroBang = false           // name! (Rust macros)
    public var capitalizedTypes = true     // Foo -> type, FOO -> constant
    public var regexLiterals = false       // /re/ where an expression may start
    public var symbols = false             // :symbol (Ruby, Elixir)

    public init(keywords: KeywordTable, _ configure: (CLikeSpec) -> Void = { _ in }) {
        self.keywords = keywords
        configure(self)
    }
}

public enum CLike {
    private static let quote: UInt8 = 0x22, apos: UInt8 = 0x27, backtick: UInt8 = 0x60
    private static let backslash: UInt8 = 0x5C, newline: UInt8 = 0x0A

    /// Lexes `[start, end)`. With a `closer` (`)` or `}`), stops at the first unbalanced closer
    /// and returns its index; otherwise returns `end`. Used recursively for interpolation.
    @discardableResult
    public static func lex(_ s: CLikeSpec, _ p: UnsafePointer<UInt8>, _ start: Int, _ end: Int,
                           _ out: TokenStream, closer: UInt8 = 0) -> Int {
        let cc = s.chars
        let opener: UInt8 = closer == 0x29 ? 0x28 : closer == 0x7D ? 0x7B : 0xFF
        var depth = 0
        var i = start
        var prev: UInt8 = newline       // last significant byte
        var prevKeyword = false
        var hint: UInt8 = 0

        while i < end {
            let b = p[i]
            let c = cc[b]
            // Identifiers, keywords, and the call/declaration/type heuristics.
            if c & ByteClass.identStart != 0 {
                let st = i
                // Most identifiers are short: scalar for 8 bytes, SIMD beyond.
                i &+= 1
                let stop = min(end, i &+ 8)
                while i < stop && cc.isIdent(p[i]) { i &+= 1 }
                if i == stop && i < end { i = cc.identSet.skip(p, i, end) }
                let len = i - st

                // String prefixes glued to a quote: f"..", r#"..", R"(..)", b'..'.
                if i < end, p[i] == quote || p[i] == apos || p[i] == 0x23 {
                    if let j = prefixedString(s, p, st, i, end, out) {
                        i = j; prev = quote; prevKeyword = false; hint = 0
                        continue
                    }
                }

                var kind = TokenKind.plain
                var newHint: UInt8 = 0
                let kw = prev == 0x2E ? 0 : s.keywords.lookup(p + st, len)
                if kw != 0 {
                    kind = TokenKind(rawValue: kw & KeywordTable.Hint.kindMask) ?? .keyword
                    newHint = kw & ~KeywordTable.Hint.kindMask
                    // `func (recv)` (Go): the parenthesis is not the declared name.
                    if newHint == KeywordTable.Hint.declaresFunction && nextSignificant(p, i, end) == 0x28 { newHint = 0 }
                } else if hint == KeywordTable.Hint.declaresFunction {
                    kind = .function
                } else if hint == KeywordTable.Hint.declaresType {
                    kind = .type
                } else if s.macroBang && i < end && p[i] == 0x21 && p[i + 1] != 0x3D {
                    i &+= 1
                    kind = .preprocessor
                } else if nextSignificant(p, i, end) == 0x28 {
                    kind = .function
                } else if prev == 0x2E && (st < 2 || p[st - 2] != 0x2E) {
                    kind = .property
                } else if s.capitalizedTypes && c & ByteClass.upper != 0 {
                    kind = len > 1 && allCaps(p, st, i, cc) ? .constant : .type
                }
                if kind != .plain { out.add(st, i, kind) }
                hint = newHint
                prev = p[i - 1]
                prevKeyword = kw != 0
                continue
            }

            if c & ByteClass.space != 0 {
                // Single spaces dominate; indentation runs go through SIMD.
                i &+= 1
                if i < end && cc.isSpace(p[i]) { i = cc.spaceSet.skip(p, i &+ 1, end) }
                continue
            }

            if c & ByteClass.digit != 0 {
                let j = number(p, i, end, cc)
                out.add(i, j, .number)
                i = j; prev = 0x30; prevKeyword = false
                continue
            }

            if b == opener { depth &+= 1 }
            else if b == closer {
                if depth == 0 { return i }
                depth &-= 1
            }

            var j = i &+ 1           // default: single punctuation byte, left plain
            var significant = true   // comments don't change `prev`
            switch b {
            case quote:
                if s.doubleQuote {
                    if s.tripleQuotes && p[i + 1] == quote && p[i + 2] == quote {
                        j = tripleString(s, p, i, end, out, quote, interp: s.interpolation)
                    } else {
                        j = string(s, p, i, end, out, quote, multiline: s.multilineStrings, escapes: true, interp: s.interpolation)
                    }
                }
            case apos:
                switch s.singleQuote {
                case .none: break
                case .char:
                    j = string(s, p, i, end, out, apos, multiline: false, escapes: true, interp: .none)
                case .string:
                    if s.tripleQuotes && p[i + 1] == apos && p[i + 2] == apos {
                        j = tripleString(s, p, i, end, out, apos, interp: .none)
                    } else {
                        j = string(s, p, i, end, out, apos, multiline: s.multilineStrings, escapes: true, interp: .none)
                    }
                case .rustLifetimeOrChar:
                    if cc.isIdentStart(p[i + 1]) && p[i + 2] != apos {
                        j = i + 2
                        while j < end && cc.isIdent(p[j]) { j &+= 1 }
                        out.add(i, j, .label)
                    } else {
                        j = string(s, p, i, end, out, apos, multiline: false, escapes: true, interp: .none)
                    }
                }
            case backtick:
                switch s.backtick {
                case .none: break
                case .template:
                    j = string(s, p, i, end, out, backtick, multiline: true, escapes: true, interp: .dollarBrace)
                case .raw:
                    j = string(s, p, i, end, out, backtick, multiline: true, escapes: false, interp: .none)
                case .command:
                    j = string(s, p, i, end, out, backtick, multiline: true, escapes: true, interp: s.interpolation)
                case .identifier:
                    let k = findAny(p, i + 1, end, backtick, newline, backtick, backtick)
                    j = k < end && p[k] == backtick ? k + 1 : k
                }
            case 0x2F: // '/'
                let n = p[i + 1]
                if s.slashSlash && n == 0x2F {
                    j = lineEnd(p, i, end); out.add(i, j, .comment); significant = false
                } else if s.slashStar && n == 0x2A {
                    j = blockComment(p, i, end, s.nestedBlockComments, 0x2F, 0x2A); out.add(i, j, .comment); significant = false
                } else if s.regexLiterals && regexAllowed(prev, prevKeyword), let k = regex(p, i, end, cc) {
                    out.add(i, k, .regex); j = k
                }
            case 0x23: // '#'
                if i == 0 && p[1] == 0x21 {   // shebang
                    j = lineEnd(p, i, end); out.add(i, j, .comment); significant = false
                } else if s.hashAttribute && (p[i + 1] == 0x5B || (p[i + 1] == 0x21 && p[i + 2] == 0x5B)) {
                    j = matchBracket(p, i + (p[i + 1] == 0x21 ? 2 : 1), end, 0x5B, 0x5D); out.add(i, j, .attribute)
                } else if s.swiftRawStrings && (p[i + 1] == quote || p[i + 1] == 0x23), let k = swiftRaw(p, i, end) {
                    out.add(i, k, .string); j = k
                } else if s.hashPreprocessor && atLineStart(p, start, i) {
                    j = preprocessor(p, i, end, cc, out)
                } else if s.hashComment {
                    j = lineEnd(p, i, end); out.add(i, j, .comment); significant = false
                }
            case 0x2D: // '-'
                if s.dashDashComment && p[i + 1] == 0x2D {
                    if s.luaLongBrackets && p[i + 2] == 0x5B, let k = luaLong(p, i + 2, end) {
                        j = k
                    } else {
                        j = lineEnd(p, i, end)
                    }
                    out.add(i, j, .comment); significant = false
                }
            case 0x3B: // ';'
                if s.semicolonComment { j = lineEnd(p, i, end); out.add(i, j, .comment); significant = false }
            case 0x25: // '%'
                if s.percentComment { j = lineEnd(p, i, end); out.add(i, j, .comment); significant = false }
            case 0x7B: // '{'
                if s.haskellBlockComment && p[i + 1] == 0x2D {
                    j = blockComment(p, i, end, true, 0x7B, 0x2D, close0: 0x2D, close1: 0x7D); out.add(i, j, .comment); significant = false
                }
            case 0x28: // '('
                if s.ocamlBlockComment && p[i + 1] == 0x2A && p[i + 2] != 0x29 {
                    j = blockComment(p, i, end, true, 0x28, 0x2A, close0: 0x2A, close1: 0x29); out.add(i, j, .comment); significant = false
                }
            case 0x5B: // '['
                if s.luaLongBrackets && (p[i + 1] == 0x5B || p[i + 1] == 0x3D), let k = luaLong(p, i, end) {
                    out.add(i, k, .string); j = k
                }
            case 0x40: // '@'
                if s.csharpStrings && p[i + 1] == quote {
                    j = verbatimString(p, i + 1, end); out.add(i, j, .string)
                } else if s.atVariable && (cc.isIdentStart(p[i + 1]) || p[i + 1] == 0x40) {
                    j = i + (p[i + 1] == 0x40 ? 2 : 1)
                    while j < end && cc.isIdent(p[j]) { j &+= 1 }
                    out.add(i, j, .variable)
                } else if s.atKeywords && p[i + 1] == quote {
                    out.add(i, i + 1, .string)
                    j = string(s, p, i + 1, end, out, quote, multiline: false, escapes: true, interp: .none)
                } else if (s.atAttribute || s.atKeywords) && cc.isIdentStart(p[i + 1]) {
                    j = i + 1
                    while j < end && cc.isIdent(p[j]) { j &+= 1 }
                    if s.atKeywords && s.keywords.lookup(p + i + 1, j - i - 1) != 0 {
                        out.add(i, j, .keyword)
                    } else {
                        // Dotted decorators: @app.route, @pytest.mark.slow
                        while j + 1 < end && p[j] == 0x2E && cc.isIdentStart(p[j + 1]) {
                            j &+= 2
                            while j < end && cc.isIdent(p[j]) { j &+= 1 }
                        }
                        out.add(i, j, .attribute)
                    }
                }
            case 0x24: // '$'
                if s.csharpStrings && (p[i + 1] == quote || (p[i + 1] == 0x40 && p[i + 2] == quote)) {
                    if p[i + 1] == 0x40 {
                        j = verbatimString(p, i + 2, end); out.add(i, j, .string)
                    } else {
                        out.add(i, i + 1, .string)
                        j = string(s, p, i + 1, end, out, quote, multiline: false, escapes: true, interp: .braces)
                    }
                } else if s.dollarVariable {
                    if p[i + 1] == 0x7B {
                        j = matchBracket(p, i + 1, end, 0x7B, 0x7D); out.add(i, j, .variable)
                    } else if cc.isIdent(p[i + 1]) {
                        j = i + 1
                        while j < end && cc.isIdent(p[j]) { j &+= 1 }
                        out.add(i, j, .variable)
                    }
                }
            case 0x3A: // ':'
                if s.symbols && prev != 0x3A && cc.isIdentStart(p[i + 1]) && p[i + 1] < 0x80 {
                    j = i + 1
                    while j < end && cc.isIdent(p[j]) { j &+= 1 }
                    if j < end && (p[j] == 0x3F || p[j] == 0x21) { j &+= 1 }
                    out.add(i, j, .constant)
                } else if s.symbols && p[i + 1] == quote && prev != 0x3A {
                    out.add(i, i + 1, .constant)
                    j = string(s, p, i + 1, end, out, quote, multiline: false, escapes: true, interp: s.interpolation)
                }
            case 0x2E: // '.'
                if cc.isDigit(p[i + 1]) && !cc.isIdent(prev) && prev != 0x29 && prev != 0x2E {
                    j = number(p, i, end, cc); out.add(i, j, .number)
                }
            default:
                break
            }
            if significant {
                prev = p[j - 1]
                prevKeyword = false
                hint = b == 0x3C || b == 0x2C ? hint : 0   // keep hint across generics `class Foo<`
            }
            i = j
        }
        return end
    }

    // MARK: - Pieces

    /// True if only spaces/tabs precede `i` on its line (within the lexed range).
    static func atLineStart(_ p: UnsafePointer<UInt8>, _ start: Int, _ i: Int) -> Bool {
        var j = i - 1
        while j >= start && (p[j] == 0x20 || p[j] == 0x09) { j -= 1 }
        return j < start || p[j] == newline
    }

    @inline(__always)
    static func nextSignificant(_ p: UnsafePointer<UInt8>, _ i: Int, _ end: Int) -> UInt8 {
        var j = i
        while j < end && (p[j] == 0x20 || p[j] == 0x09) { j &+= 1 }
        return j < end ? p[j] : 0
    }

    @inline(__always)
    static func allCaps(_ p: UnsafePointer<UInt8>, _ s: Int, _ e: Int, _ cc: ByteClass) -> Bool {
        for k in s..<e where cc[p[k]] & ByteClass.lower != 0 { return false }
        return true
    }

    static func number(_ p: UnsafePointer<UInt8>, _ i: Int, _ end: Int, _ cc: ByteClass) -> Int {
        var j = i
        let x = p[j + 1] | 0x20
        if p[j] == 0x30 && x == 0x78 {                     // 0x
            j &+= 2
            while j < end && (cc.isHex(p[j]) || p[j] == 0x5F) { j &+= 1 }
            if p[j] == 0x2E && cc.isHex(p[j + 1]) { j &+= 1; while j < end && (cc.isHex(p[j]) || p[j] == 0x5F) { j &+= 1 } }
            if (p[j] | 0x20) == 0x70 { j = exponent(p, j, end, cc) }   // hex float p-exponent
        } else if p[j] == 0x30 && (x == 0x62 || x == 0x6F) {    // 0b 0o
            j &+= 2
            while j < end && (cc.isDigit(p[j]) || p[j] == 0x5F) { j &+= 1 }
        } else {
            while j < end && (cc.isDigit(p[j]) || p[j] == 0x5F) { j &+= 1 }
            if j < end && p[j] == 0x2E && cc.isDigit(p[j + 1]) {
                j &+= 1
                while j < end && (cc.isDigit(p[j]) || p[j] == 0x5F) { j &+= 1 }
            }
            if (p[j] | 0x20) == 0x65 { j = exponent(p, j, end, cc) }
        }
        // Suffixes: u32, f64, L, ULL, n, i (imaginary)...
        while j < end && cc.isIdent(p[j]) && p[j] < 0x80 { j &+= 1 }
        return min(j, end)
    }

    @inline(__always)
    static func exponent(_ p: UnsafePointer<UInt8>, _ j: Int, _ end: Int, _ cc: ByteClass) -> Int {
        var k = j + 1
        if p[k] == 0x2B || p[k] == 0x2D { k &+= 1 }
        if !cc.isDigit(p[k]) { return j }
        while k < end && cc.isDigit(p[k]) { k &+= 1 }
        return k
    }

    /// Generic quoted string with escapes and optional interpolation. `i` is at the quote.
    static func string(_ s: CLikeSpec, _ p: UnsafePointer<UInt8>, _ i: Int, _ end: Int, _ out: TokenStream,
                       _ q: UInt8, multiline: Bool, escapes: Bool, interp: CLikeSpec.Interp) -> Int {
        var seg = i
        var j = i + 1
        let esc: UInt8 = escapes ? backslash : q
        let special: UInt8
        switch interp {
        case .dollarBrace: special = 0x24
        case .hashBrace: special = 0x23
        case .braces: special = 0x7B
        default: special = q
        }
        while true {
            let k = findAny(p, j, end, q, esc, newline, special)
            if k >= end { j = end; break }
            let ch = p[k]
            if ch == q {
                j = k + 1
                break
            }
            if ch == newline {
                if !multiline { j = k; break }
                j = k + 1
                continue
            }
            if ch == backslash {
                out.add(seg, k, .string)
                if interp == .swift && p[k + 1] == 0x28 {
                    out.add(k, k + 2, .escape)
                    let r = lex(s, p, k + 2, end, out, closer: 0x29)
                    let after = min(r + 1, end)
                    out.add(r, after, .escape)
                    seg = after; j = after
                    continue
                }
                var e = k + 2
                if p[k + 1] == 0x75 && p[k + 2] == 0x7B {               // \u{...}
                    let c = findAny(p, k + 3, min(end, k + 12), 0x7D, q, newline, 0x7D)
                    if c < end && p[c] == 0x7D { e = c + 1 }
                }
                e = min(e, end)
                out.add(k, e, .escape)
                seg = e; j = e
                continue
            }
            // Interpolation openers.
            if interp == .braces && ch == 0x7B {
                if p[k + 1] == 0x7B { j = k + 2; continue }              // {{ escape
                out.add(seg, k, .string)
                out.add(k, k + 1, .escape)
                let r = lex(s, p, k + 1, end, out, closer: 0x7D)
                let after = min(r + 1, end)
                out.add(r, after, .escape)
                seg = after; j = after
                continue
            }
            if (interp == .dollarBrace && ch == 0x24) || (interp == .hashBrace && ch == 0x23) {
                if p[k + 1] == 0x7B {
                    out.add(seg, k, .string)
                    out.add(k, k + 2, .escape)
                    let r = lex(s, p, k + 2, end, out, closer: 0x7D)
                    let after = min(r + 1, end)
                    out.add(r, after, .escape)
                    seg = after; j = after
                    continue
                }
                if ch == 0x24 && s.dollarIdentInterp && s.chars.isIdentStart(p[k + 1]) {
                    out.add(seg, k, .string)
                    var e = k + 1
                    while e < end && s.chars.isIdent(p[e]) { e &+= 1 }
                    out.add(k, e, .variable)
                    seg = e; j = e
                    continue
                }
            }
            j = k + 1
        }
        out.add(seg, j, .string)
        return j
    }

    /// """...""" / '''...''' (may contain newlines and lone quotes).
    static func tripleString(_ s: CLikeSpec, _ p: UnsafePointer<UInt8>, _ i: Int, _ end: Int, _ out: TokenStream,
                             _ q: UInt8, interp: CLikeSpec.Interp) -> Int {
        var seg = i
        var j = i + 3
        while j < end {
            let k = findAny(p, j, end, q, backslash, q, q)
            if k >= end { j = end; break }
            if p[k] == backslash {
                out.add(seg, k, .string)
                if interp == .swift && p[k + 1] == 0x28 {
                    out.add(k, k + 2, .escape)
                    let r = lex(s, p, k + 2, end, out, closer: 0x29)
                    let after = min(r + 1, end)
                    out.add(r, after, .escape)
                    seg = after; j = after
                } else {
                    let e = min(k + 2, end)
                    out.add(k, e, .escape)
                    seg = e; j = e
                }
                continue
            }
            if p[k + 1] == q && p[k + 2] == q {
                j = k + 3
                while j < end && p[j] == q { j &+= 1 }   // """" closes with extra quotes
                break
            }
            j = k + 1
        }
        out.add(seg, min(j, end), .string)
        return min(j, end)
    }

    /// C# verbatim @"..." ("" is an escaped quote, no backslash escapes). `i` at the quote.
    static func verbatimString(_ p: UnsafePointer<UInt8>, _ i: Int, _ end: Int) -> Int {
        var j = i + 1
        while j < end {
            let k = findAny(p, j, end, quote, quote, quote, quote)
            if k >= end { return end }
            if p[k + 1] == quote { j = k + 2; continue }
            return k + 1
        }
        return end
    }

    /// Prefixed string literals. `st..<i` is the identifier, `p[i]` a quote or '#'.
    static func prefixedString(_ s: CLikeSpec, _ p: UnsafePointer<UInt8>, _ st: Int, _ i: Int, _ end: Int,
                               _ out: TokenStream) -> Int? {
        let len = i - st
        let q = p[i]
        if s.pythonPrefixes && len <= 2 && q != 0x23 {
            var fmt = false
            for k in st..<i {
                switch p[k] | 0x20 {
                case 0x72, 0x62, 0x75: break         // r b u
                case 0x66: fmt = true                 // f
                default: return nil
                }
            }
            out.add(st, i, .string)
            let raw = (st..<i).contains { p[$0] | 0x20 == 0x72 }
            if s.tripleQuotes && p[i + 1] == q && p[i + 2] == q {
                return tripleString(s, p, i, end, out, q, interp: .none)
            }
            return string(s, p, i, end, out, q, multiline: false, escapes: !raw, interp: fmt ? .braces : .none)
        }
        if s.rustStrings && len <= 2 {
            let a = p[st], b2 = len == 2 ? p[st + 1] : 0
            let isB = a == 0x62 && len == 1, isR = a == 0x72 && len == 1
            let isBR = len == 2 && a == 0x62 && b2 == 0x72
            if isB && (q == quote || q == apos) {
                out.add(st, i, .string)
                return string(s, p, i, end, out, q, multiline: true, escapes: true, interp: .none)
            }
            if isR || isBR {
                var h = i
                while h < end && p[h] == 0x23 { h &+= 1 }
                if h >= end || p[h] != quote { return nil }
                let hashes = h - i
                var j = h + 1
                while j < end {
                    let k = findAny(p, j, end, quote, quote, quote, quote)
                    if k >= end { j = end; break }
                    var n = 0
                    while n < hashes && p[k + 1 + n] == 0x23 { n &+= 1 }
                    if n == hashes { j = k + 1 + hashes; break }
                    j = k + 1
                }
                out.add(st, j, .string)
                return j
            }
            return nil
        }
        if s.cppRawStrings && q == quote && p[i - 1] == 0x52 && len <= 3 {   // R"delim( ... )delim"
            let open = findAny(p, i + 1, min(end, i + 18), 0x28, newline, quote, 0x28)
            if open >= end || p[open] != 0x28 { return nil }
            let dlen = open - i - 1
            var j = open + 1
            while j < end {
                let k = findAny(p, j, end, 0x29, 0x29, 0x29, 0x29)
                if k >= end { j = end; break }
                var ok = k + 1 + dlen < end && p[k + 1 + dlen] == quote
                if ok { for d in 0..<dlen where p[k + 1 + d] != p[i + 1 + d] { ok = false; break } }
                if ok { j = k + 2 + dlen; break }
                j = k + 1
            }
            out.add(st, j, .string)
            return j
        }
        return nil
    }

    /// Swift #"..."# / ##"..."## raw strings. `i` at the first '#'.
    static func swiftRaw(_ p: UnsafePointer<UInt8>, _ i: Int, _ end: Int) -> Int? {
        var h = i
        while h < end && p[h] == 0x23 { h &+= 1 }
        if h >= end || p[h] != quote { return nil }
        let hashes = h - i
        let triple = p[h + 1] == quote && p[h + 2] == quote
        var j = h + (triple ? 3 : 1)
        while j < end {
            let k = findAny(p, j, end, quote, triple ? quote : newline, quote, quote)
            if k >= end { return end }
            if p[k] == newline { return k }
            if triple && !(p[k + 1] == quote && p[k + 2] == quote) { j = k + 1; continue }
            let after = k + (triple ? 3 : 1)
            var n = 0
            while n < hashes && p[after + n] == 0x23 { n &+= 1 }
            if n == hashes { return after + hashes }
            j = k + 1
        }
        return end
    }

    /// Lua long brackets `[[ ... ]]`, `[==[ ... ]==]`. `i` at the first '['.
    static func luaLong(_ p: UnsafePointer<UInt8>, _ i: Int, _ end: Int) -> Int? {
        var j = i + 1
        var level = 0
        while j < end && p[j] == 0x3D { level &+= 1; j &+= 1 }
        if j >= end || p[j] != 0x5B { return nil }
        j &+= 1
        while j < end {
            let k = findAny(p, j, end, 0x5D, 0x5D, 0x5D, 0x5D)
            if k >= end { return end }
            var n = 0
            while p[k + 1 + n] == 0x3D { n &+= 1 }
            if n == level && p[k + 1 + n] == 0x5D { return k + 2 + n }
            j = k + 1
        }
        return end
    }

    /// Block comment from `i` (at the 2-byte opener) to just past the closer.
    static func blockComment(_ p: UnsafePointer<UInt8>, _ i: Int, _ end: Int, _ nested: Bool,
                             _ open0: UInt8, _ open1: UInt8, close0: UInt8 = 0x2A, close1: UInt8 = 0x2F) -> Int {
        var j = i + 2
        var depth = 1
        while j < end {
            let k = nested ? findAny(p, j, end, close0, open0, close0, open0) : findAny(p, j, end, close0, close0, close0, close0)
            if k >= end { return end }
            if p[k] == close0 && p[k + 1] == close1 {
                depth &-= 1
                j = k + 2
                if depth == 0 { return j }
            } else if nested && p[k] == open0 && p[k + 1] == open1 {
                depth &+= 1
                j = k + 2
            } else {
                j = k + 1
            }
        }
        return end
    }

    /// From an opening bracket at `i` to just past its match (single line or not).
    static func matchBracket(_ p: UnsafePointer<UInt8>, _ i: Int, _ end: Int, _ open: UInt8, _ close: UInt8) -> Int {
        var depth = 0
        var j = i
        while j < end {
            let k = findAny(p, j, end, open, close, quote, quote)
            if k >= end { return end }
            if p[k] == open { depth &+= 1 }
            else if p[k] == close {
                depth &-= 1
                if depth == 0 { return k + 1 }
            } else {   // skip strings inside attributes
                let e = findAny(p, k + 1, end, quote, newline, quote, quote)
                j = e < end ? e + 1 : end
                continue
            }
            j = k + 1
        }
        return end
    }

    /// `#directive` at line start: the directive word is preprocessor, `<file>` after
    /// include/import is a string, the rest of the line is lexed normally by the caller.
    static func preprocessor(_ p: UnsafePointer<UInt8>, _ i: Int, _ end: Int, _ cc: ByteClass, _ out: TokenStream) -> Int {
        var j = i + 1
        while j < end && (p[j] == 0x20 || p[j] == 0x09) { j &+= 1 }
        let ws = j
        while j < end && cc.isIdent(p[j]) { j &+= 1 }
        out.add(i, j, .preprocessor)
        let word = j - ws
        if word == 7 || word == 6 {   // include / import
            var k = j
            while k < end && (p[k] == 0x20 || p[k] == 0x09) { k &+= 1 }
            if k < end && p[k] == 0x3C {
                let e = findAny(p, k, end, 0x3E, newline, 0x3E, 0x3E)
                if e < end && p[e] == 0x3E { out.add(k, e + 1, .string); return e + 1 }
            }
        }
        return j
    }

    @inline(__always)
    static func regexAllowed(_ prev: UInt8, _ prevKeyword: Bool) -> Bool {
        if prevKeyword { return true }
        switch prev {
        case 0x28, 0x2C, 0x3D, 0x3A, 0x5B, 0x21, 0x26, 0x7C, 0x3F, 0x7B, 0x7D, 0x3B, 0x2B, 0x2D, 0x2A,
             0x25, 0x3C, 0x3E, 0x7E, 0x5E, 0x0A:
            return true
        default:
            return false
        }
    }

    /// `/.../flags` on one line; nil if it doesn't close (then '/' was division).
    static func regex(_ p: UnsafePointer<UInt8>, _ i: Int, _ end: Int, _ cc: ByteClass) -> Int? {
        var j = i + 1
        var inClass = false
        while j < end {
            let ch = p[j]
            if ch == newline { return nil }
            if ch == backslash { j &+= 2; continue }
            if ch == 0x5B { inClass = true }
            else if ch == 0x5D { inClass = false }
            else if ch == 0x2F && !inClass {
                j &+= 1
                while j < end && cc[p[j]] & ByteClass.lower != 0 { j &+= 1 }
                return j
            }
            j &+= 1
        }
        return nil
    }
}
