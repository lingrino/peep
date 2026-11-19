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

## Workflow (start here, especially after time away)

1. `Scripts/check.sh` (~35 s): tests (debug and release), zero compiler warnings, both
   targets (and the `DIAG=1` variant), then the view checks over `Examples/` and the docs:
   smoke (open, draw, scroll, find, select every file; Markdown geometry), tile coverage,
   link hit testing, and hostile inputs (`Scripts/make-adversarial.py` -> `.build/adversarial`:
   files that once crashed, trapped, hung or ran away with memory; smoke with a time and
   memory budget). Run it first when coming back and after any macOS or toolchain update;
   it must pass before every commit. `--corpus` adds `.build/corpus` (`Scripts/make-corpus.sh`).
   A new class of hostile input (a crash, a super-linear case) gets a generator line there.
2. Measure the change against the last commit (or `--rev R`), on this machine:
   - renders: `Scripts/compare.sh renders [files]` pixel-diffs every example; every
     difference must be intended and said in the commit message;
   - speed: `Scripts/compare.sh bench <peep-dev command...>` (alternating rounds);
   - parser changes: `Scripts/make-corpus.sh`, `mddump` with the old (`Scripts/baseline.sh`)
     and new `peep-dev` + `diff -r`, `parsebench .build/corpus/files`, ASAN (see Benchmarks);
   - Quick Look itself (when it shows previews, stalls in its code paths): `DIAG=1
     Scripts/build.sh install`, `peep-dev panelwatch`, the log stream (see Debugging).
3. `Scripts/build.sh install`, try it in Finder (computer use works), then branch, commit
   and open a PR: `main` takes changes only through PRs whose CI passes, each one is
   squash-merged, and every merge is a release (see CI and releases).

Not here on purpose: a formatter or linter (the bar is zero warnings; a formatter would churn
hand-laid-out hot loops), checked-in golden images (macOS font updates move pixels; compare
against a revision on the same machine instead), SwiftPM/XCTest (see Commands). CI runs
`check.sh`, but steps 2 and 3 need this Mac (Finder, Quick Look, the Accessibility grant, a
quiet machine for timing): CI passing is not the bar. `peep-dev` is offline: remote images
never load there (`render --remote` fetches them), so checks and benchmarks are deterministic.

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
   timings>` (subsystem `com.lingrino.peep`, info level: not persisted, file names stay
   off disk), and once per process its cold-start time.
2. **Keyboard agent** — `Sources/App/Agent.swift`. Quick Look previews *never* receive key
   events (the panel never becomes key; typing goes to Finder). The agent installs a session
   event tap (needs the Accessibility grant) and forwards keys over XPC **only** when a Peep
   preview is visible in the frontmost app's Quick Look panel (a floating-level window owned by
   the frontmost app whose size matches a reported preview). Intercepts ⌘F, ⌘G/⇧⌘G, ⌘A, ⌘C (with a
   selection), and every key while the find bar is open. Everything else passes through.
   It also forwards (without consuming) single clicks in the panel, which Quick Look would
   otherwise deliver ~0.5 s late (see Quick Look facts).
   It also opens links (sandbox forbids `NSWorkspace.open`) and fetches remote images (Quick
   Look's sandbox denies outbound connections even with `network.client`). The extension
   renders untrusted files, so the agent trusts it with little: `open` is honoured only within
   3 s of a click the tap saw in the panel, and goes through `LinkPolicy` (documents open,
   anything that could run is revealed in Finder); fetches go through `RemoteFetch` (https,
   public hosts only, also on redirects; no cookies; streamed with a size cap and timeouts).
   Accessibility calls have a 0.25 s messaging timeout (they share the tap's thread: a busy
   Finder would otherwise hold every keystroke system-wide for up to 6 s).
   And it shows the copy-path button after the panel's title (`TitleButton`): the title bar is
   Quick Look's, so the button is a tiny non-activating window of the agent's (activation policy
   `.accessory`), placed from the title text's Accessibility frame (`AXStaticText` in the
   panel's title bar; hidden when a narrow panel leaves no room before its controls, or while
   the panel is dragged or resized). It shows for any previewer's file in Finder's panel and
   for Peep previews anywhere. The path: a Peep preview's state message, else Finder's
   selected item named like the panel's title, looked up on click (Accessibility gives Finder
   items a file reference `AXURL`; the panel itself exposes no path; in list view Finder's
   focus is the panel, so its main window is searched). Re-placed once input pauses after
   state messages, keys and clicks in Finder (AX calls are served on Finder's main thread:
   not per key repeat), mouse-up, and a 0.5 s poll. Its window is the agent's (a launchd process, not an app):
   find it with `CGWindowListCopyWindowInfo` (owner "Peep"), whose bounds are in points, while
   a computer-use screenshot's frame may be scaled (0.907x on one display): click where a
   zoomed screenshot shows the button, then check `pbpaste`.
3. **Peep.app** — `Sources/App/HostApp.swift`. Opening it shows setup status (extension,
   agent, Accessibility) and can open any file in a viewer window with the same renderer.
   `Peep --register` (used by the installer) writes/reloads the LaunchAgent plist. Opening
   the installed copy registers the agent too: that is how a brew install starts it.

## Source map

| Path | What |
|---|---|
| `Sources/Core/Text/` | `TextBuffer` (padded bytes), `FileLoader` (incl. tail loads), `Decoder` (encodings/binary), `LineIndex` (SIMD), `Search` (SIMD), `SIMD.swift` helpers, `HexDump`, `JSONFormatter` (minified JSON), `JSONTree` (range-based JSON parse), `ByteOutput` (generated text), `Clock` |
| `Sources/Core/Lex/` | `TokenStream` (SoA tokens), `KeywordTable`, `ByteClass`, `CLike` engine + `Specs` (most languages), `CLikeExtras` (one language's literals: Ruby/Perl quote-likes and heredocs, sigils, C# raw strings, tagged templates), `Formats` (JSON, YAML, TOML/INI, XML/HTML, CSS, shell, diff, Makefile, Dockerfile, PHP, markdown source), `Language` (detection table, wrapper suffixes, dispatch), `CodeOutline` (declarations -> sidebar entries) |
| `Sources/Core/Markdown/` | `BlockParser` (CommonMark/GFM blocks), `InlineParser` (inlines, HTML subset, reference table), `MarkdownParser` (assembly), `MarkdownModel` (flat output; links/images as ranges in a string store), `Buffers` (raw growable arrays, stack arena, SIMD newline offsets), `Entities`, `Emoji` + generated `EmojiTable` (GitHub shortcodes), `Notebook` (.ipynb -> Markdown) |
| `Sources/Core/Archive/` | `ArchiveListing` (entries SoA, folder tree, text + tokens), `ZipReader` (central directory), `TarReader` (headers, pax/GNU), `Decompress` (gzip/xz streams, single compressed files) |
| `Sources/Render/` | `DocumentView` (tiles, selection, mouse), `CodeContent`, `MarkdownContent` + `MarkdownLayout` (progressive, parallel) + `TextBox`, `ImageStore`, `RemoteFetch` (remote image policy and limits), `OutlineView` (TOC), `FindBar`, `PreviewView` (composition, key handling, truncation notice), `Theme`, `Document` (file → content pipeline: archives, compressed files, SQLite, notebooks, minified JSON, logs), `SQLitePreview`, `Prewarm` (launch-time warm-up) |
| `Sources/Preview/` | `main.swift` (starts `Prewarm`, then `NSExtensionMain`), principal class `PreviewViewController`, `AgentClient`, `Diag` (`DIAG=1` builds only) |
| `Sources/App/` | `HostApp` (setup status, viewer windows), `Agent` (XPC, event tap, link opening, image fetching), `Links` (`LinkPolicy`: what a clicked link may open), `TitleButton` (copy-path button) |
| `Dev/` | `peep-dev` (`Scripts/dev.sh` with no arguments lists the commands): `Render`, `Checks` (exit 1 on problems), `Bench`, `Dumps`, `Panel` (live Quick Look timing) |
| `Tests/` | Zero-dependency test harness + tests (text, search, lexers, markdown, archives, notebooks) |
| `Examples/` | A sample of every supported type for looking at by hand (see its README); binaries come from `Scripts/make-examples.sh` |
| `Bundle/` | Info.plists, entitlements |
| `Scripts/` | build, test, check, dev, compare/baseline, corpus, profile, signing, release, type/emoji/example generation |
| `.github/` | workflows: `validate` (PR checks), `release` (every merge to main), `review`; `renovate.json` at the root |

`Core` imports no Foundation (keep it that way: plain Swift + SIMD). `Render` uses AppKit/Core Text.

## Commands

```sh
Scripts/check.sh [--corpus]  # everything that must pass before a commit (see Workflow)
Scripts/build.sh install     # release build, sign, install to /Applications, register, reload agent
DIAG=1 Scripts/build.sh install   # + extension diagnostics: main-thread stalls, when QL shows previews
Scripts/test.sh [filter]     # debug build of Core + Tests, run   (CONFIG=release for -O)
Scripts/compare.sh renders [--rev R] [files...]     # pixel diff vs a revision (default HEAD)
Scripts/compare.sh bench [--rev R] <peep-dev args>  # alternating benchmark rounds vs a revision
Scripts/baseline.sh [rev]    # peep-dev built at a revision (cached in .build/baseline)
Scripts/make-corpus.sh [N]   # Markdown corpus from package caches into .build/corpus
Scripts/dev.sh render <file> out.png [--dark] [--size WxH] [--scroll Y] [--select a:b] [--find q] [--wait s]
Scripts/dev.sh bench <files...>       # pipeline stage timings (best of N)
Scripts/dev.sh lexbench <file> [N]    # lexer-only throughput
Scripts/dev.sh layout <file.md> [w]   # markdown block/box dump (+ geometry self-check)
Scripts/dev.sh firstpaint <files...>  # main-thread cost to first frame: open/show/layout/draw (+ markdown background layout)
Scripts/dev.sh showcost <files...>    # on-screen show + CA commit, and growing the view during background layout
Scripts/dev.sh smoke <dirs/files...>  # open+draw+scroll+find every file; crashes, geometry, slowest
Scripts/dev.sh parsebench <file.md|dir> [N]   # markdown parse throughput (dir: MB/s by file size, slowest files)
Scripts/dev.sh mddump <outdir> <files/dirs...>  # full dump per parsed .md: diff -r old/new dumps around parser changes
Scripts/dev.sh findbench <file> <query...>  # raw search vs full find path per query
Scripts/dev.sh jumpbench <files...>        # outline jump cost (scroll + tile draws), flashes, highlighted row
Scripts/dev.sh tilecheck <files...>        # random jumps/overscroll/resizes; visible rect always covered by tiles
Scripts/dev.sh linkcheck <files.md...>     # every link resolves from a click on it
Scripts/dev.sh symbols <files...>          # code outline entries as the sidebar shows them
Scripts/dev.sh imgdiff <a.png> <b.png>     # pixel comparison (exit 1 if they differ)
Scripts/dev.sh panelwatch [seconds]        # key presses -> Quick Look panel appear/settle times, live
Scripts/profile.sh .build/release/peep-dev lexbench <file> 400   # Instruments Time Profiler summary
FOCUS=CLike.lex python3 Scripts/profile.py <trace>               # hot instruction offsets
Scripts/gen-types.sh         # regenerate QLSupportedContentTypes after adding extensions
Scripts/gen-emoji.py <github.json>  # regenerate EmojiTable.swift (emojibase-data en/shortcodes/github.json)
Scripts/make-examples.sh [--large]  # regenerate Examples/ binaries (deterministic); --large: huge files in Examples/Large (ignored)
Scripts/setup-signing.sh     # one-time per Mac: the Developer ID for local builds (see Signing)
Scripts/release.sh           # what CI publishes: .build/dist/ zip + cask (not notarized locally)
PEEP_SIGN_IDENTITY=- Scripts/build.sh   # ad-hoc build, without the maintainer's certificate
```

Visual checks: `Scripts/dev.sh render` produces PNGs of the real view stack; look at them.
End-to-end checks need Finder: select a file, Space, ⌘F (computer-use tools work for this).

No SwiftPM/Xcode project: `swiftc` compiles `Sources/Core` + `Sources/Render` *into* each binary
as one whole module (full cross-file optimization). Release flags: `-O -wmo
-enforce-exclusivity=unchecked -target-cpu apple-m4`. The Command Line Tools are the default
toolchain (`DEVELOPER_DIR`); CI builds with Xcode (the workflows' `DEVELOPER_DIR`), whose Swift
should match the CLT's. `-target-cpu apple-m4` only tunes scheduling today: built for
`apple-m1` and `apple-m4`, peep-dev used the same 165 instruction mnemonics (2026-11), so
releases also run on older Apple Silicon and on CI's runners. A compiler that starts using
M4-only instructions would make CI's `check` crash (SIGILL) on older runner hardware.

## Performance rules (learned the hard way)

- Text is UTF-8 bytes in a `TextBuffer` with 64 zero bytes of padding: SIMD loops may read past
  the end; scalar scanners may rely on a 0 sentinel. Never use `String`/`Character` in hot paths.
- Every `TextBuffer` the renderer gets is *valid* UTF-8 (byte -> UTF-16 maps depend on it).
  Loads cut short (size limits, time budgets, log tails, JSON prefixes) drop the partial
  character at each end (`Decoder.completeEnd`, `continuationBytes`); archive names use the
  decoder's strict rule (`sequenceLength`) with a Latin-1 fallback.
- Hostile input must stay linear: a crash or hang takes down the shared preview process, and
  selecting a file in Finder's column view is enough to open it.
  - Native recursion is bounded: `TokenStream.nesting` (32 lexer levels: interpolation holes,
    tagged templates, heredocs, shell `$(`), `BlockParser.maxNesting` (100 containers).
  - A scan that may be retried from a later start is capped (32 link-destination parens,
    `CLike.maxParens`, `maxDelimiterRun`) or remembers its failure (`titleOpenEnd`,
    `tickLast`, `knownRegex`, `linkFloor`).
  - Output is budgeted: `tablePadding` (cells padded into short table rows), `nestedAltBudget`,
    formatted JSON (4 x the largest load, a note line at the cut), archive listings.
  - Numbers read from files are untrusted: `Int(exactly:)`, overflow-free bounds checks
    (`a > n - b`, not `a + b > n`), sizes never allocated before they're checked.
  - Test a new scanner with repeated-opener input at two sizes (4x the input should cost 4x
    the time), and add the case to `Scripts/make-adversarial.py`.
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
- `CLike.lex`'s main loop is at the edge of register pressure: one more loop-carried variable
  slowed every language ~15%, and reading spec options on common bytes (`"` `=` `<`) cost Python
  8%. New behavior goes in rare branches, behind a local gate (`anyDialect`, `hint != 0`), reading
  options from `s` there; state that would be one more variable is recomputed by looking back
  (`expressionKeywordBefore`). Compare with alternating runs of the old binary (`Scripts/compare.sh bench`).
- Rendering: tiles (512 pt, layer-backed, opaque) draw once; scrolling moves layers. A tile is
  "placed" by its row/col: parked (recycled) tiles must reset them, or a slot looks covered
  while its tile has a zero frame (blank bands after elastic overscroll + jumps; `tilecheck`). `updateTiles` asks for
  exact geometry (`willShow`) *before* computing the wanted rect and ignores the nested call
  that growing the document triggers: the other order parked the tiles the nested call had
  placed (a blank row past the estimated end; `tilecheck`'s deterministic pass). ASCII code
  lines draw via a glyph table + `CTFontDrawGlyphs` (positions are in *text space*: negate y
  because the text matrix flips). Non-ASCII lines use `CTLine`.
- In the flipped context, Core Text baseline offsets are inverted (superscript = negative).
- `CTLineDraw` advances `ctx.textPosition`; reset it after, or the next glyph-table line draws
  offset.
- Markdown layout is progressive: blocks are laid out synchronously until the viewport (+160
  pt) is covered, the rest get estimated heights; a background pass measures them in
  parallel and swaps in exact heights (`restack`: positions only, O(blocks), no Core Text).
  Core Text frames exist only for blocks that are drawn or queried (`placed(k)` builds and
  places one), and are dropped again far from the viewport (`evictFar`). The background pass
  keeps heights only: keeping a 10 MB document laid out whole was ~800 MB of frames per
  preview (two previews: 1.6 GB), freeing them stalled the main thread 0.2–0.35 s whenever
  the preview moved on, and Quick Look showed the preview only once the pass finished
  (~500 ms after prepare). Consequences:
  - Boxes are placed *absolutely* (`TextBox.place(top:)`); relative translation drew the
    prefix at 2× its y once background layout landed (this shipped).
  - Background jobs run on one process-wide `LayoutPool` (P-cores − 2 threads, newest job
    first, default QoS). Finder's column preview and the Space panel each lay out their own
    copy; a thread set per job (20 threads on 16 cores) starved Quick Look's own work in the
    process and the panel appeared only when the column pane's job ended. Utility QoS is
    throttled (1.6 s instead of 0.4 for 10 MB). Jobs are cancelled when their content goes
    away (re-layout, `isolated deinit`) and claim small chunks dynamically (a static stride
    left efficiency-core threads finishing last).
  - Past ~10 threads Core Text's glyph-storage retain/release lock caps throughput; and every
    attribute value shared by all threads (one palette `CGColor`) made atomic refcounts
    contend: books keep their own color instances.
  - Exact geometry below the prefix needs `finishLayout()` (anchors, find reveal, outline
    clicks). When the *visible* rect reaches an estimated region, `willShow` lays out just the
    next blocks in order on the main thread (extending the exact prefix); it used to call
    `finishLayout()`, which stalled Quick Look's panel 0.5–2.5 s on a 10 MB document whenever
    it opened taller than the preview was prepared at (`peep-dev showcost`, `render --early`).
    Never pass the tile margin to `willShow`: that silently made first paint lay out everything.
  - The background job starts *after* the first frame: its threads hold Core Text's per-font
    shaping lock, and a first draw competing with them was 5× slower.
  - Drawing skips blocks whose height is still an estimate (their tiles are redrawn when it
    is exact); draw also includes the block just below the rect (quote bars reach up into the
    gap above their block).
  - Layout threads each use their own `FontBook` (`main`, `workers[w]`). Core Text serializes
    OpenType shaping per font *face* (every size/weight of `NSFont.systemFont` shares one lock),
    so threads on the system fonts ran one at a time. Books make their fonts from the font
    files (`FontFiles.ownFace`: own face, own lock; variation axes and cascade list copied, so
    layout is identical: renders match pixel for pixel). Then Foundation's process-wide
    attribute-dictionary uniquing lock was next: books keep per-style dictionaries uniqued
    once, set per run with `CFAttributedStringSetAttributes` (no per-link attribute: links are
    found by text offset, `linkRef`). Background layout of a 10 MB document: 1,245 -> 346 ms
    (frames kept); measuring only, with frames freed on the workers: ~400 ms, flat memory.
- First-paint budget is measured with `peep-dev firstpaint`, not guessed. `NSVisualEffectView`
  cost ~14 ms there (CPU compositing in `renderInContext`); use plain colors unless something
  is actually behind the view.
- Text in small views (outline rows, labels) is Core Text lines + `CTLineDraw`, never
  `NSAttributedString.draw` (TextKit: 6 ms for one screen of outline rows).
- Code lines are classified/shaped/drawn only up to the prefix that can reach the tile's right
  edge; a long line with one non-ASCII character must not be shaped whole per tile.
- Core Text applies a paragraph style's extra line height above the first line too; `TextBox`
  shifts it away so a box starts at its first line's top.
- Core Text line breaking is not greedy: it weighs the whole paragraph, and its cost is
  quadratic in the paragraph's length (100 KB: 0.41 s, 1 MB: 32 s). A frame is also bounded by
  its path height (1,000,000 pt: a 70,000-line code block was cut). So a box longer than 16K
  UTF-16 units is laid out as consecutive frames: cut after newlines (identical layout but for
  < 0.5 pt rounding), and inside a paragraph over 16K units in 16K windows whose last lines are
  re-laid out by the next window (breaks differ slightly from one frame's). Lines then carry
  their frame's offset (`lineBase`): Core Text string indices are per frame. Shorter boxes
  are one frame, exactly as before.
- Per-scroll work must not scan per entry: outline lookups bisect (a linear `lastIndex { }`
  over 100k headings was 2.4 ms per scroll event; each closure call also pays a main-actor
  executor check under Swift 6).
- Every CFAttributedString range is clamped to the string's length (`Utf16Map.range`):
  release CoreFoundation doesn't bounds-check and writes past its run array. Byte -> UTF-16
  maps assume valid UTF-8, which loaders guarantee; the clamp keeps a slip from being memory
  corruption.
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
- Rare syntax must not tax every document. Footnotes, alerts and emoji first cost 4.5–7.6%
  (corpus, by size bucket) and now ~3%; what mattered, measured by A/B builds:
  - Pass-2 helpers take the parsers as parameters and the output arrays `inout` from locals.
    Stored in a struct, the parsers were retained/released per parse (a fixed ~45 ns: −14% on
    a 24-byte file) and each append called the runtime uniqueness check.
  - `unowned(unsafe)` references are *worse* than strong `let`s: every method call through
    them gets a retain/release pair.
  - Copying arrays out of a struct at the end is a retain + release each; `swap` moves them.
  - Rare paths go out of line (`@inline(never)`) behind a cheap inline byte check (`[` then
    `^` before the footnote call: list items starting with a link are common), and per-block
    context work is gated by a counter (`openSpecial`).
  - A new byte field can grow a hot struct's stride (`Container` 24 -> 32): put it in padding.
  - Code in `CLike.lex`'s loop costs even when it never runs: a 3-instruction cap in the C#
    `$` branch slowed every C-family language 1-4%. Rare-branch work goes in `@inline(never)`
    helpers (`csharpDollar`, `swiftHole`). Likewise a check inside a hot loop that captures
    state in a nested function or closure keeps that state in memory: checks go between
    slices of work (JSON formatting: 9%; tar: ~100 ns per entry).
- Footnotes: definitions are containers (indent 4, like list items) found by the block pass;
  references number them on first use; their blocks render after the main text (an ordered
  list, smaller and muted, "↩" back-links). In-document anchors `#fn:N` / `#fnref:N:k` can't
  collide with heading slugs. Alerts: `> [!NOTE]` alone on the first line of an outermost
  quote; the title is a block of kind `.alertTitle`.

## Previews beyond source and Markdown

- **Archives** (`ArchiveKind`): never loaded; ZIP from the central directory, tar from headers,
  tar.gz/xz streamed. 25 ms budget, then the background pass swaps in the full listing
  (`CodeContent.replace` + `onContentReplaced`). The main thread renders a listing only
  within 25k entries, 4 MiB of names and 50k lines (60 entries with long nested names imply
  2 million folders); bigger ones show a placeholder first. Limits: 1M entries, 64 MiB of
  names, about 128 MiB of rendered text, 1 MiB long-name/pax payloads; the ZIP directory is
  read in 1 MiB chunks. Background work holds the `Document` weakly and stops when it goes
  away. The tree is built from each entry's folder chain (no global sort: 344 ms for 150k).
- **Single .gz/.xz** files preview their content (40 ms decompression budget). gzip members
  are decoded in turn; Apple's zlib reads ~64 KB ahead and never says where a DEFLATE stream
  ends, so the next member's header is found by its magic plus the previous member's ISIZE
  (more than 1024 members at under a KB of output each end the data).
- **Notebooks** become Markdown (`Notebook`); outputs are ```` ```output ```` fences, drawn
  with a rule instead of the code background (`MDBlock.output`).
- **SQLite**: read-only + `immutable` URI; never plain `count(*)` (uninterruptible B-tree
  walk), count to 100k in an interruptible scan, else `max(rowid)`.
- **Minified JSON** is re-indented (average line > 200 bytes); progressive above 1 MB.
  Output is capped (re-indenting grows text up to 82x): 4 MiB on the main thread, 4 x the
  largest load in the background, with a note line and a notice at the cut.
- **Logs** open at the end; >64 MB logs load their last 64 MB.
- **Wrapper suffixes** (`.dist`, `.example`, `.in`, `.j2`, ...) are looked through by
  `Language.detect`; each wrapper is one registered type.
- **Code outline**: the lexer records declarations (`TokenStream.addSymbol`) from declaring
  keywords (D/T; S = the keyword itself: `init`, `impl`, HCL blocks), Go receivers, keywordless
  C-family/Dart/C# definitions (only after a type, modifier or statement boundary, never after
  `return`/`new`), JS/TS class members and `const f = () =>`, column-0 rules (`CLikeSpec.lineStart`:
  Haskell/Elm signatures, Erlang clauses, labels, R), qualified names (`def self.x`, `fun T.x`).
  `CodeOutline` titles and levels them (Swift inits get argument labels; adjacent one-line clauses
  merge). Sidebar whenever there is an entry (any length) and the preview is 780+ pt wide. Check with `peep-dev symbols [--all]`.

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

Both clear the bar. On a 1,300-file corpus (package caches + Homebrew) parsing runs at
857 / 1,014 / 981 / 840 MB/s by the same size buckets (machine under load; HEAD before
footnotes/alerts/emoji measured 875 / 1,045 / 1,015 / 870 in the same runs). Markdown parsing was ≈3× short (349 MB/s on the spec) until the
copy-once redesign described under Performance rules (the old parser on the same 653 files:
212 / 261 / 280 / 284 MB/s). Slowest left: files under ~200 bytes (fixed cost ≈0.3 µs per
parse: the document object, two TextBuffers, result arrays), nested-list changelogs (~450 MB/s:
container matching per line, a block per 10-byte item) and a 1.3 KB kitchen-sink README with
every feature once (~400 MB/s). The block pass (per-line container/leaf dispatch) is now the
largest share of the spec; inline tokenize + emit are next.

The corpus behind these numbers is local (not in the repo): a few hundred .md files from
package caches and Homebrew, plus the spec; `Scripts/make-corpus.sh` gathers one (~1,200
files) into `.build/corpus`. Any parser change must keep `mddump` output
identical over such a corpus and over random/mutated documents (or explain each difference
as a fix with a test), and stay clean under `-sanitize=address`.

## Quick Look facts (verified on macOS 27)

- QL matches **exact** UTIs only (no conformance). Many extensions have *dynamic* UTIs
  (`dyn.a…`), computed in `Dev/Dumps.swift:dynamicUTI`. Extensionless files are `public.data`.
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
- The panel takes each preview's `preferredContentSize`. Every Peep preview asks for the
  same size: sized per file (code fitted its content), stepping through files with the panel
  open (arrow keys) stalled the extension's main thread 430–480 ms on some files. ViewBridge
  tears down the previous preview's service window with a synchronous WindowServer
  transaction (`-[NSViewServiceMarshal invalidate]` → `SLSConnectionSynchronizeSLSCATransaction`)
  that waited out the panel's resize. Finder skipped files meanwhile ("jumpy").
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

- Local builds sign with the same Developer ID as releases (no timestamp, not notarized),
  from a dedicated keychain (`~/Library/Keychains/developer-id.keychain-db`, password in
  `~/Library/Application Support/DeveloperID/`) that `Scripts/setup-signing.sh` fills from
  `github/keys/apple-developer` (AWS SSO); `build.sh` refuses to build without it unless
  `PEEP_SIGN_IDENTITY=-` (ad-hoc, CI). The maintainer's other Mac apps use the same keychain
  (a copy of the script with the same paths), so it is set up once per Mac. Every Developer
  ID signature has the same designated requirement (bundle id + team ID), so the agent's
  Accessibility grant carries across `brew upgrade` and `Scripts/build.sh install` and
  survives certificate renewals. Never switch local builds to ad-hoc or another identity,
  or change the bundle ids (`com.lingrino.peep`, `com.lingrino.peep.preview`) or the agent's
  label: that means granting Accessibility again. macOS 27 lists the grant under Privacy &
  Security → Device Control and Data Access. After a signing change the old entry stays
  but no longer matches: remove Peep there (−) and add /Applications/Peep.app again (+);
  switching the old entry on doesn't take. Without the grant there is no event tap, so no
  key forwarding, no early outline clicks (~0.5 s late) and no copy-path button; the
  agent logs `trusted=` at start. (Until 2026-11-16 builds used a
  self-signed "Peep Local Signing" identity; a Mac that still has
  `~/Library/Keychains/peep-signing.keychain-db` can delete it.)
- The agent is a plain LaunchAgent in `~/Library/LaunchAgents/com.lingrino.peep.agent.plist`,
  **not** `SMAppService`: SMAppService pins the executable's cdhash in a launch constraint,
  which every local rebuild violated when builds had no Team ID (`OS_REASON_CODESIGNING`,
  then launchd drops the job).
- `Scripts/build.sh install` updates the bundle in place (`rsync --delete`); `brew upgrade`
  replaces it. Either way the agent restarts itself (see CI and releases).
- XPC peers accepted by the agent must match our signing certificate + extension identifier.
  Peer connections don't inherit the listener's queue: set the target queue to main.

## CI and releases (`.github/workflows`)

- `validate`, on every PR. The main ruleset requires a PR (no direct pushes, no force
  pushes) and its jobs: `check` (`Scripts/check.sh`, plus `zsh -n` on the zsh scripts),
  `package` (a release dry run, ad-hoc signed, and `brew style` on the generated cask) and
  `scripts` (shellcheck on the bash scripts, actionlint). Runner label `xcode-27`: GitHub's
  macOS 27 arm64 image (images are named by Xcode major). Its default Xcode lags the SDK
  the deployment target needs, so the workflows set `DEVELOPER_DIR` to the Xcode this
  project builds with (27.2). CI's runners are slower and shared: `PEEP_SMOKE_BUDGET`
  raises the hostile-input time budget there.
- `review`: Claude reviews each PR (anthropics/claude-code-action).
- `release`, on every push to main: version 0.0.N, N = commits on main (squash merges, so
  every merge bumps it; `Scripts/build.sh` stamps it into both bundles with the git hash
  as `PeepRevision`). `Scripts/release.sh` builds, signs, notarizes (API key), staples,
  zips and writes the cask. With the Apple secrets it publishes GitHub release `v0.0.N`
  and `Casks/peep.rb` in lingrino/homebrew-tap; without them it keeps the ad-hoc zip as a
  run artifact only. Notarization can take ~40 min the first time: that's Apple.
- Secrets come from Terraform in lingrino/infra (`secrets_github.tf`, `local.mac_app_repos`:
  every Mac app the maintainer releases this way gets the same ones):
  `HOMEBREW_TAP_GITHUB_TOKEN`, and from AWS Secrets Manager `github/keys/apple-developer`:
  `APPLE_CERT_P12_BASE64`, `APPLE_CERT_PASSWORD` (Developer ID Application certificate),
  `APPLE_API_KEY_P8_BASE64`, `APPLE_API_KEY_ID`, `APPLE_API_ISSUER_ID` (App Store Connect
  API key for notarytool). Both belong to the team, not to Peep; fred's
  `scripts/store-release-secrets.sh` stores a renewed certificate, then infra's next apply
  hands it to every repo. Never create new ones or handle their values: ask the owner.
  The repo (`terraform/github/repo_peep.tf`: ruleset, required checks, allowed actions) is
  there too; the required checks must match `validate.yml`'s job names.
- Upgrades: `brew upgrade` swaps /Applications/Peep.app under the running agent. The agent
  watches the folder holding its bundle (FSEvents) and, once its executable is a different
  file, ends the extension processes still running the old code (Quick Look reuses them)
  and exits; launchd starts the new agent (KeepAlive). The cask has no `uninstall launchctl:`
  (brew runs uninstall stanzas on every upgrade, and nothing would register the agent
  again); `zap` removes the agent. A fresh install needs Peep.app opened once: that
  registers the agent, which asks for Accessibility (the owner's to grant).
- Renovate keeps action versions current (`renovate.json`): the `github-actions` manager
  only. Peep has no dependencies; the manifests under `Examples/` (`package.json`,
  `Cargo.lock`, `go.mod`, a Dockerfile...) are preview samples, so Dependabot alerts are
  off for this repo too (`vulnerability_alerts` in `repo_peep.tf`): every alert was one.
- The owner's Macs install Peep through their dotfiles (lingrino/dotfiles):
  `cask 'lingrino/tap/peep'` in `home/exact_private_dot_config/private_homebrew/Brewfile_*`.
  Their `dot` runs `brew bundle cleanup --force --zap` and `brew upgrade`: a merge to main
  reaches each Mac on its next `dot`; `Scripts/build.sh install` replaces the release with a
  local build until the next upgrade.

## Debugging

- Logs: `log stream --style compact --level info --predicate 'subsystem == "com.lingrino.peep"'`
  (use `/usr/bin/log` from zsh). Crash reports: `~/Library/Logs/DiagnosticReports/Peep*.ips`.
- Each extension process logs "cold start: first prepare began N ms after process start"
  once (~150 ms is dyld + AppKit + Quick Look's view-service handshake, before any of our
  code). `Prewarm` (started from `Sources/Preview/main.swift`) uses that window to build
  fonts, glyph tables and lookup tables on a background thread: cold first prepare 9 → 3 ms.
- Debug-level lines (`--level debug`) include each preview's first paint ("first paint: N
  tiles drawn in X ms, Y ms after setContent") and markdown layout timings.
- Where the extension's time goes outside our code (between prepare and Quick Look showing
  the preview, stalls while stepping through files): `DIAG=1 Scripts/build.sh install` logs
  (category `diag`) each prepare's start, when Quick Look shows the preview, main-thread stalls
  over 40 ms and memory; `peep-dev panelwatch` times key presses against the panel window;
  `sample <pid> 10 1` while reproducing shows what a stalled main thread waits on.
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
- Commit messages: imperative summary + body explaining why. No AI attribution (no
  co-author trailers, no generated-by lines): commits are the owner's.
