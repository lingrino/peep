/// Every language Peep can highlight. To add one: add a case, a `name`, detection rules in
/// `detect`, and a branch in `lex` (usually a `CLikeSpec` in Specs.swift).
public enum Language: UInt8, CaseIterable, Sendable {
    case plain
    // C-family engine
    case swift, c, cpp, objc, csharp, java, kotlin, scala, groovy, dart, go, rust, zig
    case javascript, typescript, python, ruby, php, perl, lua, r, julia, sql, haskell, elm
    case ocaml, fsharp, elixir, erlang, nix, hcl, protobuf, graphql, glsl, solidity, d, nim
    case crystal, powershell, vim, assembly, lisp, pascal, fortran
    // Dedicated lexers
    case json, yaml, toml, ini, dotenv, xml, html, css, scss, less, shell, diff, makefile
    case dockerfile, markdown, hexdump

    public var name: String {
        switch self {
        case .plain: "Plain Text"
        case .swift: "Swift"; case .c: "C"; case .cpp: "C++"; case .objc: "Objective-C"
        case .csharp: "C#"; case .java: "Java"; case .kotlin: "Kotlin"; case .scala: "Scala"
        case .groovy: "Groovy"; case .dart: "Dart"; case .go: "Go"; case .rust: "Rust"; case .zig: "Zig"
        case .javascript: "JavaScript"; case .typescript: "TypeScript"; case .python: "Python"
        case .ruby: "Ruby"; case .php: "PHP"; case .perl: "Perl"; case .lua: "Lua"; case .r: "R"
        case .julia: "Julia"; case .sql: "SQL"; case .haskell: "Haskell"; case .elm: "Elm"
        case .ocaml: "OCaml"; case .fsharp: "F#"; case .elixir: "Elixir"; case .erlang: "Erlang"
        case .nix: "Nix"; case .hcl: "HCL"; case .protobuf: "Protocol Buffers"; case .graphql: "GraphQL"
        case .glsl: "Shader"; case .solidity: "Solidity"; case .d: "D"; case .nim: "Nim"
        case .crystal: "Crystal"; case .powershell: "PowerShell"; case .vim: "Vim Script"
        case .assembly: "Assembly"; case .lisp: "Lisp"; case .pascal: "Pascal"; case .fortran: "Fortran"
        case .json: "JSON"; case .yaml: "YAML"; case .toml: "TOML"; case .ini: "INI"; case .dotenv: "Environment"
        case .xml: "XML"; case .html: "HTML"; case .css: "CSS"; case .scss: "SCSS"; case .less: "Less"
        case .shell: "Shell"; case .diff: "Diff"; case .makefile: "Makefile"; case .dockerfile: "Dockerfile"
        case .markdown: "Markdown"
        case .hexdump: "Binary"
        }
    }

    /// Lexes `[start, end)` of a padded buffer into `out`.
    public func lex(_ p: UnsafePointer<UInt8>, _ start: Int, _ end: Int, _ out: TokenStream) {
        switch self {
        case .plain: break
        case .json: JSONLexer.lex(p, start, end, out)
        case .yaml: YAMLLexer.lex(p, start, end, out)
        case .toml, .dotenv: ConfigLexer.lex(p, start, end, out, semicolonComments: false)
        case .ini: ConfigLexer.lex(p, start, end, out, semicolonComments: true)
        case .xml: MarkupLexer.lex(p, start, end, out, html: false)
        case .html: MarkupLexer.lex(p, start, end, out, html: true)
        case .css: CSSLexer.lex(p, start, end, out, dialect: .css)
        case .scss: CSSLexer.lex(p, start, end, out, dialect: .scss)
        case .less: CSSLexer.lex(p, start, end, out, dialect: .less)
        case .shell: ShellLexer.lex(p, start, end, out)
        case .diff: DiffLexer.lex(p, start, end, out)
        case .makefile: MakefileLexer.lex(p, start, end, out)
        case .dockerfile: DockerfileLexer.lex(p, start, end, out)
        case .markdown: MarkdownSourceLexer.lex(p, start, end, out)
        case .hexdump: HexDump.lex(p, start, end, out)
        case .php: PHPLexer.lex(p, start, end, out)
        default: if let spec { CLike.lex(spec, p, start, end, out) }
        }
        out.finish(end)
    }

    var spec: CLikeSpec? {
        switch self {
        case .swift: Specs.swift; case .c: Specs.c; case .cpp: Specs.cpp; case .objc: Specs.objc
        case .csharp: Specs.csharp; case .java: Specs.java; case .kotlin: Specs.kotlin; case .scala: Specs.scala
        case .groovy: Specs.groovy; case .dart: Specs.dart; case .go: Specs.go; case .rust: Specs.rust
        case .zig: Specs.zig; case .javascript: Specs.javascript; case .typescript: Specs.typescript
        case .python: Specs.python; case .ruby: Specs.ruby; case .php: Specs.php; case .perl: Specs.perl
        case .lua: Specs.lua; case .r: Specs.r; case .julia: Specs.julia; case .sql: Specs.sql
        case .haskell: Specs.haskell; case .elm: Specs.elm; case .ocaml: Specs.ocaml; case .fsharp: Specs.fsharp
        case .elixir: Specs.elixir; case .erlang: Specs.erlang; case .nix: Specs.nix; case .hcl: Specs.hcl
        case .protobuf: Specs.protobuf; case .graphql: Specs.graphql; case .glsl: Specs.glsl
        case .solidity: Specs.solidity; case .d: Specs.d; case .nim: Specs.nim; case .crystal: Specs.crystal
        case .powershell: Specs.powershell; case .vim: Specs.vim; case .assembly: Specs.assembly
        case .lisp: Specs.lisp; case .pascal: Specs.pascal; case .fortran: Specs.fortran
        default: nil
        }
    }

    // MARK: - Detection

    /// Picks a language from the file name, then a shebang / content sniff of `head`.
    public static func detect(fileName: String, head: UnsafeBufferPointer<UInt8>) -> Language {
        let lower = fileName.lowercased()
        if let l = byName(lower) { return l }
        if let dot = lower.lastIndex(of: "."), dot != lower.startIndex {
            let ext = String(lower[lower.index(after: dot)...])
            // "config.yml.dist", "Makefile.in", "nginx.conf.j2": highlight what is wrapped.
            // One set lookup for every name; the inner detect only runs for wrapped names.
            if wrapperExtensions.contains(ext) || templateWrappers.contains(ext) {
                let inner = detect(fileName: String(lower[..<dot]), head: head)
                if inner != .plain || wrapperExtensions.contains(ext) { return inner }
            }
            if let l = byExtension(ext) { return l }
        } else if lower.hasPrefix("."), let l = byExtension(String(lower.dropFirst())) {
            return l   // dotfiles named like an extension: .bashrc -> "bashrc"
        }
        return sniff(head) ?? .plain
    }

    /// Code-fence info strings (```lang) and other free-form names. One dictionary lookup.
    public static func named(_ s: String) -> Language? {
        if s.isEmpty || s.utf8.count > 24 { return nil }
        return nameMap[asciiLower(s)]
    }

    /// Same lookup on raw bytes, no allocation: names of up to 16 bytes are lowercased and
    /// packed into two words (fences resolve without building a String; was 6% of parsing
    /// the CommonMark spec).
    public static func named(_ p: UnsafePointer<UInt8>, _ n: Int) -> Language? {
        guard n > 0, n <= 16 else {
            return n > 16 ? named(String(decoding: UnsafeBufferPointer(start: p, count: n), as: UTF8.self)) : nil
        }
        return packedNameMap.find(NameKey(p, n))
    }

    struct NameKey: Hashable, BitwiseCopyable {
        var a: UInt64 = 0, b: UInt64 = 0
        init() {}
        init(_ p: UnsafePointer<UInt8>, _ n: Int) {
            for k in 0..<n {
                var c = UInt64(p[k])
                if c >= 0x41 && c <= 0x5A { c |= 0x20 }
                if k < 8 { a |= c << (8 * UInt64(k)) } else { b |= c << (8 * UInt64(k - 8)) }
            }
        }
    }

    static let packedNameMap: PackedNameTable = {
        var entries: [(NameKey, Language)] = []
        for (name, l) in nameMap {
            let u = Array(name.utf8)
            if u.count <= 16 { u.withUnsafeBufferPointer { entries.append((NameKey($0.baseAddress!, u.count), l)) } }
        }
        return PackedNameTable(entries)
    }()

    /// Open addressing over packed names with a multiply-shift hash: Dictionary's SipHash
    /// was most of a fence lookup (one per code block; most miss, like the CommonMark spec's
    /// 700 "example" fences).
    struct PackedNameTable: @unchecked Sendable {
        let keys: UnsafeMutablePointer<NameKey>     // (0, 0) = empty slot
        let values: UnsafeMutablePointer<Language>
        let shift: UInt64
        let mask: Int

        init(_ entries: [(NameKey, Language)]) {
            var bits: UInt64 = 4
            while (1 << bits) < entries.count * 4 { bits += 1 }   // load <= 1/4: short probes
            let cap = 1 << Int(bits)
            shift = 64 - bits
            mask = cap - 1
            keys = .allocate(capacity: cap)
            keys.initialize(repeating: NameKey(), count: cap)
            values = .allocate(capacity: cap)
            values.initialize(repeating: .plain, count: cap)
            for (k, v) in entries {
                var i = slot(k)
                while keys[i] != NameKey() && keys[i] != k { i = (i + 1) & mask }
                keys[i] = k
                values[i] = v
            }
        }

        @inline(__always) func slot(_ k: NameKey) -> Int {
            Int(truncatingIfNeeded: (k.a &* 0x9E37_79B9_7F4A_7C15 ^ k.b &* 0xC2B2_AE3D_27D4_EB4F) >> shift)
        }

        @inline(__always) func find(_ k: NameKey) -> Language? {
            var i = slot(k)
            while true {
                let s = keys[i]
                if s == k { return s == NameKey() ? nil : values[i] }
                if s == NameKey() { return nil }
                i = (i + 1) & mask
            }
        }
    }

    /// Lowercased language names, common aliases, and every file extension.
    static let nameMap: [String: Language] = {
        var m: [String: Language] = [:]
        for (l, list) in extensionTable { for e in list.split(separator: " ") { m[String(e)] = l } }
        for l in Language.allCases { m[asciiLower(l.name)] = l }
        let aliases: [(String, Language)] = [
            ("objective-c", .objc), ("objectivec", .objc), ("obj-c", .objc), ("c++", .cpp), ("c#", .csharp), ("cs", .csharp),
            ("f#", .fsharp), ("shell", .shell), ("console", .shell), ("shellsession", .shell), ("terminal", .shell),
            ("sh", .shell), ("zsh", .shell), ("bash", .shell), ("text", .plain), ("txt", .plain), ("plaintext", .plain),
            ("plain", .plain), ("output", .plain), ("golang", .go), ("javascript", .javascript), ("node", .javascript),
            ("typescript", .typescript), ("python3", .python), ("py3", .python), ("docker", .dockerfile),
            ("make", .makefile), ("terraform", .hcl), ("tf", .hcl), ("patch", .diff), ("markdown", .markdown), ("md", .markdown),
            ("postgres", .sql), ("postgresql", .sql), ("mysql", .sql), ("sqlite", .sql), ("plsql", .sql), ("jsonc", .json),
            ("yml", .yaml), ("html", .html), ("xml", .xml), ("svg", .xml), ("plist", .xml), ("proto", .protobuf),
        ]
        for (k, v) in aliases { m[k] = v }
        return m
    }()

    @inline(__always) static func asciiLower(_ s: String) -> String {
        var u = Array(s.utf8)
        for i in u.indices where u[i] >= 0x41 && u[i] <= 0x5A { u[i] |= 0x20 }
        return String(decoding: u, as: UTF8.self)
    }

    static func byName(_ n: String) -> Language? {
        switch n {
        case "makefile", "gnumakefile", "justfile", "bsdmakefile": return .makefile
        case "dockerfile", "containerfile": return .dockerfile
        case "gemfile", "rakefile", "podfile", "fastfile", "appfile", "vagrantfile", "brewfile", "guardfile", "capfile", "dangerfile": return .ruby
        case "cmakelists.txt": return .shell
        case ".bashrc", ".bash_profile", ".bash_logout", ".zshrc", ".zprofile", ".zshenv", ".zlogin", ".zlogout", ".profile", ".kshrc", "pkgbuild", "apkbuild": return .shell
        case ".gitconfig", ".editorconfig", ".npmrc", ".yarnrc", ".pylintrc", ".flake8", "setup.cfg", "tox.ini", ".gitmodules": return .ini
        case ".gitignore", ".gitattributes", ".dockerignore", ".npmignore", ".prettierignore", ".eslintignore", ".hgignore", "codeowners": return .dotenv
        case ".env", ".envrc", ".flaskenv": return .dotenv
        case "cargo.lock", "pipfile", "poetry.lock", "uv.lock", "pdm.lock": return .toml
        case "go.mod", "go.sum", "go.work": return .go
        case "build", "workspace", "build.bazel", "workspace.bazel", "module.bazel", "tiltfile", "starlark": return .python
        case ".vimrc", ".gvimrc", "_vimrc": return .vim
        case "jenkinsfile": return .groovy
        case ".babelrc", ".eslintrc", ".prettierrc", ".swcrc", "flake.lock", "composer.lock": return .json
        case ".clang-format", ".clang-tidy", ".yamllint", ".gemrc": return .yaml
        default: break
        }
        if n.hasPrefix("dockerfile.") || n.hasSuffix(".dockerfile") { return .dockerfile }
        if n.hasPrefix(".env.") { return .dotenv }
        if n.hasPrefix("makefile.") { return .makefile }
        return nil
    }

    /// File extensions (lowercase, without the dot) per language. Single source of truth for
    /// detection *and* for the Quick Look content types Peep claims (Scripts/gen-types.sh).
    public static let extensionTable: [(Language, String)] = [
        (.swift, "swift swiftinterface"),
        (.c, "c h i strings modulemap pbxproj"),
        (.cpp, "cc cpp cxx c++ hh hpp hxx h++ ipp tpp inl ixx cppm ino cu cuh"),
        (.objc, "m mm"),
        (.csharp, "cs csx cake"),
        (.java, "java jav pde"),
        (.kotlin, "kt kts ktm"),
        (.scala, "scala sc sbt mill"),
        (.groovy, "groovy gvy gy gsh gradle"),
        (.dart, "dart"),
        (.go, "go"),
        (.rust, "rs ron"),
        (.zig, "zig zon"),
        (.javascript, "js mjs cjs jsx es6 es jsm gs jscad rjs"),
        (.typescript, "ts mts cts tsx"),
        (.python, "py pyw pyi pyx pxd gyp gypi bzl star sconstruct sconscript wsgi rpy"),
        (.ruby, "rb rbw rake gemspec podspec ru jbuilder rabl thor irbrc pryrc builder"),
        (.php, "php phtml php3 php4 php5 phps phpt inc"),
        (.perl, "pl pm t pod psgi cgi"),
        (.lua, "lua luau rockspec p8"),
        (.r, "r rprofile"),
        (.julia, "jl"),
        (.sql, "sql ddl dml pgsql psql mysql prql hql cql"),
        (.haskell, "hs lhs hsc cabal"),
        (.elm, "elm"),
        (.ocaml, "ml mli mll mly re rei"),
        (.fsharp, "fs fsi fsx fsscript"),
        (.elixir, "ex exs eex heex leex"),
        (.erlang, "erl hrl escript app.src"),
        (.nix, "nix"),
        (.hcl, "tf tfvars hcl nomad tftest"),
        (.protobuf, "proto proto3 thrift"),
        (.graphql, "graphql gql graphqls"),
        (.glsl, "glsl vert frag geom comp tesc tese vsh fsh metal hlsl fx wgsl shader cginc"),
        (.solidity, "sol"),
        (.d, "d di"),
        (.nim, "nim nims nimble nimrod"),
        (.crystal, "cr"),
        (.powershell, "ps1 psm1 psd1"),
        (.vim, "vim vimrc"),
        (.assembly, "s asm nasm a51 inc68k"),
        (.lisp, "lisp lsp cl el elc clj cljs cljc edn scm ss rkt fnl hy"),
        (.pascal, "pas pp dpr lpr dfm"),
        (.fortran, "f for f77 f90 f95 f03 f08"),
        (.json, "json jsonc json5 jsonl ndjson geojson webmanifest har ipynb jsonld avsc tsbuildinfo code-workspace sublime-settings sublime-project resolved alfredappearance"),
        (.yaml, "yaml yml clang-format"),
        (.toml, "toml"),
        (.ini, "ini cfg conf config cnf properties prefs reg desktop service socket timer mount target inf lnk url gitconfig editorconfig npmrc pylintrc"),
        (.dotenv, "env envrc gitignore gitattributes dockerignore npmignore ignore"),
        (.xml, "xml plist xsd xsl xslt svg rss atom xib storyboard entitlements csproj fsproj vbproj props targets nuspec resx wsdl kml gpx xaml xliff xlf dae mobileconfig sdef pom iml tmtheme tmlanguage opml manifest xcscheme stringsdict xmp xul rdf spf sptheme ecore wsf"),
        (.html, "html htm xhtml shtml vue svelte astro erb ejs hbs handlebars mustache njk jinja jinja2 j2 twig liquid jsp aspx cshtml razor tmpl gohtml rhtml"),
        (.css, "css pcss postcss"),
        (.scss, "scss sass"),
        (.less, "less styl"),
        (.shell, "sh bash zsh ksh fish command tool bats ebuild eclass bashrc zshrc profile zprofile zshenv bash_profile install"),
        (.diff, "diff patch rej"),
        (.makefile, "mk mak make just"),
        (.dockerfile, "dockerfile containerfile"),
        (.markdown, "md markdown mdown mkd mkdn mkdown mdwn mdtxt mdtext rmd qmd mdx livemd"),
        (.shell, "cmake"),
        (.toml, "lock"),
    ]

    /// Suffixes that wrap another file name (copies, examples, autoconf inputs). Registered
    /// with Quick Look as types of their own (`peep-dev types`); detection looks through them.
    public static let wrapperExtensions: Set<String> = [
        "dist", "example", "sample", "template", "orig", "bak", "old", "backup", "in", "default", "new", "disabled",
    ]
    /// Template suffixes with a language of their own (HTML-ish, see `extensionTable`) used
    /// only when the wrapped name has no known language: "x.yml.j2" is YAML, "x.j2" is HTML.
    static let templateWrappers: Set<String> = ["j2", "jinja", "jinja2", "tmpl", "erb"]

    static let extensionMap: [String: Language] = {
        var m: [String: Language] = [:]
        for (l, list) in extensionTable { for e in list.split(separator: " ") { m[String(e)] = l } }
        return m
    }()

    static func byExtension(_ e: String) -> Language? { extensionMap[e] }

    /// Shebang lines and a few unmistakable content prefixes.
    static func sniff(_ head: UnsafeBufferPointer<UInt8>) -> Language? {
        guard head.count >= 2, let base = head.baseAddress else { return nil }
        if base[0] == 0x23 && base[1] == 0x21 {   // #!
            var e = 2
            while e < head.count && base[e] != 0x0A { e += 1 }
            let line = String(decoding: UnsafeBufferPointer(start: base, count: e), as: UTF8.self)
            let parts = line.dropFirst(2).split(separator: " ").map(String.init)
            var interp = parts.first.map { String($0.split(separator: "/").last ?? "") } ?? ""
            if interp == "env" { interp = parts.dropFirst().first { !$0.hasPrefix("-") } ?? "" }
            switch interp {
            case "sh", "bash", "zsh", "ksh", "dash", "fish", "ash": return .shell
            case "python", "python2", "python3", "pypy", "pypy3": return .python
            case "node", "nodejs", "deno", "bun": return .javascript
            case "ruby": return .ruby
            case "perl": return .perl
            case "php": return .php
            case "lua", "luajit": return .lua
            case "Rscript": return .r
            case "swift": return .swift
            case "osascript": return .plain
            default:
                if interp.hasPrefix("python") { return .python }
                return nil
            }
        }
        // <?xml / <!DOCTYPE html
        var i = 0
        while i < head.count && (base[i] == 0x20 || base[i] == 0x0A || base[i] == 0x0D || base[i] == 0x09) { i += 1 }
        if i + 5 < head.count && base[i] == 0x3C {
            if base[i + 1] == 0x3F && base[i + 2] == 0x78 { return .xml }
            if base[i + 1] == 0x21 || base[i + 1] == 0x68 || base[i + 1] == 0x48 { return .html }
        }
        return nil
    }
}
