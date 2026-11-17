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
    public var csharpStrings = false       // @"..", $"..", $@"..", """raw""", $"""..."""
    public var cStringPrefixes = false     // L"..", u"..", U"..", u8"..", u'..'
    public var rawPrefix = false           // r"..." / r'...' without escapes (Dart, Nim, D, Julia)
    public var singleQuoteInterp = false   // '...' strings interpolate too (Dart)
    public var dollarParenInterp = false   // "$(expr)" inside strings (Julia, PowerShell)
    /// A byte that may join a number's digits when a digit/letter follows: C++ `1'000`, Nim
    /// `0x1F'i32`, Erlang `16#FF`. 0 = none.
    public var numberJoiner: UInt8 = 0

    /// One-off rules of a single language (or two close ones), checked only in the rare
    /// branches for the bytes they involve.
    public enum Dialect: Sendable {
        case none, ruby, perl, php, elixir, julia, powershell, vim, zig, nix, erlang, d, ocaml, swift, cpp, nim
    }
    public var dialect = Dialect.none

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

    // Code outline
    /// Function definitions without a keyword (C, C++, Java, C#): `name(...) {` at brace depth
    /// up to this value counts as a declaration. -1 = off.
    public var keywordlessDefinitionDepth = -1
    /// Go method receivers: `func (r *T) Name` declares `Name` (gofmt puts a space after func).
    public var goReceivers = false
    /// Keywordless definitions may have an expression body: `int f() => x;` (Dart, C#).
    public var arrowBodies = false
    /// JS/TS: members of class bodies (`name(...) {`, `name = (...) =>`) and top-level
    /// `const name = (...) =>` / `= function` bindings are declarations.
    public var jsDeclarations = false
    /// Declarations recognized by a name at the start of a line (column 0).
    public enum LineStart: Sendable {
        case none
        case signature         // `name :: Type` (Haskell), `name : Type` (Elm)
        case clause            // `name(Args) ->` (Erlang)
        case label             // `name:` (assembly)
        case assignedFunction  // `name <- function(` (R)
    }
    public var lineStart = LineStart.none
    /// `let` at column 0 declares (OCaml, F#).
    public var lineStartLet = false
    /// `table`/`view`/`function`... declare only after `create` (SQL).
    public var sqlCreate = false
    /// `- (type)selector` / `+ ...` at line start, `@interface Name` (Objective-C).
    public var objcMethods = false

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
        var hintAt = 0           // start of the keyword that set `hint` (outline titles)
        var braces = 0           // { } depth outside strings/comments
        var parens = 0
        var receiverBase = -1    // Go: paren depth at `func (`, then the name follows `)`
        var receiverAt = 0
        var qualStart = -1       // `def self.name`, `function M.name`: where the full name starts
        var classBodies: UInt64 = 0   // JS/TS: bit d set = brace depth d is a class body
        var inClassBody = false       // the current brace depth is a class body (members here)
        var pendingClass = false      // `class` seen, the `{` of its body not yet
        var classParens = 0           // `(` depth where the last class body opened
        var sawCreate = false         // SQL: in a `CREATE ...` statement
        // Spec options read per identifier, in locals: a class's stored properties are
        // reloaded after every opaque call (each token append), locals stay in registers.
        // Only these few: every extra loop-carried value spills and slows every language
        // (one more variable cost 15%); options of rare paths are read from `s` there,
        // behind `anyDialect` (spec loads on every `"` `'` `=` `<` cost Python 8%).
        let lineRuleOn = s.lineStart != .none
        let jsDecl = s.jsDeclarations, kwlDepth = s.keywordlessDefinitionDepth
        let capTypes = s.capitalizedTypes, macroBang = s.macroBang
        let anyDialect = s.dialect != .none
        let perlWords = s.dialect == .perl   // words that may open a literal: q{..}, qw(..)
        let keywordRules = s.lineStartLet || s.sqlCreate || jsDecl

        // `#!` line, before '#' can start a name (JS private fields).
        if start == 0 && closer == 0 && p[0] == 0x23 && p[1] == 0x21 {
            i = lineEnd(p, 0, end); out.add(0, i, .comment)
        }

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

                // String prefixes glued to a quote: f"..", r#"..", R"(..)", b'..'; tagged
                // templates whose text is another language: css`..`, html`..`, sql`..`.
                if i < end, p[i] == quote || p[i] == apos || p[i] == 0x23 || p[i] == backtick {
                    if p[i] != backtick, let j = prefixedString(s, p, st, i, end, out) {
                        i = j; prev = quote; prevKeyword = false; hint = 0
                        continue
                    }
                    if p[i] == backtick && jsDecl, let lang = taggedLanguage(p, st, i, prev: prev) {
                        if prev != 0x2E { out.add(st, i, .function) }
                        i = embeddedTemplate(s, p, i, end, out, lang)
                        prev = backtick; prevKeyword = false; hint = 0
                        continue
                    }
                }
                // Perl quote-like operators (q qq qw qr m s tr y + a delimiter), not after `->`.
                if perlWords && len <= 2 && i < end && !(prev == 0x3E && st >= 2 && p[st - 2] == 0x2D),
                   let j = perlQuoteLike(s, p, st, i, end, out) {
                    i = j; prev = quote; prevKeyword = false; hint = 0
                    continue
                }

                var kind = TokenKind.plain
                var newHint: UInt8 = 0
                var kw = prev == 0x2E ? 0 : s.keywords.lookup(p + st, len)
                var keepHint = false
                // Rare cases, behind one test: most identifiers follow no declaring keyword,
                // aren't in a JS class body and the language has no column-0 rule.
                if hint != 0 || inClassBody || (lineRuleOn && (st == start || p[st - 1] == newline)) {
                    // A keyword right after a declaring one: the declared name when parameters
                    // follow (`def match(`, `def print(`), else a modifier that keeps the hint
                    // (`type alias Model`, `let rec f`, `CREATE TABLE IF NOT EXISTS t`).
                    if kw != 0 && hint != 0 && kw & KeywordTable.Hint.declaresItself == 0 {
                        if hint == KeywordTable.Hint.declaresFunction && nextSignificant(p, i, end) == 0x28 { kw = 0 }
                        else if kw & KeywordTable.Hint.kindMask == TokenKind.keyword.rawValue { keepHint = true }
                        else if hint == KeywordTable.Hint.declaresType { kw = 0 }
                    }
                    // OCaml type parameters: `type 'a tree` declares `tree`.
                    if hint == KeywordTable.Hint.declaresType && st > start && p[st - 1] == apos {
                        prev = p[i - 1]
                        continue
                    }
                    // Declarations found by a name in column 0.
                    if lineRuleOn && kw == 0 && hint == 0 && (st == start || p[st - 1] == newline)
                        && lineStartDeclares(s.lineStart, p, i, end) {
                        out.add(st, i, s.lineStart == .label ? .label : .function)
                        out.addSymbol(st, i, .function, titleStart: st)
                        prev = p[i - 1]; prevKeyword = false
                        continue
                    }
                    // JS/TS class members: methods (also ones named like keywords: `get(key) {`)
                    // and arrow-function fields. Only identifiers directly in a class body that
                    // can start a member: after `{` `}` `;`, a decorator's `)`, `*` or a
                    // modifier (not parameter names or types: rescanning those was 25%).
                    if inClassBody && parens == classParens
                        && (prevKeyword || prev == 0x7B || prev == 0x7D || prev == 0x3B || prev == 0x29 || prev == 0x2A)
                        && memberMayFollow(nextSignificant(p, i, end)) && isClassMember(p, i, end) {
                        out.add(st, i, .function)
                        out.addSymbol(st, i, .function, titleStart: st)
                        hint = 0; prev = p[i - 1]; prevKeyword = false
                        continue
                    }
                    // Qualified names after a declaring keyword: `def self.create` (Ruby),
                    // `function M.helper` / `function obj:method` (Lua), `fun String.isEmail`,
                    // `fun <T> List<T>.second` (Kotlin), `sub My::Pkg::name` (Perl),
                    // `defmodule App.User` (Elixir), `class Foo::Bar` (Ruby). Titles keep them.
                    if hint & KeywordTable.Hint.declaresItself != 0 && i < end {
                        let fn = hint == KeywordTable.Hint.declaresFunction
                        var q = i
                        if fn && p[q] == 0x3C { q = angleEnd(p, q, end) }
                        let skip = p[q] == 0x2E ? 1 : p[q] == 0x3A ? (p[q + 1] == 0x3A ? 2 : fn ? 1 : 0) : 0
                        if skip > 0 && q + skip < end && cc.isIdentStart(p[q + skip]) {
                            if qualStart < 0 { qualStart = st }
                            let qk = kw != 0 ? TokenKind(rawValue: kw & KeywordTable.Hint.kindMask) ?? .keyword
                                : capTypes && c & ByteClass.upper != 0 ? TokenKind.type : .plain
                            if qk != .plain { out.add(st, i, qk) }
                            i = q + skip; prev = 0x2E; prevKeyword = false
                            continue   // `hint` stays: the name follows
                        }
                    }
                }
                if kw != 0 {
                    kind = TokenKind(rawValue: kw & KeywordTable.Hint.kindMask) ?? .keyword
                    newHint = kw & ~KeywordTable.Hint.kindMask
                    // `func (recv)` (Go): the parenthesis is not the declared name.
                    if newHint == KeywordTable.Hint.declaresFunction && nextSignificant(p, i, end) == 0x28 {
                        newHint = 0
                        if s.goReceivers && i < end && p[i] == 0x20 { receiverBase = parens; receiverAt = st }
                    }
                    if st > 0 && p[st - 1] == 0x3A { newHint = 0 }   // `Foo::class` refers to a class, doesn't declare one
                    if keywordRules {   // the languages with keyword-specific declaration rules
                        if s.lineStartLet && len == 3 && p[st] == 0x6C && p[st + 1] == 0x65 && p[st + 2] == 0x74
                            && (st == start || p[st - 1] == newline) {
                            newHint = KeywordTable.Hint.declaresFunction   // top-level `let f x =`
                        }
                        if s.sqlCreate {
                            if len == 6 && p[st] | 0x20 == 0x63 && p[st + 1] | 0x20 == 0x72 && p[st + 5] | 0x20 == 0x65 { sawCreate = true }
                            if newHint == KeywordTable.Hint.declaresType && !sawCreate { newHint = 0 }   // `ALTER TABLE t`
                        }
                        if jsDecl && newHint != KeywordTable.Hint.declaresItself {
                            if newHint == KeywordTable.Hint.declaresType && len == 5 && p[st] == 0x63 && p[st + 1] == 0x6C {
                                pendingClass = true   // `class`: its body holds members
                            } else if braces == 0 && newHint == 0 && isFunctionBinding(p, st, len, i, end) {
                                newHint = KeywordTable.Hint.declaresFunction   // `const name = (...) =>`
                            }
                        }
                    }
                    if newHint != 0 {
                        // `end program heat`, `end function` (Fortran, Pascal): closes, doesn't declare.
                        if newHint != KeywordTable.Hint.declaresItself && afterEnd(p, start, st) { newHint = 0 }
                        if newHint == KeywordTable.Hint.declaresItself {
                            selfDeclaration(p, st, len, i, end, prev: prev, prevKeyword: prevKeyword, out)
                            newHint = 0
                        }
                    }
                    if keepHint { newHint = hint } else if newHint != 0 { hintAt = st }
                } else if hint == KeywordTable.Hint.declaresFunction {
                    kind = .function
                    out.addSymbol(qualStart >= 0 ? qualStart : st, i, .function, titleStart: hintAt)
                    qualStart = -1
                } else if hint == KeywordTable.Hint.declaresType {
                    kind = .type
                    // C family: `struct stat st;` uses a type; only `struct foo {` defines one.
                    if kwlDepth < 0 || opensBody(p, i, end) {
                        out.addSymbol(qualStart >= 0 ? qualStart : st, i, .type, titleStart: hintAt)
                    }
                    qualStart = -1
                    sawCreate = false
                } else if macroBang && i < end && p[i] == 0x21 && p[i + 1] != 0x3D {
                    i &+= 1
                    kind = .preprocessor
                } else if nextSignificant(p, i, end) == 0x28 {
                    kind = .function
                    // A definition's name follows a type, modifier or statement boundary, never
                    // an operator, `(`, `,` or `.`: those calls skip the scan of their arguments.
                    // `return f(`, `await f(`, `new F(`: calls, whatever follows the arguments.
                    // `return f(`, `await f(`, `new F(`: calls, whatever follows the arguments.
                    // (Found by looking back: one more loop variable slowed every language 15%.)
                    if braces <= kwlDepth && definitionMayFollow(prev) && !(prevKeyword && expressionKeywordBefore(p, start, st))
                        && isDefinition(p, st, i, end, arrows: s.arrowBodies) {
                        let qs = qualifiedStart(p, start, st)   // `~Foo`, `Matrix::multiply` (C++)
                        out.addSymbol(qs, i, .function, titleStart: qs)
                    }
                } else if prev == 0x2E && (st < 2 || p[st - 2] != 0x2E) {
                    kind = .property
                } else if capTypes && c & ByteClass.upper != 0 {
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
                let j = number(p, i, end, cc, joiner: s.numberJoiner)
                out.add(i, j, .number)
                i = j; prev = 0x30; prevKeyword = false
                continue
            }

            if b == opener { depth &+= 1 }
            else if b == closer {
                if depth == 0 { return i }
                depth &-= 1
            }
            switch b {   // outline bookkeeping (strings and comments never get here)
            case 0x7B:
                braces &+= 1
                if pendingClass {
                    pendingClass = false; classParens = parens
                    if braces < 64 { classBodies |= 1 << UInt64(braces) }
                }
                if classBodies != 0 { inClassBody = braces < 64 && classBodies >> UInt64(braces) & 1 != 0 }
            case 0x7D:
                if classBodies != 0 {
                    if braces < 64 { classBodies &= ~(1 << UInt64(braces)) }
                    inClassBody = braces >= 1 && braces <= 64 && classBodies >> UInt64(braces - 1) & 1 != 0
                }
                braces = max(0, braces &- 1)
            case 0x3B: pendingClass = false
            case 0x28: parens &+= 1
            case 0x29: parens = max(0, parens &- 1)
            default: break
            }

            var j = i &+ 1           // default: single punctuation byte, left plain
            var significant = true   // comments don't change `prev`
            switch b {
            case quote:
                if anyDialect && s.dialect == .vim && atLineStart(p, start, i) {   // `" comment` starts a Vim line
                    j = lineEnd(p, i, end); out.add(i, j, .comment); significant = false
                } else if s.csharpStrings && p[i + 1] == quote && p[i + 2] == quote {
                    j = csharpRaw(p, i, end); out.add(i, j, .string)   // """raw""": no escapes
                } else if s.doubleQuote {
                    if s.tripleQuotes && p[i + 1] == quote && p[i + 2] == quote {
                        j = tripleString(s, p, i, end, out, quote, interp: s.interpolation)
                    } else {
                        j = string(s, p, i, end, out, quote, multiline: s.multilineStrings, escapes: true, interp: s.interpolation)
                    }
                }
            case apos:
                if anyDialect && s.dialect == .julia && (cc.isIdent(prev) || prev == 0x29 || prev == 0x5D || prev == 0x7D || prev == apos) {
                    break   // `A'`, `f(x)'`: transpose
                }
                if anyDialect && s.dialect == .nix && p[i + 1] == apos { j = nixIndented(s, p, i, end, out); break }
                switch s.singleQuote {
                case .none: break
                case .char:
                    j = string(s, p, i, end, out, apos, multiline: false, escapes: true, interp: .none)
                case .string:
                    let interp = s.singleQuoteInterp ? s.interpolation : .none
                    if s.tripleQuotes && p[i + 1] == apos && p[i + 2] == apos {
                        j = tripleString(s, p, i, end, out, apos, interp: interp)
                    } else {
                        j = string(s, p, i, end, out, apos, multiline: s.multilineStrings, escapes: true, interp: interp)
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
                } else if anyDialect && s.dialect == .d && n == 0x2B {   // /+ nested +/
                    j = blockComment(p, i, end, true, 0x2F, 0x2B, close0: 0x2B, close1: 0x2F); out.add(i, j, .comment); significant = false
                } else if s.regexLiterals && regexAllowed(prev, prevKeyword),
                          !(anyDialect && s.dialect == .swift && (n == 0x20 || n == 0x09 || n == 0x3D)),   // Swift: `a / b`, `/=` divide
                          !((prev == 0x2B || prev == 0x2D) && postfixStep(p, start, i)),     // `x++ / 2` divides
                          let k = regex(p, i, end, cc, out) {
                    out.add(i, k, .regex); j = k
                }
            case 0x23: // '#'
                if i == 0 && p[1] == 0x21 {   // shebang
                    j = lineEnd(p, i, end); out.add(i, j, .comment); significant = false
                } else if s.hashAttribute && (p[i + 1] == 0x5B || (p[i + 1] == 0x21 && p[i + 2] == 0x5B)) {
                    j = matchBracket(p, i + (p[i + 1] == 0x21 ? 2 : 1), end, 0x5B, 0x5D); out.add(i, j, .attribute)
                } else if anyDialect && s.dialect == .swift && (p[i + 1] == 0x2F || p[i + 1] == 0x23), let k = swiftRegex(p, i, end) {
                    out.add(i, k, .regex); j = k   // #/regex/#
                } else if anyDialect && s.dialect == .julia && p[i + 1] == 0x3D {   // #= nested =#
                    j = blockComment(p, i, end, true, 0x23, 0x3D, close0: 0x3D, close1: 0x23); out.add(i, j, .comment); significant = false
                } else if anyDialect && s.dialect == .nim && p[i + 1] == 0x5B {     // #[ nested ]#
                    j = blockComment(p, i, end, true, 0x23, 0x5B, close0: 0x5D, close1: 0x23); out.add(i, j, .comment); significant = false
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
                } else if s.objcMethods && (i == start || p[i - 1] == newline) {
                    objcMethod(p, i, end, out)
                }
            case 0x2B: // '+'
                if s.objcMethods && (i == start || p[i - 1] == newline) { objcMethod(p, i, end, out) }
            case 0x3B: // ';'
                if s.semicolonComment { j = lineEnd(p, i, end); out.add(i, j, .comment); significant = false }
                sawCreate = false
            case 0x25: // '%'
                if s.percentComment { j = lineEnd(p, i, end); out.add(i, j, .comment); significant = false }
                else if anyDialect && s.dialect == .ruby, let k = rubyPercent(s, p, i, end, out, exprStart: regexAllowed(prev, prevKeyword)) { j = k }
                else if anyDialect && s.dialect == .perl && (cc.isIdentStart(p[i + 1]) || p[i + 1] == 0x24)
                            && (prevKeyword || (!cc.isIdent(prev) && prev != 0x29 && prev != 0x5D)) {   // `my %h`, not `$a % $b`
                    j = i + 1   // %hash
                    while j < end && (cc.isIdent(p[j]) || p[j] == 0x24) { j &+= 1 }
                    out.add(i, j, .variable)
                }
            case 0x7B: // '{'
                if s.haskellBlockComment && p[i + 1] == 0x2D {
                    j = blockComment(p, i, end, true, 0x7B, 0x2D, close0: 0x2D, close1: 0x7D); out.add(i, j, .comment); significant = false
                } else if anyDialect && s.dialect == .ocaml, let k = ocamlQuoted(p, i, end) {
                    out.add(i, k, .string); j = k   // {|text|}, {id|text|id}
                }
            case 0x28: // '('
                if s.ocamlBlockComment && p[i + 1] == 0x2A && p[i + 2] != 0x29 {
                    j = blockComment(p, i, end, true, 0x28, 0x2A, close0: 0x2A, close1: 0x29); out.add(i, j, .comment); significant = false
                }
            case 0x5B: // '['
                if s.luaLongBrackets && (p[i + 1] == 0x5B || p[i + 1] == 0x3D), let k = luaLong(p, i, end) {
                    out.add(i, k, .string); j = k
                } else if anyDialect && s.dialect == .cpp && p[i + 1] == 0x5B {
                    j = matchBracket(p, i, end, 0x5B, 0x5D); out.add(i, j, .attribute)   // [[nodiscard]]
                }
            case 0x3D: // '='
                // `=begin`...`=end` (Ruby), POD `=head1`...`=cut` (Perl) at a line start.
                if (anyDialect && s.dialect == .ruby || anyDialect && s.dialect == .perl) && (i == start || p[i - 1] == newline),
                   let k = blockDoc(p, i, end, ruby: anyDialect && s.dialect == .ruby) {
                    out.add(i, k, .comment); j = k; significant = false
                }
            case 0x7E: // '~'
                if anyDialect && s.dialect == .elixir, let k = elixirSigil(s, p, i, end, out) { j = k }
            case 0x5C: // '\'
                if anyDialect && s.dialect == .zig && p[i + 1] == 0x5C { j = lineEnd(p, i, end); out.add(i, j, .string) }   // \\multiline
            case 0x40: // '@'
                if s.csharpStrings && p[i + 1] == quote {
                    j = verbatimString(p, i + 1, end); out.add(i, j, .string)
                } else if s.csharpStrings && p[i + 1] == 0x24 && p[i + 2] == quote {
                    j = verbatimString(p, i + 2, end); out.add(i, j, .string)   // @$"..."
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
                    let akw = s.atKeywords ? s.keywords.lookup(p + i + 1, j - i - 1) : 0
                    if akw != 0 {
                        out.add(i, j, .keyword)
                        // `@interface Name`, `@implementation Name`, `@protocol Name` (not `@protocol(`).
                        if akw & KeywordTable.Hint.declaresItself == KeywordTable.Hint.declaresType && p[j] == 0x20 {
                            var a = j
                            while a < end && (p[a] == 0x20 || p[a] == 0x09) { a &+= 1 }
                            var z = a
                            while z < end && cc.isIdent(p[z]) { z &+= 1 }
                            if z > a && nextSignificant(p, z, end) != 0x3B { out.addSymbol(a, z, .type, titleStart: i) }
                        }
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
                if s.csharpStrings && (p[i + 1] == quote || p[i + 1] == 0x24 || (p[i + 1] == 0x40 && p[i + 2] == quote)) {
                    j = csharpDollar(s, p, i, end, out)
                } else if anyDialect && s.dialect == .erlang {   // $a, $\n: character codes
                    j = min(i + (p[i + 1] == 0x5C ? 3 : 2), end); out.add(i, j, .string)
                } else if anyDialect && s.dialect == .perl && p[i + 1] == 0x23 && (cc.isIdentStart(p[i + 2]) || p[i + 2] == 0x7B || p[i + 2] == 0x24) {
                    j = i + 2   // $#array, $#{expr}, $#$ref: last index
                    while j < end && (cc.isIdent(p[j]) || p[j] == 0x24) { j &+= 1 }
                    out.add(i, j, .variable)
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
                    j = number(p, i, end, cc, joiner: s.numberJoiner); out.add(i, j, .number)
                }
            case 0x3C: // '<'
                // `fun <T> name` (Kotlin): type parameters before the declared name.
                if hint == KeywordTable.Hint.declaresFunction && prevKeyword { j = angleEnd(p, i, end) }
                else if p[i + 1] == 0x3C && (anyDialect && s.dialect == .ruby || anyDialect && s.dialect == .perl || anyDialect && s.dialect == .php), let k = heredoc(s, p, i, end, out) { j = k }
                else if anyDialect && s.dialect == .powershell && p[i + 1] == 0x23 {   // <# block comment #>
                    let e = findAny(p, i + 2, end, 0x3E, 0x3E, 0x3E, 0x3E)
                    var k = e
                    while k < end && p[k - 1] != 0x23 { k = findAny(p, k + 1, end, 0x3E, 0x3E, 0x3E, 0x3E) }
                    j = min(k + 1, end); out.add(i, j, .comment); significant = false
                }
            default:
                break
            }
            if significant {
                prev = p[j - 1]
                prevKeyword = false
                // Keep the hint across generics (`class Foo<`) and OCaml's `type 'a t`.
                if b != 0x3C && b != 0x2C && !(b == apos && hint == KeywordTable.Hint.declaresType) { hint = 0 }
                if hint == 0 { qualStart = -1 }
                if b == 0x29 && receiverBase >= 0 && parens <= receiverBase {
                    hint = KeywordTable.Hint.declaresFunction   // Go: `func (r *T)` -> the method name is next
                    hintAt = receiverAt
                    receiverBase = -1
                }
            }
            i = j
        }
        return end
    }

    // MARK: - Pieces

    /// `name(...)` at [st, i) is a definition when the matching `)` is followed (after
    /// qualifiers like `const`, `override`, `throws X`) by `{` (or `=>` with `arrows`), and
    /// `name` isn't after `new`.
    static func isDefinition(_ p: UnsafePointer<UInt8>, _ st: Int, _ i: Int, _ end: Int, arrows: Bool = false) -> Bool {
        var b = st - 1
        if b >= 0 && p[b] == 0x7E { b -= 1 }   // ~Destructor(
        while b >= 0 && (p[b] == 0x20 || p[b] == 0x09 || p[b] == 0x0A || p[b] == 0x0D) { b -= 1 }
        if b >= 2 && p[b] == 0x77 && p[b - 1] == 0x65 && p[b - 2] == 0x6E && (b < 3 || !isIdentByte(p[b - 3])) { return false }   // new X(
        // Base-class calls and initializer lists: `: Base(x) {`, `: a(1), b(2) {`.
        if b >= 0 && (p[b] == 0x2C || (p[b] == 0x3A && (b == 0 || p[b - 1] != 0x3A))) { return false }
        var k = i
        while k < end && (p[k] == 0x20 || p[k] == 0x09) { k += 1 }
        guard k < end, p[k] == 0x28 else { return false }
        var depth = 0
        let limit = min(end, k + 4096)
        while k < limit {
            let c = p[k]
            // Parameter lists nest a few levels at most; past `maxParens` it's not one. (Without
            // the cap `a f(` repeated scanned 4 KB per name: 0.57 s for 1 MB.)
            if c == 0x28 { depth += 1; if depth > maxParens { return false } }
            else if c == 0x29 { depth -= 1; if depth == 0 { break } }
            else if c == 0x7B || c == 0x7D || c == 0x3B { return false }
            k += 1
        }
        guard k < limit else { return false }
        k += 1
        while k < limit {
            let c = p[k]
            if c == 0x7B { return true }
            // `=>` bodies: the name must follow a return type or modifier (`int f() =>`,
            // `List<T> f() =>`), not start a switch arm (`Point(0, 0) => "origin"`).
            if arrows && c == 0x3D && p[k + 1] == 0x3E {
                var a = st - 1
                while a >= 0 && (p[a] == 0x20 || p[a] == 0x09 || p[a] == 0x0A || p[a] == 0x0D) { a -= 1 }
                return a >= 0 && (isIdentByte(p[a]) || p[a] == 0x3E || p[a] == 0x5D || p[a] == 0x3F || p[a] == 0x2A)
            }
            if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x2C || c == 0x2E || isIdentByte(c) { k += 1; continue }
            // Constructor initializers: `) : a(x), b{y} {` (C++), `) : base(x) {` (C#).
            if c == 0x3A && p[k + 1] != 0x3A { return initializerList(p, k + 1, limit) }
            return false
        }
        return false
    }

    /// After a constructor's `:`: `name(...)` / `name{...}` items separated by commas, then
    /// the body's `{`.
    static func initializerList(_ p: UnsafePointer<UInt8>, _ i: Int, _ limit: Int) -> Bool {
        var k = i
        while true {
            k = skipBlank(p, k, limit)
            let s = k
            while k < limit && (isIdentByte(p[k]) || p[k] == 0x3A || p[k] == 0x2E) { k += 1 }
            if k == s { return false }
            if p[k] == 0x3C { k = angleEnd(p, k, limit) }
            let open = p[k], close: UInt8 = open == 0x28 ? 0x29 : 0x7D
            guard open == 0x28 || open == 0x7B else { return false }
            var depth = 0
            while k < limit {
                if p[k] == open { depth += 1; if depth > maxParens { return false } }
                else if p[k] == close { depth -= 1; if depth == 0 { break } }
                else if p[k] == 0x3B { return false }
                k += 1
            }
            guard k < limit else { return false }
            k = skipBlank(p, k + 1, limit)
            if p[k] == 0x7B { return true }
            guard p[k] == 0x2C else { return false }
            k += 1
        }
    }

    /// The word before `st` (past spaces) is an expression keyword.
    static func expressionKeywordBefore(_ p: UnsafePointer<UInt8>, _ start: Int, _ st: Int) -> Bool {
        var e = st
        while e > start && (p[e - 1] == 0x20 || p[e - 1] == 0x09) { e -= 1 }
        var a = e
        while a > start && isIdentByte(p[a - 1]) { a -= 1 }
        return e - a >= 3 && e - a <= 6 && expressionKeyword(p, a)
    }

    /// The keyword at `k` starts an expression (`return`, `await`, `throw`, `new`, `yield`,
    /// `else`, `case`): a name and parentheses after it are a call, not a definition.
    @inline(__always) static func expressionKeyword(_ p: UnsafePointer<UInt8>, _ k: Int) -> Bool {
        switch p[k] {
        case 0x72: return p[k + 1] == 0x65 && p[k + 2] == 0x74 && p[k + 3] == 0x75 && p[k + 4] == 0x72 && p[k + 5] == 0x6E && !isIdentByte(p[k + 6])
        case 0x61: return p[k + 1] == 0x77 && p[k + 2] == 0x61 && p[k + 3] == 0x69 && p[k + 4] == 0x74 && !isIdentByte(p[k + 5])
        case 0x74: return p[k + 1] == 0x68 && p[k + 2] == 0x72 && p[k + 3] == 0x6F && p[k + 4] == 0x77 && !isIdentByte(p[k + 5])
        case 0x6E: return p[k + 1] == 0x65 && p[k + 2] == 0x77 && !isIdentByte(p[k + 3])
        case 0x79: return p[k + 1] == 0x69 && p[k + 2] == 0x65 && p[k + 3] == 0x6C && p[k + 4] == 0x64 && !isIdentByte(p[k + 5])
        case 0x65: return p[k + 1] == 0x6C && p[k + 2] == 0x73 && p[k + 3] == 0x65 && !isIdentByte(p[k + 4])
        case 0x63: return p[k + 1] == 0x61 && p[k + 2] == 0x73 && p[k + 3] == 0x65 && !isIdentByte(p[k + 4])
        default: return false
        }
    }

    /// What follows a class member's name: parameters, type parameters, `=` (arrow fields),
    /// `?`/`!` (TS optional/definite members).
    @inline(__always) static func memberMayFollow(_ b: UInt8) -> Bool {
        b == 0x28 || b == 0x3C || b == 0x3D || b == 0x3F || b == 0x21
    }

    /// Bytes that can precede a keywordless definition's name: the end of a type or modifier
    /// (`int f(`, `List<T> f(`, `int[] f(`, `char *f(`, `T& f(`, `int? f(`), `::`/`~` (C++),
    /// or a statement boundary (`}` `;` `{`, a line start, `)` after an attribute).
    @inline(__always) static func definitionMayFollow(_ prev: UInt8) -> Bool {
        switch prev {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x5F, 0x80...0xFF,
             0x3E, 0x5D, 0x3F, 0x2A, 0x26, 0x7D, 0x3B, 0x7B, 0x3A, 0x7E, 0x0A, 0x29:
            return true
        default:
            return false
        }
    }

    /// From a `<` at `i` to just past its matching `>` (`=>` and `->` inside don't close);
    /// `i + 1` if it doesn't close on the line.
    static func angleEnd(_ p: UnsafePointer<UInt8>, _ i: Int, _ end: Int) -> Int {
        var depth = 0
        var k = i
        let limit = min(end, i + 256)
        while k < limit {
            switch p[k] {
            case 0x3C: depth += 1
            case 0x3E:
                if p[k - 1] != 0x3D && p[k - 1] != 0x2D {
                    depth -= 1
                    if depth == 0 { return k + 1 }
                }
            case 0x0A, 0x3B, 0x7B, 0x7D: return i + 1
            default: break
            }
            k += 1
        }
        return i + 1
    }

    /// From a `(` at `i` to just past its match, or nil (unbalanced within 4 KB, or nested
    /// deeper than `maxParens`).
    static func parenEnd(_ p: UnsafePointer<UInt8>, _ i: Int, _ end: Int) -> Int? {
        var depth = 0
        var k = i
        let limit = min(end, i + 4096)
        while k < limit {
            let c = p[k]
            if c == 0x28 { depth += 1; if depth > maxParens { return nil } }
            else if c == 0x29 { depth -= 1; if depth == 0 { return k + 1 } }
            k += 1
        }
        return nil
    }

    /// Declaration heuristics give up on parentheses nested deeper (real parameter lists and
    /// values nest a few levels): each scan then stops within 32 `(`, so names repeated
    /// before unclosed `(`s cost O(32) each instead of a 4 KB scan each.
    static let maxParens = 32

    @inline(__always) static func skipBlank(_ p: UnsafePointer<UInt8>, _ i: Int, _ end: Int) -> Int {
        var k = i
        while k < end && (p[k] == 0x20 || p[k] == 0x09 || p[k] == 0x0A || p[k] == 0x0D) { k += 1 }
        return k
    }

    /// A keyword that is itself a declaration (`init`, `deinit`, `subscript`, `constructor`,
    /// C++ `operator`, Rust `impl`, HCL blocks). Followed by parameters or a body: a function
    /// named by the keyword. Otherwise (`impl Trait for Type {`, `resource "a" "b" {`) a
    /// block whose header, up to `{`, is the title.
    static func selfDeclaration(_ p: UnsafePointer<UInt8>, _ st: Int, _ len: Int, _ i: Int, _ end: Int,
                                prev: UInt8, prevKeyword: Bool, _ out: TokenStream) {
        var k = i
        if len == 8 && p[st] == 0x6F && p[st + 1] == 0x70 {   // operator+(...) {, operator()(...) {
            while k < end && (p[k] == 0x20 || p[k] == 0x09) { k += 1 }
            if (p[k] == 0x28 && p[k + 1] == 0x29) || (p[k] == 0x5B && p[k + 1] == 0x5D) {
                k += 2
            } else if isIdentByte(p[k]) {   // conversions and allocation: operator bool, operator new
                while k < end && isIdentByte(p[k]) { k += 1 }
                if p[k] == 0x5B && p[k + 1] == 0x5D { k += 2 }
            } else {
                while k < end, case let c = p[k], c != 0x28 && c != 0x20 && c != 0x0A && c != 0x3B && c != 0x7B && c != 0x29 { k += 1 }
            }
            if k > i && isDefinition(p, st, k, end) { out.addSymbol(st, k, .function, titleStart: st) }
            return
        }
        if p[k] == 0x3F || p[k] == 0x21 { k += 1 }   // init? init!
        while k < end && (p[k] == 0x20 || p[k] == 0x09) { k += 1 }
        if p[k] == 0x3C { k = angleEnd(p, k, end); while k < end && (p[k] == 0x20 || p[k] == 0x09) { k += 1 } }
        if p[k] == 0x28 || p[k] == 0x7B {
            out.addSymbol(st, i, .function, titleStart: st)
            return
        }
        // Block header: only where a statement starts (`fn f() -> impl Trait` names a type),
        // and not an assignment (`data = {` in HCL); `=` inside `<...>` is fine.
        guard prevKeyword || prev == 0x0A || prev == 0x7D || prev == 0x3B || prev == 0x7B || prev == 0x5D else { return }
        let limit = min(end, i + 512)
        // Every HCL block comes here, so jump with SIMD to the first `{ ; = <` (a `<` means
        // generics: the careful scan, where `=` may be inside `<...>` and lines may continue).
        k = min(findAny(p, i, limit, 0x7B, 0x3B, 0x3D, 0x3C), limit)
        if k < limit && p[k] == 0x3D { return }   // an assignment: `data = {`
        if k < limit && p[k] == 0x3C {
            var angles = 0
            while k < limit {
                let c = p[k]
                if c == 0x7B || c == 0x3B || (c == 0x0A && angles <= 0) { break }
                switch c {
                case 0x3C: angles += 1
                case 0x3E: if p[k - 1] != 0x2D && p[k - 1] != 0x3D { angles -= 1 }
                case 0x3D: if angles <= 0 && p[k + 1] != 0x3E { return }
                default: break
                }
                k += 1
            }
            // A header may continue on the next lines (`impl<T> Foo<T>\nwhere\n  T: X,\n{`).
            if k < limit && p[k] == 0x0A {
                while k < limit && p[k] != 0x7B && p[k] != 0x3B { k += 1 }
            }
        }
        guard k < limit, p[k] == 0x7B else { return }
        var e = k
        if len == 4 && p[st] == 0x69 {   // Rust `impl`: a `where` clause stays out of the title
            var w = i
            while w + 5 < e {
                if p[w] == 0x77 && p[w + 1] == 0x68 && p[w + 2] == 0x65 && p[w + 3] == 0x72 && p[w + 4] == 0x65
                    && !isIdentByte(p[w - 1]) && !isIdentByte(p[w + 5]) { e = w; break }
                w += 1
            }
        }
        while e > i && (p[e - 1] == 0x20 || p[e - 1] == 0x09 || p[e - 1] == 0x0A || p[e - 1] == 0x0D) { e -= 1 }
        out.addSymbol(st, e, .type, titleStart: st)
    }

    /// A column-0 name at `[.., i)` declares, per `rule`.
    static func lineStartDeclares(_ rule: CLikeSpec.LineStart, _ p: UnsafePointer<UInt8>, _ i: Int, _ end: Int) -> Bool {
        var k = i
        switch rule {
        case .none: return false
        case .clause: return p[k] == 0x28
        case .label: return p[k] == 0x3A
        case .signature:
            while k < end && (p[k] == 0x20 || p[k] == 0x09) { k += 1 }
            return p[k] == 0x3A && (p[k + 1] == 0x3A || p[k + 1] == 0x20)
        case .assignedFunction:
            while k < end && (p[k] == 0x20 || p[k] == 0x09) { k += 1 }
            if p[k] == 0x3C && p[k + 1] == 0x2D { k += 2 }
            else if p[k] == 0x3C && p[k + 1] == 0x3C && p[k + 2] == 0x2D { k += 3 }
            else if p[k] == 0x3D && p[k + 1] != 0x3D { k += 1 }
            else { return false }
            while k < end && (p[k] == 0x20 || p[k] == 0x09) { k += 1 }
            if p[k] == 0x5C && p[k + 1] == 0x28 { return true }   // \(x) lambda
            return p[k] == 0x66 && p[k + 1] == 0x75 && p[k + 2] == 0x6E && p[k + 3] == 0x63 && p[k + 4] == 0x74
                && p[k + 5] == 0x69 && p[k + 6] == 0x6F && p[k + 7] == 0x6E && !isIdentByte(p[k + 8])
        }
    }

    /// The word before `st` on the same line is `end` (any case): `end program x` closes.
    static func afterEnd(_ p: UnsafePointer<UInt8>, _ start: Int, _ st: Int) -> Bool {
        var a = st - 1
        while a >= start && (p[a] == 0x20 || p[a] == 0x09) { a -= 1 }
        guard a - 2 >= start, a < st - 1 else { return false }
        return p[a] | 0x20 == 0x64 && p[a - 1] | 0x20 == 0x6E && p[a - 2] | 0x20 == 0x65
            && (a - 3 < start || !isIdentByte(p[a - 3]))
    }

    /// Start of a definition's full name: `~Foo`, `Matrix::multiply`, `a::b::~c` (C++).
    static func qualifiedStart(_ p: UnsafePointer<UInt8>, _ start: Int, _ st: Int) -> Int {
        var a = st
        if a > start && p[a - 1] == 0x7E { a -= 1 }
        while a - 2 > start && p[a - 1] == 0x3A && p[a - 2] == 0x3A {
            var y = a - 2
            while y > start && isIdentByte(p[y - 1]) { y -= 1 }
            if y == a - 2 { break }
            a = y
        }
        return a
    }

    /// `- (type)name:(T)arg rest {` or `+ ...` at line start (Objective-C): the selector's first
    /// part, with its colon. Only a definition (a `{` before any `;`).
    static func objcMethod(_ p: UnsafePointer<UInt8>, _ i: Int, _ end: Int, _ out: TokenStream) {
        var k = i + 1
        while k < end && (p[k] == 0x20 || p[k] == 0x09) { k += 1 }
        if p[k] == 0x28, let close = parenEnd(p, k, end) { k = close }
        while k < end && (p[k] == 0x20 || p[k] == 0x09) { k += 1 }
        let s = k
        while k < end && (isIdentByte(p[k]) || p[k] >= 0x80) { k += 1 }
        guard k > s else { return }
        let e = p[k] == 0x3A ? k + 1 : k
        var b = e
        let limit = min(end, e + 2048)
        while b < limit && p[b] != 0x7B && p[b] != 0x3B { b += 1 }
        if b < limit && p[b] == 0x7B { out.addSymbol(s, e, .function, titleStart: s) }
    }

    /// JS/TS class member at `[.., i)`: `name(...) {`, `name<T>(...): R {`, or a field holding
    /// an arrow function (`name = (...) =>`, `name = async x =>`).
    static func isClassMember(_ p: UnsafePointer<UInt8>, _ i: Int, _ end: Int) -> Bool {
        var k = i
        if p[k] == 0x3F || p[k] == 0x21 { k += 1 }   // name?( / name!: (TS)
        while k < end && (p[k] == 0x20 || p[k] == 0x09) { k += 1 }
        if p[k] == 0x3C { k = angleEnd(p, k, end) }
        if p[k] == 0x28 {
            guard let close = parenEnd(p, k, end) else { return false }
            k = skipBlank(p, close, end)
            if p[k] == 0x7B { return true }
            guard p[k] == 0x3A else { return false }
            // A return type, then the body (`;` first: an overload or abstract signature).
            let limit = min(end, k + 1024)
            while k < limit {
                switch p[k] {
                case 0x7B: return true
                case 0x3B, 0x7D: return false
                case 0x3D: if p[k + 1] != 0x3E { return false }
                default: break
                }
                k += 1
            }
            return false
        }
        guard let eq = assignment(p, k, end) else { return false }
        return isFunctionValue(p, eq + 1, end)
    }

    /// `const|let|var name[: Type] = <function>`, the keyword at `st..<st+len`: the binding
    /// declares a function.
    static func isFunctionBinding(_ p: UnsafePointer<UInt8>, _ st: Int, _ len: Int, _ i: Int, _ end: Int) -> Bool {
        let isBinding = (len == 5 && p[st] == 0x63 && p[st + 1] == 0x6F && p[st + 2] == 0x6E && p[st + 3] == 0x73 && p[st + 4] == 0x74)
            || (len == 3 && ((p[st] == 0x6C && p[st + 1] == 0x65 && p[st + 2] == 0x74) || (p[st] == 0x76 && p[st + 1] == 0x61 && p[st + 2] == 0x72)))
        guard isBinding else { return false }
        var k = i
        while k < end && (p[k] == 0x20 || p[k] == 0x09) { k += 1 }
        guard k < end, (isIdentByte(p[k]) && !(p[k] >= 0x30 && p[k] <= 0x39)) || p[k] == 0x24 else { return false }
        while k < end && (isIdentByte(p[k]) || p[k] == 0x24 || p[k] >= 0x80) { k += 1 }
        guard let eq = assignment(p, k, end) else { return false }
        return isFunctionValue(p, eq + 1, end)
    }

    /// From just after a name: optional `!`/`?` and `: Type`, then `=` (not `==`/`=>`).
    /// Returns the `=`'s index.
    static func assignment(_ p: UnsafePointer<UInt8>, _ i: Int, _ end: Int) -> Int? {
        var k = i
        if p[k] == 0x21 || p[k] == 0x3F { k += 1 }
        while k < end && (p[k] == 0x20 || p[k] == 0x09) { k += 1 }
        if p[k] == 0x3D { return p[k + 1] == 0x3D || p[k + 1] == 0x3E ? nil : k }
        guard p[k] == 0x3A else { return nil }
        var depth = 0   // brackets inside the type annotation
        let limit = min(end, k + 512)
        k += 1
        while k < limit {
            switch p[k] {
            case 0x28, 0x3C, 0x5B, 0x7B: depth += 1
            case 0x29, 0x5D, 0x7D: depth -= 1; if depth < 0 { return nil }
            case 0x3E: if p[k - 1] != 0x3D { depth -= 1; if depth < 0 { return nil } }
            case 0x3D:
                if p[k + 1] == 0x3E { k += 1 }
                else if depth == 0 { return p[k + 1] == 0x3D ? nil : k }
            case 0x3B, 0x0A: if depth == 0 { return nil }
            default: break
            }
            k += 1
        }
        return nil
    }

    /// A function expression starts at `i`: `function`, `(...) =>`, `x =>`, `<T>(...) =>`,
    /// each optionally `async`.
    static func isFunctionValue(_ p: UnsafePointer<UInt8>, _ i: Int, _ end: Int) -> Bool {
        var k = i
        while k < end && (p[k] == 0x20 || p[k] == 0x09) { k += 1 }
        if p[k] == 0x61 && p[k + 1] == 0x73 && p[k + 2] == 0x79 && p[k + 3] == 0x6E && p[k + 4] == 0x63 && !isIdentByte(p[k + 5]) {
            k += 5
            while k < end && (p[k] == 0x20 || p[k] == 0x09) { k += 1 }
        }
        if p[k] == 0x66 && p[k + 1] == 0x75 && p[k + 2] == 0x6E && p[k + 3] == 0x63 && p[k + 4] == 0x74
            && p[k + 5] == 0x69 && p[k + 6] == 0x6F && p[k + 7] == 0x6E && !isIdentByte(p[k + 8]) { return true }
        if p[k] == 0x3C { k = angleEnd(p, k, end) }
        if p[k] == 0x28 {
            guard let close = parenEnd(p, k, end) else { return false }
            k = close
            while k < end && (p[k] == 0x20 || p[k] == 0x09) { k += 1 }
            if p[k] == 0x3A {   // a return type, then `=>`
                let limit = min(end, k + 256)
                while k < limit && p[k] != 0x0A && p[k] != 0x3B && !(p[k] == 0x3D && p[k + 1] == 0x3E) { k += 1 }
            }
            return p[k] == 0x3D && p[k + 1] == 0x3E
        }
        guard isIdentByte(p[k]) && !(p[k] >= 0x30 && p[k] <= 0x39) else { return false }
        while k < end && (isIdentByte(p[k]) || p[k] == 0x24) { k += 1 }
        while k < end && (p[k] == 0x20 || p[k] == 0x09) { k += 1 }
        return p[k] == 0x3D && p[k + 1] == 0x3E
    }

    /// A `{` comes before any `;`, `=`, `(` or `)` (within 512 bytes): the type has a body.
    static func opensBody(_ p: UnsafePointer<UInt8>, _ i: Int, _ end: Int) -> Bool {
        var k = i
        while k < end && (p[k] == 0x20 || p[k] == 0x09) { k += 1 }
        if p[k] == 0x3C { k = angleEnd(p, k, end) }
        // Records and primary constructors: `record Point(int X, int Y) {` (C#, Java).
        if p[k] == 0x28, let close = parenEnd(p, k, end) { k = close }
        let limit = min(end, k + 512)
        var bases = false   // after `:`, base calls may take arguments: `: Shape("circle") {`
        while k < limit {
            switch p[k] {
            case 0x7B: return true
            case 0x3A: bases = true; k += 1
            case 0x28:
                guard bases, let close = parenEnd(p, k, end) else { return false }
                k = close
            case 0x3B, 0x3D, 0x29: return false
            default: k += 1
            }
        }
        return false
    }

    @inline(__always) static func isIdentByte(_ c: UInt8) -> Bool {
        (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || (c >= 0x30 && c <= 0x39) || c == 0x5F
    }

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

    static func number(_ p: UnsafePointer<UInt8>, _ i: Int, _ end: Int, _ cc: ByteClass, joiner: UInt8 = 0) -> Int {
        var j = i
        let x = p[j + 1] | 0x20
        // `_` separates digits everywhere; `joiner` too where the language has one (C++ `1'000`,
        // Erlang `16#FF`), when a hex digit follows it.
        @inline(__always) func sep(_ k: Int) -> Bool { p[k] == 0x5F || (p[k] == joiner && joiner != 0 && cc.isHex(p[k + 1])) }
        if p[j] == 0x30 && x == 0x78 {                     // 0x
            j &+= 2
            while j < end && (cc.isHex(p[j]) || sep(j)) { j &+= 1 }
            if p[j] == 0x2E && cc.isHex(p[j + 1]) { j &+= 1; while j < end && (cc.isHex(p[j]) || sep(j)) { j &+= 1 } }
            if (p[j] | 0x20) == 0x70 { j = exponent(p, j, end, cc) }   // hex float p-exponent
        } else if p[j] == 0x30 && (x == 0x62 || x == 0x6F) {    // 0b 0o
            j &+= 2
            while j < end && (cc.isDigit(p[j]) || sep(j)) { j &+= 1 }
        } else {
            while j < end && (cc.isDigit(p[j]) || sep(j)) { j &+= 1 }
            if j < end && p[j] == 0x2E && cc.isDigit(p[j + 1]) {
                j &+= 1
                while j < end && (cc.isDigit(p[j]) || sep(j)) { j &+= 1 }
            }
            if (p[j] | 0x20) == 0x65 { j = exponent(p, j, end, cc) }
        }
        // Suffixes: u32, f64, L, ULL, n, i (imaginary)...; Nim's `'i32` after the joiner.
        if joiner != 0 && p[j] == joiner && cc.isIdentStart(p[j + 1]) { j &+= 1 }
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
        let special = interpolationByte(interp, q)
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
                if interp == .swift && p[k + 1] == 0x28, let after = swiftHole(s, p, k, end, out) {
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
            if let r = interpolation(s, p, k, end, out, interp, &seg) { j = r; continue }
            j = k + 1
        }
        out.add(seg, j, .string)
        return j
    }

    /// Swift `\(expr)` at `k` (the backslash): delimiters as escapes, the expression lexed as
    /// code; where the string continues. Nil when nested too deep (`TokenStream.nesting`):
    /// then `\(` is an escape and the rest string text. Out of line: inlined, the nesting
    /// bookkeeping grew `string`, which every string literal runs, by 11%.
    @inline(never)
    static func swiftHole(_ s: CLikeSpec, _ p: UnsafePointer<UInt8>, _ k: Int, _ end: Int, _ out: TokenStream) -> Int? {
        if out.nesting >= TokenStream.maxNesting { return nil }
        out.add(k, k + 2, .escape)
        out.nesting &+= 1
        let r = lex(s, p, k + 2, end, out, closer: 0x29)
        out.nesting &-= 1
        let after = min(r + 1, end)
        out.add(r, after, .escape)
        return after
    }

    /// The byte that opens an interpolation for `interp` (the quote itself when none).
    @inline(__always) static func interpolationByte(_ interp: CLikeSpec.Interp, _ q: UInt8) -> UInt8 {
        switch interp {
        case .dollarBrace: 0x24
        case .hashBrace: 0x23
        case .braces: 0x7B
        default: q
        }
    }

    /// An interpolation at `k` (where the opener byte is): `{expr}`, `${expr}`, `#{expr}`,
    /// `$(expr)`, `$name`. Emits the string up to it, the delimiters as escapes and the
    /// expression lexed as code; returns where the string continues. Nil: not one.
    static func interpolation(_ s: CLikeSpec, _ p: UnsafePointer<UInt8>, _ k: Int, _ end: Int, _ out: TokenStream,
                              _ interp: CLikeSpec.Interp, _ seg: inout Int, kind: TokenKind = .string) -> Int? {
        let ch = p[k]
        var open = 0, closer: UInt8 = 0x7D
        if interp == .braces && ch == 0x7B {
            if p[k + 1] == 0x7B { return k + 2 }   // {{ escape
            open = 1
        } else if (interp == .dollarBrace && ch == 0x24) || (interp == .hashBrace && ch == 0x23) {
            if p[k + 1] == 0x7B {
                open = 2
            } else if ch == 0x24 && s.dollarParenInterp && p[k + 1] == 0x28 {
                open = 2; closer = 0x29
            } else if ch == 0x24 && s.dollarIdentInterp && s.chars.isIdentStart(p[k + 1]) {
                out.add(seg, k, kind)
                var e = k + 1
                while e < end && s.chars.isIdent(p[e]) && p[e] != 0x2D { e &+= 1 }
                out.add(k, e, .variable)
                seg = e
                return e
            }
        }
        if open == 0 || out.nesting >= TokenStream.maxNesting { return nil }   // too deep: string text
        out.add(seg, k, kind)
        out.add(k, k + open, .escape)
        out.nesting &+= 1
        let r = lex(s, p, k + open, end, out, closer: closer)
        out.nesting &-= 1
        let after = min(r + 1, end)
        out.add(r, after, .escape)
        seg = after
        return after
    }

    /// """...""" / '''...''' (may contain newlines and lone quotes), with the language's
    /// interpolation (Kotlin/Scala/Dart `${}`, Python f'''{}''', Elixir `#{}`).
    static func tripleString(_ s: CLikeSpec, _ p: UnsafePointer<UInt8>, _ i: Int, _ end: Int, _ out: TokenStream,
                             _ q: UInt8, interp: CLikeSpec.Interp, escapes: Bool = true) -> Int {
        var seg = i
        var j = i + 3
        let esc: UInt8 = escapes ? backslash : q
        let special = interpolationByte(interp, q)
        while j < end {
            let k = findAny(p, j, end, q, esc, special, q)
            if k >= end { j = end; break }
            let ch = p[k]
            if ch == q {
                if p[k + 1] == q && p[k + 2] == q {
                    j = k + 3
                    while j < end && p[j] == q { j &+= 1 }   // """" closes with extra quotes
                    break
                }
                j = k + 1
                continue
            }
            if ch == backslash {
                out.add(seg, k, .string)
                if interp == .swift && p[k + 1] == 0x28, let after = swiftHole(s, p, k, end, out) {
                    seg = after; j = after
                } else {
                    let e = min(k + 2, end)
                    out.add(k, e, .escape)
                    seg = e; j = e
                }
                continue
            }
            if let r = interpolation(s, p, k, end, out, interp, &seg) { j = r; continue }
            j = k + 1
        }
        out.add(seg, min(j, end), .string)
        return min(j, end)
    }

    /// C# `$"..."`, `$@"..."`, `$$"""..."""` at the `$` at `i`: where lexing continues (`i + 1`
    /// if it isn't one). Out of line: in `lex`'s loop body the delimiter cap's few
    /// instructions slowed lexing 1-4% in every C-family language, without ever running.
    @inline(never)
    static func csharpDollar(_ s: CLikeSpec, _ p: UnsafePointer<UInt8>, _ i: Int, _ end: Int, _ out: TokenStream) -> Int {
        var q = i + 1
        while p[q] == 0x24 && q - i < maxDelimiterRun { q &+= 1 }   // $$"""...""" raw interpolated
        if p[q] == quote && p[q + 1] == quote && p[q + 2] == quote {
            let j = csharpRaw(p, q, end); out.add(i, j, .string); return j
        } else if p[i + 1] == 0x40 {
            let j = verbatimString(p, i + 2, end); out.add(i, j, .string); return j
        } else if p[q] == quote {
            out.add(i, q, .string)
            return string(s, p, q, end, out, quote, multiline: false, escapes: true, interp: .braces)
        }
        return i + 1
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
                return tripleString(s, p, i, end, out, q, interp: fmt ? .braces : .none, escapes: !raw)
            }
            return string(s, p, i, end, out, q, multiline: false, escapes: !raw, interp: fmt ? .braces : .none)
        }
        // C/C++ encoding prefixes: L"wide", u8"utf8", u'c', U"x" (raw forms like u8R"(..)" below).
        if s.cStringPrefixes && (q == quote || q == apos)
            && ((len == 1 && (p[st] == 0x4C || p[st] == 0x75 || p[st] == 0x55)) || (len == 2 && p[st] == 0x75 && p[st + 1] == 0x38)) {
            out.add(st, i, .string)
            return string(s, p, i, end, out, q, multiline: false, escapes: true, interp: .none)
        }
        // r"raw" / r'raw' (Dart, Nim, D, Julia): no escapes, no interpolation.
        if s.rawPrefix && len == 1 && p[st] == 0x72 && (q == quote || q == apos) {
            out.add(st, i, .string)
            if s.tripleQuotes && p[i + 1] == q && p[i + 2] == q {
                return tripleString(s, p, i, end, out, q, interp: .none, escapes: false)
            }
            return string(s, p, i, end, out, q, multiline: false, escapes: false, interp: .none)
        }
        if s.rustStrings && len <= 2 {
            let a = p[st], b2 = len == 2 ? p[st + 1] : 0
            // c"..." / cr"..." C strings behave like b"..." / br"...".
            let isB = (a == 0x62 || a == 0x63) && len == 1, isR = a == 0x72 && len == 1
            let isBR = len == 2 && (a == 0x62 || a == 0x63) && b2 == 0x72
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

    /// Raw string and regex delimiters (`#`, C# `$`) longer than this aren't recognized: each
    /// byte of a long run counted the rest of the run (Swift `#` repeated: 4.4 s for 128 KB).
    static let maxDelimiterRun = 32

    /// Swift #"..."# / ##"..."## raw strings. `i` at the first '#'.
    static func swiftRaw(_ p: UnsafePointer<UInt8>, _ i: Int, _ end: Int) -> Int? {
        var h = i
        while h < end && p[h] == 0x23 && h - i < maxDelimiterRun { h &+= 1 }
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

    /// The last significant byte before `i` ends `++` or `--` (a postfix step: an operand).
    static func postfixStep(_ p: UnsafePointer<UInt8>, _ start: Int, _ i: Int) -> Bool {
        var k = i - 1
        while k > start && (p[k] == 0x20 || p[k] == 0x09) { k -= 1 }
        return k > start && p[k - 1] == p[k]
    }

    /// `/.../flags` on one line; nil if it doesn't close (then '/' was division).
    static func regex(_ p: UnsafePointer<UInt8>, _ i: Int, _ end: Int, _ cc: ByteClass, _ out: TokenStream) -> Int? {
        if i > out.regexFrom && i < out.regexTo && end == out.regexEnd { return knownRegex(p, i, end, cc) }
        var j = i + 1
        var inClass = false
        while j < end {
            let ch = p[j]
            if ch == newline { break }
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
        out.regexFrom = i; out.regexTo = min(j, end); out.regexEnd = end
        return nil
    }

    /// A regex from a `/` at `i` inside the failed search of `out.regexFrom` (same line): from
    /// `i + 1` both searches step through the same bytes (a `\` skips the same next byte), and
    /// at the first `[` or `]` they agree on being in a class; from there on the earlier one
    /// found no closing `/`. So this one closes only at a `/` before any bracket. (Searching
    /// again per `/` was quadratic: `;/[` repeated on a line, 13 s for 300 KB.)
    @inline(never)
    static func knownRegex(_ p: UnsafePointer<UInt8>, _ i: Int, _ end: Int, _ cc: ByteClass) -> Int? {
        var j = i + 1
        while j < end {
            let ch = p[j]
            if ch == newline || ch == 0x5B || ch == 0x5D { return nil }
            if ch == backslash { j &+= 2; continue }
            if ch == 0x2F {
                j &+= 1
                while j < end && cc[p[j]] & ByteClass.lower != 0 { j &+= 1 }
                return j
            }
            j &+= 1
        }
        return nil
    }
}
