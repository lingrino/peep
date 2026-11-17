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

## Security and privacy

- **The preview extension** is sandboxed: it can read files (to show images next to a
  document) but has no network access and can't open other apps.
- **The background agent** (part of Peep.app, started by launchd) has the Accessibility
  permission. Its event tap looks at keystrokes only to decide whether a Peep preview is
  the frontmost Quick Look panel, forwards just the ones it uses (⌘F and friends, and typing
  while the find bar is open), and never logs them.
- **Links** open only when clicked in a preview. Web and mail links open as usual; a link to
  a local file opens it if it is a document (text, image, media, PDF), and anything that
  could run (scripts, apps, installers, `.command` files, profiles) is revealed in Finder
  instead.
- **Remote images** in Markdown load when a document is previewed, as in a browser, so a
  document's author can learn that it was viewed (and from which IP address). Only https
  images from public hosts are fetched (never `localhost` or the local network), without
  cookies, with size and time limits. Set `ImageStore.maxRemote` to 0 to turn them off.
- **Code signing.** `Scripts/setup-signing.sh` creates a self-signed identity so the
  Accessibility permission survives rebuilds. Its keychain password is stored in your login
  keychain without an access prompt (builds would otherwise ask every time), so any program
  running as you could sign code that macOS treats as Peep and that inherits the
  Accessibility permission. If that matters more to you than convenience, delete the
  identity (`security delete-keychain ~/Library/Keychains/peep-signing.keychain-db`) and
  grant the permission again after each build.

`Scripts/check.sh` runs every test and check (about a minute), including generated hostile
inputs (`Scripts/make-adversarial.py`). Architecture and development
notes for contributors (human or AI) are in [AGENTS.md](AGENTS.md).

## License

[MIT](LICENSE). The emoji shortcode table comes from
[emojibase-data](https://github.com/milesj/emojibase) (MIT); its notice is in
`Sources/Core/Markdown/EmojiTable.swift`.
