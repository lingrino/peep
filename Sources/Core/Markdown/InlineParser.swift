// CommonMark + GFM inline parsing.
//
// Input: one block's content bytes (lines joined by "\n": a pointer straight into the source
// when the block's lines are contiguous there, else a gathered copy). Output: rendered text and
// style runs appended to the document being built. Internally a doubly linked list of nodes
// in a flat buffer: pass 1 tokenizes text/code/delimiters/brackets/HTML, links resolve when a
// `]` is seen, emphasis resolves with the CommonMark delimiter algorithm, and a final walk
// emits text with a style stack.
//
// Text nodes are byte ranges into the block input (or into `scratch` for decoded text such
// as entities), so each rendered byte is copied once: source -> output. Link and image strings
// are byte ranges in one string store (`strings`). All working storage is raw buffers owned by
// this object and reused across blocks: no per-block allocation, no uniqueness checks.

import Darwin

final class InlineParser {
    // Node kinds
    static let kText: UInt8 = 0, kDelim: UInt8 = 1, kSoft: UInt8 = 2, kHard: UInt8 = 3, kCode: UInt8 = 4
    static let kOpen: UInt8 = 5, kClose: UInt8 = 6, kBracket: UInt8 = 7, kLinkOpen: UInt8 = 8, kLinkClose: UInt8 = 9
    static let kImageOpen: UInt8 = 10, kImageClose: UInt8 = 11, kImageAtom: UInt8 = 12

    /// Text/code node bytes live in `scratch` (else in the block input).
    static let fScratch: UInt8 = 1

    struct Node: BitwiseCopyable {
        var kind: UInt8
        var flags: UInt8 = 0    // delim: 1 = can open, 2 = can close; bracket: 1 = image, 2 = inactive; text/code: fScratch
        var a: Int32 = 0        // text/code: start; delim: remaining count
        var b: Int32 = 0        // text/code: end; delim: original count
        var c: Int32 = 0        // delim: char; open/close: style bits; link/image: ref index
        var next: Int32 = -1
        var prev: Int32 = -1
    }

    struct Bracket: BitwiseCopyable {
        var node: Int32
        var delimBottom: Int32
    }

    // Per block (reset by `parse`).
    var nodes: RawArray<Node>
    var head: Int32 = -1
    var tail: Int32 = -1
    var delims: RawArray<Int32>
    var brackets: RawArray<Bracket>
    var scratch: ByteBuf
    /// The current block's input; text nodes without `fScratch` index it.
    var src: UnsafePointer<UInt8>

    // Reused helpers.
    var gather: ByteBuf     // joined lines (see `joinLines`)
    var label: ByteBuf      // normalized reference labels, attribute values
    var tmp: ByteBuf        // link text for labels
    var cells: RawArray<Int32>   // `splitCells` output, pairs

    // The document being built.
    var out: ByteBuf
    var runs: RawArray<MDRun>
    var strings: ByteBuf
    var links: RawArray<StrRange>
    var images: RawArray<MDImageSpec>
    var footnotes: [String: Int] = [:]
    /// Block-level hints discovered while parsing HTML (align, heading level).
    var blockAlign: MDAlign = .left
    /// Alignment of open `<div>`/`<center>` elements. They often span several Markdown blocks
    /// (README headers: `<div align="center">`, blank line, links paragraph, `</div>`); the
    /// blocks in between inherit the innermost alignment, as in a browser.
    var alignStack: [MDAlign] = []
    var blockHeading: UInt8 = 0
    var sawRule = false
    /// `<picture><source media=dark srcset=...>` seen; applies to the next image.
    var pendingDark = StrRange.none

    // Link reference definitions: open addressing on normalized label bytes (kept in
    // `strings`), so resolving `[text]` allocates nothing.
    struct RefSlot: BitwiseCopyable { var hash: UInt32; var key: StrRange; var dest: StrRange }
    var refSlots: UnsafeMutablePointer<RefSlot>?
    var refMask = 0
    var refCount = 0

    private var finished = false
    let special: UnsafePointer<UInt8> = InlineParser.specialTable
    let specialSet = InlineParser.specialNibbles
    static let specialNibbles = NibbleSet { InlineParser.specialTable[Int($0)] != 0 }

    /// Working buffers start in `arena`; the output text and string store are their own
    /// allocations (they become the document's).
    init(sourceCount n: Int, _ arena: inout Arena) {
        nodes = RawArray(capacity: 128, &arena)
        delims = RawArray(capacity: 32, &arena)
        brackets = RawArray(capacity: 16, &arena)
        scratch = ByteBuf(capacity: 256, &arena)
        gather = ByteBuf(capacity: 512, &arena)
        label = ByteBuf(capacity: 64, &arena)
        tmp = ByteBuf(capacity: 64, &arena)
        cells = RawArray(capacity: 32, &arena)
        links = RawArray(capacity: 32, &arena)
        images = RawArray(capacity: 8, &arena)
        runs = RawArray(capacity: min(n / 32 + 16, 1024), &arena)
        src = UnsafePointer(scratch.p)
        out = ByteBuf(capacity: n + n / 16 + 64)
        strings = ByteBuf(capacity: 256)
    }

    deinit {
        nodes.free(); delims.free(); brackets.free(); scratch.free()
        gather.free(); label.free(); tmp.free(); cells.free()
        runs.free(); links.free(); images.free()
        refSlots?.deallocate()
        if !finished { out.free(); strings.free() }
    }

    /// Hands the built text and strings to a document. The parser must not be used after.
    func finish() -> MarkdownDocument {
        finished = true
        let doc = MarkdownDocument(text: out.finish(), strings: strings.finish(),
                                   links: links.toArray(), images: images.toArray())
        doc.runs = runs.toArray()
        return doc
    }

    /// Bytes that stop the plain-text scan. ':' '.' (and 0x1A/0x0E, which match them under
    /// the case-folding compare `bareAutolink` uses) trigger the bare-autolink check, which
    /// looks back for "http"/"https"/"www": cheaper than testing every word start.
    nonisolated(unsafe) static let specialTable: UnsafePointer<UInt8> = {
        let t = UnsafeMutablePointer<UInt8>.allocate(capacity: 256)
        t.initialize(repeating: 0, count: 256)
        for b: UInt8 in [0x5C, 0x0A, 0x60, 0x2A, 0x5F, 0x7E, 0x21, 0x5B, 0x5D, 0x3C, 0x26] { t[Int(b)] = 1 }
        for b: UInt8 in [0x3A, 0x1A, 0x2E, 0x0E] { t[Int(b)] = 2 }
        return UnsafePointer(t)
    }()

    // MARK: - Nodes

    @inline(__always) @discardableResult
    func add(_ kind: UInt8, a: Int32 = 0, b: Int32 = 0, c: Int32 = 0, flags: UInt8 = 0) -> Int32 {
        let i = Int32(truncatingIfNeeded: nodes.count)
        nodes.append(Node(kind: kind, flags: flags, a: a, b: b, c: c, next: -1, prev: tail))
        if tail >= 0 { nodes[Int(tail)].next = i } else { head = i }
        tail = i
        return i
    }

    /// Text node for `src[s..<e]`.
    @inline(__always) func text(_ s: Int, _ e: Int) {
        add(InlineParser.kText, a: Int32(truncatingIfNeeded: s), b: Int32(truncatingIfNeeded: e))
    }

    /// Text node for scratch bytes appended since `mark`.
    @inline(__always) func scratchText(from mark: Int) {
        add(InlineParser.kText, a: Int32(mark), b: Int32(scratch.count), flags: InlineParser.fScratch)
    }

    func scratchText(_ s: StaticString) {
        let m = scratch.count
        scratch.append(s)
        scratchText(from: m)
    }

    /// Inserts a node after `after` (doubly linked, O(1)).
    @discardableResult
    func insert(_ n: Node, after: Int32) -> Int32 {
        var m = n
        m.next = nodes[Int(after)].next
        m.prev = after
        let i = Int32(nodes.count)
        nodes.append(m)
        if m.next >= 0 { nodes[Int(m.next)].prev = i }
        nodes[Int(after)].next = i
        if tail == after { tail = i }
        return i
    }

    /// Inserts a node before `before`.
    @discardableResult
    func insert(_ n: Node, before: Int32) -> Int32 {
        let pv = nodes[Int(before)].prev
        if pv >= 0 { return insert(n, after: pv) }
        var m = n
        m.prev = -1
        m.next = before
        let i = Int32(nodes.count)
        nodes.append(m)
        nodes[Int(before)].prev = i
        head = i
        return i
    }

    // MARK: - Entry

    /// Parses `p[0..<n]` (padded: readable 16 bytes past `n`) and appends rendered text + runs.
    func parse(_ p: UnsafePointer<UInt8>, _ n: Int) {
        nodes.count = 0
        delims.count = 0
        brackets.count = 0
        scratch.count = 0
        head = -1
        tail = -1
        src = p
        tokenize(p, n)
        processEmphasis(bottom: 0)
        emit()
    }

    /// Content lines joined with "\n" (plus one after the last line if `trailingNewline`).
    /// When the lines are contiguous in the source (unindented paragraphs, every one-line
    /// block) this is a pointer into the source: no copy. Else a copy in `gather`.
    func joinLines(_ p: UnsafePointer<UInt8>, _ lines: UnsafePointer<Int32>, _ count: Int,
                   trailingNewline: Bool) -> (UnsafePointer<UInt8>, Int) {
        if count == 0 { return (p, 0) }
        let first = Int(lines[0])
        let last = Int(lines[2 * count - 1])
        var contiguous = !trailingNewline || p[last] == 0x0A
        if contiguous {
            var k = 1
            while k < count {
                if lines[2 * k] != lines[2 * k - 1] &+ 1 { contiguous = false; break }
                k += 1
            }
        }
        if contiguous && last >= first {
            return (p + first, last - first + (trailingNewline ? 1 : 0))
        }
        gather.count = 0
        for k in 0..<count {
            let s = Int(lines[2 * k]), e = Int(lines[2 * k + 1])
            if k > 0 { gather.append(0x0A) }
            if e > s { gather.appendPadded(p + s, e - s) }
        }
        if trailingNewline { gather.append(0x0A) }
        return (UnsafePointer(gather.p), gather.count)
    }

    // MARK: - Tokenize

    func tokenize(_ p: UnsafePointer<UInt8>, _ n: Int) {
        let cls = special
        let set = specialSet
        var i = 0
        var textStart = 0
        @inline(__always) func flush(_ upto: Int) {
            if upto > textStart { text(textStart, upto) }
        }
        while i < n {
            // Skip plain text 16 bytes at a time (reads past `n` are padding or later input,
            // and a hit past `n` ends the loop).
            let m = nibblesOf(set.match(load16(p + i)))
            if m == 0 { i &+= 16; continue }
            i &+= Int(truncatingIfNeeded: m.trailingZeroBitCount >> 2)
            if i >= n { break }
            let b = p[i]
            let k = cls[Int(b)]
            if k == 0 { i &+= 1; continue }   // (the vector set is exact; never taken)
            if k == 2 {
                // GFM bare autolinks at word starts (www., http://, https://), found from the
                // ':' or '.' that follows the prefix.
                if let s = autolinkStart(p, i, textStart), let e = InlineParser.bareAutolink(p, s, n) {
                    flush(s)
                    let ref = Int32(links.count)
                    let m = strings.count
                    if (p[s] | 0x20) == 0x77 { strings.append("http://") }
                    strings.appendPadded(p + s, e - s)
                    links.append(StrRange(start: Int32(m), end: Int32(strings.count)))
                    add(InlineParser.kLinkOpen, c: ref)
                    text(s, e)
                    add(InlineParser.kLinkClose)
                    i = e
                    textStart = i
                    continue
                }
                i &+= 1
                continue
            }
            switch b {
            case 0x5C: // backslash
                if i + 1 < n && InlineParser.isASCIIPunct(p[i + 1]) {
                    flush(i)
                    text(i + 1, i + 2)
                    i += 2
                    textStart = i
                } else if i + 1 < n && p[i + 1] == 0x0A {
                    flush(i)
                    add(InlineParser.kHard)
                    i += 2
                    while i < n && (p[i] == 0x20 || p[i] == 0x09) { i += 1 }
                    textStart = i
                } else { i += 1 }
            case 0x0A: // line break
                var e = i
                var spaces = 0
                while e > textStart && p[e - 1] == 0x20 { e -= 1; spaces += 1 }
                flush(e)
                add(spaces >= 2 ? InlineParser.kHard : InlineParser.kSoft)
                i += 1
                while i < n && (p[i] == 0x20 || p[i] == 0x09) { i += 1 }
                textStart = i
            case 0x60: // code span
                var k = i
                while k < n && p[k] == 0x60 { k += 1 }
                let ticks = k - i
                if let close = InlineParser.findCodeClose(p, k, n, ticks) {
                    flush(i)
                    codeSpan(p, k, close)
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
                let lf = !InlineParser.isWhite(after) && (!InlineParser.isPunct(after) || InlineParser.isWhite(before) || InlineParser.isPunct(before))
                let rf = !InlineParser.isWhite(before) && (!InlineParser.isPunct(before) || InlineParser.isWhite(after) || InlineParser.isPunct(after))
                var canOpen = lf, canClose = rf
                if b == 0x5F {
                    canOpen = lf && (!rf || InlineParser.isPunct(before))
                    canClose = rf && (!lf || InlineParser.isPunct(after))
                }
                if b == 0x7E && count > 2 { canOpen = false; canClose = false }
                let idx = add(InlineParser.kDelim, a: Int32(count), b: Int32(count), c: Int32(b),
                              flags: (canOpen ? 1 : 0) | (canClose ? 2 : 0))
                if canOpen || canClose { delims.append(idx) }
                i = k
                textStart = i
            case 0x21: // ![
                if i + 1 < n && p[i + 1] == 0x5B {
                    flush(i)
                    let idx = add(InlineParser.kBracket, flags: 1)
                    brackets.append(Bracket(node: idx, delimBottom: Int32(delims.count)))
                    i += 2
                    textStart = i
                } else { i += 1 }
            case 0x5B: // [
                flush(i)
                // Footnote reference [^label] (and definition "[^label]:" at block start).
                if i + 1 < n && p[i + 1] == 0x5E, let close = InlineParser.findByte(p, i + 2, n, 0x5D), close > i + 2 {
                    let label = String(decoding: UnsafeBufferPointer(start: p + i + 2, count: close - i - 2), as: UTF8.self)
                    let isDef = close + 1 < n && p[close + 1] == 0x3A && i == 0
                    let num: Int
                    if let v = footnotes[label] { num = v } else { num = footnotes.count + 1; footnotes[label] = num }
                    let fs = Int32(MDStyle.superscript.rawValue | MDStyle.footnoteRef.rawValue)
                    add(InlineParser.kOpen, c: fs)
                    let m = scratch.count
                    InlineParser.appendDecimal(num, &scratch)
                    scratchText(from: m)
                    add(InlineParser.kClose, c: fs)
                    i = close + (isDef ? 2 : 1)
                    if isDef { scratchText(" "); while i < n && p[i] == 0x20 { i += 1 } }
                    textStart = i
                    continue
                }
                let idx = add(InlineParser.kBracket)
                brackets.append(Bracket(node: idx, delimBottom: Int32(delims.count)))
                i += 1
                textStart = i
            case 0x5D: // ]
                flush(i)
                i = closeBracket(p, i, n)
                textStart = i
            case 0x3C: // < autolink or HTML
                if let a = InlineParser.autolink(p, i, n) {
                    flush(i)
                    let ref = Int32(links.count)
                    let m = strings.count
                    if a.isEmail { strings.append("mailto:") }
                    strings.appendPadded(p + a.urlStart, a.urlEnd - a.urlStart)
                    links.append(StrRange(start: Int32(m), end: Int32(strings.count)))
                    add(InlineParser.kLinkOpen, c: ref)
                    text(a.urlStart, a.urlEnd)
                    add(InlineParser.kLinkClose)
                    i = a.end
                    textStart = i
                } else if i + 3 < n && p[i + 1] == 0x21 && p[i + 2] == 0x2D && p[i + 3] == 0x2D {
                    // <!-- comment -->
                    flush(i)
                    var e = i + 4
                    while e + 2 < n && !(p[e] == 0x2D && p[e + 1] == 0x2D && p[e + 2] == 0x3E) { e += 1 }
                    i = min(n, e + 3)
                    textStart = i
                } else if let e = InlineParser.htmlTagEnd(p, i, n) {
                    flush(i)
                    htmlTag(p, i, e)
                    i = e
                    textStart = i
                } else { i += 1 }
            case 0x26: // entity
                let m = scratch.count
                if let e = InlineParser.entity(p, i, n, into: &scratch) {
                    flush(i)
                    scratchText(from: m)
                    i = e
                    textStart = i
                } else { i += 1 }
            default:
                i += 1
            }
        }
        flush(n)
    }

    /// Start of a bare autolink prefix ending at the trigger byte `p[i]` (':' after "http" or
    /// "https", '.' after "www"), at a word start inside the current text run.
    @inline(__always)
    func autolinkStart(_ p: UnsafePointer<UInt8>, _ i: Int, _ textStart: Int) -> Int? {
        let t = p[i] | 0x20
        var s: Int
        if t == 0x3A {
            guard i - 4 >= textStart, (p[i - 1] | 0x20) == 0x70 || (p[i - 1] | 0x20) == 0x73 else { return nil }
            s = (p[i - 1] | 0x20) == 0x73 ? i - 5 : i - 4
            if s < textStart { return nil }
            if (p[s] | 0x20) != 0x68 || (p[s + 1] | 0x20) != 0x74 || (p[s + 2] | 0x20) != 0x74 || (p[s + 3] | 0x20) != 0x70 { return nil }
        } else {
            s = i - 3
            if s < textStart { return nil }
            if (p[s] | 0x20) != 0x77 || (p[s + 1] | 0x20) != 0x77 || (p[s + 2] | 0x20) != 0x77 { return nil }
        }
        if s > 0 && InlineParser.isAlnum(p[s - 1]) { return nil }
        return s
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

    static func appendDecimal(_ v: Int, _ buf: inout ByteBuf) {
        var digits: [UInt8] = []
        var x = v
        repeat { digits.append(UInt8(x % 10) + 0x30); x /= 10 } while x > 0
        for d in digits.reversed() { buf.append(d) }
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

    /// Code span content `p[s..<e]`: one leading + trailing space stripped if both present
    /// (and not all spaces); line breaks become spaces. Single-line spans reference the input.
    func codeSpan(_ p: UnsafePointer<UInt8>, _ s: Int, _ e: Int) {
        var a = s, b = e
        var newline = false
        for k in a..<b where p[k] == 0x0A { newline = true; break }
        if b - a >= 2 && (p[a] == 0x20 || p[a] == 0x0A) && (p[b - 1] == 0x20 || p[b - 1] == 0x0A) {
            var allSpace = true
            for k in a..<b where p[k] != 0x20 && p[k] != 0x0A { allSpace = false; break }
            if !allSpace { a += 1; b -= 1 }
        }
        if !newline {
            add(InlineParser.kCode, a: Int32(a), b: Int32(b))
            return
        }
        let m = scratch.count
        for k in a..<b { scratch.append(p[k] == 0x0A ? 0x20 : p[k]) }
        add(InlineParser.kCode, a: Int32(m), b: Int32(scratch.count), flags: InlineParser.fScratch)
    }

    // MARK: - Links

    /// Handles `]` at `i`: tries to form a link/image with the nearest active opener.
    func closeBracket(_ p: UnsafePointer<UInt8>, _ i: Int, _ n: Int) -> Int {
        guard !brackets.isEmpty else {
            text(i, i + 1)
            return i + 1
        }
        let opener = brackets.last.node
        let delimBottom = Int(brackets.last.delimBottom)
        let isImage = nodes[Int(opener)].flags & 1 != 0
        if nodes[Int(opener)].flags & 2 != 0 {   // inactive
            brackets.removeLast()
            text(i, i + 1)
            return i + 1
        }
        var dest = StrRange.none
        var end = i + 1
        if i + 1 < n && p[i + 1] == 0x28 {
            let m = strings.count
            if let e = inlineLinkTail(p, i + 2, n) {
                dest = StrRange(start: Int32(m), end: Int32(strings.count))
                end = e
            } else {
                strings.count = m
            }
        }
        if dest.isNone && refCount > 0 {   // no definitions: skip building and folding labels
            var haveText = false
            if i + 1 < n && p[i + 1] == 0x5B, let close = InlineParser.findLabelEnd(p, i + 2, n) {
                if close > i + 2 {
                    normalizeLabel(p + i + 2, close - i - 2)
                } else {
                    linkText(from: opener)
                    haveText = true
                    normalizeLabel(UnsafePointer(tmp.p), tmp.count)
                }
                if let r = findRef() { dest = r; end = close + 1 }
            }
            if dest.isNone {
                if !haveText { linkText(from: opener) }
                normalizeLabel(UnsafePointer(tmp.p), tmp.count)
                if let r = findRef() { dest = r; end = i + 1 }
            }
        }
        guard !dest.isNone else {
            brackets.removeLast()
            text(i, i + 1)
            return i + 1
        }
        // Emphasis inside the link text resolves first (only delimiters after the opener).
        processEmphasis(bottom: delimBottom)
        if isImage {
            let ref = Int32(images.count)
            linkText(from: opener)
            let m = strings.count
            strings.appendPadded(UnsafePointer(tmp.p), tmp.count)
            var img = MDImageSpec(url: dest, alt: StrRange(start: Int32(m), end: Int32(strings.count)))
            if !pendingDark.isNone { img.dark = pendingDark; pendingDark = .none }
            images.append(img)
            nodes[Int(opener)].kind = InlineParser.kImageOpen
            nodes[Int(opener)].c = ref
            add(InlineParser.kImageClose, c: ref)
        } else {
            let ref = Int32(links.count)
            links.append(dest)
            nodes[Int(opener)].kind = InlineParser.kLinkOpen
            nodes[Int(opener)].c = ref
            add(InlineParser.kLinkClose, c: ref)
            // No links inside links: deactivate earlier [ openers.
            for k in 0..<brackets.count where nodes[Int(brackets[k].node)].flags & 1 == 0 {
                nodes[Int(brackets[k].node)].flags |= 2
            }
        }
        brackets.removeLast()
        return end
    }

    /// Plain text of the nodes after `opener` (reference labels, image alt text), into `tmp`.
    func linkText(from opener: Int32) {
        tmp.count = 0
        var k = nodes[Int(opener)].next
        while k >= 0 {
            let nd = nodes[Int(k)]
            switch nd.kind {
            case InlineParser.kText, InlineParser.kCode:
                let base = nd.flags & InlineParser.fScratch != 0 ? UnsafePointer(scratch.p) : src
                tmp.append(base + Int(nd.a), Int(nd.b - nd.a))
            case InlineParser.kDelim:
                for _ in 0..<Int(nd.a) { tmp.append(UInt8(truncatingIfNeeded: nd.c)) }
            case InlineParser.kSoft, InlineParser.kHard:
                tmp.append(0x20)
            default: break
            }
            k = nd.next
        }
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

    /// Parses `dest "title")` after `(`, appending the unescaped destination to `strings`.
    /// Returns the end index (after `)`), or nil (the caller rolls `strings` back).
    func inlineLinkTail(_ p: UnsafePointer<UInt8>, _ i: Int, _ n: Int) -> Int? {
        var k = InlineParser.skipWS(p, i, n)
        if k < n && p[k] == 0x3C {   // <dest>
            var e = k + 1
            while e < n && p[e] != 0x3E && p[e] != 0x0A && p[e] != 0x3C { if p[e] == 0x5C { e += 1 }; e += 1 }
            if e >= n || p[e] != 0x3E { return nil }
            InlineParser.unescape(p, k + 1, e, into: &strings)
            k = e + 1
        } else {
            let s = k
            let escapes: Bool
            (k, escapes) = InlineParser.plainDestEnd(p, s, n)
            if escapes { InlineParser.unescape(p, s, k, into: &strings) }
            else if k > s { strings.appendPadded(p + s, k - s) }
        }
        let beforeTitle = k
        k = InlineParser.skipWS(p, k, n)
        if k < n && k > beforeTitle && (p[k] == 0x22 || p[k] == 0x27 || p[k] == 0x28) {
            // The title is validated but not kept (nothing renders it).
            let close: UInt8 = p[k] == 0x28 ? 0x29 : p[k]
            var e = k + 1
            while e < n && p[e] != close { if p[e] == 0x5C { e += 1 }; e += 1 }
            if e >= n { return nil }
            k = InlineParser.skipWS(p, e + 1, n)
        }
        if k >= n || p[k] != 0x29 { return nil }
        return k + 1
    }

    /// End of a destination without `<>` starting at `start`: the first space or control byte,
    /// or an unbalanced `)`; `\`-escaped punctuation is skipped. Scans 16 bytes at a time
    /// (URLs are long and plain). `escapes` is true if a `\` or `&` occurs before the end
    /// (then the destination needs `unescape`).
    static func plainDestEnd(_ p: UnsafePointer<UInt8>, _ start: Int, _ n: Int) -> (Int, escapes: Bool) {
        var k = start
        var depth = 0
        var escapes = false
        let space = splat(0x20), bs = splat(0x5C), open = splat(0x28), close = splat(0x29), amp = splat(0x26)
        while k < n {
            let v = load16(p + k)
            let stop = nibbles((v .<= space) .| (v .== bs) .| (v .== open) .| (v .== close))
            let a = nibbles(v .== amp)
            if stop == 0 {
                if a != 0 { escapes = true }   // (possibly past `n`: only costs the slow copy)
                k &+= 16
                continue
            }
            let lane = stop.trailingZeroBitCount >> 2
            if a & ((1 << UInt64(4 * lane)) &- 1) != 0 { escapes = true }
            let j = k + lane
            if j >= n { return (n, escapes) }
            let c = p[j]
            if c == 0x5C {
                escapes = true
                k = j + 1 < n && isASCIIPunct(p[j + 1]) ? j + 2 : j + 1
            } else if c == 0x28 {
                depth += 1
                k = j + 1
            } else if c == 0x29 {
                if depth == 0 { return (j, escapes) }
                depth -= 1
                k = j + 1
            } else {
                return (j, escapes)
            }
        }
        return (n, escapes)
    }

    @inline(__always) static func skipWS(_ p: UnsafePointer<UInt8>, _ i: Int, _ n: Int) -> Int {
        var k = i
        while k < n && (p[k] == 0x20 || p[k] == 0x09 || p[k] == 0x0A) { k += 1 }
        return k
    }

    /// Resolves backslash escapes and entities in `p[s..<e]` (a destination, title or
    /// attribute value), appending the result to `buf`. `p` is a padded buffer (block input).
    static func unescape(_ p: UnsafePointer<UInt8>, _ s: Int, _ e: Int, into buf: inout ByteBuf) {
        var k = findAny(p, s, e, 0x5C, 0x26, 0x5C, 0x26)
        if k == e {   // the common case: no escapes or entities
            if e > s { buf.appendPadded(p + s, e - s) }
            return
        }
        if k > s { buf.appendPadded(p + s, k - s) }
        while k < e {
            if p[k] == 0x5C && k + 1 < e && isASCIIPunct(p[k + 1]) { buf.append(p[k + 1]); k += 2; continue }
            if p[k] == 0x26, let end = entity(p, k, e, into: &buf) { k = end; continue }
            buf.append(p[k])
            k += 1
        }
    }

    // MARK: - Reference definitions

    /// Normalized label `p[0..<n]` into `label`: case-folded, whitespace collapsed.
    func normalizeLabel(_ p: UnsafePointer<UInt8>, _ n: Int) {
        // ASCII fast path on bytes; split/joined/lowercased cost ~15% of parse time on docs
        // with many bracketed spans.
        label.count = 0
        var space = false
        for k in 0..<n {
            let c = p[k]
            if c >= 0x80 { normalizeLabelUnicode(p, n); return }
            if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D { space = label.count > 0; continue }
            if space { label.append(0x20); space = false }
            label.append(c >= 0x41 && c <= 0x5A ? c | 0x20 : c)
        }
    }

    func normalizeLabelUnicode(_ p: UnsafePointer<UInt8>, _ n: Int) {
        let s = String(decoding: UnsafeBufferPointer(start: p, count: n), as: UTF8.self)
        label.count = 0
        label.append(s.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }).joined(separator: " "))
    }

    @inline(__always) func labelHash() -> UInt32 {
        var h: UInt32 = 2166136261
        for k in 0..<label.count { h = (h ^ UInt32(label.p[k])) &* 16777619 }
        return h | 1   // 0 marks an empty slot
    }

    /// Destination for the normalized label in `label`.
    func findRef() -> StrRange? {
        guard let slots = refSlots else { return nil }
        let h = labelHash()
        var i = Int(h) & refMask
        while slots[i].hash != 0 {
            let s = slots[i]
            if s.hash == h && Int(s.key.end - s.key.start) == label.count
                && memcmp(strings.p + Int(s.key.start), label.p, label.count) == 0 {
                return s.dest
            }
            i = (i + 1) & refMask
        }
        return nil
    }

    struct RefDef {
        var consumed: Int
        var labelStart: Int, labelEnd: Int
        var destStart: Int, destEnd: Int
    }

    /// Records a definition parsed from `base` unless its label is already defined (the first
    /// definition wins).
    func addReference(_ base: UnsafePointer<UInt8>, _ d: RefDef) {
        normalizeLabel(base + d.labelStart, d.labelEnd - d.labelStart)
        if findRef() != nil { return }
        if refSlots == nil || (refCount + 1) * 2 > refMask + 1 { growRefs() }
        let key = StrRange(start: Int32(strings.count), end: Int32(strings.count + label.count))
        strings.append(UnsafePointer(label.p), label.count)
        let ds = strings.count
        InlineParser.unescape(base, d.destStart, d.destEnd, into: &strings)
        insertRef(RefSlot(hash: labelHash(), key: key, dest: StrRange(start: Int32(ds), end: Int32(strings.count))))
    }

    private func insertRef(_ slot: RefSlot) {
        let slots = refSlots!
        var i = Int(slot.hash) & refMask
        while slots[i].hash != 0 { i = (i + 1) & refMask }
        slots[i] = slot
        refCount += 1
    }

    private func growRefs() {
        let old = refSlots, oldCap = refSlots == nil ? 0 : refMask + 1
        let cap = max(16, oldCap * 2)
        let slots = UnsafeMutablePointer<RefSlot>.allocate(capacity: cap)
        slots.initialize(repeating: RefSlot(hash: 0, key: .none, dest: .none), count: cap)
        refSlots = slots
        refMask = cap - 1
        refCount = 0
        if let old {
            for k in 0..<oldCap where old[k].hash != 0 { insertRef(old[k]) }
            old.deallocate()
        }
    }

    /// `[label]: dest "title"` at the start of `p[0..<n]`: bytes consumed (through the line
    /// end) and the label and raw destination ranges.
    static func parseReferenceDefinition(_ p: UnsafePointer<UInt8>, _ n: Int) -> RefDef? {
        var k = 0
        while k < n && k < 3 && p[k] == 0x20 { k += 1 }
        guard k < n, p[k] == 0x5B, let close = findLabelEnd(p, k + 1, n), close > k + 1,
              close + 1 < n, p[close + 1] == 0x3A else { return nil }
        let ls = k + 1, le = close
        if p[ls] == 0x5E {   // footnote definition, rendered inline
            // (`String.hasPrefix("^")` compares grapheme clusters: a combining mark after the
            // caret makes it a different first character.)
            if ls + 1 >= le || p[ls + 1] < 0x80
                || String(decoding: UnsafeBufferPointer(start: p + ls, count: le - ls), as: UTF8.self).hasPrefix("^") { return nil }
        }
        var blank = true
        for j in ls..<le where p[j] != 0x20 && p[j] != 0x0A { blank = false; break }
        if blank { return nil }
        k = skipWS(p, close + 2, n)
        var ds = 0, de = 0
        if k < n && p[k] == 0x3C {
            var e = k + 1
            while e < n && p[e] != 0x3E && p[e] != 0x0A { e += 1 }
            if e >= n || p[e] != 0x3E { return nil }
            ds = k + 1; de = e
            k = e + 1
        } else {
            let s = k
            while k < n && p[k] > 0x20 { k += 1 }
            if k == s { return nil }
            ds = s; de = k
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
                    return RefDef(consumed: min(n, t + 1), labelStart: ls, labelEnd: le, destStart: ds, destEnd: de)
                }
            }
        }
        // No (valid) title: the destination must end its line.
        var t = afterDest
        while t < n && (p[t] == 0x20 || p[t] == 0x09) { t += 1 }
        if t < n && p[t] != 0x0A { return nil }
        return RefDef(consumed: min(n, t + 1), labelStart: ls, labelEnd: le, destStart: ds, destEnd: de)
    }

    // MARK: - Autolinks

    struct Autolink { var end: Int; var urlStart: Int; var urlEnd: Int; var isEmail: Bool }

    static func autolink(_ p: UnsafePointer<UInt8>, _ i: Int, _ n: Int) -> Autolink? {
        var k = i + 1
        let s = k
        while k < n && p[k] < 0x80 && (isAlnum(p[k]) || p[k] == 0x2B || p[k] == 0x2E || p[k] == 0x2D) { k += 1 }
        if k - s >= 2 && k - s <= 32 && k < n && p[k] == 0x3A {
            var e = k + 1
            while e < n && p[e] > 0x20 && p[e] != 0x3C && p[e] != 0x3E { e += 1 }
            if e < n && p[e] == 0x3E {
                return Autolink(end: e + 1, urlStart: s, urlEnd: e, isEmail: false)
            }
        }
        var e = s
        var at = -1
        while e < n && p[e] != 0x3E && p[e] > 0x20 && p[e] != 0x3C {
            if p[e] == 0x40 { if at >= 0 { return nil }; at = e }
            e += 1
        }
        if at > s && e < n && p[e] == 0x3E && e > at + 1 && memchr(p + at, 0x2E, e - at) != nil {
            return Autolink(end: e + 1, urlStart: s, urlEnd: e, isEmail: true)
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

    /// Decodes the entity at `p[i]` (`&...;`) into `buf`; returns its end, or nil (nothing
    /// written) if it isn't one.
    static func entity(_ p: UnsafePointer<UInt8>, _ i: Int, _ n: Int, into buf: inout ByteBuf) -> Int? {
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
            buf.appendScalar(v)
            return k + 1
        }
        let s = k
        while k < n && k - s < 32 && p[k] < 0x80 && isAlnum(p[k]) { k += 1 }
        guard k > s, k < n, p[k] == 0x3B else { return nil }
        let name = String(decoding: UnsafeBufferPointer(start: p + s, count: k - s), as: UTF8.self)
        guard let v = Entities.named[name] else { return nil }
        buf.append(v)
        return k + 1
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
    func htmlTag(_ p: UnsafePointer<UInt8>, _ i: Int, _ e: Int) {
        var k = i + 1
        let closing = p[k] == 0x2F
        if closing { k += 1 }
        let ns = k
        while k < e && p[k] < 0x80 && (InlineParser.isAlnum(p[k]) || p[k] == 0x2D) { k += 1 }
        let name = InlineParser.tagKey(p, ns, k)
        let attrs = k
        // Attributes are read only for the tags that use them (never on closing tags).
        func attr(_ wanted: StaticString, into buf: inout ByteBuf) -> Bool {
            if closing { return false }
            return InlineParser.attribute(p, attrs, e, wanted, into: &buf)
        }
        func style(_ s: MDStyle) {
            add(closing ? InlineParser.kClose : InlineParser.kOpen, c: Int32(s.rawValue))
        }
        /// Lowercased `align` attribute compared to the literal (nil if absent).
        func align() -> UInt64? {
            label.count = 0
            guard attr("align", into: &label) else { return nil }
            return InlineParser.tagKeyAny(label.p, label.count)
        }
        switch name {
        case Tag.br: add(InlineParser.kHard)
        case Tag.b, Tag.strong, Tag.summary: style(.strong)
        case Tag.i, Tag.em, Tag.cite, Tag.var_, Tag.dfn: style(.emphasis)
        case Tag.code, Tag.tt, Tag.samp: style(.code)
        case Tag.kbd: style(.kbd)
        case Tag.s, Tag.del, Tag.strike: style(.strike)
        case Tag.sub: style(.subscriptStyle)
        case Tag.sup: style(.superscript)
        case Tag.a:
            if closing { add(InlineParser.kLinkClose) }
            else {
                let m = strings.count
                if attr("href", into: &strings) {
                    let ref = Int32(links.count)
                    links.append(StrRange(start: Int32(m), end: Int32(strings.count)))
                    add(InlineParser.kLinkOpen, c: ref)
                } else { strings.count = m }
            }
        case Tag.img:
            let m = strings.count
            if attr("src", into: &strings) {
                let url = StrRange(start: Int32(m), end: Int32(strings.count))
                let am = strings.count
                if !attr("alt", into: &strings) { strings.count = am }
                var img = MDImageSpec(url: url, alt: StrRange(start: Int32(am), end: Int32(strings.count)))
                label.count = 0
                if attr("width", into: &label) { img.width = InlineParser.number(label) }
                label.count = 0
                if attr("height", into: &label) { img.height = InlineParser.number(label) }
                if !pendingDark.isNone { img.dark = pendingDark; pendingDark = .none }
                let ref = Int32(images.count)
                images.append(img)
                add(InlineParser.kImageAtom, c: ref)
            } else { strings.count = m }
        case Tag.source:
            // <picture><source media="(prefers-color-scheme: dark)" srcset="..."><img ...></picture>
            label.count = 0
            if attr("media", into: &label), memmem(label.p, label.count, "dark", 4) != nil {
                let m = strings.count
                if attr("srcset", into: &strings) {
                    var e = m
                    while e < strings.count && strings.p[e] != 0x20 { e += 1 }   // first URL
                    strings.count = e
                    pendingDark = StrRange(start: Int32(m), end: Int32(e))
                } else { strings.count = m }
            }
        case Tag.p, Tag.div, Tag.center:
            if !closing {
                let a = align()
                if name == Tag.center || a == Tag.center { blockAlign = .center }
                else if a == InlineParser.alignRight { blockAlign = .right }
                else if a == InlineParser.alignLeft { blockAlign = .left }
                if name != Tag.p { alignStack.append(a == nil && name != Tag.center ? (alignStack.last ?? .left) : blockAlign) }
            } else if name != Tag.p, !alignStack.isEmpty {
                alignStack.removeLast()
            }
            if tail >= 0 { add(InlineParser.kHard) }
        case _ where k - ns == 2 && p[ns] | 0x20 == 0x68 && p[ns + 1] >= 0x31 && p[ns + 1] <= 0x36:   // h1-h6
            if !closing {
                blockHeading = p[ns + 1] - 0x30
                if align() == Tag.center { blockAlign = .center }
            }
        case Tag.hr: sawRule = true
        case Tag.li: if !closing { if tail >= 0 { add(InlineParser.kHard) }; scratchText("• ") }
        case Tag.tr: if closing { add(InlineParser.kHard) }
        case Tag.td, Tag.th: if closing { scratchText("  ") }
        default: break   // unknown tags are dropped; their text content stays
        }
    }

    static let alignRight = tagKey("right"), alignLeft = tagKey("left")

    /// `tagKey` for an attribute value: exact lowercase match needs every byte ASCII (a value
    /// whose `lowercased()` is "center" is ASCII; 0 never equals a key).
    static func tagKeyAny(_ p: UnsafePointer<UInt8>, _ n: Int) -> UInt64 {
        if n == 0 || n > 8 { return 0 }
        var v: UInt64 = 0
        for k in 0..<n {
            let c = p[k]
            if c >= 0x80 { return 0 }
            v |= UInt64(c >= 0x41 && c <= 0x5A ? c | 0x20 : c) << (8 * UInt64(k))
        }
        return v
    }

    /// HTML length attribute: "120" or "120px" -> 120; "50%" -> -50 (percent of the content
    /// width, resolved at layout).
    static func number(_ b: ByteBuf) -> Float {
        let s = b.string(0, b.count)
        let v = Float(s.filter { $0.isNumber || $0 == "." }) ?? 0
        return s.hasSuffix("%") ? -min(v, 100) : v
    }

    /// Value of the last attribute named `wanted` (lowercase literal; names compare
    /// ASCII-case-insensitively) in `p[s..<e]`, unescaped into `buf`. False if absent.
    static func attribute(_ p: UnsafePointer<UInt8>, _ s: Int, _ e: Int, _ wanted: StaticString, into buf: inout ByteBuf) -> Bool {
        var k = s
        var vs = -1, ve = -1, found = false
        let wl = wanted.utf8CodeUnitCount
        while k < e {
            while k < e && (isWhite(p[k]) || p[k] == 0x2F) { k += 1 }
            let ns = k
            while k < e && p[k] != 0x3D && !isWhite(p[k]) && p[k] != 0x3E && p[k] != 0x2F { k += 1 }
            if k == ns { k += 1; continue }
            let match = k - ns == wl && BlockParser.lowerEquals(p + ns, wanted)
            while k < e && isWhite(p[k]) { k += 1 }
            var a = 0, b = 0
            if k < e && p[k] == 0x3D {
                k += 1
                while k < e && isWhite(p[k]) { k += 1 }
                if k < e && (p[k] == 0x22 || p[k] == 0x27) {
                    let q = p[k]
                    a = k + 1
                    k = a
                    while k < e && p[k] != q { k += 1 }
                    b = k
                    k += 1
                } else {
                    a = k
                    while k < e && !isWhite(p[k]) && p[k] != 0x3E { k += 1 }
                    b = k
                }
            }
            if match { vs = a; ve = b; found = true }
        }
        if found && ve > vs { unescape(p, vs, ve, into: &buf) }
        return found
    }

    // MARK: - Emphasis (CommonMark "process emphasis")

    func processEmphasis(bottom: Int) {
        // Lowest delimiter index worth searching, per (char, closer length % 3, can-open).
        var openersBottom = InlineArray<18, Int32>(repeating: -1)
        var ci = bottom
        while ci < delims.count {
            let closer = delims[ci]
            let cn = nodes[Int(closer)]
            if cn.flags & 2 == 0 || cn.a == 0 { ci += 1; continue }
            let ch = cn.c
            let key = (ch == 0x2A ? 0 : ch == 0x5F ? 6 : 12) + Int(cn.b % 3) * 2 + Int(cn.flags & 1)
            let ob = Int(openersBottom[key])
            let floor = ob < 0 ? bottom : max(bottom, ob)
            var oi = ci - 1
            var found = -1
            while oi >= floor {
                let on = nodes[Int(delims[oi])]
                if on.c == ch && on.flags & 1 != 0 && on.a > 0 {
                    let both = on.flags == 3 || cn.flags == 3
                    let ruleOf3 = both && (on.b + cn.b) % 3 == 0 && !(on.b % 3 == 0 && cn.b % 3 == 0)
                    let tildeOK = ch != 0x7E || on.a == cn.a
                    if !ruleOf3 && tildeOK { found = oi; break }
                }
                oi -= 1
            }
            if found < 0 {
                openersBottom[key] = Int32(ci)
                if cn.flags & 1 == 0 { delims.remove(at: ci) } else { ci += 1 }
                continue
            }
            let opener = delims[found]
            let oa = nodes[Int(opener)].a
            let use: Int32 = ch == 0x7E ? oa : (oa >= 2 && cn.a >= 2 ? 2 : 1)
            let style: MDStyle = ch == 0x7E ? .strike : (use == 2 ? .strong : .emphasis)
            nodes[Int(opener)].a -= use
            nodes[Int(closer)].a -= use
            insert(Node(kind: InlineParser.kOpen, c: Int32(style.rawValue)), after: opener)
            insert(Node(kind: InlineParser.kClose, c: Int32(style.rawValue)), before: closer)
            // Delimiters between opener and closer can no longer match.
            delims.removeSubrange(found + 1, ci)
            ci = found + 1
            if nodes[Int(opener)].a == 0 { delims.remove(at: found); ci -= 1 }
            if nodes[Int(closer)].a == 0 { delims.remove(at: ci) }
        }
        if bottom < delims.count { delims.count = bottom }
    }

    // MARK: - Emit

    func emit() {
        var counts = InlineArray<10, Int32>(repeating: 0)   // nesting per style bit
        var style: UInt16 = 0      // bits whose count is > 0
        var link: Int32 = -1
        var imageDepth = 0
        var runStyle: UInt16 = 0
        var runRef: Int32 = -1
        var runStart = out.count

        @inline(__always) func restyle() {
            let s = link >= 0 ? style | MDStyle.link.rawValue : style
            if s == runStyle && link == runRef { return }
            if out.count > runStart && runStyle != 0 {
                runs.append(MDRun(start: Int32(runStart), end: Int32(out.count), style: MDStyle(rawValue: runStyle), ref: runRef))
            }
            runStyle = s
            runRef = link
            runStart = out.count
        }

        let np = nodes.p
        let srcBase = src
        var k = head
        while k >= 0 {
            let nd = np[Int(k)]
            switch nd.kind {
            case InlineParser.kText:
                if imageDepth == 0 {
                    let base = nd.flags & InlineParser.fScratch != 0 ? UnsafePointer(scratch.p) : srcBase
                    out.appendPadded(base + Int(nd.a), Int(nd.b &- nd.a))
                }
            case InlineParser.kSoft:
                if imageDepth == 0 { out.append(0x20) }
            case InlineParser.kDelim:
                if imageDepth == 0 && nd.a > 0 { for _ in 0..<Int(nd.a) { out.append(UInt8(truncatingIfNeeded: nd.c)) } }
            case InlineParser.kHard:
                if imageDepth == 0 { out.append(0x0A) }
            case InlineParser.kCode:
                if imageDepth == 0 {
                    counts[2] += 1
                    style |= MDStyle.code.rawValue
                    restyle()
                    let base = nd.flags & InlineParser.fScratch != 0 ? UnsafePointer(scratch.p) : srcBase
                    out.appendPadded(base + Int(nd.a), Int(nd.b &- nd.a))
                    counts[2] -= 1
                    if counts[2] == 0 { style &= ~MDStyle.code.rawValue }
                    restyle()
                }
            case InlineParser.kOpen, InlineParser.kClose:
                let open = nd.kind == InlineParser.kOpen
                for b in 0..<10 where nd.c & (1 << b) != 0 {
                    let v = max(0, counts[b] + (open ? 1 : -1))
                    counts[b] = v
                    if v > 0 { style |= 1 << UInt16(b) } else { style &= ~(1 << UInt16(b)) }
                }
                restyle()
            case InlineParser.kBracket:
                if imageDepth == 0 {
                    if nd.flags & 1 != 0 { out.append(0x21) }
                    out.append(0x5B)
                }
            case InlineParser.kLinkOpen:
                link = nd.c
                restyle()
            case InlineParser.kLinkClose:
                link = -1
                restyle()
            case InlineParser.kImageOpen, InlineParser.kImageAtom:
                if imageDepth == 0 {
                    restyle()
                    // An image is one U+FFFC object-replacement character carrying the image run
                    // (links around images still apply: the run keeps the link ref separately).
                    let start = Int32(out.count)
                    out.append(0xEF); out.append(0xBF); out.append(0xBC)
                    runs.append(MDRun(start: start, end: Int32(out.count), style: .image, ref: nd.c))
                    if link >= 0 {
                        runs.append(MDRun(start: start, end: Int32(out.count), style: .link, ref: link))
                    }
                    runStart = out.count
                }
                if nd.kind == InlineParser.kImageOpen { imageDepth += 1 }
            case InlineParser.kImageClose:
                imageDepth = max(0, imageDepth - 1)
            default: break
            }
            k = nd.next
        }
        if out.count > runStart && runStyle != 0 {
            runs.append(MDRun(start: Int32(runStart), end: Int32(out.count), style: MDStyle(rawValue: runStyle), ref: runRef))
        }
    }

    // MARK: - Tables

    /// Splits a table row into cell byte ranges (pairs in `cells`) on unescaped `|` outside
    /// code spans, dropping the optional leading/trailing pipe. Returns the cell count.
    @discardableResult
    func splitCells(_ p: UnsafePointer<UInt8>, _ s: Int, _ e: Int) -> Int {
        cells.count = 0
        var a = s, b = e
        while a < b && (p[a] == 0x20 || p[a] == 0x09) { a += 1 }
        while b > a && (p[b - 1] == 0x20 || p[b - 1] == 0x09) { b -= 1 }
        if a < b && p[a] == 0x7C { a += 1 }
        if b > a && p[b - 1] == 0x7C && (b - 2 < a || p[b - 2] != 0x5C) { b -= 1 }
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
                cells.append(Int32(start))
                cells.append(Int32(k))
                start = k + 1
            }
            k += 1
        }
        if b > a || cells.count > 0 {
            cells.append(Int32(start))
            cells.append(Int32(max(start, b)))
        }
        return cells.count / 2
    }
}
