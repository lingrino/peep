/// Compact description of a parsed document, one line per block:
/// "<kind>|<text with runs re-marked>" e.g. "P|hi **bold** [x](u)".
func mdDump(_ src: String) -> [String] {
    let d = MarkdownParser.parse(TextBuffer(src))
    var out: [String] = []
    let bytes = Array(UnsafeBufferPointer(start: d.text.base, count: d.text.count))
    for b in d.blocks {
        var tag: String
        switch b.kind {
        case .paragraph: tag = "P"
        case .heading: tag = "H\(b.level)"
        case .code: tag = "CODE(\(b.language.name))"
        case .rule: tag = "HR"
        case .table: tag = "TABLE"
        case .html: tag = "HTML"
        case .footnote: tag = "FN"
        }
        if b.quoteDepth > 0 { tag = "Q\(b.quoteDepth)" + tag }
        if b.listDepth > 0 {
            let m: String
            switch b.marker {
            case .none: m = ""
            case .bullet: m = "•"
            case .ordered: m = "\(b.markerNumber)."
            case .taskOpen: m = "[ ]"
            case .taskDone: m = "[x]"
            }
            tag = "L\(b.listDepth)\(m)\(b.tight ? "t" : "")" + tag
        }
        if b.align == .center { tag += "^" }
        // Re-insert markers for runs inside this block.
        var opens: [Int: [String]] = [:], closes: [Int: [String]] = [:]
        for r in d.runs[Int(b.runStart)..<Int(b.runEnd)] {
            let s = Int(r.start), e = Int(r.end)
            var o = "", c = ""
            if r.style.contains(.image) {
                let img = d.images[Int(r.ref)]
                o = "![\(img.alt)](\(img.url))"; c = ""
                opens[s, default: []].append(o)
                closes[e, default: []].insert("", at: 0)
                continue
            }
            if r.style.contains(.link) { o += "["; c = "](\(d.links[Int(r.ref)]))" + c }
            if r.style.contains(.strong) { o += "**"; c = "**" + c }
            if r.style.contains(.emphasis) { o += "_"; c = "_" + c }
            if r.style.contains(.code) { o += "`"; c = "`" + c }
            if r.style.contains(.strike) { o += "~~"; c = "~~" + c }
            if r.style.contains(.kbd) { o += "<kbd>"; c = "</kbd>" + c }
            if r.style.contains(.superscript) { o += "^"; c = "^" + c }
            opens[s, default: []].append(o)
            closes[e, default: []].insert(c, at: 0)
        }
        var s = ""
        var k = Int(b.textStart)
        while k <= Int(b.textEnd) {
            if let c = closes[k] { s += c.joined() }
            if k == Int(b.textEnd) { break }
            if let o = opens[k] { s += o.joined() }
            let ch = bytes[k]
            if ch == 0xEF && k + 2 < bytes.count && bytes[k + 1] == 0xBF && bytes[k + 2] == 0xBC { k += 3; continue }   // U+FFFC
            s += ch == 0x0A ? "⏎" : ch == 0x09 ? "|" : String(decoding: [ch], as: UTF8.self)
            if ch >= 0xC0 {   // copy whole UTF-8 sequence
                s.removeLast()
                var e = k + 1
                while e < bytes.count && bytes[e] & 0xC0 == 0x80 { e += 1 }
                s += String(decoding: bytes[k..<e], as: UTF8.self)
                k = e
                continue
            }
            k += 1
        }
        out.append("\(tag)|\(s)")
    }
    return out
}

func expectMD(_ src: String, _ want: [String], file: StaticString = #fileID, line: UInt = #line) {
    let got = mdDump(src)
    if got != want {
        fail("\n      got:  \(got)\n      want: \(want)", file: file, line: line)
    }
}

let markdownTests: [Test] = [
    Test("md: headings and paragraphs") {
        expectMD("# Title\n\nSome text\nwrapped.\n\nSetext\n===\n\n## Closed ##", [
            "H1|Title", "P|Some text wrapped.", "H1|Setext", "H2|Closed",
        ])
    },
    Test("md: emphasis") {
        expectMD("*a* **b** ***c*** _d_ __e__ ~~f~~ snake_case_word **unclosed", [
            "P|_a_ **b** **_c_** _d_ **e** ~~f~~ snake_case_word **unclosed",
        ])
        expectMD("*foo **bar** baz*", ["P|_foo _**_bar_**_ baz_"])
    },
    Test("md: code spans and escapes") {
        expectMD("Use `a *b*` and `` x`y `` and \\*not\\* &amp; &copy; &#x41;", [
            "P|Use `a *b*` and `x`y` and *not* & © A",
        ])
    },
    Test("md: links and images") {
        expectMD("[a](http://x \"t\") [b][r] [r] ![i](p.png) <https://auto> www.example.com\n\n[r]: /dest", [
            "P|[a](http://x) [b](/dest) [r](/dest) ![i](p.png) [https://auto](https://auto) [www.example.com](http://www.example.com)",
        ])
    },
    Test("md: lists tight, loose, nested, task") {
        expectMD("- a\n- b\n  - c\n1. one\n2. two\n\n- [ ] todo\n- [x] done", [
            "L1•P|a", "L1•tP|b", "L2•tP|c", "L11.P|one", "L12.tP|two", "L1[ ]P|todo", "L1[x]tP|done",
        ])
    },
    Test("md: empty task items") {
        // A bare "[ ]" after the marker used to strip 4 bytes from a 3-byte line (a negative
        // range: crashed the previewer).
        expectMD("- [ ]\n- [x]\n-  [ ]", ["L1[ ]P|", "L1[x]tP|", "L1[ ]tP|"])
    },
    Test("md: overlong ordered markers are text") {
        // 10 digits: not a list item (CommonMark allows 9). Reading them overflowed Int32 and
        // trapped (crashed the previewer).
        expectMD("9999999999. a\n\n999999999. b", ["P|9999999999. a", "L1999999999.P|b"])
    },
    Test("md: deep nesting uses relative indents") {
        expectMD("- a\n  - b\n    - c\n      - d\n- e", ["L1•P|a", "L2•tP|b", "L3•tP|c", "L4•tP|d", "L1•tP|e"])
        expectMD("1. a\n   1. b\n      - c", ["L11.P|a", "L21.tP|b", "L3•tP|c"])
    },
    Test("md: quotes and lazy continuation") {
        expectMD("> quote\nlazy\n> > nested\n\nafter", ["Q1P|quote lazy", "Q2P|nested", "P|after"])
    },
    Test("md: code blocks") {
        expectMD("```swift\nlet x = 1\n```\n\n    indented\n    code\n\n~~~\nplain\n~~~", [
            "CODE(Swift)|let x = 1", "CODE(Plain Text)|indented⏎code", "CODE(Plain Text)|plain",
        ])
    },
    Test("md: tables") {
        expectMD("| a | b |\n|:-:|--:|\n| 1 | **2** |\n| x \\| y | `c|d` |", [
            "TABLE|a|b⏎1|**2**⏎x | y|`c|d`",
        ])
    },
    Test("md: html subset") {
        expectMD("<p align=\"center\">\n  <img src=\"logo.png\" alt=\"Logo\" width=\"100\">\n</p>\n\n<!-- hidden -->\n\nPress <kbd>⌘</kbd>+<b>F</b><br>next", [
            "P^|![Logo](logo.png)", "P|Press <kbd>⌘</kbd>+**F**⏎next",
        ])
    },
    Test("md: aligned div spans blocks") {
        expectMD("<div align=\"center\">\n  <img src=\"logo.png\" alt=\"L\">\n\n[a](x) | b\n</div>\n\nafter", [
            "P^|![L](logo.png)", "P^|[a](x) | b", "P|after",
        ])
        expectMD("<center>\n\n# Title\n\n</center>\n\ntext", ["H1^|Title", "P|text"])
        expectMD("<div>\n\nplain\n\n</div>", ["P|plain"])
    },
    Test("md: link and image strings") {
        let d = MarkdownParser.parse(TextBuffer(
            "<picture><source media=\"(prefers-color-scheme: dark)\" srcset=\"d.png 2x\"><img src=\"l.png\" alt=\"A &amp; B\" width=\"50%\" height=\"20px\"></picture>"
            + " [x](<u v> \"t\") [y](a\\(b\\)c) <https://a.b> www.c.d <me@x.org>\n\n![alt *em*](i.png)"))
        expectEqual(d.images.count, 2)
        let img = d.images[0]
        expectEqual(img.url, "l.png")
        expectEqual(img.alt, "A & B")
        expectEqual(img.width, -50)
        expectEqual(img.height, 20)
        expectEqual(img.darkURL, "d.png")
        expectEqual(d.images[1].alt, "alt em")
        expectEqual(d.images[1].darkURL, nil)
        expectEqual(Array(d.links), ["u v", "a(b)c", "https://a.b", "http://www.c.d", "mailto:me@x.org"])
    },
    Test("md: html tag names match exactly") {
        expectMD("<STRONG>a</STRONG> <a2>b</a2> <h7>c</h7> <Kbd>k</Kbd> <code>x</code>", [
            "P|**a** b c <kbd>k</kbd> `x`",
        ])
        expectMD("<h3 align=\"center\">Title</h3>", ["H3^|Title"])
    },
    Test("md: front matter hidden, rules, footnotes") {
        expectMD("---\ntitle: x\n---\n# Doc\n\n---\n\nText[^1]\n\n[^1]: Note", [
            "H1|Doc", "HR|", "P|Text^1^", "P|^1^ Note",
        ])
    },
    Test("md: consecutive reference definitions") {
        // Several definitions in one paragraph, then a definition followed by text, then a
        // paragraph starting with "[" that is not a definition.
        expectMD("[a] [b] [c]\n\n[a]: /1\n[b]: /2 \"t\"\n  [c]:\n  /3\n\n[d]: /4\ntext [d]\n\n[x] y", [
            "P|[a](/1) [b](/2) [c](/3)", "P|text [d](/4)", "P|[x] y",
        ])
    },
    Test("md: slugs for ASCII and Unicode headings") {
        expectEqual(MarkdownParser.slugify("Hello, World_2 - x"), "hello-world_2---x")
        expectEqual(MarkdownParser.slugify("Ünïcode Tëst ✓"), "ünïcode-tëst-")
    },
    Test("md: heading titles trimmed, images as alt text") {
        // Trimming used to apply only to titles that happened to contain a 0xEF byte.
        let d = MarkdownParser.parse(TextBuffer("# Title<br>\n## &#32;Two ❄️<br>\n### ![logo](l.png) Name"))
        expectEqual(d.headings.map(\.title), ["Title", "Two ❄️", "logo Name"])
    },
    Test("md: headings collected with slugs") {
        let d = MarkdownParser.parse(TextBuffer("# Hello World!\n## Hello World!\n### API `v2`"))
        expectEqual(d.headingSlugs(), ["hello-world", "hello-world-1", "api-v2"])
        expectEqual(d.headings.map(\.level), [1, 2, 3])
    },
    Test("md: robustness on random input") {
        var rng = SystemRandomNumberGenerator()
        let alphabet = Array("#*_~`[]()!<>|-+:.\\ \n\nabc1&;\"'`>".unicodeScalars)
        for _ in 0..<300 {
            var s = ""
            for _ in 0..<200 { s.unicodeScalars.append(alphabet[Int.random(in: 0..<alphabet.count, using: &rng)]) }
            let d = MarkdownParser.parse(TextBuffer(s))
            for b in d.blocks {
                expect(b.textStart <= b.textEnd && Int(b.textEnd) <= d.text.count)
                expect(b.runStart <= b.runEnd && Int(b.runEnd) <= d.runs.count)
            }
            for r in d.runs { expect(r.start < r.end && Int(r.end) <= d.text.count, "bad run") }
        }
    },
]
