import Darwin

/// Re-indents minified JSON for display ("x.min.json", API dumps saved on one line).
///
/// One pass, no parse tree: structure characters get newlines and 2-space indentation,
/// strings are copied in bulk (vector scan for `"` and `\`), scalars are copied as they are.
/// Tolerant of anything: invalid JSON comes out re-indented the same way, never rejected.
/// Several top-level values (concatenated documents) stay on separate lines.
public enum JSONFormatter {
    /// Bytes per line, averaged over the first 64 KB, above which a JSON file is treated as
    /// minified. Formatted JSON averages 20-60; a minified file is one or a few huge lines.
    static let minifiedLineLength = 200

    public static func looksMinified(_ t: TextBuffer) -> Bool {
        let n = min(t.count, 64 << 10)
        if n < 256 { return false }
        var lines = 1
        var i = 0
        while true {
            i = lineEnd(t.base, i, n)
            if i >= n { break }
            lines += 1
            i += 1
        }
        return lines * minifiedLineLength < n
    }

    /// Indentation stops growing here, so pathological nesting can't blow up the output.
    /// It still grows it: every `[` `{` `,` at depth 40+ becomes 82 bytes, so callers bound
    /// the output (`outputLimit`).
    static let maxIndentDepth = 40

    public static func format(_ t: TextBuffer) -> TextBuffer { format(t, count: t.count) }

    /// Formats the first `n` bytes (a prefix cut anywhere is fine: output up to the cut equals
    /// the full output's beginning, except possibly its last line).
    public static func format(_ t: TextBuffer, count n: Int) -> TextBuffer {
        format(t, count: n, outputLimit: .max).text
    }

    public struct Formatted {
        public let text: TextBuffer
        /// Input bytes formatted: fewer than asked when the output limit (or cancellation)
        /// stopped formatting, always at a token boundary.
        public let consumed: Int
        /// Where `stopNote` starts in `text` (`text.count` when there is none).
        public let noteStart: Int
    }

    /// Bytes of output between `cancelled` checks (~1 ms of formatting).
    static let checkInterval = 1 << 20
    /// Input formatted between checks of the output size: at most 82x this past the limit.
    static let slice = 4096

    /// Formats the first `n` bytes, stopping at a token boundary once the output reaches
    /// `outputLimit` bytes (it can exceed it by what one `slice` of input becomes, plus a
    /// token: a string or scalar is copied whole). A stop at the limit appends a line with
    /// `stopNote` (when not empty). `cancelled` is polled every `checkInterval` bytes of
    /// output (background formatting of a big file stops when its preview goes away).
    ///
    /// The checks run between slices of input, and the per-token loop is a function of its
    /// own: checks in it (even one compare per token), or the loop inline in this function,
    /// made formatting 3-9% slower.
    public static func format(_ t: TextBuffer, count n: Int, outputLimit: Int, stopNote: String = "",
                              cancelled: () -> Bool = { false }) -> Formatted {
        var s = State(out: ByteOutput(capacity: min(n + n / 2, outputLimit) + 4096))
        var poll = checkInterval
        var atLimit = false
        while s.i < n {
            if s.out.count >= outputLimit { atLimit = true; break }
            if s.out.count >= poll {
                if cancelled() { break }
                poll = s.out.count + checkInterval
            }
            run(UnsafePointer(t.base), n, min(n, s.i &+ slice), &s)
        }
        s.out.byte(0x0A)
        let noteStart = s.out.count
        if atLimit && !stopNote.isEmpty {
            s.out.string(stopNote)
            s.out.byte(0x0A)
        }
        return Formatted(text: s.out.finish(), consumed: min(s.i, n), noteStart: noteStart)
    }

    struct State {
        var out: ByteOutput
        var i = 0
        var depth = 0
        var afterTopValue = false   // a complete value at depth 0 was written
    }

    /// Formats the tokens starting before `end` (each runs to its own end, up to `n`).
    @inline(never)
    static func run(_ p: UnsafePointer<UInt8>, _ n: Int, _ end: Int, _ state: inout State) {
        var out = state.out, i = state.i, depth = state.depth, afterTopValue = state.afterTopValue
        defer { state = State(out: out, i: i, depth: depth, afterTopValue: afterTopValue) }
        @inline(__always) func beginValue() {
            if depth == 0 {
                if afterTopValue { out.byte(0x0A) }
            }
        }
        while i < end {
            let c = p[i]
            switch c {
            case 0x20, 0x09, 0x0A, 0x0D:
                i &+= 1
            case 0x22:   // string: copy through the closing quote
                beginValue()
                let s = i
                i &+= 1
                while true {
                    i = findAny(p, i, n, 0x22, 0x5C, 0x22, 0x5C)
                    if i >= n { break }
                    if p[i] == 0x5C { i &+= 2; continue }
                    i &+= 1
                    break
                }
                i = min(i, n)
                out.bytes(p + s, i - s)
                if depth == 0 { afterTopValue = true }
            case 0x7B, 0x5B:   // { [
                beginValue()
                var j = i &+ 1
                while j < n, p[j] == 0x20 || p[j] == 0x0A || p[j] == 0x09 || p[j] == 0x0D { j &+= 1 }
                if j < n && p[j] == c &+ 2 {   // empty: {} []
                    out.byte(c)
                    out.byte(c &+ 2)
                    i = j &+ 1
                    if depth == 0 { afterTopValue = true }
                    continue
                }
                out.byte(c)
                depth &+= 1
                out.newline(depth, maxDepth: maxIndentDepth)
                i &+= 1
            case 0x7D, 0x5D:   // } ]
                depth = max(0, depth &- 1)
                if out.count > 0 { out.newline(depth, maxDepth: maxIndentDepth) }
                out.byte(c)
                i &+= 1
                if depth == 0 { afterTopValue = true }
            case 0x2C:   // ,
                out.byte(c)
                out.newline(depth, maxDepth: maxIndentDepth)
                i &+= 1
            case 0x3A:   // :
                out.byte(c)
                out.byte(0x20)
                i &+= 1
            default:     // number, true/false/null, or garbage: copy the run
                beginValue()
                let s = i
                while i < n {
                    let b = p[i]
                    if b == 0x2C || b == 0x7D || b == 0x5D || b == 0x3A || b == 0x7B || b == 0x5B || b == 0x22
                        || b == 0x20 || b == 0x0A || b == 0x09 || b == 0x0D { break }
                    i &+= 1
                }
                out.bytes(p + s, i - s)
                if depth == 0 { afterTopValue = true }
            }
        }
    }
}
