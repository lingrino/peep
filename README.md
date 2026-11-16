# Peep

A fast Quick Look extension for macOS: select a source file or Markdown document in Finder,
press Space, and get a syntax-highlighted (or rendered) preview. Press ⌘F to search inside it.

- **Code**: ~60 languages and formats, hand-written lexers, line numbers, no wrapping,
  selection and copy, light/dark themes modeled on Xcode's.
- **Markdown**: CommonMark + GitHub extensions (tables, task lists, strikethrough, autolinks,
  footnotes with back-links, alerts like `> [!NOTE]`, `:emoji:` shortcodes), highlighted code
  blocks, images (local and remote), a common subset of inline HTML, and a table-of-contents
  sidebar.
- **Outline**: a sidebar of headings (Markdown) or declarations (code) that follows the scroll.
- **Find**: ⌘F, ⌘G/⇧⌘G, Return/⇧Return, Esc — incremental, smart-case, SIMD search.
- **Archives**: ZIP-family (zip, jar, whl, apk, …), tar, tar.gz, tar.xz listed as a tree;
  single `.gz`/`.xz` files previewed decompressed.
- **Jupyter notebooks**, **SQLite databases** (tables, schema, first rows), **minified JSON**
  (re-indented), **logs** (opened at the end), and wrapped names like `config.yml.dist`.
- **Binary files**: property lists shown as XML, everything else as a hex dump.

Everything is native (Core Text, no web views) and dependency-free. Built for macOS 27 on
Apple Silicon.

## Building

Requires the Xcode Command Line Tools.

```sh
Scripts/setup-signing.sh      # once: a local code-signing identity
Scripts/build.sh install      # build, sign, install to /Applications
```

Then open Peep.app once and grant Accessibility access when asked (Quick Look previews can't
receive keystrokes; Peep's small background agent forwards ⌘F and friends).

[Examples](Examples) has a sample of every supported file type to try it on.

`Scripts/check.sh` runs every test and check (about a minute). Architecture and development
notes for contributors (human or AI) are in [AGENTS.md](AGENTS.md).
