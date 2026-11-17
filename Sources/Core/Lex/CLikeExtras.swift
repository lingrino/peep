import Darwin

/// Literal forms of single languages that the generic C-family engine doesn't cover: Ruby and
/// Perl quote-like literals and heredocs, PHP heredocs, Elixir sigils, C# raw strings, Swift
/// regex literals, OCaml/Nix/Zig strings. Each is reached from one rarely taken branch of
/// `CLike.lex` (a specific byte in a specific dialect), so none costs anything elsewhere.
extension CLike {
    private static let quote: UInt8 = 0x22, apos: UInt8 = 0x27, backtick: UInt8 = 0x60
    private static let backslash: UInt8 = 0x5C, newline: UInt8 = 0x0A

    @inline(__always) static func closing(_ o: UInt8) -> UInt8 {
        switch o {
        case 0x28: 0x29
        case 0x5B: 0x5D
        case 0x7B: 0x7D
        case 0x3C: 0x3E
        default: o
        }
    }

    /// A literal from the delimiter at `open` to its closer (bracket pairs nest), as `kind`
    /// from `seg`, with backslash escapes skipped and `interp` holes lexed as code.
    static func delimited(_ s: CLikeSpec, _ p: UnsafePointer<UInt8>, _ open: Int, _ end: Int, _ out: TokenStream,
                          kind: TokenKind, interp: CLikeSpec.Interp, from seg0: Int) -> Int {
        let o = p[open], c = closing(o)
        var depth = 1, seg = seg0, j = open + 1
        let special = interpolationByte(interp, c)
        while j < end {
            let k = findAny(p, j, end, c, o, backslash, special)
            if k >= end { j = end; break }
            let ch = p[k]
            if ch == backslash { j = min(k + 2, end); continue }
            if o != c && ch == o { depth += 1; j = k + 1; continue }
            if ch == c {
                depth -= 1
                j = k + 1
                if depth == 0 { break }
                continue
            }
            if let r = interpolation(s, p, k, end, out, interp, &seg, kind: kind) { j = r; continue }
            j = k + 1
        }
        out.add(seg, j, kind)
        return j
    }

    /// Bytes that can delimit a quote-like literal (`%w[`, `q{`, `m!`, `~r/`).
    @inline(__always) static func isLiteralDelimiter(_ b: UInt8) -> Bool {
        switch b {
        case 0x28, 0x5B, 0x7B, 0x3C, 0x2F, 0x7C, 0x21, 0x22, 0x27, 0x23, 0x5E, 0x7E, 0x25, 0x3A, 0x40, 0x2B: true
        default: false
        }
    }

    // MARK: - Ruby

    /// `%w[a b]`, `%q(..)`, `%Q{..#{x}..}`, `%r{re}i`, `%i[..]`, `%(..)` at `i` (the `%`).
    /// Nil: modulo. `exprStart`: an expression may begin here (so `%(` is a literal).
    static func rubyPercent(_ s: CLikeSpec, _ p: UnsafePointer<UInt8>, _ i: Int, _ end: Int, _ out: TokenStream,
                            exprStart: Bool) -> Int? {
        var t = p[i + 1], d = i + 2
        switch t {
        case 0x77, 0x57, 0x71, 0x51, 0x69, 0x49, 0x72, 0x73, 0x78:   // w W q Q i I r s x
            guard isLiteralDelimiter(p[d]) && p[d] != 0x3D else { return nil }
        default:
            guard exprStart, t == 0x28 || t == 0x5B || t == 0x7B || t == 0x3C || t == 0x7C || t == 0x21 else { return nil }
            t = 0x51; d = i + 1   // %(...) is %Q(...)
        }
        let interp: CLikeSpec.Interp = (t == 0x51 || t == 0x57 || t == 0x49 || t == 0x72 || t == 0x78) ? .hashBrace : .none
        let kind: TokenKind = t == 0x72 ? .regex : (t == 0x73 || t == 0x69 || t == 0x49) ? .constant : .string
        var j = delimited(s, p, d, end, out, kind: kind, interp: interp, from: i)
        if t == 0x72 {   // regex flags
            let f = j
            while j < end && p[j] >= 0x61 && p[j] <= 0x7A { j += 1 }
            out.add(f, j, .regex)
        }
        return j
    }

    // MARK: - Heredocs (Ruby, Perl, PHP)

    /// A heredoc opener at `i` (`<<~ID`, `<<-'ID'`, `<<"ID"`, `<<<ID`). The rest of its line
    /// is lexed as code, then the body (interpolated unless the tag is single-quoted) up to
    /// the terminator line. Returns the end of the terminator line; nil if it isn't one.
    static func heredoc(_ s: CLikeSpec, _ p: UnsafePointer<UInt8>, _ i: Int, _ end: Int, _ out: TokenStream) -> Int? {
        var k = i + 2
        let php = s.dialect == .php
        if php { guard p[k] == 0x3C else { return nil }; k += 1; while p[k] == 0x20 { k += 1 } }
        var indented = php   // PHP 7.3+: the terminator may be indented
        if !php && (p[k] == 0x7E || p[k] == 0x2D) { indented = true; k += 1 }
        var q: UInt8 = 0
        if p[k] == quote || p[k] == apos || (p[k] == backtick && s.dialect == .ruby) { q = p[k]; k += 1 }
        let id = k
        while k < end && isIdentByte(p[k]) { k += 1 }
        let idLen = k - id
        guard idLen > 0 && (q == 0 || p[k] == q) else { return nil }
        // A bare `<<ID` (no `~`/`-`/quote) must look like a tag, not a shift: `x << y`, `a <<b`.
        if q == 0 && !indented && !php && !(p[id] >= 0x41 && p[id] <= 0x5A) { return nil }
        if q != 0 { k += 1 }
        out.add(i, k, .string)
        let le = lineEnd(p, k, end)
        if le > k && out.nesting < TokenStream.maxNesting {   // `<<~SQL.strip + x` / `print <<EOF;`
            out.nesting &+= 1   // (another heredoc on the line nests: `<<A <<B ...`)
            lex(s, p, k, le, out)
            out.nesting &-= 1
        }
        var ls = min(le + 1, end)
        let interp: CLikeSpec.Interp = q == apos ? .none : s.interpolation
        let special = interpolationByte(interp, newline)
        var seg = ls
        while ls < end {
            let e = lineEnd(p, ls, end)
            var a = ls
            if indented { while a < e && (p[a] == 0x20 || p[a] == 0x09) { a += 1 } }
            if e - a >= idLen && memcmp(p + a, p + id, idLen) == 0
                && (a + idLen == e || (php && !isIdentByte(p[a + idLen])) || p[a + idLen] == 0x0D) {
                out.add(seg, a + idLen, .string)
                return php ? a + idLen : e   // PHP: `ID;` — the `;` is code
            }
            // Interpolation holes in this line.
            if special != newline {
                var j = ls
                while j < e {
                    let h = findAny(p, j, e, special, backslash, special, special)
                    if h >= e { break }
                    if p[h] == backslash { j = h + 2; continue }
                    if let r = interpolation(s, p, h, end, out, interp, &seg) { j = r } else { j = h + 1 }
                }
            }
            ls = e + 1
        }
        out.add(seg, end, .string)
        return end
    }

    /// `=begin`...`=end` (Ruby) or POD `=head1`...`=cut` (Perl) at a line start `i`: a comment
    /// through the closing line. Nil if `i` doesn't start one.
    static func blockDoc(_ p: UnsafePointer<UInt8>, _ i: Int, _ end: Int, ruby: Bool) -> Int? {
        guard (p[i + 1] >= 0x61 && p[i + 1] <= 0x7A) else { return nil }
        if ruby && !(p[i + 1] == 0x62 && p[i + 2] == 0x65 && p[i + 3] == 0x67 && p[i + 4] == 0x69 && p[i + 5] == 0x6E) { return nil }
        var ls = lineEnd(p, i, end) + 1
        while ls < end {
            let e = lineEnd(p, ls, end)
            if p[ls] == 0x3D && (ruby ? (p[ls + 1] == 0x65 && p[ls + 2] == 0x6E && p[ls + 3] == 0x64)
                                      : (p[ls + 1] == 0x63 && p[ls + 2] == 0x75 && p[ls + 3] == 0x74)) {
                return e
            }
            ls = e + 1
        }
        return end
    }

    // MARK: - Perl

    /// Perl quote-like operators: `q{}`, `qq//`, `qw()`, `qr//`, `m{}`, `s{}{}`, `tr///`, `y///`.
    /// `st..<i` is the word, `p[i]` its delimiter. Nil if the word isn't one of them.
    static func perlQuoteLike(_ s: CLikeSpec, _ p: UnsafePointer<UInt8>, _ st: Int, _ i: Int, _ end: Int,
                              _ out: TokenStream) -> Int? {
        let len = i - st, a = p[st], b = len == 2 ? p[st + 1] : 0
        let d = p[i]
        guard isLiteralDelimiter(d) && d != 0x3A && d != 0x2B else { return nil }   // `s::f`, `y+1`?
        enum Op { case q, qq, qw, regex, subst }
        let op: Op
        switch (len, a, b) {
        case (1, 0x71, _): op = .q
        case (2, 0x71, 0x71): op = .qq
        case (2, 0x71, 0x77): op = .qw
        case (2, 0x71, 0x72), (1, 0x6D, _): op = .regex
        case (1, 0x73, _), (2, 0x74, 0x72), (1, 0x79, _): op = .subst
        default: return nil
        }
        if d == 0x23 && p[i - 1] == 0x20 { return nil }   // `q #` would be a comment
        let interp: CLikeSpec.Interp = op == .q || op == .qw ? .none : .dollarBrace
        let kind: TokenKind = op == .regex || op == .subst ? .regex : .string
        var j = delimited(s, p, i, end, out, kind: kind, interp: interp, from: st)
        if op == .subst {
            // Second part: right after (same delimiter) or a new bracket pair `s{a}{b}`.
            if closing(d) == d {
                j = delimited(s, p, j - 1, end, out, kind: kind, interp: interp, from: j)
            } else {
                var k = j
                while k < end && (p[k] == 0x20 || p[k] == 0x09 || p[k] == newline) { k += 1 }
                if k < end && isLiteralDelimiter(p[k]) { j = delimited(s, p, k, end, out, kind: kind, interp: interp, from: j) }
            }
        }
        if kind == .regex {
            let f = j
            while j < end && p[j] >= 0x61 && p[j] <= 0x7A { j += 1 }
            out.add(f, j, .regex)
        }
        return j
    }

    // MARK: - Elixir

    /// Sigils: `~r/re/i`, `~s(text)`, `~w[a b]a`, `~S"""..."""`. `i` at the `~`.
    static func elixirSigil(_ s: CLikeSpec, _ p: UnsafePointer<UInt8>, _ i: Int, _ end: Int, _ out: TokenStream) -> Int? {
        var k = i + 1
        guard (p[k] >= 0x61 && p[k] <= 0x7A) || (p[k] >= 0x41 && p[k] <= 0x5A) else { return nil }
        let letter = p[k]
        while k < end && ((p[k] >= 0x41 && p[k] <= 0x5A) || (p[k] >= 0x61 && p[k] <= 0x7A && k == i + 1)) { k += 1 }
        let d = p[k]
        guard d == 0x2F || d == 0x7C || d == quote || d == apos || d == 0x28 || d == 0x5B || d == 0x7B || d == 0x3C else { return nil }
        let lower = letter >= 0x61
        let kind: TokenKind = letter | 0x20 == 0x72 ? .regex : .string
        var j: Int
        if (d == quote || d == apos) && p[k + 1] == d && p[k + 2] == d {
            out.add(i, k, kind)
            j = tripleString(s, p, k, end, out, d, interp: lower ? .hashBrace : .none, escapes: lower)
        } else {
            j = delimited(s, p, k, end, out, kind: kind, interp: lower ? .hashBrace : .none, from: i)
        }
        let f = j
        while j < end && ((p[j] >= 0x61 && p[j] <= 0x7A) || (p[j] >= 0x41 && p[j] <= 0x5A)) { j += 1 }   // modifiers
        out.add(f, j, kind)
        return j
    }

    // MARK: - C#, Swift, OCaml, Nix, Zig, Erlang

    /// C# raw string literal from `i` (the first of 3+ quotes) to a run of at least as many.
    static func csharpRaw(_ p: UnsafePointer<UInt8>, _ i: Int, _ end: Int) -> Int {
        var n = 0
        while i + n < end && p[i + n] == quote { n += 1 }
        var j = i + n
        while j < end {
            let k = findAny(p, j, end, quote, quote, quote, quote)
            if k >= end { return end }
            var r = 0
            while k + r < end && p[k + r] == quote { r += 1 }
            if r >= n { return k + r }
            j = k + r
        }
        return end
    }

    /// Swift `#/regex/#`, `##/.../##` (extended, may span lines). `i` at the first `#`.
    static func swiftRegex(_ p: UnsafePointer<UInt8>, _ i: Int, _ end: Int) -> Int? {
        var h = i
        while h < end && p[h] == 0x23 && h - i < maxDelimiterRun { h += 1 }
        guard h < end, p[h] == 0x2F else { return nil }
        let hashes = h - i
        var j = h + 1
        while j < end {
            let k = findAny(p, j, end, 0x2F, backslash, 0x2F, 0x2F)
            if k >= end { return end }
            if p[k] == backslash { j = k + 2; continue }
            var n = 0
            while n < hashes && p[k + 1 + n] == 0x23 { n += 1 }
            if n == hashes { return k + 1 + hashes }
            j = k + 1
        }
        return end
    }

    /// OCaml quoted strings `{|...|}` and `{id|...|id}`. `i` at the `{`.
    static func ocamlQuoted(_ p: UnsafePointer<UInt8>, _ i: Int, _ end: Int) -> Int? {
        var k = i + 1
        while k < end && ((p[k] >= 0x61 && p[k] <= 0x7A) || p[k] == 0x5F) { k += 1 }
        guard k < end, p[k] == 0x7C else { return nil }
        let id = i + 1, idLen = k - id
        var j = k + 1
        while j < end {
            let b = findAny(p, j, end, 0x7C, 0x7C, 0x7C, 0x7C)
            if b >= end { return end }
            if p[b + 1 + idLen] == 0x7D && memcmp(p + b + 1, p + id, idLen) == 0 { return b + 2 + idLen }
            j = b + 1
        }
        return end
    }

    /// Nix indented strings `''...''` (`'''` and `''$` escape) with `${}` holes. `i` at `''`.
    static func nixIndented(_ s: CLikeSpec, _ p: UnsafePointer<UInt8>, _ i: Int, _ end: Int, _ out: TokenStream) -> Int {
        var seg = i, j = i + 2
        while j < end {
            let k = findAny(p, j, end, apos, 0x24, apos, apos)
            if k >= end { j = end; break }
            if p[k] == apos {
                if p[k + 1] == apos {
                    if p[k + 2] == apos || p[k + 2] == 0x24 || p[k + 2] == backslash { j = k + 3; continue }   // escapes
                    j = k + 2
                    break
                }
                j = k + 1
                continue
            }
            if let r = interpolation(s, p, k, end, out, .dollarBrace, &seg) { j = r } else { j = k + 1 }
        }
        out.add(seg, j, .string)
        return j
    }

    // MARK: - Embedded languages in JS/TS tagged templates

    /// The language of a tagged template: css`..`, styled.div`..`, html`..`, sql`..`, gql`..`.
    static func taggedLanguage(_ p: UnsafePointer<UInt8>, _ st: Int, _ i: Int, prev: UInt8) -> Language? {
        let n = i - st
        @inline(__always) func word(_ w: StaticString) -> Bool {
            n == w.utf8CodeUnitCount && memcmp(p + st, w.utf8Start, n) == 0
        }
        if prev == 0x2E {   // styled.div`...`
            var a = st - 1
            while a > 0 && isIdentByte(p[a - 1]) { a -= 1 }
            return st - 1 - a == 6 && memcmp(p + a, "styled", 6) == 0 ? .css : nil
        }
        if word("css") || word("keyframes") || word("createGlobalStyle") || word("injectGlobal") { return .css }
        if word("html") || word("svg") { return .html }
        if word("sql") { return .sql }
        if word("gql") || word("graphql") { return .graphql }
        return nil
    }

    /// A template literal at `i` (the backtick) whose text is `lang`, with `${}` holes in JS.
    static func embeddedTemplate(_ s: CLikeSpec, _ p: UnsafePointer<UInt8>, _ i: Int, _ end: Int, _ out: TokenStream,
                                 _ lang: Language) -> Int {
        // Too deep (html`<script>` holds JS again): a plain template string, whose holes stay text.
        if out.nesting >= TokenStream.maxNesting {
            return string(s, p, i, end, out, backtick, multiline: true, escapes: true, interp: .dollarBrace)
        }
        // CSS-in-JS bodies are declaration lists with nesting: SCSS inside a block.
        @inline(__always) func text(_ a: Int, _ b: Int) {
            if b <= a { return }
            out.nesting &+= 1
            if lang == .css { CSSLexer.lex(p, a, b, out, dialect: .scss, depth: 1); out.finish(b) } else { lang.lex(p, a, b, out) }
            out.nesting &-= 1
        }
        out.add(i, i + 1, .string)
        var seg = i + 1, j = i + 1
        while j < end {
            let k = findAny(p, j, end, backtick, 0x24, backslash, backtick)
            if k >= end { break }
            if p[k] == backslash { j = k + 2; continue }
            if p[k] == 0x24 {
                guard p[k + 1] == 0x7B else { j = k + 1; continue }
                text(seg, k)
                out.add(k, k + 2, .escape)
                out.nesting &+= 1
                let r = lex(s, p, k + 2, end, out, closer: 0x7D)
                out.nesting &-= 1
                let after = min(r + 1, end)
                out.add(r, after, .escape)
                seg = after; j = after
                continue
            }
            text(seg, k)
            out.add(k, k + 1, .string)
            return k + 1
        }
        text(seg, end)
        return end
    }
}
