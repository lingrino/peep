// CommonMark + GFM inline parsing.
//
// Input: one block's content bytes (lines joined by "\n"). Output: rendered text appended to
// a `TextBuilder` and style runs. Internally a singly linked list of nodes in flat arrays
// (no objects): pass 1 tokenizes text/code/delimiters/brackets/HTML, links resolve when a
// `]` is seen, emphasis resolves with the CommonMark delimiter algorithm, and a final walk
// emits text with a style stack.

/// Growable byte buffer for the rendered text.
struct TextBuilder {
    var bytes: [UInt8] = []
    var count: Int { bytes.count }
    @inline(__always) mutating func append(_ b: UInt8) { bytes.append(b) }
    @inline(__always) mutating func append(_ s: UnsafeBufferPointer<UInt8>) { bytes.append(contentsOf: s) }
    mutating func append(_ s: String) { bytes.append(contentsOf: s.utf8) }
}

/// Shared state while assembling a MarkdownDocument.
final class InlineContext {
    var text = TextBuilder()
    var runs: [MDRun] = []
    var links: [String] = []
    var images: [MDImage] = []
    var refs: [String: (String, String)]
    var footnotes: [String: Int] = [:]
    /// Block-level hints discovered while parsing HTML (align, heading level).
    var blockAlign: MDAlign = .left
    var blockHeading: UInt8 = 0
    var sawRule = false
    /// `<picture><source media=dark srcset=...>` seen; applies to the next <img>.
    var pendingDarkSource: String?

    init(refs: [String: (String, String)]) { self.refs = refs }

    private var spare: InlineParser.State?

    func takeState() -> InlineParser.State {
        guard var s = spare else { return InlineParser.State() }
        spare = nil
        s.reset()
        return s
    }

    func returnState(_ s: InlineParser.State) { spare = s }
}

enum InlineParser {
    // Node kinds
    static let kText: UInt8 = 0, kDelim: UInt8 = 1, kSoft: UInt8 = 2, kHard: UInt8 = 3, kCode: UInt8 = 4
    static let kOpen: UInt8 = 5, kClose: UInt8 = 6, kBracket: UInt8 = 7, kLinkOpen: UInt8 = 8, kLinkClose: UInt8 = 9
    static let kImageOpen: UInt8 = 10, kImageClose: UInt8 = 11, kImageAtom: UInt8 = 12

    struct Node {
        var kind: UInt8
        var a: Int32 = 0        // text: start in scratch; delim: remaining count
        var b: Int32 = 0        // text: end in scratch; delim: original count
        var c: Int32 = 0        // delim: char; open/close: style bits; link/image: ref index
        var flags: UInt8 = 0    // delim: 1 = can open, 2 = can close; bracket: 1 = image, 2 = inactive
        var next: Int32 = -1
        var prev: Int32 = -1
    }

    /// Per-call working state.
    struct State {
        var nodes: [Node] = []
        var scratch: [UInt8] = []   // decoded text referenced by text/code nodes
        var tail: Int32 = -1
        var head: Int32 = -1
        var delims: [Int32] = []    // stack of delimiter node indices (emphasis)
        var brackets: [(node: Int32, delimBottom: Int)] = []

        mutating func reset() {
            nodes.removeAll(keepingCapacity: true)
            scratch.removeAll(keepingCapacity: true)
            delims.removeAll(keepingCapacity: true)
            brackets.removeAll(keepingCapacity: true)
            head = -1
            tail = -1
        }

        @discardableResult
        mutating func add(_ n: Node) -> Int32 {
            var m = n
            m.prev = tail
            m.next = -1
            nodes.append(m)
            let i = Int32(nodes.count - 1)
            if tail >= 0 { nodes[Int(tail)].next = i } else { head = i }
            tail = i
            return i
        }

        mutating func text(_ bytes: UnsafeBufferPointer<UInt8>) {
            // Merge with a preceding text node when contiguous in scratch.
            let s = Int32(scratch.count)
            scratch.append(contentsOf: bytes)
            if tail >= 0 && nodes[Int(tail)].kind == kText && nodes[Int(tail)].b == s {
                nodes[Int(tail)].b = Int32(scratch.count)
            } else {
                add(Node(kind: kText, a: s, b: Int32(scratch.count)))
            }
        }

        mutating func text(_ byte: UInt8) {
            var b = byte
            withUnsafePointer(to: &b) { text(UnsafeBufferPointer(start: $0, count: 1)) }
        }

        mutating func text(_ s: String) {
            var s = s
            s.withUTF8 { text($0) }
        }

        /// Inserts a node after `after` (doubly linked, O(1)).
        @discardableResult
        mutating func insert(_ n: Node, after: Int32) -> Int32 {
            var m = n
            m.next = nodes[Int(after)].next
            m.prev = after
            nodes.append(m)
            let i = Int32(nodes.count - 1)
            if m.next >= 0 { nodes[Int(m.next)].prev = i }
            nodes[Int(after)].next = i
            if tail == after { tail = i }
            return i
        }

        /// Inserts a node before `before`.
        @discardableResult
        mutating func insert(_ n: Node, before: Int32) -> Int32 {
            let p = nodes[Int(before)].prev
            if p >= 0 { return insert(n, after: p) }
            var m = n
            m.prev = -1
            m.next = before
            nodes.append(m)
            let i = Int32(nodes.count - 1)
            nodes[Int(before)].prev = i
            head = i
            return i
        }
    }

    // MARK: - Entry

    /// Parses `src[0..<n]` and appends rendered text + runs to `ctx`. Working arrays live in
    /// `ctx.scratchState` and are reused across blocks (no per-paragraph allocations).
    static func parse(_ src: UnsafePointer<UInt8>, _ n: Int, _ ctx: InlineContext, baseStyle: MDStyle = []) {
        var st = ctx.takeState()
        tokenize(src, n, &st, ctx)
        processEmphasis(&st, bottom: 0)
        emit(&st, ctx, baseStyle: baseStyle)
        ctx.returnState(st)
    }

    // MARK: - Tokenize

    static func tokenize(_ p: UnsafePointer<UInt8>, _ n: Int, _ st: inout State, _ ctx: InlineContext) {
        var i = 0
        var textStart = 0
        @inline(__always) func flush(_ upto: Int) {
            if upto > textStart { st.text(UnsafeBufferPointer(start: p + textStart, count: upto - textStart)) }
        }
        while i < n {
            let b = p[i]
            if !isSpecial(b) {
                // GFM bare autolinks at word starts (www., http://, https://).
                if (b == 0x77 || b == 0x68 || b == 0x57 || b == 0x48) && (i == 0 || !isAlnum(p[i - 1])), let e = bareAutolink(p, i, n) {
                    flush(i)
                    let url = String(decoding: UnsafeBufferPointer(start: p + i, count: e - i), as: UTF8.self)
                    let ref = Int32(ctx.links.count)
                    ctx.links.append((b | 0x20) == 0x77 ? "http://" + url : url)
                    st.add(Node(kind: kLinkOpen, c: ref))
                    st.text(UnsafeBufferPointer(start: p + i, count: e - i))
                    st.add(Node(kind: kLinkClose))
                    i = e
                    textStart = i
                    continue
                }
                i += 1
                continue
            }
            switch b {
            case 0x5C: // backslash
                if i + 1 < n && isASCIIPunct(p[i + 1]) {
                    flush(i)
                    st.text(p[i + 1])
                    i += 2
                    textStart = i
                } else if i + 1 < n && p[i + 1] == 0x0A {
                    flush(i)
                    st.add(Node(kind: kHard))
                    i += 2
                    while i < n && (p[i] == 0x20 || p[i] == 0x09) { i += 1 }
                    textStart = i
                } else { i += 1 }
            case 0x0A: // line break
                var e = i
                var spaces = 0
                while e > textStart && p[e - 1] == 0x20 { e -= 1; spaces += 1 }
                flush(e)
                st.add(Node(kind: spaces >= 2 ? kHard : kSoft))
                i += 1
                while i < n && (p[i] == 0x20 || p[i] == 0x09) { i += 1 }
                textStart = i
            case 0x60: // code span
                var k = i
                while k < n && p[k] == 0x60 { k += 1 }
                let ticks = k - i
                if let close = findCodeClose(p, k, n, ticks) {
                    flush(i)
                    let s = Int32(st.scratch.count)
                    appendCodeContent(p, k, close, &st.scratch)
                    st.add(Node(kind: kCode, a: s, b: Int32(st.scratch.count)))
                    i = close + ticks
                    textStart = i
                } else {
                    i = k   // literal backticks
                }
            case 0x2A, 0x5F, 0x7E: // * _ ~
                flush(i)
                var k = i
                while k < n && p[k] == b { k += 1 }
                let count = k - i
                let before: UInt8 = i > 0 ? p[i - 1] : 0x20
                let after: UInt8 = k < n ? p[k] : 0x20
                let lf = !isWhite(after) && (!isPunct(after) || isWhite(before) || isPunct(before))
                let rf = !isWhite(before) && (!isPunct(before) || isWhite(after) || isPunct(after))
                var canOpen = lf, canClose = rf
                if b == 0x5F {
                    canOpen = lf && (!rf || isPunct(before))
                    canClose = rf && (!lf || isPunct(after))
                }
                if b == 0x7E && count > 2 { canOpen = false; canClose = false }
                let idx = st.add(Node(kind: kDelim, a: Int32(count), b: Int32(count), c: Int32(b),
                                      flags: (canOpen ? 1 : 0) | (canClose ? 2 : 0)))
                if canOpen || canClose { st.delims.append(idx) }
                i = k
                textStart = i
            case 0x21: // ![
                if i + 1 < n && p[i + 1] == 0x5B {
                    flush(i)
                    let idx = st.add(Node(kind: kBracket, flags: 1))
                    st.brackets.append((idx, st.delims.count))
                    i += 2
                    textStart = i
                } else { i += 1 }
            case 0x5B: // [
                flush(i)
                // Footnote reference [^label] (and definition "[^label]:" at block start).
                if i + 1 < n && p[i + 1] == 0x5E, let close = findByte(p, i + 2, n, 0x5D), close > i + 2 {
                    let label = String(decoding: UnsafeBufferPointer(start: p + i + 2, count: close - i - 2), as: UTF8.self)
                    let isDef = close + 1 < n && p[close + 1] == 0x3A && i == 0
                    let num: Int
                    if let v = ctx.footnotes[label] { num = v } else { num = ctx.footnotes.count + 1; ctx.footnotes[label] = num }
                    let fs = Int32(MDStyle.superscript.rawValue | MDStyle.footnoteRef.rawValue)
                    st.add(Node(kind: kOpen, c: fs))
                    st.text("\(num)")
                    st.add(Node(kind: kClose, c: fs))
                    i = close + (isDef ? 2 : 1)
                    if isDef { st.text(0x20); while i < n && p[i] == 0x20 { i += 1 } }
                    textStart = i
                    continue
                }
                let idx = st.add(Node(kind: kBracket))
                st.brackets.append((idx, st.delims.count))
                i += 1
                textStart = i
            case 0x5D: // ]
                flush(i)
                i = closeBracket(p, i, n, &st, ctx)
                textStart = i
            case 0x3C: // < autolink or HTML
                if let (e, url, isEmail) = autolink(p, i, n) {
                    flush(i)
                    let ref = Int32(ctx.links.count)
                    ctx.links.append(isEmail ? "mailto:" + url : url)
                    st.add(Node(kind: kLinkOpen, c: ref))
                    st.text(url)
                    st.add(Node(kind: kLinkClose))
                    i = e
                    textStart = i
                } else if i + 3 < n && p[i + 1] == 0x21 && p[i + 2] == 0x2D && p[i + 3] == 0x2D {
                    // <!-- comment -->
                    flush(i)
                    var e = i + 4
                    while e + 2 < n && !(p[e] == 0x2D && p[e + 1] == 0x2D && p[e + 2] == 0x3E) { e += 1 }
                    i = min(n, e + 3)
                    textStart = i
                } else if let e = htmlTagEnd(p, i, n) {
                    flush(i)
                    htmlTag(p, i, e, &st, ctx)
                    i = e
                    textStart = i
                } else { i += 1 }
            case 0x26: // entity
                if let (e, decoded) = entity(p, i, n) {
                    flush(i)
                    st.text(decoded)
                    i = e
                    textStart = i
                } else { i += 1 }
            default:
                i += 1
            }
        }
        flush(n)
    }

    @inline(__always) static func isSpecial(_ b: UInt8) -> Bool {
        switch b {
        case 0x5C, 0x0A, 0x60, 0x2A, 0x5F, 0x7E, 0x21, 0x5B, 0x5D, 0x3C, 0x26: return true
        default: return false
        }
    }

    @inline(__always) static func isWhite(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D || b == 0x0C }
    @inline(__always) static func isAlnum(_ b: UInt8) -> Bool {
        (b >= 0x30 && b <= 0x39) || ((b | 0x20) >= 0x61 && (b | 0x20) <= 0x7A) || b >= 0x80
    }
    @inline(__always) static func isASCIIPunct(_ b: UInt8) -> Bool {
        (b >= 0x21 && b <= 0x2F) || (b >= 0x3A && b <= 0x40) || (b >= 0x5B && b <= 0x60) || (b >= 0x7B && b <= 0x7E)
    }
    /// ASCII punctuation (Unicode punctuation outside ASCII counts as non-punct here).
    @inline(__always) static func isPunct(_ b: UInt8) -> Bool { isASCIIPunct(b) }

    static func findByte(_ p: UnsafePointer<UInt8>, _ i: Int, _ n: Int, _ c: UInt8) -> Int? {
        var k = i
        while k < n { if p[k] == c { return k }; if p[k] == 0x0A { return nil }; k += 1 }
        return nil
    }

    // MARK: - Code spans

    static func findCodeClose(_ p: UnsafePointer<UInt8>, _ i: Int, _ n: Int, _ ticks: Int) -> Int? {
        var k = i
        while k < n {
            if p[k] == 0x60 {
                var e = k
                while e < n && p[e] == 0x60 { e += 1 }
                if e - k == ticks { return k }
                k = e
            } else { k += 1 }
        }
        return nil
    }

    static func appendCodeContent(_ p: UnsafePointer<UInt8>, _ s: Int, _ e: Int, _ out: inout [UInt8]) {
        var a = s, b = e
        // Strip one leading+trailing space if both present and content isn't all spaces.
        if b - a >= 2 && (p[a] == 0x20 || p[a] == 0x0A) && (p[b - 1] == 0x20 || p[b - 1] == 0x0A) {
            var allSpace = true
            for k in a..<b where p[k] != 0x20 && p[k] != 0x0A { allSpace = false; break }
            if !allSpace { a += 1; b -= 1 }
        }
        for k in a..<b { out.append(p[k] == 0x0A ? 0x20 : p[k]) }
    }

    // MARK: - Links

    /// Handles `]` at `i`: tries to form a link/image with the nearest active opener.
    static func closeBracket(_ p: UnsafePointer<UInt8>, _ i: Int, _ n: Int, _ st: inout State, _ ctx: InlineContext) -> Int {
        guard let (opener, delimBottom) = st.brackets.last else {
            st.text(0x5D)
            return i + 1
        }
        let isImage = st.nodes[Int(opener)].flags & 1 != 0
        if st.nodes[Int(opener)].flags & 2 != 0 {   // inactive
            st.brackets.removeLast()
            st.text(0x5D)
            return i + 1
        }
        var dest: String?
        var end = i + 1
        if i + 1 < n && p[i + 1] == 0x28, let (e, d, _) = inlineLinkTail(p, i + 2, n) {
            dest = d
            end = e
        } else if !ctx.refs.isEmpty {   // no definitions: skip building and folding labels
            if i + 1 < n && p[i + 1] == 0x5B, let close = findLabelEnd(p, i + 2, n) {
                let label = close > i + 2
                    ? String(decoding: UnsafeBufferPointer(start: p + i + 2, count: close - i - 2), as: UTF8.self)
                    : linkText(st, from: opener)
                if let r = ctx.refs[normalizeLabel(label)] { dest = r.0; end = close + 1 }
            }
            if dest == nil, let r = ctx.refs[normalizeLabel(linkText(st, from: opener))] {
                dest = r.0
                end = i + 1
            }
        }
        guard let d = dest else {
            st.brackets.removeLast()
            st.text(0x5D)
            return i + 1
        }
        // Emphasis inside the link text resolves first (only delimiters after the opener).
        processEmphasis(&st, bottom: delimBottom)
        if isImage {
            let ref = Int32(ctx.images.count)
            var img = MDImage(url: d, alt: linkText(st, from: opener))
            if let dark = ctx.pendingDarkSource { img.darkURL = dark; ctx.pendingDarkSource = nil }
            ctx.images.append(img)
            st.nodes[Int(opener)].kind = kImageOpen
            st.nodes[Int(opener)].c = ref
            st.add(Node(kind: kImageClose, c: ref))
        } else {
            let ref = Int32(ctx.links.count)
            ctx.links.append(d)
            st.nodes[Int(opener)].kind = kLinkOpen
            st.nodes[Int(opener)].c = ref
            st.add(Node(kind: kLinkClose, c: ref))
            // No links inside links: deactivate earlier [ openers.
            for k in st.brackets.indices where st.nodes[Int(st.brackets[k].node)].flags & 1 == 0 {
                st.nodes[Int(st.brackets[k].node)].flags |= 2
            }
        }
        st.brackets.removeLast()
        return end
    }

    /// Plain text of the nodes after `opener` (for reference labels and image alt text).
    static func linkText(_ st: State, from opener: Int32) -> String {
        var bytes: [UInt8] = []
        var k = st.nodes[Int(opener)].next
        while k >= 0 {
            let nd = st.nodes[Int(k)]
            switch nd.kind {
            case kText, kCode: bytes.append(contentsOf: st.scratch[Int(nd.a)..<Int(nd.b)])
            case kDelim: bytes.append(contentsOf: repeatElement(UInt8(truncatingIfNeeded: nd.c), count: Int(nd.a)))
            case kSoft, kHard: bytes.append(0x20)
            default: break
            }
            k = nd.next
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func findLabelEnd(_ p: UnsafePointer<UInt8>, _ i: Int, _ n: Int) -> Int? {
        var k = i
        while k < n && k - i < 1000 {
            if p[k] == 0x5C { k += 2; continue }
            if p[k] == 0x5B { return nil }
            if p[k] == 0x5D { return k }
            k += 1
        }
        return nil
    }

    /// Parses `dest "title")` after `(`. Returns end index (after `)`), destination, title.
    static func inlineLinkTail(_ p: UnsafePointer<UInt8>, _ i: Int, _ n: Int) -> (Int, String, String)? {
        var k = skipWS(p, i, n)
        var dest = ""
        if k < n && p[k] == 0x3C {   // <dest>
            var e = k + 1
            while e < n && p[e] != 0x3E && p[e] != 0x0A && p[e] != 0x3C { if p[e] == 0x5C { e += 1 }; e += 1 }
            if e >= n || p[e] != 0x3E { return nil }
            dest = unescape(p, k + 1, e)
            k = e + 1
        } else {
            var depth = 0
            let s = k
            while k < n {
                let c = p[k]
                if c == 0x5C && k + 1 < n && isASCIIPunct(p[k + 1]) { k += 2; continue }
                if c == 0x28 { depth += 1 }
                else if c == 0x29 { if depth == 0 { break }; depth -= 1 }
                else if c <= 0x20 { break }
                k += 1
            }
            dest = unescape(p, s, k)
        }
        let beforeTitle = k
        k = skipWS(p, k, n)
        var title = ""
        if k < n && k > beforeTitle && (p[k] == 0x22 || p[k] == 0x27 || p[k] == 0x28) {
            let close: UInt8 = p[k] == 0x28 ? 0x29 : p[k]
            var e = k + 1
            while e < n && p[e] != close { if p[e] == 0x5C { e += 1 }; e += 1 }
            if e >= n { return nil }
            title = unescape(p, k + 1, e)
            k = skipWS(p, e + 1, n)
        }
        if k >= n || p[k] != 0x29 { return nil }
        return (k + 1, dest, title)
    }

    @inline(__always) static func skipWS(_ p: UnsafePointer<UInt8>, _ i: Int, _ n: Int) -> Int {
        var k = i
        while k < n && (p[k] == 0x20 || p[k] == 0x09 || p[k] == 0x0A) { k += 1 }
        return k
    }

    /// Resolves backslash escapes and entities in a link destination/title.
    static func unescape(_ p: UnsafePointer<UInt8>, _ s: Int, _ e: Int) -> String {
        // Most destinations/titles have no escapes or entities: one String straight from the
        // source bytes (the byte-at-a-time rebuild was 25% of parse time on a link list).
        if memchr(p + s, 0x5C, e - s) == nil && memchr(p + s, 0x26, e - s) == nil {
            return String(decoding: UnsafeBufferPointer(start: p + s, count: e - s), as: UTF8.self)
        }
        var out: [UInt8] = []
        out.reserveCapacity(e - s)
        var k = s
        while k < e {
            if p[k] == 0x5C && k + 1 < e && isASCIIPunct(p[k + 1]) { out.append(p[k + 1]); k += 2; continue }
            if p[k] == 0x26, let (end, d) = entity(p, k, e) { out.append(contentsOf: d.utf8); k = end; continue }
            out.append(p[k])
            k += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Case-folded, whitespace-collapsed reference label.
    static func normalizeLabel(_ s: String) -> String {
        // ASCII fast path on bytes; split/joined/lowercased cost ~15% of parse time on docs
        // with many bracketed spans.
        var out: [UInt8] = []
        out.reserveCapacity(s.utf8.count)
        var space = false
        for c in s.utf8 {
            if c >= 0x80 { return normalizeLabelUnicode(s) }
            if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D { space = !out.isEmpty; continue }
            if space { out.append(0x20); space = false }
            out.append(c >= 0x41 && c <= 0x5A ? c | 0x20 : c)
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func normalizeLabelUnicode(_ s: String) -> String {
        s.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }).joined(separator: " ")
    }

    /// `[label]: dest "title"` at the start of `b`. Returns bytes consumed (through the line
    /// end), label, destination, title.
    static func parseReferenceDefinition(_ p: UnsafePointer<UInt8>, _ n: Int) -> (Int, String, String, String)? {
        do {
            var k = 0
            while k < n && k < 3 && p[k] == 0x20 { k += 1 }
            guard k < n, p[k] == 0x5B, let close = findLabelEnd(p, k + 1, n), close > k + 1,
                  close + 1 < n, p[close + 1] == 0x3A else { return nil }
            let label = String(decoding: UnsafeBufferPointer(start: p + k + 1, count: close - k - 1), as: UTF8.self)
            if label.hasPrefix("^") { return nil }   // footnote definition, rendered inline
            if label.allSatisfy({ $0 == " " || $0 == "\n" }) { return nil }
            k = skipWS(p, close + 2, n)
            var dest = ""
            if k < n && p[k] == 0x3C {
                var e = k + 1
                while e < n && p[e] != 0x3E && p[e] != 0x0A { e += 1 }
                if e >= n || p[e] != 0x3E { return nil }
                dest = unescape(p, k + 1, e)
                k = e + 1
            } else {
                let s = k
                while k < n && p[k] > 0x20 { k += 1 }
                if k == s { return nil }
                dest = unescape(p, s, k)
            }
            let afterDest = k
            let j = skipWS(p, k, n)
            if j < n && j > afterDest && (p[j] == 0x22 || p[j] == 0x27 || p[j] == 0x28) {
                let close: UInt8 = p[j] == 0x28 ? 0x29 : p[j]
                var e = j + 1
                while e < n && p[e] != close { if p[e] == 0x5C { e += 1 }; e += 1 }
                if e < n {
                    var t = e + 1
                    while t < n && (p[t] == 0x20 || p[t] == 0x09) { t += 1 }
                    if t >= n || p[t] == 0x0A {
                        return (min(n, t + 1), label, dest, unescape(p, j + 1, e))
                    }
                }
            }
            // No (valid) title: the destination must end its line.
            var t = afterDest
            while t < n && (p[t] == 0x20 || p[t] == 0x09) { t += 1 }
            if t < n && p[t] != 0x0A { return nil }
            return (min(n, t + 1), label, dest, "")
        }
    }

    // MARK: - Autolinks

    static func autolink(_ p: UnsafePointer<UInt8>, _ i: Int, _ n: Int) -> (Int, String, Bool)? {
        var k = i + 1
        let s = k
        while k < n && p[k] < 0x80 && (isAlnum(p[k]) || p[k] == 0x2B || p[k] == 0x2E || p[k] == 0x2D) { k += 1 }
        if k - s >= 2 && k - s <= 32 && k < n && p[k] == 0x3A {
            var e = k + 1
            while e < n && p[e] > 0x20 && p[e] != 0x3C && p[e] != 0x3E { e += 1 }
            if e < n && p[e] == 0x3E {
                return (e + 1, String(decoding: UnsafeBufferPointer(start: p + s, count: e - s), as: UTF8.self), false)
            }
        }
        var e = s
        var at = -1
        while e < n && p[e] != 0x3E && p[e] > 0x20 && p[e] != 0x3C {
            if p[e] == 0x40 { if at >= 0 { return nil }; at = e }
            e += 1
        }
        if at > s && e < n && p[e] == 0x3E && e > at + 1 && memchr(p + at, 0x2E, e - at) != nil {
            return (e + 1, String(decoding: UnsafeBufferPointer(start: p + s, count: e - s), as: UTF8.self), true)
        }
        return nil
    }

    /// GFM extended autolink starting with www., http:// or https://. Returns end.
    static func bareAutolink(_ p: UnsafePointer<UInt8>, _ i: Int, _ n: Int) -> Int? {
        var k = i
        func has(_ s: StaticString) -> Bool {
            let q = s.utf8Start
            let len = s.utf8CodeUnitCount
            if k + len > n { return false }
            for j in 0..<len where (p[k + j] | 0x20) != q[j] { return false }
            return true
        }
        if has("https://") { k += 8 } else if has("http://") { k += 7 } else if has("www.") { k += 4 } else { return nil }
        let hostStart = k
        while k < n && p[k] > 0x20 && p[k] != 0x3C { k += 1 }
        if k == hostStart { return nil }
        while k > hostStart {
            let c = p[k - 1]
            if c == 0x3F || c == 0x21 || c == 0x2E || c == 0x2C || c == 0x3A || c == 0x2A || c == 0x5F || c == 0x7E || c == 0x27 || c == 0x22 {
                k -= 1; continue
            }
            if c == 0x29 {
                var open = 0, close = 0
                for j in i..<k { if p[j] == 0x28 { open += 1 } else if p[j] == 0x29 { close += 1 } }
                if close > open { k -= 1; continue }
            }
            break
        }
        return k > hostStart ? k : nil
    }

    // MARK: - Entities

    static func entity(_ p: UnsafePointer<UInt8>, _ i: Int, _ n: Int) -> (Int, String)? {
        var k = i + 1
        if k < n && p[k] == 0x23 {
            k += 1
            var v: UInt32 = 0
            var digits = 0
            if k < n && (p[k] | 0x20) == 0x78 {
                k += 1
                while k < n && digits < 7, let d = hexValue(p[k]) { v = v * 16 + UInt32(d); k += 1; digits += 1 }
            } else {
                while k < n && digits < 8 && p[k] >= 0x30 && p[k] <= 0x39 { v = v * 10 + UInt32(p[k] - 0x30); k += 1; digits += 1 }
            }
            guard digits > 0, k < n, p[k] == 0x3B else { return nil }
            if v == 0 || v > 0x10FFFF || (v >= 0xD800 && v < 0xE000) { v = 0xFFFD }
            return (k + 1, String(UnicodeScalar(v).map(Character.init) ?? "\u{FFFD}"))
        }
        let s = k
        while k < n && k - s < 32 && p[k] < 0x80 && isAlnum(p[k]) { k += 1 }
        guard k > s, k < n, p[k] == 0x3B else { return nil }
        let name = String(decoding: UnsafeBufferPointer(start: p + s, count: k - s), as: UTF8.self)
        guard let v = Entities.named[name] else { return nil }
        return (k + 1, v)
    }

    @inline(__always) static func hexValue(_ b: UInt8) -> UInt8? {
        if b >= 0x30 && b <= 0x39 { return b - 0x30 }
        let l = b | 0x20
        if l >= 0x61 && l <= 0x66 { return l - 0x61 + 10 }
        return nil
    }

    // MARK: - Raw HTML (safe subset)

    /// End of an HTML tag starting at `i` (`<tag ...>` or `</tag>`), or nil.
    static func htmlTagEnd(_ p: UnsafePointer<UInt8>, _ i: Int, _ n: Int) -> Int? {
        var k = i + 1
        if k < n && p[k] == 0x2F { k += 1 }
        guard k < n, (p[k] | 0x20) >= 0x61 && (p[k] | 0x20) <= 0x7A else { return nil }
        while k < n && p[k] < 0x80 && (isAlnum(p[k]) || p[k] == 0x2D) { k += 1 }
        while k < n {
            let c = p[k]
            if c == 0x3E { return k + 1 }
            if c == 0x22 || c == 0x27 {
                var e = k + 1
                while e < n && p[e] != c { e += 1 }
                if e >= n { return nil }
                k = e + 1
                continue
            }
            if c == 0x3C { return nil }
            k += 1
        }
        return nil
    }

    /// Lowercase ASCII bytes packed little-endian into a UInt64 (0 if longer than 8 bytes):
    /// tag names compare as integers instead of allocated, lowercased Strings.
    @inline(__always)
    static func tagKey(_ p: UnsafePointer<UInt8>, _ s: Int, _ e: Int) -> UInt64 {
        if e - s > 8 || e <= s { return 0 }
        var v: UInt64 = 0
        for k in s..<e { v |= UInt64(p[k] | 0x20) << (8 * UInt64(k - s)) }
        return v
    }

    static func tagKey(_ name: StaticString) -> UInt64 {
        tagKey(name.utf8Start, 0, name.utf8CodeUnitCount)
    }

    enum Tag {
        static let br = tagKey("br"), b = tagKey("b"), strong = tagKey("strong"), i = tagKey("i")
        static let em = tagKey("em"), cite = tagKey("cite"), var_ = tagKey("var"), dfn = tagKey("dfn")
        static let code = tagKey("code"), tt = tagKey("tt"), samp = tagKey("samp"), kbd = tagKey("kbd")
        static let s = tagKey("s"), del = tagKey("del"), strike = tagKey("strike"), sub = tagKey("sub")
        static let sup = tagKey("sup"), a = tagKey("a"), img = tagKey("img"), source = tagKey("source")
        static let p = tagKey("p"), div = tagKey("div"), center = tagKey("center"), summary = tagKey("summary")
        static let hr = tagKey("hr"), li = tagKey("li"), tr = tagKey("tr"), td = tagKey("td"), th = tagKey("th")
    }

    /// Interprets one tag `p[i..<e]` (already known to be well-formed).
    static func htmlTag(_ p: UnsafePointer<UInt8>, _ i: Int, _ e: Int, _ st: inout State, _ ctx: InlineContext) {
        var k = i + 1
        let closing = p[k] == 0x2F
        if closing { k += 1 }
        let ns = k
        while k < e && p[k] < 0x80 && (isAlnum(p[k]) || p[k] == 0x2D) { k += 1 }
        let name = tagKey(p, ns, k)
        // Attributes are parsed only for the tags that read them.
        func attrs() -> [String: String] { closing ? [:] : parseAttributes(p, k, e) }
        func style(_ s: MDStyle) {
            st.add(Node(kind: closing ? kClose : kOpen, c: Int32(s.rawValue)))
        }
        switch name {
        case Tag.br: st.add(Node(kind: kHard))
        case Tag.b, Tag.strong, Tag.summary: style(.strong)
        case Tag.i, Tag.em, Tag.cite, Tag.var_, Tag.dfn: style(.emphasis)
        case Tag.code, Tag.tt, Tag.samp: style(.code)
        case Tag.kbd: style(.kbd)
        case Tag.s, Tag.del, Tag.strike: style(.strike)
        case Tag.sub: style(.subscriptStyle)
        case Tag.sup: style(.superscript)
        case Tag.a:
            if closing { st.add(Node(kind: kLinkClose)) }
            else if let href = attrs()["href"] {
                let ref = Int32(ctx.links.count)
                ctx.links.append(href)
                st.add(Node(kind: kLinkOpen, c: ref))
            }
        case Tag.img:
            let at = attrs()
            if let src = at["src"] {
                var img = MDImage(url: src, alt: at["alt"] ?? "")
                img.width = number(at["width"])
                img.height = number(at["height"])
                if let dark = ctx.pendingDarkSource { img.darkURL = dark; ctx.pendingDarkSource = nil }
                let ref = Int32(ctx.images.count)
                ctx.images.append(img)
                st.add(Node(kind: kImageAtom, c: ref))
            }
        case Tag.source:
            // <picture><source media="(prefers-color-scheme: dark)" srcset="..."><img ...></picture>
            let at = attrs()
            if let media = at["media"], hasBytes(media, "dark"), let set = at["srcset"] {
                let u = set.utf8
                ctx.pendingDarkSource = String(set[..<(u.firstIndex(of: 0x20) ?? u.endIndex)])   // first URL
            }
        case Tag.p, Tag.div, Tag.center:
            if !closing {
                let align = attrs()["align"]?.lowercased()
                if name == Tag.center || align == "center" { ctx.blockAlign = .center }
                else if align == "right" { ctx.blockAlign = .right }
            }
            if st.tail >= 0 { st.add(Node(kind: kHard)) }
        case _ where k - ns == 2 && p[ns] | 0x20 == 0x68 && p[ns + 1] >= 0x31 && p[ns + 1] <= 0x36:   // h1-h6
            if !closing {
                ctx.blockHeading = p[ns + 1] - 0x30
                if attrs()["align"]?.lowercased() == "center" { ctx.blockAlign = .center }
            }
        case Tag.hr: ctx.sawRule = true
        case Tag.li: if !closing { if st.tail >= 0 { st.add(Node(kind: kHard)) }; st.text("• ") }
        case Tag.tr: if closing { st.add(Node(kind: kHard)) }
        case Tag.td, Tag.th: if closing { st.text("  ") }
        default: break   // unknown tags are dropped; their text content stays
        }
    }

    /// Substring test on UTF-8 bytes. (`String.contains` and `utf8.firstRange(of:)` are
    /// generic searches with runtime metadata lookups: 20% of a small README's parse.)
    static func hasBytes(_ s: String, _ needle: StaticString) -> Bool {
        var s = s
        return s.withUTF8 { b in
            guard let base = b.baseAddress else { return false }
            return memmem(base, b.count, needle.utf8Start, needle.utf8CodeUnitCount) != nil
        }
    }

    static func number(_ s: String?) -> Float {
        guard let s else { return 0 }
        return Float(s.filter { $0.isNumber || $0 == "." }) ?? 0
    }

    static func parseAttributes(_ p: UnsafePointer<UInt8>, _ s: Int, _ e: Int) -> [String: String] {
        var out: [String: String] = [:]
        var k = s
        while k < e {
            while k < e && (isWhite(p[k]) || p[k] == 0x2F) { k += 1 }
            let ns = k
            while k < e && p[k] != 0x3D && !isWhite(p[k]) && p[k] != 0x3E && p[k] != 0x2F { k += 1 }
            if k == ns { k += 1; continue }
            let name = String(decoding: UnsafeBufferPointer(start: p + ns, count: k - ns), as: UTF8.self).lowercased()
            while k < e && isWhite(p[k]) { k += 1 }
            var value = ""
            if k < e && p[k] == 0x3D {
                k += 1
                while k < e && isWhite(p[k]) { k += 1 }
                if k < e && (p[k] == 0x22 || p[k] == 0x27) {
                    let q = p[k]
                    let vs = k + 1
                    k = vs
                    while k < e && p[k] != q { k += 1 }
                    value = unescape(p, vs, k)
                    k += 1
                } else {
                    let vs = k
                    while k < e && !isWhite(p[k]) && p[k] != 0x3E { k += 1 }
                    value = unescape(p, vs, k)
                }
            }
            out[name] = value
        }
        return out
    }

    // MARK: - Emphasis (CommonMark "process emphasis")

    static func processEmphasis(_ st: inout State, bottom: Int) {
        var openersBottom: [Int: Int] = [:]   // key: char, closer length % 3, can-open
        var ci = bottom
        while ci < st.delims.count {
            let closer = st.delims[ci]
            let cn = st.nodes[Int(closer)]
            if cn.flags & 2 == 0 || cn.a == 0 { ci += 1; continue }
            let ch = cn.c
            let key = Int(ch) * 8 + Int(cn.b % 3) * 2 + Int(cn.flags & 1)
            let floor = max(bottom, openersBottom[key] ?? bottom)
            var oi = ci - 1
            var found = -1
            while oi >= floor {
                let on = st.nodes[Int(st.delims[oi])]
                if on.c == ch && on.flags & 1 != 0 && on.a > 0 {
                    let both = on.flags == 3 || cn.flags == 3
                    let ruleOf3 = both && (on.b + cn.b) % 3 == 0 && !(on.b % 3 == 0 && cn.b % 3 == 0)
                    let tildeOK = ch != 0x7E || on.a == cn.a
                    if !ruleOf3 && tildeOK { found = oi; break }
                }
                oi -= 1
            }
            if found < 0 {
                openersBottom[key] = ci
                if cn.flags & 1 == 0 { st.delims.remove(at: ci) } else { ci += 1 }
                continue
            }
            let opener = st.delims[found]
            let oa = st.nodes[Int(opener)].a
            let use: Int32 = ch == 0x7E ? oa : (oa >= 2 && cn.a >= 2 ? 2 : 1)
            let style: MDStyle = ch == 0x7E ? .strike : (use == 2 ? .strong : .emphasis)
            st.nodes[Int(opener)].a -= use
            st.nodes[Int(closer)].a -= use
            st.insert(Node(kind: kOpen, c: Int32(style.rawValue)), after: opener)
            st.insert(Node(kind: kClose, c: Int32(style.rawValue)), before: closer)
            // Delimiters between opener and closer can no longer match.
            st.delims.removeSubrange((found + 1)..<ci)
            ci = found + 1
            if st.nodes[Int(opener)].a == 0 { st.delims.remove(at: found); ci -= 1 }
            if st.nodes[Int(closer)].a == 0 { st.delims.remove(at: ci) }
        }
        if bottom < st.delims.count { st.delims.removeSubrange(bottom...) }
    }

    // MARK: - Emit

    static func emit(_ st: inout State, _ ctx: InlineContext, baseStyle: MDStyle) {
        var counts = [Int](repeating: 0, count: 10)   // per style bit
        var link: Int32 = -1
        var imageDepth = 0
        var runStyle = baseStyle
        var runRef: Int32 = -1
        var runStart = ctx.text.count

        func restyle() {
            var s = baseStyle
            for b in 0..<10 where counts[b] > 0 { s.insert(MDStyle(rawValue: 1 << UInt16(b))) }
            if link >= 0 { s.insert(.link) }
            let r = link
            if s == runStyle && r == runRef { return }
            if ctx.text.count > runStart && !runStyle.isEmpty {
                ctx.runs.append(MDRun(start: Int32(runStart), end: Int32(ctx.text.count), style: runStyle, ref: runRef))
            }
            runStyle = s
            runRef = r
            runStart = ctx.text.count
        }

        var k = st.head
        while k >= 0 {
            let nd = st.nodes[Int(k)]
            switch nd.kind {
            case kText:
                if imageDepth == 0 { ctx.text.bytes.append(contentsOf: st.scratch[Int(nd.a)..<Int(nd.b)]) }
            case kDelim:
                if imageDepth == 0 && nd.a > 0 { ctx.text.bytes.append(contentsOf: repeatElement(UInt8(truncatingIfNeeded: nd.c), count: Int(nd.a))) }
            case kSoft:
                if imageDepth == 0 { ctx.text.append(0x20) }
            case kHard:
                if imageDepth == 0 { ctx.text.append(0x0A) }
            case kCode:
                if imageDepth == 0 {
                    counts[2] += 1; restyle()
                    ctx.text.bytes.append(contentsOf: st.scratch[Int(nd.a)..<Int(nd.b)])
                    counts[2] -= 1; restyle()
                }
            case kOpen, kClose:
                for b in 0..<10 where nd.c & (1 << b) != 0 {
                    counts[b] = max(0, counts[b] + (nd.kind == kOpen ? 1 : -1))
                }
                restyle()
            case kBracket:
                if imageDepth == 0 { ctx.text.append(nd.flags & 1 != 0 ? "![" : "[") }
            case kLinkOpen:
                link = nd.c; restyle()
            case kLinkClose:
                link = -1; restyle()
            case kImageOpen, kImageAtom:
                if imageDepth == 0 {
                    restyle()
                    // An image is one U+FFFC object-replacement character carrying the image run
                    // (links around images still apply: the run keeps the link ref separately).
                    let start = ctx.text.count
                    ctx.text.append("\u{FFFC}")
                    ctx.runs.append(MDRun(start: Int32(start), end: Int32(ctx.text.count), style: .image, ref: nd.c))
                    if link >= 0 {
                        ctx.runs.append(MDRun(start: Int32(start), end: Int32(ctx.text.count), style: .link, ref: link))
                    }
                    runStart = ctx.text.count
                }
                if nd.kind == kImageOpen { imageDepth += 1 }
            case kImageClose:
                imageDepth = max(0, imageDepth - 1)
            default: break
            }
            k = nd.next
        }
        if ctx.text.count > runStart && !runStyle.isEmpty {
            ctx.runs.append(MDRun(start: Int32(runStart), end: Int32(ctx.text.count), style: runStyle, ref: runRef))
        }
    }

    // MARK: - Tables

    /// Splits a table row into cell byte ranges on unescaped `|` outside code spans,
    /// dropping the optional leading/trailing pipe.
    static func splitCells(_ p: UnsafePointer<UInt8>, _ s: Int, _ e: Int) -> [(Int, Int)] {
        var a = s, b = e
        while a < b && (p[a] == 0x20 || p[a] == 0x09) { a += 1 }
        while b > a && (p[b - 1] == 0x20 || p[b - 1] == 0x09) { b -= 1 }
        if a < b && p[a] == 0x7C { a += 1 }
        if b > a && p[b - 1] == 0x7C && (b - 2 < a || p[b - 2] != 0x5C) { b -= 1 }
        var cells: [(Int, Int)] = []
        var start = a
        var k = a
        var inCode = 0
        while k < b {
            let c = p[k]
            if c == 0x5C { k += 2; continue }
            if c == 0x60 {
                var t = k
                while t < b && p[t] == 0x60 { t += 1 }
                let n = t - k
                inCode = inCode == 0 ? n : (inCode == n ? 0 : inCode)
                k = t
                continue
            }
            if c == 0x7C && inCode == 0 {
                cells.append((start, k))
                start = k + 1
            }
            k += 1
        }
        if b > a || !cells.isEmpty { cells.append((start, max(start, b))) }
        return cells
    }
}

import Darwin
