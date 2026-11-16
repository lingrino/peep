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
    case dockerfile, markdown

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
            if let l = byExtension(ext) { return l }
        } else if lower.hasPrefix("."), let l = byExtension(String(lower.dropFirst())) {
            return l   // dotfiles named like an extension: .bashrc -> "bashrc"
        }
        return sniff(head) ?? .plain
    }

    /// Code-fence info strings (```lang) and other free-form names.
    public static func named(_ s: String) -> Language? {
        let lower = s.lowercased()
        switch lower {
        case "objective-c", "objectivec", "obj-c": return .objc
        case "c++": return .cpp
        case "c#", "cs": return .csharp
        case "f#": return .fsharp
        case "shell", "console", "shellsession", "terminal": return .shell
        case "text", "txt", "plaintext", "plain", "output": return .plain
        case "golang": return .go
        case "javascript", "node": return .javascript
        case "typescript": return .typescript
        case "python3", "py3": return .python
        case "docker": return .dockerfile
        case "make": return .makefile
        case "terraform", "tf": return .hcl
        case "patch": return .diff
        case "markdown", "md": return .markdown
        case "postgres", "postgresql", "mysql", "sqlite", "plsql": return .sql
        default: break
        }
        if let l = Language.allCases.first(where: { $0.name.lowercased() == lower }) { return l }
        return byExtension(lower)
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

    static func byExtension(_ e: String) -> Language? {
        switch e {
        case "swift", "swiftinterface": return .swift
        case "c", "h", "i": return .c
        case "cc", "cpp", "cxx", "c++", "hh", "hpp", "hxx", "h++", "ipp", "tpp", "inl", "ixx", "cppm", "ino", "cu", "cuh": return .cpp
        case "m", "mm": return .objc
        case "cs", "csx", "cake": return .csharp
        case "java", "jav": return .java
        case "kt", "kts", "ktm": return .kotlin
        case "scala", "sc", "sbt", "mill": return .scala
        case "groovy", "gvy", "gy", "gsh", "gradle": return .groovy
        case "dart": return .dart
        case "go": return .go
        case "rs", "ron": return .rust
        case "zig", "zon": return .zig
        case "js", "mjs", "cjs", "jsx", "es6", "es", "jsm", "gs", "jscad": return .javascript
        case "ts", "mts", "cts", "tsx": return .typescript
        case "py", "pyw", "pyi", "pyx", "pxd", "gyp", "gypi", "bzl", "star", "sconstruct", "sconscript", "wsgi", "rpy": return .python
        case "rb", "rbw", "rake", "gemspec", "podspec", "ru", "jbuilder", "rabl", "thor", "irbrc", "pryrc", "builder": return .ruby
        case "php", "phtml", "php3", "php4", "php5", "phps", "phpt", "inc": return .php
        case "pl", "pm", "t", "pod", "psgi", "cgi": return .perl
        case "lua", "luau", "rockspec", "p8": return .lua
        case "r", "rprofile": return .r
        case "jl": return .julia
        case "sql", "ddl", "dml", "pgsql", "psql", "mysql", "prql", "hql", "cql": return .sql
        case "hs", "lhs", "hsc", "cabal": return .haskell
        case "elm": return .elm
        case "ml", "mli", "mll", "mly", "re", "rei": return .ocaml
        case "fs", "fsi", "fsx", "fsscript": return .fsharp
        case "ex", "exs", "eex", "heex", "leex": return .elixir
        case "erl", "hrl", "escript", "app.src": return .erlang
        case "nix": return .nix
        case "tf", "tfvars", "hcl", "nomad", "tftest": return .hcl
        case "proto", "proto3", "thrift": return .protobuf
        case "graphql", "gql", "graphqls": return .graphql
        case "glsl", "vert", "frag", "geom", "comp", "tesc", "tese", "vsh", "fsh", "metal", "hlsl", "fx", "wgsl", "shader", "cginc": return .glsl
        case "sol": return .solidity
        case "d", "di": return .d
        case "nim", "nims", "nimble": return .nim
        case "cr": return .crystal
        case "ps1", "psm1", "psd1": return .powershell
        case "vim", "vimrc": return .vim
        case "s", "asm", "nasm", "a51", "inc68k": return .assembly
        case "lisp", "lsp", "cl", "el", "elc", "clj", "cljs", "cljc", "edn", "scm", "ss", "rkt", "fnl", "hy": return .lisp
        case "pas", "pp", "dpr", "lpr", "dfm": return .pascal
        case "f", "for", "f77", "f90", "f95", "f03", "f08": return .fortran
        case "json", "jsonc", "json5", "jsonl", "ndjson", "geojson", "webmanifest", "har", "ipynb", "jsonld", "avsc", "tsbuildinfo", "code-workspace", "sublime-settings", "sublime-project": return .json
        case "yaml", "yml", "clang-format": return .yaml
        case "toml": return .toml
        case "ini", "cfg", "conf", "config", "cnf", "properties", "prefs", "reg", "desktop", "service", "socket", "timer", "mount", "target", "inf", "lnk", "url", "gitconfig", "editorconfig", "npmrc", "pylintrc": return .ini
        case "env", "envrc", "gitignore", "gitattributes", "dockerignore", "npmignore", "ignore": return .dotenv
        case "xml", "plist", "xsd", "xsl", "xslt", "svg", "rss", "atom", "xib", "storyboard", "entitlements", "csproj", "fsproj", "vbproj", "props", "targets", "nuspec", "resx", "wsdl", "kml", "gpx", "xaml", "xliff", "xlf", "dae", "mobileconfig", "sdef", "pom", "iml", "tmtheme", "tmlanguage", "opml", "manifest": return .xml
        case "html", "htm", "xhtml", "shtml", "vue", "svelte", "astro", "erb", "ejs", "hbs", "handlebars", "mustache", "njk", "jinja", "jinja2", "j2", "twig", "liquid", "jsp", "aspx", "cshtml", "razor", "tmpl", "gohtml": return .html
        case "css", "pcss", "postcss": return .css
        case "scss", "sass": return .scss
        case "less", "styl": return .less
        case "sh", "bash", "zsh", "ksh", "fish", "command", "tool", "bats", "ebuild", "eclass", "bashrc", "zshrc", "profile", "zprofile", "zshenv", "bash_profile", "install": return .shell
        case "diff", "patch", "rej": return .diff
        case "mk", "mak", "make", "just": return .makefile
        case "dockerfile", "containerfile": return .dockerfile
        case "md", "markdown", "mdown", "mkd", "mkdn", "mdwn", "mdtxt", "mdtext", "rmd", "qmd", "mdx", "livemd": return .markdown
        case "cmake": return .shell
        case "lock": return .toml
        default: return nil
        }
    }

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
