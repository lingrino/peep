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

## Install

```sh
brew install --cask lingrino/tap/peep
open -a Peep
```

Opening Peep.app once starts its small background agent; grant it Accessibility access when
asked (System Settings → Privacy & Security → Device Control and Data Access, as macOS 27
calls it). Quick Look previews can't receive keystrokes or prompt clicks, so the agent
forwards ⌘F and friends and outline clicks, and shows the copy-path button.
Update with `brew upgrade --cask peep`: the agent restarts itself when its app is replaced.

[Examples](Examples) has a sample of every supported file type to try it on.

## Building

Requires the Xcode Command Line Tools. `Scripts/build.sh install` builds, signs with the
maintainer's Developer ID (`Scripts/setup-signing.sh`) and installs to /Applications; to
build without it, `PEEP_SIGN_IDENTITY=- Scripts/build.sh install` (ad-hoc: Accessibility has
to be granted again after each build). Every PR runs the checks in GitHub Actions, and every
merge to main is released as 0.0.N: signed with a Developer ID, notarized, and published to
the tap.

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
- **Code signing.** Releases are signed with a Developer ID and notarized. The maintainer's
  local builds sign with the same Developer ID, so the Accessibility permission carries
  across releases and local builds. `Scripts/setup-signing.sh` keeps it in a dedicated
  keychain whose password sits in a file only your account can read (builds would otherwise
  ask every time), so any program running as you could sign code that macOS treats as Peep
  and that inherits the Accessibility permission. Builds signed ad-hoc
  (`PEEP_SIGN_IDENTITY=-`) need no certificate, but the permission has to be granted again
  after each one.

`Scripts/check.sh` runs every test and check (about a minute), including generated hostile
inputs (`Scripts/make-adversarial.py`). Architecture and development
notes for contributors (human or AI) are in [AGENTS.md](AGENTS.md).

## License

[MIT](LICENSE). The emoji shortcode table comes from
[emojibase-data](https://github.com/milesj/emojibase) (MIT); its notice is in
`Sources/Core/Markdown/EmojiTable.swift`.
