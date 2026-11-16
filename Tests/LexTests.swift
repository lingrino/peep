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
        // Wrapper suffixes are looked through; template suffixes only when the inner name is known.
        expectEqual(d("config.yml.dist"), .yaml); expectEqual(d("Makefile.in"), .makefile); expectEqual(d("config.h.in"), .c)
        expectEqual(d(".env.example"), .dotenv); expectEqual(d("app.json.sample.bak"), .json); expectEqual(d("notes.bak"), .plain)
        expectEqual(d("nginx.conf.j2"), .ini); expectEqual(d("page.j2"), .html); expectEqual(d("config.yml.erb"), .yaml)
        expectEqual(d("Package.resolved"), .json); expectEqual(d("x.xcscheme"), .xml); expectEqual(d("x.mkdown"), .markdown)
        // Byte lookup agrees with the String lookup for every name, in any case.
        func bytes(_ s: String) -> Language? { Array(s.utf8).withUnsafeBufferPointer { Language.named($0.baseAddress!, $0.count) } }
        for name in Language.nameMap.keys {
            expectEqual(bytes(name), Language.named(name))
            expectEqual(bytes(name.uppercased()), Language.named(name))
        }
        expectEqual(bytes("JavaScript"), .javascript); expectEqual(bytes("nope"), nil)
        expectEqual(bytes("averyveryverylonglanguagename"), nil)
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
    Test("outline: declarations from the lexer") {
        func syms(_ lang: Language, _ src: String) -> [String] {
            let t = TextBuffer(src), li = LineIndex(t), tk = TokenStream(expectedBytes: t.count)
            lang.lex(t.base, 0, t.count, tk)
            return CodeOutline.symbols(t, li, tk).map { String(repeating: ">", count: $0.level) + $0.title }
        }
        expectEqual(syms(.go, "type T struct {}\nfunc (t *T) Run() {\n\tf := func(x int) int { return x }\n}\nfunc main() {}\n"),
                    ["type T", "T.Run", "main"])
        expectEqual(syms(.c, "struct node { int v; };\nstatic int add(int a, int b) {\n  struct node n; return helper(a);\n}\nint proto(void);\n"),
                    ["struct node", "add"])
        expectEqual(syms(.java, "class A {\n  void run() {\n    new Thread() { };\n    go(x);\n  }\n}\n"), ["class A", ">run"])
        expectEqual(syms(.java, "class B {\n  Stream open(String p) {\n    return with(p);\n  }\n}\n"), ["class B", ">open"])
        expectEqual(syms(.kotlin, "@file:Opt(Foo::class)\nclass C {\n  fun f() {}\n}\n"), ["class C", ">f"])
        expectEqual(syms(.python, "class A:\n    def m(self):\n        def inner(): pass\ndef top(): pass\n"), ["class A", ">m", ">>inner", "top"])
    },
    Test("outline: keywordless members and qualified names") {
        func syms(_ lang: Language, _ src: String) -> [String] {
            let t = TextBuffer(src), li = LineIndex(t), tk = TokenStream(expectedBytes: t.count)
            lang.lex(t.base, 0, t.count, tk)
            return CodeOutline.symbols(t, li, tk).map { String(repeating: ">", count: $0.level) + $0.title }
        }
        // JS/TS: class members (methods, accessors, private, arrow fields), not calls, control
        // flow, overload signatures or object literals; top-level function bindings.
        expectEqual(syms(.typescript, """
            export const load = async (p: string): Promise<C> => {
            };
            const total = items.reduce((a, b) => a + b, 0);
            const obj = { m() { return 1; } };
            class Store<T> extends Base {
              #items: T[] = [];
              onChange = (e: Event) => { this.emit(e); };
              constructor(private n: string) {
                if (n) { log(n); }
              }
              get size(): number { return 0; }
              static create<U>(n: string): Store<U> { return new Store<U>(n); }
              over(x: string): void;
              over(x: any) {}
              #check(x: T): boolean { return true; }
              get(key: string) { return 1; }
            }
            interface Shape { area(): number; }
            """), ["load", "class Store", ">onChange", ">constructor", ">size", ">create", ">over", ">#check", ">get", "interface Shape"])
        expectEqual(syms(.javascript, "#!/usr/bin/env node\nconst throttle = (fn) => {};\nlet id = x => x;\nvar f = function () {};\n"),
                    ["throttle", "id", "f"])
        // Swift: initializers named with their argument labels; `.init(` calls aren't declarations.
        expectEqual(syms(.swift, """
            struct S {
                init(name: String, count: Int = 0) { let s = S.init(name: "x", count: 1) }
                init?(_ d: [String: Any]) {}
                deinit {}
                subscript(index: Int) -> Int { 0 }
            }
            """), ["struct S", ">init(name:count:)", ">init?(_:)", ">deinit", ">subscript(index:)"])
        // Rust impl blocks (not `-> impl Trait`), Ruby/Lua/Kotlin/Perl qualified names.
        expectEqual(syms(.rust, "impl fmt::Display for P {\n    fn fmt(&self) {}\n}\nfn it() -> impl Iterator<Item = u8> {}\n"),
                    ["impl fmt::Display for P", ">fmt", "it"])
        expectEqual(syms(.ruby, "class A::B\n  def self.create; end\nend\n"), ["class A::B", ">self.create"])
        expectEqual(syms(.lua, "function M.new() end\nfunction M:value() end\n"), ["M.new", "M:value"])
        expectEqual(syms(.kotlin, "fun String.isEmail(): Boolean = true\nfun <T> List<T>.second(): T = this[1]\n"),
                    ["String.isEmail", "List<T>.second"])
        expectEqual(syms(.perl, "sub My::Pkg::helper { }\n"), ["My::Pkg::helper"])
        // Keywords as names (`def match(`) and as modifiers (`type alias`).
        expectEqual(syms(.python, "def match(self): pass\n"), ["match"])
        expectEqual(syms(.elm, "type alias Model = Int\nupdate : Msg -> Int\nupdate msg m = m\n"), ["type alias Model", "update"])
        // C#: expression bodies and records; switch-arm patterns and base calls aren't definitions.
        expectEqual(syms(.csharp, """
            record Circle(double R) : Shape("c")
            {
                public override string ToString() => "c";
                string D(object o) => o switch { Point(0, 0) => "o", _ => "x" };
            }
            """), ["record Circle", ">ToString", ">D"])
        // C++: operators, destructors, qualified definitions, initializer lists.
        expectEqual(syms(.cpp, """
            class M {
              ~M() {}
              M operator*(const M& o) const { return o; }
              double& operator()(int r) { return d; }
            };
            M::M(int n)
                : n_(n),
                  d_{n} {
            }
            void M::resize(int n) {}
            """), ["class M", ">~M", ">operator*", ">operator()", "M::M", "M::resize"])
        // Column-0 declarations: Haskell signatures, Erlang clauses (one entry), assembly labels.
        expectEqual(syms(.haskell, "main :: IO ()\nmain = print 1\ndata T = A | B\n"), ["main", "data T"])
        expectEqual(syms(.erlang, "-module(m).\nloop(0) -> ok;\nloop(N) -> loop(N - 1).\n"), ["loop"])
        expectEqual(syms(.assembly, "_main:\n    ret\nmsg: .ascii \"x\"\n"), ["_main", "msg"])
        // SQL: only after CREATE; HCL blocks; Objective-C; Fortran `end function` closes.
        expectEqual(syms(.sql, "CREATE TABLE IF NOT EXISTS users (id INT);\nALTER TABLE users ADD x INT;\ncreate view v as select 1;\n"),
                    ["TABLE users", "view v"])
        expectEqual(syms(.hcl, "terraform {\n}\nresource \"aws_s3_bucket\" \"a\" {\n  tags = { x = 1 }\n}\n"),
                    ["terraform", "resource aws_s3_bucket a"])
        expectEqual(syms(.objc, "@interface G : NSObject\n- (int)hi:(int)h;\n@end\n@implementation G\n- (int)hi:(int)h {\n  return h;\n}\n@end\n"),
                    ["@interface G", "@implementation G", "hi:"])
        expectEqual(syms(.fortran, "module m\ncontains\n  function f(x)\n  end function f\nend module m\n"), ["module m", ">f"])
    },
]
