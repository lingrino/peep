// Hand-written lexers for formats that are not C-family code. Each takes the padded text
// pointer and a byte range, and reports interesting spans to a TokenStream.

private let quote: UInt8 = 0x22, apos: UInt8 = 0x27, nl: UInt8 = 0x0A, backslash: UInt8 = 0x5C
private let cc = ByteClass.standard

@inline(__always) private func isSpaceTab(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 }

@inline(__always)
private func skipSpaces(_ p: UnsafePointer<UInt8>, _ i: Int, _ end: Int) -> Int {
    var j = i
    while j < end && isSpaceTab(p[j]) { j &+= 1 }
    return j
}

/// Simple quoted string with backslash escapes (escapes colored), single line unless `multiline`.
/// With `out == nil` it only scans (lookahead) and reports nothing.
@inline(__always)
private func quoted(_ p: UnsafePointer<UInt8>, _ i: Int, _ end: Int, _ out: TokenStream?, _ kind: TokenKind,
                    escapes: Bool = true, multiline: Bool = false) -> Int {
    let q = p[i]
    var j = i + 1
    var seg = i
    while true {
        let k = findAny(p, j, end, q, escapes ? backslash : q, nl, q)
        if k >= end { j = end; break }
        if p[k] == q { j = k + 1; break }
        if p[k] == nl { if multiline { j = k + 1; continue }; j = k; break }
        out?.add(seg, k, kind)
        let e = min(k + 2, end)
        out?.add(k, e, .escape)
        seg = e; j = e
    }
    out?.add(seg, j, kind)
    return j
}

// MARK: - JSON / JSONC / JSON5

public enum JSONLexer {
    public static func lex(_ p: UnsafePointer<UInt8>, _ start: Int, _ end: Int, _ out: TokenStream) {
        var i = start
        while i < end {
            let b = p[i]
            switch b {
            case quote, apos:
                let s = i
                // Key if the next significant byte after the string is ':'.
                var j = quoted(p, i, end, nil, .string)
                var k = j
                while k < end && cc.isSpace(p[k]) { k &+= 1 }
                j = quoted(p, s, end, out, k < end && p[k] == 0x3A ? .property : .string)
                i = j
            case 0x2F where p[i + 1] == 0x2F:
                let e = lineEnd(p, i, end); out.add(i, e, .comment); i = e
            case 0x2F where p[i + 1] == 0x2A:
                let e = CLike.blockComment(p, i, end, false, 0x2F, 0x2A); out.add(i, e, .comment); i = e
            case 0x2D, 0x30...0x39:
                let j = CLike.number(p, b == 0x2D ? i + 1 : i, end, cc)
                out.add(i, j, .number); i = max(j, i + 1)
            case 0x74, 0x66, 0x6E:   // true false null
                var j = i
                while j < end && cc.isIdent(p[j]) { j &+= 1 }
                let w = j - i
                if (w == 4 && (matches(p, i, end, "true") || matches(p, i, end, "null"))) || (w == 5 && matches(p, i, end, "false")) {
                    out.add(i, j, .constant)
                }
                i = j
            default:
                if cc.isIdentStart(b) {   // JSON5 bare keys / Infinity / NaN
                    var j = i
                    while j < end && cc.isIdent(p[j]) { j &+= 1 }
                    var k = j
                    while k < end && isSpaceTab(p[k]) { k &+= 1 }
                    if k < end && p[k] == 0x3A { out.add(i, j, .property) }
                    i = j
                } else {
                    i &+= 1
                }
            }
        }
    }
}

// MARK: - YAML

public enum YAMLLexer {
    public static func lex(_ p: UnsafePointer<UInt8>, _ start: Int, _ end: Int, _ out: TokenStream) {
        var i = start
        var blockScalarIndent = -1   // >= 0 while inside a | or > block scalar
        while i < end {
            let ls = i
            let le = lineEnd(p, i, end)
            var j = skipSpaces(p, i, le)
            let indent = j - ls
            if blockScalarIndent >= 0 {
                if j == le || indent > blockScalarIndent {
                    out.add(ls, le, .string); i = le + 1; continue
                }
                blockScalarIndent = -1
            }
            if j == le { i = le + 1; continue }
            if j == ls && (matches(p, j, le, "---") || matches(p, j, le, "...")) {
                out.add(j, j + 3, .meta)
                i = le + 1; continue
            }
            // Sequence dashes
            while j < le && p[j] == 0x2D && (j + 1 == le || isSpaceTab(p[j + 1])) { j = skipSpaces(p, j + 1, le) }
            if j < le && p[j] == 0x23 { out.add(j, le, .comment); i = le + 1; continue }
            // key: (plain or quoted)
            var k = j
            if p[k] == quote || p[k] == apos {
                k = quoted(p, k, le, nil, .string)
            } else {
                while k < le && !(p[k] == 0x3A && (k + 1 == le || isSpaceTab(p[k + 1]))) && p[k] != 0x23 { k &+= 1 }
            }
            var v = j
            if k < le && p[k] == 0x3A && (k + 1 == le || isSpaceTab(p[k + 1])) && k > j {
                out.add(j, k, .property)
                v = skipSpaces(p, k + 1, le)
            }
            i = value(p, v, le, out, &blockScalarIndent, indent)
            i = le + 1
        }
    }

    private static func value(_ p: UnsafePointer<UInt8>, _ v: Int, _ le: Int, _ out: TokenStream,
                              _ block: inout Int, _ indent: Int) -> Int {
        var j = v
        while j < le {
            let b = p[j]
            if b == 0x23 && (j == v || isSpaceTab(p[j - 1])) { out.add(j, le, .comment); return le }
            if b == quote || b == apos { j = quoted(p, j, le, out, .string, escapes: b == quote); continue }
            if (b == 0x7C || b == 0x3E) && j == v {   // | or > block scalar
                block = indent
                out.add(j, le, .meta)
                return le
            }
            if b == 0x26 || b == 0x2A {   // &anchor *alias
                var e = j + 1
                while e < le && !cc.isSpace(p[e]) && p[e] != 0x2C && p[e] != 0x5D && p[e] != 0x7D { e &+= 1 }
                out.add(j, e, .variable); j = e; continue
            }
            if b == 0x21 {   // !tag
                var e = j + 1
                while e < le && !cc.isSpace(p[e]) { e &+= 1 }
                out.add(j, e, .type); j = e; continue
            }
            if cc.isSpace(b) || b == 0x2C || b == 0x5B || b == 0x5D || b == 0x7B || b == 0x7D { j &+= 1; continue }
            // Plain scalar up to a flow/comment boundary: classify the whole word.
            var e = j
            while e < le && !(p[e] == 0x23 && isSpaceTab(p[e - 1])) && p[e] != 0x2C && p[e] != 0x5D && p[e] != 0x7D {
                if p[e] == 0x3A && (e + 1 == le || isSpaceTab(p[e + 1])) { break }   // flow mapping key
                e &+= 1
            }
            var we = e
            while we > j && isSpaceTab(p[we - 1]) { we &-= 1 }
            let kind = scalarKind(p, j, we)
            if p[e] == 0x3A && e < le { out.add(j, we, .property) }
            else if kind != .plain { out.add(j, we, kind) }
            j = max(e, j + 1)
        }
        return le
    }

    static func scalarKind(_ p: UnsafePointer<UInt8>, _ s: Int, _ e: Int) -> TokenKind {
        let n = e - s
        if n == 0 { return .plain }
        switch n {
        case 1 where p[s] == 0x7E: return .constant
        case 4 where matches(p, s, e, "true") || matches(p, s, e, "True") || matches(p, s, e, "TRUE")
            || matches(p, s, e, "null") || matches(p, s, e, "Null") || matches(p, s, e, "NULL"): return .constant
        case 5 where matches(p, s, e, "false") || matches(p, s, e, "False") || matches(p, s, e, "FALSE"): return .constant
        case 2 where matches(p, s, e, "on") || matches(p, s, e, "no"): return .constant
        case 3 where matches(p, s, e, "yes") || matches(p, s, e, "off"): return .constant
        default: break
        }
        var k = s
        if p[k] == 0x2D || p[k] == 0x2B { k &+= 1 }
        if k < e && (cc.isDigit(p[k]) || (p[k] == 0x2E && k + 1 < e && cc.isDigit(p[k + 1]))) {
            var ok = true
            for m in k..<e where !(cc.isHex(p[m]) || p[m] == 0x2E || p[m] == 0x5F || p[m] == 0x78 || p[m] == 0x6F
                                   || p[m] == 0x65 || p[m] == 0x45 || p[m] == 0x2B || p[m] == 0x2D || p[m] == 0x3A
                                   || p[m] == 0x54 || p[m] == 0x5A) { ok = false; break }
            if ok { return .number }
        }
        return .plain
    }
}

// MARK: - TOML / INI / properties / .env

public enum ConfigLexer {
    /// `semicolonComments` for INI; `colonSeparator` for .properties.
    public static func lex(_ p: UnsafePointer<UInt8>, _ start: Int, _ end: Int, _ out: TokenStream,
                           semicolonComments: Bool = true) {
        var i = start
        while i < end {
            let le = lineEnd(p, i, end)
            let j = skipSpaces(p, i, le)
            if j == le { i = le + 1; continue }
            let b = p[j]
            if b == 0x23 || (semicolonComments && b == 0x3B) { out.add(j, le, .comment); i = le + 1; continue }
            if b == 0x5B {   // [section] / [[array.table]]
                var e = j
                while e < le && p[e] != 0x5D { e &+= 1 }
                while e < le && p[e] == 0x5D { e &+= 1 }
                out.add(j, e, .heading)
                rest(p, e, le, out)
                i = le + 1; continue
            }
            // key (bare, dotted or quoted) up to = or :
            var k = j
            if b == 0x65 && matches(p, j, le, "export ") { out.add(j, j + 6, .keyword); k = skipSpaces(p, j + 7, le) }
            let ks = k
            while k < le && p[k] != 0x3D && p[k] != 0x3A {
                if p[k] == quote || p[k] == apos { k = quoted(p, k, le, nil, .string); continue }
                k &+= 1
            }
            if k < le {
                var ke = k
                while ke > ks && isSpaceTab(p[ke - 1]) { ke &-= 1 }
                out.add(ks, ke, .property)
                rest(p, k + 1, le, out)
            } else {
                rest(p, j, le, out)
            }
            i = le + 1
        }
    }

    /// Value part: strings, numbers/dates, booleans, inline comments, ${VAR} references.
    static func rest(_ p: UnsafePointer<UInt8>, _ s: Int, _ le: Int, _ out: TokenStream) {
        var j = s
        while j < le {
            let b = p[j]
            if b == 0x23 && (j == s || isSpaceTab(p[j - 1])) { out.add(j, le, .comment); return }
            if b == quote || b == apos {
                if p[j + 1] == b && p[j + 2] == b {   // TOML multi-line strings: color to end of line
                    out.add(j, le, .string); return
                }
                j = quoted(p, j, le, out, .string, escapes: b == quote); continue
            }
            if b == 0x24 && (p[j + 1] == 0x7B || cc.isIdentStart(p[j + 1])) {
                var e = j + 1
                if p[e] == 0x7B { while e < le && p[e] != 0x7D { e &+= 1 }; e = min(e + 1, le) }
                else { while e < le && cc.isIdent(p[e]) { e &+= 1 } }
                out.add(j, e, .variable); j = e; continue
            }
            if cc.isDigit(b) || ((b == 0x2D || b == 0x2B) && cc.isDigit(p[j + 1])) {
                var e = j + 1
                while e < le && (cc.isIdent(p[e]) || p[e] == 0x2E || p[e] == 0x3A || p[e] == 0x2D || p[e] == 0x2B) { e &+= 1 }
                out.add(j, e, .number); j = e; continue
            }
            if cc.isIdentStart(b) {
                var e = j
                while e < le && cc.isIdent(p[e]) { e &+= 1 }
                let w = e - j
                if (w == 4 && matches(p, j, le, "true")) || (w == 5 && matches(p, j, le, "false")) { out.add(j, e, .constant) }
                j = e; continue
            }
            j &+= 1
        }
    }
}

// MARK: - XML / HTML / SVG / plist

public enum MarkupLexer {
    /// `html`: enables <script>/<style> embedding and void-tag leniency.
    public static func lex(_ p: UnsafePointer<UInt8>, _ start: Int, _ end: Int, _ out: TokenStream, html: Bool) {
        var i = start
        while i < end {
            let k = findAny(p, i, end, 0x3C, 0x26, 0x3C, 0x26)   // < &
            if k >= end { break }
            if p[k] == 0x26 {   // entity
                var e = k + 1
                while e < end && e < k + 12 && (cc.isIdent(p[e]) || p[e] == 0x23) { e &+= 1 }
                if e < end && p[e] == 0x3B { out.add(k, e + 1, .escape); i = e + 1 } else { i = k + 1 }
                continue
            }
            if matches(p, k, end, "<!--") {
                let e = find(p, k + 4, end, "-->")
                out.add(k, e, .comment); i = e; continue
            }
            if matches(p, k, end, "<![CDATA[") {
                let e = find(p, k + 9, end, "]]>")
                out.add(k, e, .string); i = e; continue
            }
            if p[k + 1] == 0x21 || p[k + 1] == 0x3F {   // <!DOCTYPE ...> <?xml ...?>
                let e = findAny(p, k, end, 0x3E, 0x3E, 0x3E, 0x3E)
                let stop = min(e + 1, end)
                out.add(k, stop, .meta); i = stop; continue
            }
            let closing = p[k + 1] == 0x2F
            let ns = k + (closing ? 2 : 1)
            if !(cc.isIdentStart(p[ns])) { i = k + 1; continue }
            var ne = ns
            while ne < end && (cc.isIdent(p[ne]) || p[ne] == 0x2D || p[ne] == 0x3A || p[ne] == 0x2E) { ne &+= 1 }
            out.add(ns, ne, .tag)
            // Attributes until '>'
            var j = ne
            while j < end && p[j] != 0x3E {
                let b = p[j]
                if b == quote || b == apos {
                    let q = b
                    let e = findAny(p, j + 1, end, q, q, q, q)
                    let stop = min(e + 1, end)
                    out.add(j, stop, .string); j = stop; continue
                }
                if cc.isIdentStart(b) || b == 0x40 || b == 0x3A {
                    var e = j + 1
                    while e < end && (cc.isIdent(p[e]) || p[e] == 0x2D || p[e] == 0x3A || p[e] == 0x2E) { e &+= 1 }
                    out.add(j, e, .attrName); j = e; continue
                }
                j &+= 1
            }
            i = min(j + 1, end)
            if html && !closing && p[i - 2] != 0x2F {
                let name = ne - ns
                if name == 6 && matchesCI(p, ns, "script") {
                    let close = findCI(p, i, end, "</script")
                    // Vue/Svelte `<script lang="ts">`, JSON data blocks, else JavaScript.
                    if attribute(p, ne, j, "lang", startsWith: "ts") || attribute(p, ne, j, "lang", startsWith: "typescript") {
                        CLike.lex(Specs.typescript, p, i, close, out)
                    } else if attribute(p, ne, j, "type", contains: "json") || attribute(p, ne, j, "type", startsWith: "importmap") {
                        JSONLexer.lex(p, i, close, out)
                    } else {
                        CLike.lex(Specs.javascript, p, i, close, out)
                    }
                    i = close
                } else if name == 5 && matchesCI(p, ns, "style") {
                    let close = findCI(p, i, end, "</style")
                    let dialect: CSSLexer.Dialect = attribute(p, ne, j, "lang", startsWith: "scss") || attribute(p, ne, j, "lang", startsWith: "sass") ? .scss
                        : attribute(p, ne, j, "lang", startsWith: "less") ? .less : .css
                    CSSLexer.lex(p, i, close, out, dialect: dialect)
                    i = close
                }
            }
        }
    }

    /// The tag's attribute `name` (in `[from, to)`) has a quoted value starting with (or
    /// containing) `value`, ASCII case-insensitively.
    static func attribute(_ p: UnsafePointer<UInt8>, _ from: Int, _ to: Int, _ name: StaticString,
                          startsWith value: StaticString? = nil, contains part: StaticString? = nil) -> Bool {
        let n = name.utf8CodeUnitCount
        var k = from
        while k + n < to {
            if matchesCI(p, k, name) && !cc.isIdent(p[k - 1]) && p[k + n] == 0x3D && (p[k + n + 1] == quote || p[k + n + 1] == apos) {
                let q = p[k + n + 1], v = k + n + 2
                var e = v
                while e < to && p[e] != q { e += 1 }
                if let value {
                    let m = value.utf8CodeUnitCount
                    if e - v >= m && matchesCI(p, v, value) && (e - v == m || !cc.isIdent(p[v + m])) { return true }
                }
                if let part {
                    let m = part.utf8CodeUnitCount
                    var a = v
                    while a + m <= e { if matchesCI(p, a, part) { return true }; a += 1 }
                }
                return false
            }
            k += 1
        }
        return false
    }
}

// MARK: - PHP

/// PHP files are HTML with `<?php ... ?>` / `<?= ... ?>` code; a file (or a Markdown snippet)
/// without any `<?` is all code.
public enum PHPLexer {
    public static func lex(_ p: UnsafePointer<UInt8>, _ start: Int, _ end: Int, _ out: TokenStream) {
        var i = start
        var first = true
        while i < end {
            guard let open = pair(p, i, end, 0x3C, 0x3F) else {   // `<?`
                if first { CLike.lex(Specs.php, p, i, end, out) } else { MarkupLexer.lex(p, i, end, out, html: true) }
                return
            }
            first = false
            if open > i { MarkupLexer.lex(p, i, open, out, html: true) }
            var code = open + 2
            if MarkupLexer.matchesCI(p, code, "php") { code += 3 } else if p[code] == 0x3D { code += 1 }
            out.add(open, code, .meta)
            let codeEnd = pair(p, code, end, 0x3F, 0x3E) ?? end   // `?>`
            CLike.lex(Specs.php, p, code, codeEnd, out)
            if codeEnd < end { out.add(codeEnd, codeEnd + 2, .meta) }
            i = min(codeEnd + 2, end)
        }
    }

    /// Index of the two-byte sequence `a b` in `[i, end)`.
    static func pair(_ p: UnsafePointer<UInt8>, _ i: Int, _ end: Int, _ a: UInt8, _ b: UInt8) -> Int? {
        var j = i
        while j < end {
            let k = findAny(p, j, end, a, a, a, a)
            if k + 1 >= end { return nil }
            if p[k + 1] == b { return k }
            j = k + 1
        }
        return nil
    }
}

extension MarkupLexer {

    /// Index just past `needle` (or `end`).
    static func find(_ p: UnsafePointer<UInt8>, _ i: Int, _ end: Int, _ needle: StaticString) -> Int {
        let first = needle.utf8Start[0]
        var j = i
        while j < end {
            let k = findAny(p, j, end, first, first, first, first)
            if k >= end { return end }
            if matches(p, k, end, needle) { return k + needle.utf8CodeUnitCount }
            j = k + 1
        }
        return end
    }

    /// Index of the start of `needle` (case-insensitive ASCII), or `end`.
    static func findCI(_ p: UnsafePointer<UInt8>, _ i: Int, _ end: Int, _ needle: StaticString) -> Int {
        var j = i
        while j < end {
            let k = findAny(p, j, end, 0x3C, 0x3C, 0x3C, 0x3C)
            if k >= end { return end }
            if matchesCI(p, k, needle) { return k }
            j = k + 1
        }
        return end
    }

    @inline(__always)
    static func matchesCI(_ p: UnsafePointer<UInt8>, _ i: Int, _ s: StaticString) -> Bool {
        let q = s.utf8Start
        for k in 0..<s.utf8CodeUnitCount where (p[i + k] | 0x20) != (q[k] | 0x20) { return false }
        return true
    }
}

// MARK: - CSS / SCSS / Less

public enum CSSLexer {
    public enum Dialect { case css, scss, less }

    /// `depth` 1: the text is a declaration list, as in a block (CSS-in-JS templates).
    public static func lex(_ p: UnsafePointer<UInt8>, _ start: Int, _ end: Int, _ out: TokenStream, dialect: Dialect, depth startDepth: Int = 0) {
        var i = start
        var depth = startDepth
        var inValue = false   // after "prop:" until ';' or '}'
        while i < end {
            let b = p[i]
            switch b {
            case 0x2F where p[i + 1] == 0x2A:
                let e = CLike.blockComment(p, i, end, false, 0x2F, 0x2A); out.add(i, e, .comment); i = e
            case 0x2F where p[i + 1] == 0x2F && dialect != .css:
                let e = lineEnd(p, i, end); out.add(i, e, .comment); i = e
            case quote, apos:
                i = quoted(p, i, end, out, .string)
            case 0x7B: depth &+= 1; inValue = false; i &+= 1
            case 0x7D: depth = max(0, depth - 1); inValue = false; i &+= 1
            case 0x3B: inValue = false; i &+= 1
            case 0x40:   // @media / @include / less @var
                var e = i + 1
                while e < end && (cc.isIdent(p[e]) || p[e] == 0x2D) { e &+= 1 }
                out.add(i, e, dialect == .less && p[skipSpaces(p, e, end)] == 0x3A ? .variable : .keyword)
                i = e
            case 0x24 where dialect == .scss:
                var e = i + 1
                while e < end && (cc.isIdent(p[e]) || p[e] == 0x2D) { e &+= 1 }
                out.add(i, e, .variable); i = e
            case 0x21:   // !important
                var e = i + 1
                while e < end && cc.isIdent(p[e]) { e &+= 1 }
                out.add(i, e, .keyword); i = e
            case 0x23 where inValue:   // #fff color
                var e = i + 1
                while e < end && cc.isHex(p[e]) { e &+= 1 }
                out.add(i, e, .number); i = e
            case 0x2E, 0x23:   // .class / #id selectors (outside values)
                if inValue && b == 0x2E && cc.isDigit(p[i + 1]) {
                    let e = unit(p, i, end); out.add(i, e, .number); i = e
                } else if cc.isIdentStart(p[i + 1]) || p[i + 1] == 0x2D {
                    var e = i + 1
                    while e < end && (cc.isIdent(p[e]) || p[e] == 0x2D) { e &+= 1 }
                    out.add(i, e, inValue ? .plain : .type); i = e
                } else { i &+= 1 }
            case 0x30...0x39:
                let e = unit(p, i, end); out.add(i, e, .number); i = e
            default:
                if cc.isIdentStart(b) || (b == 0x2D && (cc.isIdentStart(p[i + 1]) || p[i + 1] == 0x2D)) {
                    var e = i + 1
                    while e < end && (cc.isIdent(p[e]) || p[e] == 0x2D) { e &+= 1 }
                    let after = skipSpaces(p, e, end)
                    if inValue {
                        out.add(i, e, p[e] == 0x28 ? .function : .constant)
                    } else if p[after] == 0x3A && depth > 0 && !isPseudo(p, after, end) {
                        out.add(i, e, .property)
                        inValue = true
                    } else if p[e] == 0x28 {
                        out.add(i, e, .function)
                    } else {
                        out.add(i, e, .tag)
                    }
                    i = e
                } else if b == 0x3A && !inValue {   // :hover ::before
                    var e = i + 1
                    if p[e] == 0x3A { e &+= 1 }
                    while e < end && (cc.isIdent(p[e]) || p[e] == 0x2D) { e &+= 1 }
                    out.add(i, e, .attribute); i = e
                } else {
                    i &+= 1
                }
            }
        }
    }

    /// `prop: value` vs `a:hover` inside nested SCSS: a pseudo-class colon is followed by an
    /// identifier and eventually '{' before any ';'.
    static func isPseudo(_ p: UnsafePointer<UInt8>, _ colon: Int, _ end: Int) -> Bool {
        if !cc.isIdentStart(p[colon + 1]) && p[colon + 1] != 0x3A { return false }
        let k = findAny(p, colon, end, 0x7B, 0x3B, 0x7D, nl)
        return k < end && p[k] == 0x7B
    }

    static func unit(_ p: UnsafePointer<UInt8>, _ i: Int, _ end: Int) -> Int {
        var e = i
        while e < end && (cc.isDigit(p[e]) || p[e] == 0x2E) { e &+= 1 }
        while e < end && (cc[p[e]] & (ByteClass.lower | ByteClass.upper) != 0 || p[e] == 0x25) { e &+= 1 }
        return e
    }
}

// MARK: - Shell (sh, bash, zsh, fish)

public enum ShellLexer {
    static let keywords = KeywordTable([
        (TokenKind.keyword.rawValue, "if then else elif fi for while until do done case esac in select return break continue exit export local readonly declare typeset unset shift source alias set trap eval exec time coproc end begin switch not and or"),
        (TokenKind.keyword.rawValue | KeywordTable.Hint.declaresFunction, "function"),
        (TokenKind.builtin.rawValue, "echo printf cd pwd read test true false kill wait sudo"),
    ])
    static let chars = ByteClass(extraIdent: "-")

    public static func lex(_ p: UnsafePointer<UInt8>, _ start: Int, _ end: Int, _ out: TokenStream) {
        var i = start
        var cmdStart = true
        var hint: UInt8 = 0
        while i < end {
            let b = p[i]
            switch b {
            case nl, 0x3B, 0x7C, 0x26, 0x28, 0x60:   // command separators
                if b == nl || b == 0x3B || b == 0x7C || b == 0x26 { cmdStart = true }
                i &+= 1
            case 0x20, 0x09, 0x0D: i &+= 1
            case 0x23 where i == start || cc.isSpace(p[i - 1]) || p[i - 1] == 0x3B:
                let e = lineEnd(p, i, end); out.add(i, e, .comment); i = e
            case apos:
                let e = findAny(p, i + 1, end, apos, apos, apos, apos)
                let stop = min(e + 1, end)
                out.add(i, stop, .string); i = stop; cmdStart = false
            case quote:
                i = dquoted(p, i, end, out); cmdStart = false
            case 0x24:
                i = dollar(p, i, end, out); cmdStart = false
            case 0x3C where p[i + 1] == 0x3C && p[i + 2] != 0x3C:   // heredoc
                i = heredoc(p, i, end, out)
            default:
                if chars.isIdentStart(b) || b == 0x2E || b == 0x2F || b == 0x7E {
                    var e = i
                    while e < end && !cc.isSpace(p[e]) && p[e] != 0x3B && p[e] != 0x7C && p[e] != 0x26 && p[e] != 0x29
                            && p[e] != 0x28 && p[e] != quote && p[e] != apos && p[e] != 0x24 && p[e] != 0x3D && p[e] != 0x60 { e &+= 1 }
                    let kw = ShellLexer.keywords.lookup(p + i, e - i)
                    if p[e] == 0x3D && cmdStart {
                        out.add(i, e, .variable)             // NAME=value
                    } else if kw != 0 && (cmdStart || kw & KeywordTable.Hint.kindMask == TokenKind.keyword.rawValue) {
                        out.add(i, e, TokenKind(rawValue: kw & KeywordTable.Hint.kindMask) ?? .keyword)
                        hint = kw & ~KeywordTable.Hint.kindMask
                        i = e
                        continue   // keywords keep cmdStart (if/then/do are followed by commands)
                    } else if hint != 0 || (p[skipSpaces(p, e, end)] == 0x28 && p[skipSpaces(p, e, end) + 1] == 0x29) {
                        out.add(i, e, .function)
                    } else if cmdStart {
                        out.add(i, e, .function)              // command name
                    } else if b == 0x2D {
                        out.add(i, e, .attribute)             // -flags
                    }
                    hint = 0
                    cmdStart = false
                    i = max(e, i + 1)
                } else if cc.isDigit(b) {
                    var e = i
                    while e < end && cc.isDigit(p[e]) { e &+= 1 }
                    if e == end || cc.isSpace(p[e]) || p[e] == 0x3E || p[e] == 0x3B { out.add(i, e, .number) }
                    i = max(e, i + 1); cmdStart = false
                } else {
                    i &+= 1
                }
            }
        }
    }

    static func dquoted(_ p: UnsafePointer<UInt8>, _ i: Int, _ end: Int, _ out: TokenStream) -> Int {
        var seg = i
        var j = i + 1
        while j < end {
            let k = findAny(p, j, end, quote, backslash, 0x24, 0x60)
            if k >= end { j = end; break }
            switch p[k] {
            case quote:
                out.add(seg, k + 1, .string); return k + 1
            case backslash:
                out.add(seg, k, .string); let e = min(k + 2, end); out.add(k, e, .escape); seg = e; j = e
            case 0x24:
                out.add(seg, k, .string); let e = dollar(p, k, end, out); seg = e; j = e
            default:   // `cmd`
                let e = findAny(p, k + 1, end, 0x60, 0x60, 0x60, 0x60)
                out.add(seg, k, .string); out.add(k, min(e + 1, end), .escape); seg = min(e + 1, end); j = seg
            }
        }
        out.add(seg, j, .string)
        return j
    }

    static func dollar(_ p: UnsafePointer<UInt8>, _ i: Int, _ end: Int, _ out: TokenStream) -> Int {
        let n = p[i + 1]
        if n == 0x7B {
            let e = CLike.matchBracket(p, i + 1, end, 0x7B, 0x7D)
            out.add(i, e, .variable); return e
        }
        if n == 0x28 {   // $( command ) / $(( arithmetic ))
            out.add(i, i + 2, .escape)
            let close = CLike.matchBracket(p, i + 1, end, 0x28, 0x29)
            lex(p, i + 2, max(i + 2, close - 1), out)
            out.add(close - 1, close, .escape)
            return close
        }
        if cc.isIdent(n) || n == 0x40 || n == 0x23 || n == 0x3F || n == 0x2A || n == 0x21 || n == 0x24 || n == 0x2D {
            var e = i + 2
            if cc.isIdent(n) { while e < end && cc.isIdent(p[e]) { e &+= 1 } }
            out.add(i, e, .variable); return e
        }
        return i + 1
    }

    static func heredoc(_ p: UnsafePointer<UInt8>, _ i: Int, _ end: Int, _ out: TokenStream) -> Int {
        var j = i + 2
        if p[j] == 0x2D || p[j] == 0x7E { j &+= 1 }
        j = skipSpaces(p, j, end)
        let q = p[j]
        let quotedTag = q == apos || q == quote
        if quotedTag { j &+= 1 }
        let ts = j
        while j < end && (cc.isIdent(p[j])) { j &+= 1 }
        let tag = j - ts
        if tag == 0 { return i + 2 }
        if quotedTag && j < end { j &+= 1 }
        out.add(i, j, .meta)
        // The rest of the opening line is commands: `cat <<EOF | grep x > out`.
        let first = lineEnd(p, j, end)
        if first > j { lex(p, j, first, out) }
        // Body: from next line until a line that is exactly the tag (leading tabs allowed).
        // An unquoted tag expands `$var`, `${...}`, `$(...)` and backticks in the body.
        var ls = first + 1
        var seg = ls
        while ls < end {
            let le = lineEnd(p, ls, end)
            var s = ls
            while s < le && p[s] == 0x09 { s &+= 1 }
            if le - s == tag && memcmp(p + s, p + ts, tag) == 0 {
                out.add(seg, ls, .string)
                out.add(s, le, .meta)
                return le
            }
            var k = ls
            while !quotedTag && k < le {
                let d = findAny(p, k, le, 0x24, backslash, 0x60, 0x24)
                if d >= le { break }
                if p[d] == backslash { k = d + 2; continue }
                if p[d] == 0x60 {
                    let e = min(findAny(p, d + 1, le, 0x60, 0x60, 0x60, 0x60) + 1, le)
                    out.add(seg, d, .string); out.add(d, e, .escape); seg = e; k = e
                    continue
                }
                out.add(seg, d, .string)
                let e = dollar(p, d, end, out)
                if e > d + 1 { seg = e }
                k = max(e, d + 1)
            }
            ls = le + 1
        }
        out.add(seg, end, .string)
        return end
    }
}

// MARK: - Diff / patch

public enum DiffLexer {
    public static func lex(_ p: UnsafePointer<UInt8>, _ start: Int, _ end: Int, _ out: TokenStream) {
        var i = start
        while i < end {
            let le = lineEnd(p, i, end)
            let b = p[i]
            if matches(p, i, le, "+++") || matches(p, i, le, "---") || matches(p, i, le, "diff ")
                || matches(p, i, le, "index ") || matches(p, i, le, "@@") || matches(p, i, le, "new file")
                || matches(p, i, le, "deleted file") || matches(p, i, le, "similarity") || matches(p, i, le, "rename ") {
                out.add(i, le, .meta)
            } else if b == 0x2B || b == 0x3E {
                out.add(i, le, .inserted)
            } else if b == 0x2D || b == 0x3C {
                out.add(i, le, .deleted)
            } else if b == 0x21 {
                out.add(i, le, .constant)
            }
            i = le + 1
        }
    }
}

// MARK: - Makefile

public enum MakefileLexer {
    static let directives = KeywordTable([(TokenKind.keyword.rawValue, "include -include sinclude ifeq ifneq ifdef ifndef else endif define endef export unexport override vpath private undefine")])

    public static func lex(_ p: UnsafePointer<UInt8>, _ start: Int, _ end: Int, _ out: TokenStream) {
        var i = start
        while i < end {
            let le = lineEnd(p, i, end)
            if p[i] == 0x09 {   // recipe line: shell
                var s = i + 1
                if p[s] == 0x40 || p[s] == 0x2D { s &+= 1 }
                vars(p, i, le, out, shell: true)
                i = le + 1; continue
            }
            let j = skipSpaces(p, i, le)
            if j < le && p[j] == 0x23 { out.add(j, le, .comment); i = le + 1; continue }
            var e = j
            while e < le && (cc.isIdent(p[e]) || p[e] == 0x2D || p[e] == 0x2E || p[e] == 0x2F || p[e] == 0x25) { e &+= 1 }
            if directives.lookup(p + j, e - j) != 0 {
                out.add(j, e, .keyword); vars(p, e, le, out, shell: false)
            } else {
                let k = skipSpaces(p, e, le)
                if k < le && (p[k] == 0x3D || ((p[k] == 0x3A || p[k] == 0x3F || p[k] == 0x2B || p[k] == 0x21) && p[k + 1] == 0x3D)) {
                    out.add(j, e, .variable)
                    vars(p, k, le, out, shell: false)
                } else {
                    let colon = findAny(p, j, le, 0x3A, 0x3A, 0x3A, 0x3A)
                    if colon < le && p[colon + 1] != 0x3D {
                        out.add(j, colon, .function)
                        vars(p, colon + 1, le, out, shell: false)
                    } else {
                        vars(p, j, le, out, shell: false)
                    }
                }
            }
            i = le + 1
        }
    }

    static func vars(_ p: UnsafePointer<UInt8>, _ s: Int, _ le: Int, _ out: TokenStream, shell: Bool) {
        if shell {
            // Recipe lines are shell with make variables; lex as shell (handles $(VAR) too).
            ShellLexer.lex(p, s, le, out)
            return
        }
        var j = s
        while j < le {
            let k = findAny(p, j, le, 0x24, 0x23, 0x24, 0x24)
            if k >= le { return }
            if p[k] == 0x23 { out.add(k, le, .comment); return }
            if p[k + 1] == 0x28 || p[k + 1] == 0x7B {
                let e = CLike.matchBracket(p, k + 1, le, p[k + 1], p[k + 1] == 0x28 ? 0x29 : 0x7D)
                out.add(k, e, .variable); j = e
            } else {
                out.add(k, min(k + 2, le), .variable); j = k + 2
            }
        }
    }
}

// MARK: - Dockerfile

public enum DockerfileLexer {
    static let instructions = KeywordTable([(TokenKind.keyword.rawValue, "from run cmd label maintainer expose env add copy entrypoint volume user workdir arg onbuild stopsignal healthcheck shell as")], caseInsensitive: true)

    public static func lex(_ p: UnsafePointer<UInt8>, _ start: Int, _ end: Int, _ out: TokenStream) {
        var i = start
        var continuation = false
        while i < end {
            let le = lineEnd(p, i, end)
            let j = skipSpaces(p, i, le)
            if j < le && p[j] == 0x23 { out.add(j, le, .comment); i = le + 1; continue }
            var bodyStart = j
            if !continuation {
                var e = j
                while e < le && cc.isIdent(p[e]) { e &+= 1 }
                if instructions.lookup(p + j, e - j) != 0 { out.add(j, e, .keyword); bodyStart = e }
            }
            ShellLexer.lex(p, bodyStart, le, out)
            var t = le
            while t > j && cc.isSpace(p[t - 1]) { t &-= 1 }
            continuation = t > j && p[t - 1] == backslash
            i = le + 1
        }
    }
}

// MARK: - Markdown source (used for fenced ```markdown blocks and plain-source mode)

public enum MarkdownSourceLexer {
    public static func lex(_ p: UnsafePointer<UInt8>, _ start: Int, _ end: Int, _ out: TokenStream) {
        var i = start
        var fence: UInt8 = 0
        while i < end {
            let le = lineEnd(p, i, end)
            let j = skipSpaces(p, i, le)
            if fence != 0 {
                if matches(p, j, le, fence == 0x60 ? "```" : "~~~") { fence = 0; out.add(j, le, .meta) } else { out.add(i, le, .code) }
                i = le + 1; continue
            }
            if matches(p, j, le, "```") || matches(p, j, le, "~~~") {
                fence = p[j]; out.add(j, le, .meta); i = le + 1; continue
            }
            if p[j] == 0x23 { out.add(j, le, .heading); i = le + 1; continue }
            if p[j] == 0x3E { out.add(j, le, .quote); i = le + 1; continue }
            var k = j
            if (p[k] == 0x2D || p[k] == 0x2A || p[k] == 0x2B) && isSpaceTab(p[k + 1]) { out.add(k, k + 1, .listMarker); k += 2 }
            inline(p, k, le, out)
            i = le + 1
        }
    }

    static func inline(_ p: UnsafePointer<UInt8>, _ s: Int, _ le: Int, _ out: TokenStream) {
        var j = s
        while j < le {
            let k = findAny(p, j, le, 0x60, 0x2A, 0x5B, 0x5F)
            if k >= le { return }
            switch p[k] {
            case 0x60:
                let e = findAny(p, k + 1, le, 0x60, 0x60, 0x60, 0x60)
                let stop = min(e + 1, le); out.add(k, stop, .code); j = stop
            case 0x5B:
                let e = findAny(p, k + 1, le, 0x5D, 0x5D, 0x5D, 0x5D)
                if e < le && p[e + 1] == 0x28 {
                    let c = findAny(p, e + 1, le, 0x29, 0x29, 0x29, 0x29)
                    let stop = min(c + 1, le); out.add(k, stop, .link); j = stop
                } else { j = k + 1 }
            default:
                let strong = p[k + 1] == p[k]
                let d = strong ? 2 : 1
                var e = findAny(p, k + d, le, p[k], p[k], p[k], p[k])
                if e < le && strong && p[e + 1] != p[k] { e = le }
                if e < le && e > k + d {
                    let stop = min(e + d, le); out.add(k, stop, strong ? .strong : .emphasis); j = stop
                } else { j = k + d }
            }
        }
    }
}

import Darwin
