/// Non-plain tokens as "kind:text" strings, for compact expectations.
func lexed(_ lang: Language, _ src: String) -> [String] {
    let b = TextBuffer(src)
    let out = TokenStream(expectedBytes: b.count)
    lang.lex(b.base, 0, b.count, out)
    var r: [String] = []
    for i in 0..<out.count where out.kind(i) != .plain {
        r.append("\(out.kind(i)):\(b.string(out.start(i), out.end(i)))")
    }
    // Invariants: tokens tile the text, no empty tokens, no adjacent equal kinds.
    expectEqual(out.count == 0 ? 0 : out.end(out.count - 1), b.count, "coverage")
    for i in 0..<out.count {
        expect(out.end(i) > out.start(i), "empty token at \(i)")
        if i > 0 { expect(out.kinds[i] != out.kinds[i - 1], "unmerged neighbors at \(i)") }
    }
    return r
}

func expectTokens(_ lang: Language, _ src: String, contains want: [String], file: StaticString = #fileID, line: UInt = #line) {
    let got = lexed(lang, src)
    for w in want where !got.contains(w) {
        fail("missing \(w) in \(got)", file: file, line: line)
    }
}

let lexTests: [Test] = [
    Test("keywords table") {
        let t = KeywordTable([(1, "if else return"), (2, "associatedtype"), (3, "x")])
        let b = TextBuffer("if else return associatedtype x xy iff")
        func look(_ s: Int, _ n: Int) -> UInt8 { t.lookup(b.base + s, n) }
        expectEqual(look(0, 2), 1); expectEqual(look(3, 4), 1); expectEqual(look(8, 6), 1)
        expectEqual(look(15, 14), 2); expectEqual(look(30, 1), 3); expectEqual(look(32, 2), 0); expectEqual(look(35, 3), 0)
        let ci = KeywordTable([(1, "select from")], caseInsensitive: true)
        let b2 = TextBuffer("SELECT From")
        expectEqual(ci.lookup(b2.base, 6), 1); expectEqual(ci.lookup(b2.base + 7, 4), 1)
    },
    Test("swift") {
        expectTokens(.swift, """
        import Foundation
        /// doc
        struct Point { let x: Double = 1.5e3 }
        func move(by d: Int) -> String { return "a\\(d + 1)b" }
        @MainActor final class View: NSView {}
        let r = #"raw \\n"#
        /* outer /* nested */ still */ let z = nil
        """, contains: ["keyword:import", "type:Foundation", "comment:/// doc", "keyword:struct", "type:Point",
                        "type:Double", "number:1.5e3", "function:move", "string:\"a", "escape:\\(", "number:1", "escape:)",
                        "string:b\"", "attribute:@MainActor", "type:View", "string:#\"raw \\n\"#",
                        "comment:/* outer /* nested */ still */", "constant:nil"])
    },
    Test("rust") {
        expectTokens(.rust, """
        #[derive(Debug)]
        fn main<'a>(x: &'a str) -> u32 { println!("{}", 'c'); let s = r#"q"#; 0xFF_u32 }
        """, contains: ["attribute:#[derive(Debug)]", "keyword:fn", "function:main", "label:'a", "type:u32",
                        "preprocessor:println!", "string:'c'", "string:r#\"q\"#", "number:0xFF_u32"])
    },
    Test("go") {
        expectTokens(.go, "package main\nfunc (s *S) Run(x int) error { return nil }\nvar r = `raw\nline`",
                     contains: ["keyword:package", "keyword:func", "function:Run", "type:int", "type:error", "constant:nil", "string:`raw\nline`"])
    },
    Test("javascript") {
        expectTokens(.javascript, "const re = /a[/]b/g; let t = `x ${y + 1} z`; x = a / b / c;",
                     contains: ["keyword:const", "regex:/a[/]b/g", "string:`x ", "escape:${", "number:1", "escape:}", "string: z`"])
        let ops = lexed(.javascript, "x = a / b / c;")
        expect(!ops.contains { $0.hasPrefix("regex") }, "division must not be a regex: \(ops)")
    },
    Test("python") {
        expectTokens(.python, "@dataclass\nclass A:\n    def f(self):\n        return f\"v={self.x}\" + '''doc'''  # c\n",
                     contains: ["attribute:@dataclass", "keyword:class", "type:A", "keyword:def", "function:f",
                                "builtin:self", "string:f\"v=", "escape:{", "escape:}", "string:'''doc'''", "comment:# c"])
    },
    Test("c preprocessor") {
        expectTokens(.c, "#include <stdio.h>\n#define N 10\nint main(void) { char *s = \"hi\\n\"; }",
                     contains: ["preprocessor:#include", "string:<stdio.h>", "preprocessor:#define", "type:int", "function:main",
                                "string:\"hi", "escape:\\n"])
    },
    Test("sql case-insensitive") {
        expectTokens(.sql, "SELECT id FROM t WHERE x = 'a' -- c", contains: ["keyword:SELECT", "keyword:FROM", "keyword:WHERE", "string:'a'", "comment:-- c"])
    },
    Test("json") {
        expectTokens(.json, "{\"k\": \"v\", \"n\": -1.5e2, \"b\": true, \"z\": null}",
                     contains: ["property:\"k\"", "string:\"v\"", "number:-1.5e2", "constant:true", "constant:null"])
    },
    Test("yaml") {
        expectTokens(.yaml, "---\nname: app # c\nlist:\n  - a: 1\n    b: \"s\"\nflag: true\nref: *anchor\n",
                     contains: ["meta:---", "property:name", "comment:# c", "property:list", "property:a", "number:1",
                                "string:\"s\"", "constant:true", "variable:*anchor"])
    },
    Test("toml") {
        expectTokens(.toml, "[package]\nname = \"peep\"\nversion = 1\n# c", contains: ["heading:[package]", "property:name", "string:\"peep\"", "number:1", "comment:# c"])
    },
    Test("html") {
        expectTokens(.html, "<!DOCTYPE html><div class=\"a\">&amp;<script>let x = 1;</script><!-- c --></div>",
                     contains: ["meta:<!DOCTYPE html>", "tag:div", "attrName:class", "string:\"a\"", "escape:&amp;",
                                "tag:script", "keyword:let", "number:1", "comment:<!-- c -->"])
    },
    Test("css") {
        expectTokens(.css, "@media screen { .btn:hover { color: #fff; margin: 0 1.5em !important; } }",
                     contains: ["keyword:@media", "type:.btn", "attribute::hover", "property:color", "number:#fff",
                                "number:0", "number:1.5em", "keyword:!important"])
    },
    Test("shell") {
        expectTokens(.shell, "#!/bin/bash\nif [ -f \"$HOME/x\" ]; then\n  echo ${A} $(ls -l) # c\nfi\nNAME=1 cat <<EOF\nbody\nEOF\n",
                     contains: ["comment:#!/bin/bash", "keyword:if", "variable:$HOME", "keyword:then", "builtin:echo",
                                "variable:${A}", "function:ls", "comment:# c", "keyword:fi", "variable:NAME", "string:body\n"])
    },
    Test("diff") {
        expectTokens(.diff, "--- a\n+++ b\n@@ -1 +1 @@\n-old\n+new\n ctx", contains: ["meta:--- a", "meta:+++ b", "meta:@@ -1 +1 @@", "deleted:-old", "inserted:+new"])
    },
    Test("detection") {
        func d(_ n: String, _ head: String = "") -> Language {
            var h = head
            return h.withUTF8 { Language.detect(fileName: n, head: $0) }
        }
        expectEqual(d("main.swift"), .swift); expectEqual(d("Makefile"), .makefile); expectEqual(d("Dockerfile.dev"), .dockerfile)
        expectEqual(d(".zshrc"), .shell); expectEqual(d("x.TSX"), .typescript); expectEqual(d("run", "#!/usr/bin/env python3\n"), .python)
        expectEqual(d("Gemfile"), .ruby); expectEqual(d(".env.local"), .dotenv); expectEqual(d("a.unknown"), .plain)
        expectEqual(Language.named("c++"), .cpp); expectEqual(Language.named("Swift"), .swift); expectEqual(Language.named("sh"), .shell)
    },
    Test("robustness: every language survives garbage") {
        var rng = SystemRandomNumberGenerator()
        let alphabet = Array("\"'`/\\*#@$-{}()[]<>!?:;.,=+%&|^~ \n\tabcXYZ019_r€😀".unicodeScalars)
        for _ in 0..<40 {
            var s = ""
            for _ in 0..<400 { s.unicodeScalars.append(alphabet[Int.random(in: 0..<alphabet.count, using: &rng)]) }
            for l in Language.allCases { _ = lexed(l, s) }
        }
    },
]
