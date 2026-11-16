import AppKit

// peep-dev: developer tool (not shipped). Everything runs through the real view stack and
// pipeline (Core + Render compiled in), off screen unless noted. Build and run with
// Scripts/dev.sh; Scripts/check.sh runs the checks, Scripts/compare.sh diffs against an
// older revision.

let usage = """
    peep-dev <command> [args]

    Rendering (Render.swift)
      render <file> <out.png> [--dark] [--size WxH] [--scroll Y] [--select a:b] [--find q] [--wait s] [--early] [--remote]
      icon <dir.iconset>                    app icon at every iconset size

    Checks: exit 1 on any problem (Checks.swift)
      smoke <dirs/files...>                 open, draw, scroll, find, select every file; geometry; slowest
      tilecheck <files...>                  random jumps/overscroll/resizes: visible rect always tiled
      linkcheck <files.md...>               every link resolves from a click on it
      imgdiff <a.png> <b.png>               pixel comparison (count and bounding box)

    Benchmarks (Bench.swift)
      bench <files...> [--iterations N]     pipeline stage timings
      lexbench <file> [N]                   lexer throughput
      parsebench <file.md|dir> [N]          markdown parse throughput (dir: by size bucket)
      mdbench <file.md> [N]                 markdown parse + layout
      firstpaint <files...>                 main-thread cost to the first frame (+ background layout)
      showcost <files...>                   on-screen show + Core Animation commit
      findbench <file> <query...>           raw search vs the full find path
      jumpbench <files...>                  outline jump cost, flashes, highlighted row

    Dumps (Dumps.swift)
      tokens <file>                         lexer tokens
      layout <file.md> [width]              markdown blocks and boxes (+ geometry check)
      mddump <outdir> <files/dirs...>       every parsed field per .md (diff -r around parser changes)
      symbols <files...> [--all]            code outline entries
      types                                 QLSupportedContentTypes for the Info.plist

    Live (Panel.swift; needs a Quick Look panel on screen)
      panelwatch [seconds]                  key presses and Quick Look panel appear/resize/settle times
    """

/// Problems found by the check commands; the tool exits 1 when nonzero.
nonisolated(unsafe) var checkFailures = 0

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { print(usage); exit(2) }
let rest = Array(args.dropFirst())
MainActor.assumeIsolated {
    _ = NSApplication.shared
    // Offline: remote images (README badges) never load, so checks and benchmarks are
    // deterministic and make no requests. `render --remote` fetches them.
    ImageStore.remoteFetch = { _, done in done(nil) }
    switch cmd {
    case "render": render(rest)
    case "icon": icon(rest)
    case "smoke": smoke(rest)
    case "tilecheck": tileCheck(rest)
    case "linkcheck": linkCheck(rest)
    case "imgdiff": imgDiff(rest)
    case "bench": bench(rest)
    case "lexbench": lexbench(rest)
    case "parsebench": parsebench(rest)
    case "mdbench": mdbench(rest)
    case "firstpaint": firstPaint(rest)
    case "showcost": showCost(rest)
    case "findbench": findBench(rest)
    case "jumpbench": jumpBench(rest)
    case "tokens": tokens(rest)
    case "layout": layoutDump(rest)
    case "mddump": mdDump(rest)
    case "symbols": symbolsDump(rest)
    case "types": types(rest)
    case "panelwatch": panelWatch(rest)
    default: print(usage); exit(2)
    }
}
exit(checkFailures == 0 ? 0 : 1)
