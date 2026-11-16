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
   → show, then calls the handler. Logs `prepare <file>: <stage timings>` (subsystem
   `com.lingrino.peep`).
2. **Keyboard agent** — `Sources/App/Agent.swift`. Quick Look previews *never* receive key
   events (the panel never becomes key; typing goes to Finder). The agent installs a session
   event tap (needs the Accessibility grant) and forwards keys over XPC **only** when a Peep
   preview is visible in the frontmost app's Quick Look panel (a floating-level window owned by
   the frontmost app whose size matches a reported preview). Intercepts ⌘F, ⌘G/⇧⌘G, ⌘A, ⌘C (with a
   selection), and every key while the find bar is open. Everything else passes through.
   It also opens links (sandbox forbids `NSWorkspace.open`) and fetches remote images (Quick
   Look's sandbox denies outbound connections even with `network.client`).
3. **Peep.app** — `Sources/App/HostApp.swift`. Opening it shows setup status (extension,
   agent, Accessibility) and can open any file in a viewer window with the same renderer.
   `Peep --register` (used by the installer) writes/reloads the LaunchAgent plist.

## Source map

| Path | What |
|---|---|
| `Sources/Core/Text/` | `TextBuffer` (padded bytes), `FileLoader`, `Decoder` (encodings/binary), `LineIndex` (SIMD), `Search` (SIMD), `SIMD.swift` helpers, `HexDump` |
| `Sources/Core/Lex/` | `TokenStream` (SoA tokens), `KeywordTable`, `ByteClass`, `CLike` engine + `Specs` (most languages), `Formats` (JSON, YAML, TOML/INI, XML/HTML, CSS, shell, diff, Makefile, Dockerfile, markdown source), `Language` (detection table + dispatch) |
| `Sources/Core/Markdown/` | `BlockParser` (CommonMark/GFM blocks), `InlineParser` (inlines, HTML subset), `MarkdownParser` (assembly), `MarkdownModel` (flat output), `Entities` |
| `Sources/Render/` | `DocumentView` (tiles, selection, mouse), `CodeContent`, `MarkdownContent` + `TextBox`, `ImageStore`, `OutlineView` (TOC), `FindBar`, `PreviewView` (composition + key handling), `Theme`, `Document` (file → content pipeline) |
| `Sources/Preview/` | Extension principal class + `AgentClient` |
| `Sources/App/` | Host app, agent |
| `Dev/` | `peep-dev` tool: `render`, `bench`, `lexbench`, `tokens`, `layout`, `types` |
| `Tests/` | Zero-dependency test harness + tests (text, search, lexers, markdown) |
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
Scripts/dev.sh layout <file.md> [w]   # markdown block/box dump
Scripts/profile.sh .build/release/peep-dev lexbench <file> 400   # Instruments Time Profiler summary
FOCUS=CLike.lex python3 Scripts/profile.py <trace>               # hot instruction offsets
Scripts/gen-types.sh         # regenerate QLSupportedContentTypes after adding extensions
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

## Quick Look facts (verified on macOS 27)

- QL matches **exact** UTIs only (no conformance). Many extensions have *dynamic* UTIs
  (`dyn.a…`), computed in `Dev/main.swift:dynamicUTI`. Extensionless files are `public.data`.
- Apple's previewers win for `public.plain-text`, `public.html`, CSV — listing them is harmless.
- Keyboard: see Processes. Never call `makeFirstResponder` (another app's extension broke
  Finder's arrow keys that way); `DocumentView.acceptsFirstResponder` is false.
- Sandbox: no network (agent fetches), no `NSWorkspace.open` (agent opens), reading files next
  to the previewed one needs the `absolute-path.read-only` temporary exception (granted for `/`).
- Killing the extension while a panel shows it (every install does) leaves that panel in a
  "failed during preview" state; close it and move the selection to recover. Not a bug.
- Remote view frames reported to the extension are synthetic; only sizes are meaningful.

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
- Agent state: `launchctl print gui/$(id -u)/com.lingrino.peep.agent`.
- Extension registration: `pluginkit -m -v -i com.lingrino.peep.preview` (`+` = enabled).
- Another QL extension claiming the same types (e.g. Peek) can win; disable it with
  `pluginkit -e ignore -i <id>`.

## Adding a language

1. Add a `Language` case + `name`, extensions in `extensionTable` (and `byName` for special
   file names), and dispatch in `lex`.
2. C-like syntax: add a `CLikeSpec` in `Specs.swift` (keyword groups: K/D/T/C/B/Y). Otherwise a
   lexer in `Formats.swift`.
3. Add a test in `Tests/LexTests.swift`; run `Scripts/gen-types.sh`; rebuild.

## Conventions

- Swift 6 language mode. Main-thread UI types are `@MainActor`; buffers shared with background
  work are `@unchecked Sendable` final classes with immutable contents.
- Hot loops: `&+`, unsafe pointers, no closures/allocations per element, `@inline(__always)` on
  tiny helpers. Comment *why* for every non-obvious performance trick.
- Tests: `Tests/*.swift`, registered in `Tests/main.swift`. Fuzz-ish robustness tests exist for
  lexers and markdown — keep them passing.
- Commit messages: imperative summary + body explaining why; end with the co-author trailer.
