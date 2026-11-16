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
    static let maxIndentDepth = 40

    public static func format(_ t: TextBuffer) -> TextBuffer { format(t, count: t.count) }

    /// Formats the first `n` bytes (a prefix cut anywhere is fine: output up to the cut equals
    /// the full output's beginning, except possibly its last line).
    public static func format(_ t: TextBuffer, count n: Int) -> TextBuffer {
        let p = UnsafePointer(t.base)
        var out = ByteOutput(capacity: n + n / 2 + 4096)
        var depth = 0
        var afterTopValue = false   // a complete value at depth 0 was written
        var i = 0
        @inline(__always) func beginValue() {
            if depth == 0 {
                if afterTopValue { out.byte(0x0A) }
            }
        }
        while i < n {
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
        out.byte(0x0A)
        return out.finish()
    }
}
