# Peep — agent guide

Peep is a macOS Quick Look extension (select a file in Finder, press Space) for source code
and Markdown. It is built for one user, maintained by AI agents, and optimized without
compromise for latency. Read this whole file before changing anything.

## Principles (from the owner)

- **Audience of one.** No settings UI. Preferences are constants in code; change the code.
- **Performance is the product.** Every millisecond matters: launch-to-first-paint, scrolling,
  search. Prefer redesigns over caches ("caching is cope for a slow design"). Measure before
  and after (`Scripts/dev.sh bench`, `Scripts/profile.sh`).
- **No third-party dependencies.** Only Apple frameworks. Write our own lexers, parser, etc.
- **Latest macOS only** (27+), Apple Silicon only (M4-class). Use newest APIs freely.
- **Public-repo hygiene.** Nothing machine- or person-specific in code, docs, tests or commit
  messages (no usernames, paths, hostnames). Commits are authored by the owner's git identity.
- **Stop only for one-way doors** or things only the owner can do (permission prompts,
  passwords). Otherwise decide, record the decision here or in code comments, and move on.

## Processes

```
Finder ──Space──▶ Quick Look ──▶ PeepPreview.appex (sandboxed, view-based QLPreviewingController)
                                      │  XPC (mach service com.lingrino.peep.agent)
                                      ▼
                              Peep (same binary as Peep.app) running as a launchd LaunchAgent:
                              Accessibility event tap + link opening + remote image fetching
```

1. **PeepPreview.appex** — `Sources/Preview/`. One `PreviewViewController` per visible preview
   (Finder's column preview pane and the Space panel each get one); the process is long-lived
   and reused. `preparePreviewOfFile` runs on the main thread: load → decode → detect → lex/parse
   → show → draw the first tiles, then calls the handler. Logs `prepare <file>: <stage
   timings>` (subsystem `com.lingrino.peep`), and once per process its cold-start time.
2. **Keyboard agent** — `Sources/App/Agent.swift`. Quick Look previews *never* receive key
   events (the panel never becomes key; typing goes to Finder). The agent installs a session
   event tap (needs the Accessibility grant) and forwards keys over XPC **only** when a Peep
   preview is visible in the frontmost app's Quick Look panel (a floating-level window owned by
   the frontmost app whose size matches a reported preview). Intercepts ⌘F, ⌘G/⇧⌘G, ⌘A, ⌘C (with a
   selection), and every key while the find bar is open. Everything else passes through.
   It also forwards (without consuming) single clicks in the panel, which Quick Look would
   otherwise deliver ~0.5 s late (see Quick Look facts).
   It also opens links (sandbox forbids `NSWorkspace.open`) and fetches remote images (Quick
   Look's sandbox denies outbound connections even with `network.client`).
3. **Peep.app** — `Sources/App/HostApp.swift`. Opening it shows setup status (extension,
   agent, Accessibility) and can open any file in a viewer window with the same renderer.
   `Peep --register` (used by the installer) writes/reloads the LaunchAgent plist.

## Source map

| Path | What |
|---|---|
| `Sources/Core/Text/` | `TextBuffer` (padded bytes), `FileLoader` (incl. tail loads), `Decoder` (encodings/binary), `LineIndex` (SIMD), `Search` (SIMD), `SIMD.swift` helpers, `HexDump`, `JSONFormatter` (minified JSON), `JSONTree` (range-based JSON parse), `ByteOutput` (generated text), `Clock` |
| `Sources/Core/Lex/` | `TokenStream` (SoA tokens), `KeywordTable`, `ByteClass`, `CLike` engine + `Specs` (most languages), `Formats` (JSON, YAML, TOML/INI, XML/HTML, CSS, shell, diff, Makefile, Dockerfile, markdown source), `Language` (detection table, wrapper suffixes, dispatch), `CodeOutline` (declarations -> sidebar entries) |
| `Sources/Core/Markdown/` | `BlockParser` (CommonMark/GFM blocks), `InlineParser` (inlines, HTML subset, reference table), `MarkdownParser` (assembly), `MarkdownModel` (flat output; links/images as ranges in a string store), `Buffers` (raw growable arrays, stack arena, SIMD newline offsets), `Entities`, `Notebook` (.ipynb -> Markdown) |
| `Sources/Core/Archive/` | `ArchiveListing` (entries SoA, folder tree, text + tokens), `ZipReader` (central directory), `TarReader` (headers, pax/GNU), `Decompress` (gzip/xz streams, single compressed files) |
| `Sources/Render/` | `DocumentView` (tiles, selection, mouse), `CodeContent`, `MarkdownContent` + `MarkdownLayout` (progressive, parallel) + `TextBox`, `ImageStore`, `OutlineView` (TOC), `FindBar`, `PreviewView` (composition, key handling, truncation notice), `Theme`, `Document` (file → content pipeline: archives, compressed files, SQLite, notebooks, minified JSON, logs), `SQLitePreview`, `Prewarm` (launch-time warm-up) |
| `Sources/Preview/` | `main.swift` (starts `Prewarm`, then `NSExtensionMain`), principal class `PreviewViewController`, `AgentClient` |
| `Sources/App/` | Host app, agent |
| `Dev/` | `peep-dev` tool: `render`, `bench`, `lexbench`, `parsebench`, `mddump`, `mdbench`, `firstpaint`, `findbench`, `smoke`, `tokens`, `layout`, `types`, `icon` |
| `Tests/` | Zero-dependency test harness + tests (text, search, lexers, markdown) |
| `Examples/` | A sample of every supported type for looking at by hand (see its README); binaries come from `Scripts/make-examples.sh` |
| `Bundle/` | Info.plists, entitlements |
| `Scripts/` | build/test/dev/profile/signing/type generation |

`Core` imports no Foundation (keep it that way: plain Swift + SIMD). `Render` uses AppKit/Core Text.

## Commands

```sh
Scripts/build.sh install     # release build, sign, install to /Applications, register, reload agent
Scripts/test.sh [filter]     # debug build of Core + Tests, run   (CONFIG=release for -O)
Scripts/dev.sh render <file> out.png [--dark] [--size WxH] [--scroll Y] [--select a:b] [--find q] [--wait s]
Scripts/dev.sh bench <files...>       # pipeline stage timings (best of N)
Scripts/dev.sh lexbench <file> [N]    # lexer-only throughput
Scripts/dev.sh layout <file.md> [w]   # markdown block/box dump (+ geometry self-check)
Scripts/dev.sh firstpaint <files...>  # main-thread cost to first frame: open/show/layout/draw
Scripts/dev.sh smoke <dirs/files...>  # open+draw+scroll+find every file; crashes, geometry, slowest
Scripts/dev.sh parsebench <file.md|dir> [N]   # markdown parse throughput (dir: MB/s by file size, slowest files)
Scripts/dev.sh mddump <outdir> <files/dirs...>  # full dump per parsed .md: diff -r old/new dumps around parser changes
Scripts/dev.sh findbench <file> <query...>  # raw search vs full find path per query
Scripts/dev.sh jumpbench <files...>        # outline jump cost (scroll + tile draws), flashes, highlighted row
Scripts/dev.sh symbols <files...>          # code outline entries as the sidebar shows them
Scripts/profile.sh .build/release/peep-dev lexbench <file> 400   # Instruments Time Profiler summary
FOCUS=CLike.lex python3 Scripts/profile.py <trace>               # hot instruction offsets
Scripts/gen-types.sh         # regenerate QLSupportedContentTypes after adding extensions
Scripts/make-examples.sh [--large]  # regenerate Examples/ binaries (deterministic); --large: huge files in Examples/Large (ignored)
Scripts/setup-signing.sh     # one-time per machine: local code-signing identity
```

Visual checks: `Scripts/dev.sh render` produces PNGs of the real view stack; look at them.
End-to-end checks need Finder: select a file, Space, ⌘F (computer-use tools work for this).

No SwiftPM/Xcode project: `swiftc` compiles `Sources/Core` + `Sources/Render` *into* each binary
as one whole module (full cross-file optimization). Release flags: `-O -wmo
-enforce-exclusivity=unchecked -target-cpu apple-m4`. The Command Line Tools are the default
toolchain (`DEVELOPER_DIR`); Xcode (for Instruments) is also installed.

## Performance rules (learned the hard way)

- Text is UTF-8 bytes in a `TextBuffer` with 64 zero bytes of padding: SIMD loops may read past
  the end; scalar scanners may rely on a 0 sentinel. Never use `String`/`Character` in hot paths.
- SIMD in plain Swift (`SIMD16<UInt8>`) compiles to good NEON **only if**:
  - comparisons are vector-vs-vector (`v .< SIMD16(repeating: 0)`). A scalar RHS (`v .< 0`)
    scalarizes to a per-lane loop through the stack (30× slower — this happened);
  - you avoid `any()`, `min()`, `max()`, `wrappedSum()` (out-of-line calls). Use
    `nibbles(mask) != 0` (cmeq + shrn + fmov), or NEON intrinsics via
    `import _Builtin_intrinsics.arm.neon` (`vqtbl1q_u8`, `vpaddq_u8`, `vtstq_u8`).
  - Verify with `swiftc -O -emit-assembly` (see `Scripts/profile.py` for hot spots).
- `NibbleSet` classifies 16 bytes with two `tbl` lookups; but its latency loses to a scalar
  loop on 1–6 byte runs. Lexers check a few bytes scalar first, then go SIMD.
- Token storage is struct-of-arrays (`ends: [UInt32]`, `kinds: [UInt8]`); starts are implied.
- Big files: lex a 256 KB prefix synchronously, the rest on a background P-core, swap tokens.
- Rendering: tiles (512 pt, layer-backed, opaque) draw once; scrolling moves layers. ASCII code
  lines draw via a glyph table + `CTFontDrawGlyphs` (positions are in *text space*: negate y
  because the text matrix flips). Non-ASCII lines use `CTLine`.
- In the flipped context, Core Text baseline offsets are inverted (superscript = negative).
- `CTLineDraw` advances `ctx.textPosition`; reset it after, or the next glyph-table line draws
  offset.
- Markdown layout is progressive: blocks are laid out synchronously until the viewport (+160
  pt) is covered, the rest get estimated heights and are laid out in parallel in the
  background, then the whole list is re-stacked. Consequences:
  - Anything that re-stacks must place boxes *absolutely* (`TextBox.place(top:)`); relative
    translation drew the prefix at 2× its y once background layout landed (this shipped).
  - Exact geometry below the prefix needs `finishLayout()` (anchors, find reveal, outline
    clicks); `willShow` calls it when the *visible* rect reaches an estimated region. Never
    pass the tile margin to `willShow`: that silently made first paint lay out everything.
  - The background job starts *after* the first frame: its threads hold Core Text's per-font
    shaping lock, and a first draw competing with them was 5× slower.
- First-paint budget is measured with `peep-dev firstpaint`, not guessed. `NSVisualEffectView`
  cost ~14 ms there (CPU compositing in `renderInContext`); use plain colors unless something
  is actually behind the view.
- Text in small views (outline rows, labels) is Core Text lines + `CTLineDraw`, never
  `NSAttributedString.draw` (TextKit: 6 ms for one screen of outline rows).
- Code lines are classified/shaped/drawn only up to the prefix that can reach the tile's right
  edge; a long line with one non-ASCII character must not be shaped whole per tile.
- Core Text applies a paragraph style's extra line height above the first line too; `TextBox`
  shifts it away so a box starts at its first line's top.
- Markdown parse is copy-once: block content is parsed straight from the source when its lines
  are contiguous there (else gathered once), inline text nodes are byte ranges into that input,
  and emit copies source -> output with inline 16-byte vector copies. That input must be padded
  (the source TextBuffer or a `ByteBuf`): the tokenizer's SIMD skip and the copies read up to 16
  bytes past the end. Link/image strings are ranges in one store (`MDLinks`/`MDImages` make
  Strings on access); reference labels are normalized into a reused buffer and probed in an
  open-addressing table. Working buffers are `RawArray`/`ByteBuf` in a per-parse stack arena
  (Swift `Array.append` checks uniqueness through a runtime call per append).
- Markdown parse hot spots were never the obvious ones: per-paragraph scratch copies (reference
  definitions), header-cell splitting on every second line (tables), `Character`-level Unicode
  checks (slugs: a Unicode slug per heading cost more than parsing it, so `headingSlugs()` is
  computed on demand), `utf8.contains(0xEF)` (a generic iterator that also matches every emoji
  with a variation selector), `Language.named` hashing per code fence (SipHash: now a
  multiply-shift table), a libc `memmove` per 30-byte URL. Prefilter on bytes before doing real
  work; measure the whole corpus (`parsebench <dir>`), not one file.
- A search for each line's end mispredicted its exit on most lines; `newlineOffsets` finds all
  of them in one branch-light pass (64-byte masks, flattened as in `LineIndex`).

## Previews beyond source and Markdown

- **Archives** (`ArchiveKind`): never loaded; ZIP from the central directory, tar from headers,
  tar.gz/xz streamed. 25 ms budget, then the background pass swaps in the full listing
  (`CodeContent.replace` + `onContentReplaced`); renders over 25k entries are deferred. The
  tree is built from each entry's folder chain (no global sort: that was 344 ms for 150k).
- **Single .gz/.xz** files preview their content (40 ms decompression budget).
- **Notebooks** become Markdown (`Notebook`); outputs are ```` ```output ```` fences, drawn
  with a rule instead of the code background (`MDBlock.output`).
- **SQLite**: read-only + `immutable` URI; never plain `count(*)` (uninterruptible B-tree
  walk), count to 100k in an interruptible scan, else `max(rowid)`.
- **Minified JSON** is re-indented (average line > 200 bytes); progressive above 1 MB.
- **Logs** open at the end; >64 MB logs load their last 64 MB.
- **Wrapper suffixes** (`.dist`, `.example`, `.in`, `.j2`, ...) are looked through by
  `Language.detect`; each wrapper is one registered type.
- **Code outline**: the lexer records declarations (`TokenStream.addSymbol`) from declaring
  keywords, Go receivers, and keywordless C-family definitions; `CodeOutline` titles and levels
  them. Sidebar for files of 60+ lines with 3+ symbols.

## Benchmarks and the bar

The owner set pierre's Wasm `highlights` and `words` (pierrecomputer/pierre) as the *minimum*
bar. Their published numbers (Apple M4 Pro / M5 Max): highlights TS → tokens 225 MiB/s
(→ HTML 354; HTML/JSONC ~1,000); words Markdown → HTML ~930 MiB/s on the 211 KiB GFM spec,
500–1,280 MiB/s on small files. Ours (`peep-dev lexbench` / `parsebench`, best of N; Peep in
MB/s = 10^6 B/s, the bar in MiB/s = 2^20 B/s, so 930 MiB/s = 975 MB/s):

| Input | Peep | Bar |
|---|---:|---:|
| TypeScript (93 KB) lex | 1,760 MB/s | 225 MiB/s |
| Java / Swift / Rust lex | 1,600–2,700 MB/s | — |
| C (520 KB) / lodash.js lex | 630 / 1,160 MB/s | — |
| minified jQuery lex | 318 MB/s | — |
| CommonMark spec (206 KB) parse | 1,610 MB/s | ~930 MiB/s |
| link-list README (78 KB) parse | 1,140 MB/s | — |
| 3 KB README (HTML + ref defs) parse | 800 MB/s | 500+ MiB/s |
| 653 real .md files by size: < 2 KB / 2–8 / 8–64 / ≥ 64 KB | 1,000 / 1,190 / 1,190 / 1,070 MB/s | 500+ MiB/s (small) |

Both clear the bar. Markdown parsing was ≈3× short (349 MB/s on the spec) until the
copy-once redesign described under Performance rules (the old parser on the same 653 files:
212 / 261 / 280 / 284 MB/s). Slowest left: files under ~200 bytes (fixed cost ≈0.3 µs per
parse: the document object, two TextBuffers, result arrays), nested-list changelogs (~450 MB/s:
container matching per line, a block per 10-byte item) and a 1.3 KB kitchen-sink README with
every feature once (~400 MB/s). The block pass (per-line container/leaf dispatch) is now the
largest share of the spec; inline tokenize + emit are next.

The corpus behind these numbers is local (not in the repo): a few hundred .md files from
package caches and Homebrew, plus the spec. Any parser change must keep `mddump` output
identical over such a corpus and over random/mutated documents (or explain each difference
as a fix with a test), and stay clean under `-sanitize=address`.

## Quick Look facts (verified on macOS 27)

- QL matches **exact** UTIs only (no conformance). Many extensions have *dynamic* UTIs
  (`dyn.a…`), computed in `Dev/main.swift:dynamicUTI`. Extensionless files are `public.data`.
- Apple's built-in previewers win for some standard types whatever we list (measured in Finder):
  `.txt` (`public.plain-text`), `.csv` (the system Office generator claims it), `.pdf`, `.html`,
  `.svg`. For others Apple also claims (JSON, XML) and everything else, Peep wins. So Peep doesn't
  build features only the losing types would need (a CSV/TSV table view would only ever reach
  TSV). Check a type with: reveal a file in Finder's column view and look for Peep's `prepare` log.
- Keyboard: see Processes. Never call `makeFirstResponder` (another app's extension broke
  Finder's arrow keys that way); `DocumentView.acceptsFirstResponder` is false.
- Sandbox: no network (agent fetches), no `NSWorkspace.open` (agent opens), reading files next
  to the previewed one needs the `absolute-path.read-only` temporary exception (granted for `/`).
- Killing the extension while a panel shows it (every install does) leaves that panel in a
  "failed during preview" state; close it and move the selection to recover. Not a bug.
- Remote view frames reported to the extension are synthetic; only sizes are meaningful.
- Clicks reach the extension **~510 ms late** (measured against the agent's event tap on the
  same clock): Quick Look holds every mouse-down/up for the double-click interval, because a
  double-click in the panel opens the file in its default app. Selection drags are unaffected
  in feel, but table-of-contents clicks were. The agent therefore also taps left mouse-down
  (never consuming it) and forwards single clicks inside the panel with their timestamp;
  `PreviewView.earlyClick` handles outline rows at once (~1 ms) and drops the late copy by
  timestamp. The panel-to-view offset is calibrated from the late copy (5, 38 pt on macOS 27).
  Measure with `peep-dev jumpbench` (in-process cost) and the "early click handled" debug log.
- Cursor: only cursor *rects* reach the screen (`NSCursor.set()` is dropped). The rect's cursor
  applies when the mouse enters it; a panel opening under a still mouse shows the arrow until
  it crosses a rect edge. Overlapping rects show the arrow, and moving between adjacent rects
  with different cursors often leaves the arrow (exit/enter arrive in no fixed order). So:
  one I-beam rect over the visible area, refreshed when the visible rect changes (the remote
  window doesn't re-ask after sizing); no pointing hand over links. To measure, sample
  `NSCursor.currentSystem` from a separate process while moving the mouse.

## Signing, permissions, agent

- `Scripts/setup-signing.sh` creates a self-signed identity ("Peep Local Signing") in a
  dedicated keychain; `build.sh` signs with it (falls back to ad-hoc). Stable designated
  requirement ⇒ the Accessibility grant survives rebuilds. Ad-hoc signing breaks it every build.
- The agent is a plain LaunchAgent in `~/Library/LaunchAgents/com.lingrino.peep.agent.plist`,
  **not** `SMAppService`: SMAppService pins the executable's cdhash in a launch constraint,
  which every local rebuild violates (`OS_REASON_CODESIGNING`, then launchd drops the job).
- Install updates the bundle in place (`rsync --delete`), never delete+copy.
- XPC peers accepted by the agent must match our signing certificate + extension identifier.
  Peer connections don't inherit the listener's queue: set the target queue to main.

## Debugging

- Logs: `log stream --style compact --predicate 'subsystem == "com.lingrino.peep"'`
  (use `/usr/bin/log` from zsh). Crash reports: `~/Library/Logs/DiagnosticReports/Peep*.ips`.
- Each extension process logs "cold start: first prepare began N ms after process start"
  once (~150 ms is dyld + AppKit + Quick Look's view-service handshake, before any of our
  code). `Prewarm` (started from `Sources/Preview/main.swift`) uses that window to build
  fonts, glyph tables and lookup tables on a background thread: cold first prepare 9 → 3 ms.
- Debug-level lines (`--level debug`) include each preview's first paint ("first paint: N
  tiles drawn in X ms, Y ms after setContent") and markdown layout timings.
- Agent state: `launchctl print gui/$(id -u)/com.lingrino.peep.agent`.
- Extension registration: `pluginkit -m -v -i com.lingrino.peep.preview` (`+` = enabled).
- Another QL extension claiming the same types (e.g. Peek) can win; disable it with
  `pluginkit -e ignore -i <id>`.

## Adding a language

1. Add a `Language` case + `name`, extensions in `extensionTable` (and `byName` for special
   file names), and dispatch in `lex`.
2. C-like syntax: add a `CLikeSpec` in `Specs.swift` (keyword groups: K/D/T/C/B/Y). Otherwise a
   lexer in `Formats.swift`.
3. Add a test in `Tests/LexTests.swift` and a sample in `Examples/Code/`; run `Scripts/gen-types.sh`; rebuild.

## Conventions

- Swift 6 language mode. Main-thread UI types are `@MainActor`; buffers shared with background
  work are `@unchecked Sendable` final classes with immutable contents.
- Hot loops: `&+`, unsafe pointers, no closures/allocations per element, `@inline(__always)` on
  tiny helpers. Comment *why* for every non-obvious performance trick.
- Tests: `Tests/*.swift`, registered in `Tests/main.swift`. Fuzz-ish robustness tests exist for
  lexers and markdown — keep them passing.
- Commit messages: imperative summary + body explaining why; end with the co-author trailer.
