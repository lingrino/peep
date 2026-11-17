// CommonMark + GFM block structure.
//
// Pass 1 (this file) walks lines once, maintaining a stack of open containers (block quotes
// and list items) and at most one open leaf block. The open leaf's content lines are always
// the tail of `lines` (only one leaf is open at a time), so closing a leaf records a range
// instead of copying. Closed leaves become `PendingBlock`s. Pass 2 (InlineParser) turns
// pending blocks into rendered text + style runs, after all link reference definitions are
// known.

struct PendingBlock: BitwiseCopyable {
    var kind: MDBlockKind
    var level: UInt8 = 0
    var quoteDepth: UInt8 = 0
    var listDepth: UInt8 = 0
    var marker: MDMarker = .none
    var firstInItem = false
    var alert: MDAlert = .none           // GitHub alert of the outermost quote
    var markerNumber: Int32 = 0
    var list: Int32 = -1                 // innermost enclosing list (for tight/loose)
    var lineStart: Int32 = 0             // first line (index of a pair in BlockParser.lines)
    var lineCount: Int32 = 0
    var infoStart: Int32 = 0             // fenced code info string (source offsets)
    var infoEnd: Int32 = 0
    var alignStart: Int32 = 0            // tables: range in BlockParser.aligns
    var alignCount: Int32 = 0
}

struct ListInfo: BitwiseCopyable {
    var loose = false
    var firstBlock: Int32 = 0
    var lastBlock: Int32 = 0
    var parent: Int32 = -1           // list of the enclosing item, if nested
}

final class BlockParser {
    let p: UnsafePointer<UInt8>
    let n: Int
    /// Owns the string store and reference table that definitions are added to.
    unowned let inline: InlineParser

    enum ContainerKind: UInt8, BitwiseCopyable { case quote, item, footnote }
    struct Container: BitwiseCopyable {
        var kind: ContainerKind
        var ordered = false
        var emitted = false          // first leaf of the item has been emitted
        var started = false          // item has had content
        var task: MDMarker = .none
        var bullet: UInt8 = 0        // '-', '+', '*' or '.'/')' for ordered
        var alert: MDAlert = .none   // quote: GitHub alert (one byte, in padding: stride stays 24)
        var indent = 0               // item: columns required to continue
        var number: Int32 = 0        // item: list number; footnote: definition index
        var list: Int32 = -1         // index into `lists`
    }

    enum Leaf: UInt8 { case none, paragraph, fenced, indented, html, table }

    var stack: RawArray<Container>
    var leaf = Leaf.none
    /// Index in `lines` (Int32 units) where the open leaf's lines start.
    var leafFirst = 0
    var fenceChar: UInt8 = 0
    var fenceLen = 0
    var fenceIndent = 0
    var fenceInfo: (Int32, Int32) = (0, 0)
    var htmlEnd = 0                  // HTML block end condition (1...7)
    var tableAlignStart = 0

    /// Containers (quotes, items, footnote definitions) nest at most this deep; deeper markers
    /// are paragraph text. Blocks carry their quote/list depths in a byte (more than 255 `>`
    /// trapped), and nothing real comes close: markdown-it's default limit is 100 too.
    static let maxNesting = 100

    /// Table cells the parser may add to pad short rows to the header's width, per document,
    /// beyond what the rows' own bytes pay for (a row of n bytes has at most n + 1 cells).
    /// Unbounded, a 2,000-column header over 5,000 one-byte rows asked the renderer for 10
    /// million cells from 28 KB (10 GB, minutes). Like cmark-gfm's limit on auto-completed
    /// cells: past it, a short row ends the table and starts a paragraph. Real tables omit a
    /// few trailing cells per row; 16,384 of them cost about what 32 KB of real cells do
    /// (rendering a 65,536-cell table: 0.3 s, 340 MB).
    var tablePadding = 1 << 14

    var blocks: RawArray<PendingBlock>
    var lines: RawArray<Int32>       // leaf content lines, pairs (start, end)
    var newlines: RawArray<UInt32>   // offset of every "\n" (see `run`)
    var lists: RawArray<ListInfo>
    var aligns: RawArray<MDAlign>
    var lastLineBlank = false
    var pendingBlankItems = false
    /// Open footnote definitions and alert quotes. While 0 (almost always), emitting a block
    /// skips the work they need.
    var openSpecial = 0
    /// Blocks inside footnote definitions: (block index, definition index) pairs, in order.
    var noteOf: [Int32] = []

    init(_ p: UnsafePointer<UInt8>, _ n: Int, _ inline: InlineParser, _ arena: inout Arena) {
        self.p = p
        self.n = n
        self.inline = inline
        // ~1 block per 70 bytes and a line per 40 in typical documents; growth is cheap anyway.
        stack = RawArray(capacity: 16, &arena)
        lists = RawArray(capacity: 16, &arena)
        aligns = RawArray(capacity: 16, &arena)
        blocks = RawArray(capacity: min(n / 64 + 16, 512), &arena)
        lines = RawArray(capacity: min(n / 16 + 32, 2048), &arena)
        newlines = RawArray(capacity: min(n / 24 + 64, 4096), &arena)
    }

    deinit {
        stack.free(); blocks.free(); lines.free(); lists.free(); aligns.free(); newlines.free()
    }

    // MARK: - Driver

    func run() {
        var i = skipFrontMatter()
        newlineOffsets(p, i, n, into: &newlines)
        let nlp = newlines.p, nlc = newlines.count
        var k = 0
        while i < n {
            let le = k < nlc ? Int(nlp[k]) : n
            k &+= 1
            var ce = le
            if ce > i && p[ce - 1] == 0x0D { ce -= 1 }
            processLine(i, ce)
            i = le + 1
        }
        closeLeaf()
        while !stack.isEmpty { closeContainer() }
    }

    /// YAML front matter (`---` ... `---`/`...` at the very top) is hidden.
    func skipFrontMatter() -> Int {
        guard n >= 3, p[0] == 0x2D, p[1] == 0x2D, p[2] == 0x2D else { return 0 }
        var e = 3
        while e < n && (p[e] == 0x20 || p[e] == 0x09) { e += 1 }
        guard e < n, p[e] == 0x0A || p[e] == 0x0D else { return 0 }
        var i = lineEnd(p, 0, n) + 1
        while i < n {
            let le = lineEnd(p, i, n)
            var ce = le
            while ce > i && (p[ce - 1] == 0x20 || p[ce - 1] == 0x0D || p[ce - 1] == 0x09) { ce -= 1 }
            if ce - i == 3 && ((p[i] == 0x2D && p[i + 1] == 0x2D && p[i + 2] == 0x2D) || (p[i] == 0x2E && p[i + 1] == 0x2E && p[i + 2] == 0x2E)) {
                return le + 1
            }
            i = le + 1
        }
        return 0   // unterminated: not front matter
    }

    // MARK: - Line scanning helpers

    /// Columns of leading whitespace from `pos` (tabs to multiples of 4 from `col`), and
    /// the offset of the first non-whitespace byte.
    @inline(__always)
    func indentation(_ pos: Int, _ end: Int, col: Int) -> (cols: Int, at: Int) {
        var c = col
        var j = pos
        while j < end {
            let b = p[j]
            if b == 0x20 { c += 1 } else if b == 0x09 { c += 4 - c % 4 } else { break }
            j += 1
        }
        return (c - col, j)
    }

    /// Advance past `count` columns of whitespace. Returns new position and column.
    @inline(__always)
    func consumeColumns(_ pos: Int, _ end: Int, col: Int, count: Int) -> (Int, Int) {
        var c = col
        var j = pos
        while j < end && c - col < count {
            if p[j] == 0x20 { c += 1 } else if p[j] == 0x09 { c += 4 - c % 4 } else { break }
            j += 1
        }
        return (j, c)
    }

    @inline(__always) func isBlank(_ pos: Int, _ end: Int) -> Bool {
        var j = pos
        while j < end { if p[j] != 0x20 && p[j] != 0x09 { return false }; j += 1 }
        return true
    }

    // MARK: - Per line

    func processLine(_ ls: Int, _ le: Int) {
        if stack.isEmpty {
            // No containers to continue (most lines): fenced-code content, plain paragraph text
            // and blank lines take the same steps as below with one whitespace scan and no
            // recognizers.
            let (ind, at) = indentation(ls, le, col: 0)
            let blank = at == le
            if leaf == .fenced {
                if ind <= 3 && isClosingFence(at, le) {
                    closeLeaf()
                } else if fenceIndent == 0 && leafLineCount > 0 && Int(lines.last) &+ 1 == ls {
                    // Contiguous with the previous content line (separated by just "\n"):
                    // extend it. Code is emitted as its lines joined by "\n", so one range
                    // spanning several lines renders the same, with one copy.
                    lines.last = Int32(truncatingIfNeeded: le)
                } else {
                    let (sp, _) = consumeColumns(ls, le, col: 0, count: fenceIndent)
                    addLine(sp, le)
                }
                lastLineBlank = blank
                return
            }
            if leaf != .html {
                if blank {
                    leafLine(ls, le, col: 0, blank: true)
                    lastLineBlank = true
                    return
                }
                let plain = BlockParser.plainStart[Int(p[at])]
                if ind < 4 && (plain == 1 || (plain == 2 && p[at + 1] != 0x5E)) {
                    if leaf == .table && tableRowFits(at, le) { addLine(at, le); lastLineBlank = false; return }
                    if leaf != .paragraph { closeLeaf(); startLeaf(.paragraph) }
                    addLine(at, le)
                    itemStarted()
                    lastLineBlank = false
                    return
                }
            }
        }
        var pos = ls
        var col = 0
        var matched = 0
        var blank = isBlank(ls, le)

        // 1. Continue open containers.
        let depth = stack.count
        while matched < depth {
            let c = stack[matched]
            if c.kind == .quote {
                let (ind, at) = indentation(pos, le, col: col)
                if ind <= 3 && at < le && p[at] == 0x3E {
                    col += ind + 1
                    pos = at + 1
                    if pos < le && (p[pos] == 0x20 || p[pos] == 0x09) {
                        if p[pos] == 0x09 { col += 4 - col % 4 } else { col += 1 }
                        pos += 1
                    }
                    matched += 1
                } else { break }
            } else {
                // Items, and footnote definitions (indent 4, always started: they continue on
                // blank lines and lines indented 4 columns).
                if blank {
                    // A blank line keeps an item open unless the item hasn't started yet
                    // and this is its second line (an item can begin with at most one blank).
                    if !c.started && lastLineBlank { break }
                    matched += 1
                } else {
                    let (ind, _) = indentation(pos, le, col: col)
                    if ind >= c.indent {
                        (pos, col) = consumeColumns(pos, le, col: col, count: c.indent)
                        matched += 1
                    } else { break }
                }
            }
        }
        let allMatched = matched == depth

        // 2. Inside a fenced code block / HTML block: content or end.
        if allMatched && leaf == .fenced {
            let (ind, at) = indentation(pos, le, col: col)
            if ind <= 3 && isClosingFence(at, le) {
                closeLeaf()
            } else {
                let (sp, _) = consumeColumns(pos, le, col: col, count: fenceIndent)
                addLine(sp, le)
            }
            lastLineBlank = blank
            return
        }
        if allMatched && leaf == .html {
            if blank && (htmlEnd == 6 || htmlEnd == 7) {
                closeLeaf()
            } else {
                addLine(pos, le)
                if htmlEnds(pos, le) { closeLeaf() }
            }
            lastLineBlank = blank
            return
        }

        // 3. New containers (up to `maxNesting` open; see there).
        var opened = false
        while stack.count < BlockParser.maxNesting {
            let (ind, at) = indentation(pos, le, col: col)
            if ind >= 4 || at >= le { break }
            let b = p[at]
            if b == 0x3E {   // >
                if !opened { closeUnmatched(matched); opened = true }
                closeLeaf()
                stack.append(Container(kind: .quote))
                matched = stack.count
                col += ind + 1
                pos = at + 1
                if pos < le && (p[pos] == 0x20 || p[pos] == 0x09) {
                    if p[pos] == 0x09 { col += 4 - col % 4 } else { col += 1 }
                    pos += 1
                }
                // GitHub alert: "> [!NOTE]" alone on the quote's first line.
                if p[pos] == 0x5B && openAlert(pos, le) { return }
                continue
            }
            // "[^": checked here, not in the call (list items starting with a link are common).
            if b == 0x5B && p[at + 1] == 0x5E, let content = openFootnote(at, le, closeFrom: opened ? -1 : matched) {
                opened = true
                matched = stack.count
                col += ind + (content - at)
                pos = content
                continue
            }
            // Only bullets and digits can start an item: skip the call for everything else.
            if b == 0x2D || b == 0x2B || b == 0x2A || (b >= 0x30 && b <= 0x39),
               var item = listMarker(at, le, col: col + ind, interruptsParagraph: leaf == .paragraph && allMatched && !opened) {
                // Continuation indent is relative to where this container's prefix starts.
                item.indent -= col
                // A thematic break that looks like a bullet (`- - -`) is a break.
                if isThematicBreak(at, le) { break }
                if !opened { closeUnmatched(matched); opened = true }
                closeLeaf()
                openItem(item)
                matched = stack.count
                pos = item.contentPos
                col = item.contentCol
                if item.blankStart { break }
                continue
            }
            break
        }

        // A line whose rest is blank after its container markers (">" alone) is a blank line
        // inside those containers: it ends a paragraph there.
        if !blank { blank = isBlank(pos, le) }

        // 4. Lazy paragraph continuation.
        if !opened && !allMatched && leaf == .paragraph && !blank && !startsBlock(pos, le, col: col) {
            addLine(firstNonSpace(pos, le), le)
            lastLineBlank = false
            return
        }
        if !opened { closeUnmatched(matched) }

        // 5. Leaf content.
        leafLine(pos, le, col: col, blank: blank)
        lastLineBlank = blank
    }

    /// Bytes that can't begin anything but paragraph text (not a container marker, and not
    /// the first byte of a heading, break, fence, HTML block, setext underline or table
    /// delimiter row).
    nonisolated(unsafe) static let plainStart: UnsafePointer<UInt8> = {
        let t = UnsafeMutablePointer<UInt8>.allocate(capacity: 256)
        t.initialize(repeating: 1, count: 256)
        for c in ">-+*#`~<=_|: \t".utf8 { t[Int(c)] = 0 }
        t[0x5B] = 2   // '[': plain unless "[^" (a footnote definition)
        for c in UInt8(0x30)...UInt8(0x39) { t[Int(c)] = 0 }
        return UnsafePointer(t)
    }()

    /// Inline check, out-of-line work: called for nearly every line inside containers, and
    /// almost always there's nothing to close.
    @inline(__always) func closeUnmatched(_ matched: Int) {
        if matched < stack.count { closeContainers(above: matched) }
    }

    @inline(never) func closeContainers(above matched: Int) {
        closeLeaf()
        while stack.count > matched { closeContainer() }
    }

    func firstNonSpace(_ pos: Int, _ le: Int) -> Int {
        var j = pos
        while j < le && (p[j] == 0x20 || p[j] == 0x09) { j += 1 }
        return j
    }

    /// Would this line start a non-paragraph block? (Stops lazy continuation.)
    func startsBlock(_ pos: Int, _ le: Int, col: Int) -> Bool {
        let (ind, at) = indentation(pos, le, col: col)
        if ind >= 4 || at >= le { return false }
        let b = p[at]
        if b == 0x3E { return true }
        if b == 0x5B && p[at + 1] == 0x5E && footnoteStart(at, le) != nil { return true }
        if isThematicBreak(at, le) || atxLevel(at, le) > 0 || isOpeningFence(at, le) { return true }
        if listMarker(at, le, col: col + ind, interruptsParagraph: true) != nil { return true }
        if b == 0x3C && htmlStart(at, le, interrupting: true) > 0 { return true }
        return false
    }

    // MARK: - Leaf blocks

    /// Lines of the open leaf.
    @inline(__always) var leafLineCount: Int { (lines.count - leafFirst) >> 1 }

    func leafLine(_ pos: Int, _ le: Int, col: Int, blank: Bool) {
        if blank {
            if leaf == .paragraph || leaf == .table { closeLeaf() }
            else if leaf == .indented { addLine(pos, pos) }   // trailing blanks trimmed at close
            pendingBlankItems = true
            return
        }
        let (ind, at) = indentation(pos, le, col: col)
        if ind >= 4 && leaf != .paragraph {
            if leaf != .indented { closeLeaf(); startLeaf(.indented) }
            let (sp, _) = consumeColumns(pos, le, col: col, count: 4)
            addLine(sp, le)
            itemStarted()
            return
        }
        if leaf == .indented { closeLeaf() }
        let b = p[at]

        // Setext underline / GFM table delimiter row turn the open paragraph into something else.
        if leaf == .paragraph {
            if (b == 0x3D || b == 0x2D), let lvl = setextLevel(at, le) {
                emitLeaf(.heading, level: UInt8(lvl))
                return
            }
            if leafLineCount == 1, isDelimiterCandidate(at, le),
               tableDelimiter(at, le, headerCells: cellCount(Int(lines[leafFirst]), Int(lines[leafFirst + 1]))) {
                leaf = .table
                return
            }
        }
        if leaf == .table {
            if startsBlock(at, le, col: col + ind) || !tableRowFits(at, le) { closeLeaf() } else { addLine(at, le); return }
        }

        // Only these bytes can start a non-paragraph leaf: most lines skip every recognizer.
        switch b {
        case 0x2A, 0x2D, 0x5F:   // * - _
            if isThematicBreak(at, le) {
                closeLeaf()
                startLeaf(.paragraph)
                emitLeaf(.rule)
                itemStarted()
                return
            }
        case 0x23:   // #
            let lvl = atxLevel(at, le)
            if lvl > 0 {
                closeLeaf()
                startLeaf(.paragraph)
                var s = at + lvl
                while s < le && (p[s] == 0x20 || p[s] == 0x09) { s += 1 }
                var e = le
                while e > s && (p[e - 1] == 0x20 || p[e - 1] == 0x09) { e -= 1 }
                // Optional closing sequence of #s (preceded by a space).
                var h = e
                while h > s && p[h - 1] == 0x23 { h -= 1 }
                if h == s || p[h - 1] == 0x20 || p[h - 1] == 0x09 {
                    e = h
                    while e > s && (p[e - 1] == 0x20 || p[e - 1] == 0x09) { e -= 1 }
                }
                addLine(s, e)
                emitLeaf(.heading, level: UInt8(lvl))
                itemStarted()
                return
            }
        case 0x60, 0x7E:   // ` ~
            if isOpeningFence(at, le) {
                closeLeaf()
                startLeaf(.fenced)
                fenceChar = b
                let k = runEnd(at, le, b)
                fenceLen = k - at
                fenceIndent = ind
                var s = k
                while s < le && (p[s] == 0x20 || p[s] == 0x09) { s += 1 }
                var e = le
                while e > s && (p[e - 1] == 0x20 || p[e - 1] == 0x09) { e -= 1 }
                fenceInfo = (Int32(s), Int32(e))
                itemStarted()
                return
            }
        case 0x3C:   // <
            let kind = htmlStart(at, le, interrupting: leaf == .paragraph)
            if kind > 0 {
                closeLeaf()
                startLeaf(.html)
                htmlEnd = kind
                addLine(pos, le)
                if htmlEnds(pos, le) { closeLeaf() }
                itemStarted()
                return
            }
        default:
            break
        }
        // Paragraph text.
        if leaf != .paragraph { closeLeaf(); startLeaf(.paragraph) }
        addLine(at, le)
        itemStarted()
    }

    @inline(__always) func startLeaf(_ l: Leaf) {
        leaf = l
        leafFirst = lines.count
    }

    @inline(__always) func addLine(_ s: Int, _ e: Int) {
        lines.append(Int32(truncatingIfNeeded: s))
        lines.append(Int32(truncatingIfNeeded: e))
    }

    func closeLeaf() {
        switch leaf {
        case .none: return
        case .paragraph:
            stripReferenceDefinitions()
            if leafLineCount > 0 { emitLeaf(.paragraph) } else { leaf = .none }
        case .fenced: emitLeaf(.code)
        case .indented:
            while leafLineCount > 0 && isBlank(Int(lines[lines.count - 2]), Int(lines[lines.count - 1])) {
                lines.removeLast(2)
            }
            emitLeaf(.code)
        case .html: emitLeaf(.html)
        case .table: emitLeaf(.table)
        }
    }

    /// Records the open leaf as a pending block with its container context.
    func emitLeaf(_ kind: MDBlockKind, level: UInt8 = 0) {
        var b = PendingBlock(kind: kind, level: level)
        b.lineStart = Int32(leafFirst >> 1)
        b.lineCount = Int32(leafLineCount)
        if kind == .code && leaf == .fenced { b.infoStart = fenceInfo.0; b.infoEnd = fenceInfo.1 }
        if kind == .table {
            b.alignStart = Int32(tableAlignStart)
            b.alignCount = Int32(aligns.count - tableAlignStart)
        }
        var q: UInt8 = 0, l: UInt8 = 0
        var item = -1
        if openSpecial == 0 {
            for k in 0..<stack.count {
                if stack[k].kind == .quote { q += 1 } else { l += 1; item = k }
            }
        } else {
            item = specialContext(&b, &q, &l)
        }
        b.quoteDepth = q
        b.listDepth = l
        if item >= 0 {
            b.list = stack[item].list
            if !stack[item].emitted {
                stack[item].emitted = true
                b.firstInItem = true
                b.marker = stack[item].task != .none ? stack[item].task : (stack[item].ordered ? .ordered : .bullet)
                b.markerNumber = stack[item].number
                // Task marker `[ ] ` is stripped from the item's first paragraph. (A bare
                // "- [ ]" line leaves an empty line, not a negative range.)
                if stack[item].task != .none && kind == .paragraph && b.lineCount > 0 {
                    let li = Int(b.lineStart) * 2
                    lines[li] = min(lines[li] + 4, lines[li + 1])
                    while lines[li] < lines[li + 1] && (p[Int(lines[li])] == 0x20 || p[Int(lines[li])] == 0x09) { lines[li] += 1 }
                }
            }
            lists[Int(b.list)].lastBlock = Int32(blocks.count)
        }
        blocks.append(b)
        leaf = .none
        leafFirst = lines.count
    }

    // MARK: - Containers

    struct ItemStart {
        var ordered: Bool
        var bullet: UInt8
        var number: Int32
        var contentPos: Int
        var contentCol: Int
        var indent: Int        // columns from line start to content
        var blankStart: Bool
        var task: MDMarker
    }

    /// Parses a list marker at `at` (column `col`). nil if not a list item start.
    func listMarker(_ at: Int, _ le: Int, col: Int, interruptsParagraph: Bool) -> ItemStart? {
        var k = at
        var ordered = false
        var number: Int32 = 0
        var bullet: UInt8 = 0
        let b = p[k]
        if b == 0x2D || b == 0x2B || b == 0x2A {
            bullet = b
            k += 1
        } else if b >= 0x30 && b <= 0x39 {
            var digits = 0
            while k < le && p[k] >= 0x30 && p[k] <= 0x39 && digits < 10 { number = number &* 10 &+ Int32(p[k] - 0x30); k += 1; digits += 1 }
            if digits > 9 || k >= le || (p[k] != 0x2E && p[k] != 0x29) { return nil }
            bullet = p[k]
            ordered = true
            k += 1
        } else {
            return nil
        }
        let markerEndCol = col + (k - at)
        if k < le && p[k] != 0x20 && p[k] != 0x09 { return nil }
        let blankStart = isBlank(k, le)
        if interruptsParagraph && (blankStart || (ordered && number != 1)) { return nil }
        var item = ItemStart(ordered: ordered, bullet: bullet, number: number, contentPos: k, contentCol: markerEndCol,
                             indent: 0, blankStart: blankStart, task: .none)
        if blankStart {
            item.indent = markerEndCol + 1
            item.contentPos = le
            item.contentCol = markerEndCol
            return item
        }
        let (sp, at2) = indentation(k, le, col: markerEndCol)
        if sp >= 5 {
            // Content is indented code: the item content starts one column after the marker.
            item.indent = markerEndCol + 1
            (item.contentPos, item.contentCol) = consumeColumns(k, le, col: markerEndCol, count: 1)
        } else {
            item.indent = markerEndCol + sp
            item.contentPos = at2
            item.contentCol = markerEndCol + sp
        }
        // GFM task list item: [ ] / [x] followed by whitespace.
        let c = item.contentPos
        if c + 3 <= le && p[c] == 0x5B && p[c + 2] == 0x5D && (c + 3 == le || p[c + 3] == 0x20 || p[c + 3] == 0x09) {
            if p[c + 1] == 0x20 { item.task = .taskOpen }
            else if p[c + 1] == 0x78 || p[c + 1] == 0x58 { item.task = .taskDone }
        }
        return item
    }

    func openItem(_ s: ItemStart) {
        // Continue the list if the previous sibling item (just closed or still innermost)
        // belongs to a compatible list.
        var list: Int32 = -1
        if hasLastClosed, lastClosed.depth == stack.count, lastClosed.bullet == s.bullet, lastClosed.ordered == s.ordered {
            list = lastClosed.list
            if lastLineBlank { lists[Int(list)].loose = true }
        }
        if list < 0 {
            var parent: Int32 = -1
            var k = stack.count - 1
            while k >= 0 && stack[k].kind != .footnote {
                if stack[k].kind == .item { parent = stack[k].list; break }
                k -= 1
            }
            lists.append(ListInfo(firstBlock: Int32(blocks.count), lastBlock: Int32(blocks.count), parent: parent))
            list = Int32(lists.count - 1)
        }
        var number = s.number
        if s.ordered, hasLastClosed, lastClosed.list == list { number = lastClosed.number &+ 1 }
        stack.append(Container(kind: .item, ordered: s.ordered, started: !s.blankStart, task: s.task,
                               bullet: s.bullet, indent: s.indent, number: number, list: list))
        hasLastClosed = false
    }

    struct ClosedItem { var depth: Int; var bullet: UInt8; var ordered: Bool; var list: Int32; var number: Int32 }
    var lastClosed = ClosedItem(depth: 0, bullet: 0, ordered: false, list: -1, number: 0)
    var hasLastClosed = false

    func closeContainer() {
        closeLeaf()
        guard !stack.isEmpty else { return }
        let c = stack.last
        stack.removeLast()
        if c.kind == .item {
            lastClosed = ClosedItem(depth: stack.count, bullet: c.bullet, ordered: c.ordered, list: c.list, number: c.number)
            hasLastClosed = true
            if !c.emitted { emitEmptyItem(c) }
        } else {
            hasLastClosed = false
            if c.kind == .footnote || c.alert != .none { openSpecial -= 1 }
        }
    }

    /// Container context of a block while a footnote definition or alert is open: depths
    /// count only containers inside the innermost definition (definitions render at the end
    /// of the document), the outermost quote's alert, and the definition the block is in.
    /// Returns the innermost item (-1: none).
    @inline(never)
    func specialContext(_ b: inout PendingBlock, _ q: inout UInt8, _ l: inout UInt8) -> Int {
        var item = -1, firstQuote = 0, note: Int32 = -1
        for k in 0..<stack.count {
            let kind = stack[k].kind
            if kind == .quote {
                if q == 0 { firstQuote = k }
                q += 1
            } else if kind == .item {
                l += 1; item = k
            } else {
                q = 0; l = 0; item = -1
                note = stack[k].number
            }
        }
        if q > 0 { b.alert = stack[firstQuote].alert }
        if note >= 0 { noteOf.append(Int32(blocks.count)); noteOf.append(note) }
        return item
    }

    /// An item closed without content still draws its marker.
    @inline(never)
    func emitEmptyItem(_ c: Container) {
        var b = PendingBlock(kind: .paragraph)
        b.lineStart = Int32(lines.count >> 1)
        b.lineCount = 0
        var q: UInt8 = 0, l: UInt8 = 0
        if openSpecial == 0 {
            for k in 0..<stack.count { if stack[k].kind == .quote { q += 1 } else { l += 1 } }
        } else {
            _ = specialContext(&b, &q, &l)
        }
        b.quoteDepth = q
        b.listDepth = l + 1
        b.list = c.list
        b.firstInItem = true
        b.marker = c.task != .none ? c.task : (c.ordered ? .ordered : .bullet)
        b.markerNumber = c.number
        lists[Int(c.list)].lastBlock = Int32(blocks.count)
        blocks.append(b)
    }

    /// Content in an item after a blank line inside it makes the list loose.
    @inline(__always) func itemStarted() {
        var k = stack.count - 1
        while k >= 0 {
            if stack[k].kind == .item {
                if pendingBlankItems && stack[k].started && stack[k].emitted {
                    lists[Int(stack[k].list)].loose = true
                }
                stack[k].started = true
                break
            }
            k -= 1
        }
        pendingBlankItems = false
    }

    // MARK: - Block recognizers

    /// `[^label]:` at `at` (a label has no whitespace or `]`, as in GFM): the label range and
    /// where the definition's content starts (after the spaces following the colon).
    func footnoteStart(_ at: Int, _ le: Int) -> (Int, Int, Int)? {
        guard at + 3 < le, p[at] == 0x5B, p[at + 1] == 0x5E else { return nil }
        var k = at + 2
        while k < le, case let c = p[k], c != 0x5D, c != 0x20, c != 0x09 { k += 1 }
        guard k > at + 2, k + 1 < le, p[k] == 0x5D, p[k + 1] == 0x3A else { return nil }
        var c = k + 2
        while c < le && (p[c] == 0x20 || p[c] == 0x09) { c += 1 }
        return (at + 2, k, c)
    }

    /// The quote just opened is an alert if the rest of its line is a marker: emits the title.
    @inline(never)
    func openAlert(_ pos: Int, _ le: Int) -> Bool {
        guard outermostQuote() == stack.count - 1, let type = alertMarker(pos, le) else { return false }
        stack[stack.count - 1].alert = type
        openSpecial += 1
        emitLeaf(.alertTitle)
        lastLineBlank = false
        return true
    }

    /// Opens a footnote definition container at `at`: where its content starts, or nil if this
    /// isn't a definition. Containers from `closeFrom` up are closed first (-1: none).
    @inline(never)
    func openFootnote(_ at: Int, _ le: Int, closeFrom: Int) -> Int? {
        guard let (ls, lend, content) = footnoteStart(at, le) else { return nil }
        if closeFrom >= 0 { closeUnmatched(closeFrom) }
        closeLeaf()
        stack.append(Container(kind: .footnote, started: true, indent: 4, number: inline.defineFootnote(p + ls, lend - ls)))
        openSpecial += 1
        return content
    }

    /// Index of the outermost quote inside the innermost footnote definition, or -1.
    func outermostQuote() -> Int {
        var found = -1
        for k in 0..<stack.count {
            if stack[k].kind == .footnote { found = -1 } else if stack[k].kind == .quote && found < 0 { found = k }
        }
        return found
    }

    /// `[!NOTE]` (TIP, IMPORTANT, WARNING, CAUTION; any case) alone on the rest of the line.
    func alertMarker(_ pos: Int, _ le: Int) -> MDAlert? {
        var s = pos
        while s < le && (p[s] == 0x20 || p[s] == 0x09) { s += 1 }
        guard s + 2 < le, p[s] == 0x5B, p[s + 1] == 0x21 else { return nil }
        var e = s + 2
        while e < le && p[e] != 0x5D { e += 1 }
        guard e < le else { return nil }
        var t = e + 1
        while t < le && (p[t] == 0x20 || p[t] == 0x09) { t += 1 }
        guard t == le else { return nil }
        let w = p + s + 2
        let type: MDAlert?
        switch e - (s + 2) {
        case 3: type = BlockParser.lowerEquals(w, "tip") ? .tip : nil
        case 4: type = BlockParser.lowerEquals(w, "note") ? .note : nil
        case 7: type = BlockParser.lowerEquals(w, "warning") ? .warning : BlockParser.lowerEquals(w, "caution") ? .caution : nil
        case 9: type = BlockParser.lowerEquals(w, "important") ? .important : nil
        default: type = nil
        }
        return type
    }

    func isThematicBreak(_ at: Int, _ le: Int) -> Bool {
        let c = p[at]
        guard c == 0x2A || c == 0x2D || c == 0x5F else { return false }
        var count = 0
        for j in at..<le {
            if p[j] == c { count += 1 } else if p[j] != 0x20 && p[j] != 0x09 { return false }
        }
        return count >= 3
    }

    func atxLevel(_ at: Int, _ le: Int) -> Int {
        var k = at
        while k < le && p[k] == 0x23 && k - at < 7 { k += 1 }
        let lvl = k - at
        if lvl == 0 || lvl > 6 { return 0 }
        if k < le && p[k] != 0x20 && p[k] != 0x09 { return 0 }
        return lvl
    }

    func setextLevel(_ at: Int, _ le: Int) -> Int? {
        guard at < le, p[at] == 0x3D || p[at] == 0x2D else { return nil }
        let c = p[at]
        var k = at
        while k < le && p[k] == c { k += 1 }
        while k < le && (p[k] == 0x20 || p[k] == 0x09) { k += 1 }
        return k == le ? (c == 0x3D ? 1 : 2) : nil
    }

    /// End of the run of byte `c` starting at `at` (16 bytes per step: the CommonMark spec
    /// fences its examples with 32 backticks).
    @inline(__always) func runEnd(_ at: Int, _ le: Int, _ c: UInt8) -> Int {
        var k = at
        let v = splat(c)
        while k < le {
            let m = nibbles(load16(p + k) .!= v)
            if m != 0 { return min(k + (m.trailingZeroBitCount >> 2), le) }
            k &+= 16
        }
        return le
    }

    func isOpeningFence(_ at: Int, _ le: Int) -> Bool {
        let c = p[at]
        guard c == 0x60 || c == 0x7E else { return false }
        let k = runEnd(at, le, c)
        if k - at < 3 { return false }
        if c == 0x60 && findAny(p, k, le, 0x60, 0x60, 0x60, 0x60) < le { return false }
        return true
    }

    func isClosingFence(_ at: Int, _ le: Int) -> Bool {
        guard at < le, p[at] == fenceChar else { return false }
        let k = runEnd(at, le, fenceChar)
        if k - at < fenceLen { return false }
        return isBlank(k, le)
    }

    /// HTML block start condition (CommonMark 4.6), 0 if none.
    func htmlStart(_ at: Int, _ le: Int, interrupting: Bool) -> Int {
        @inline(__always) func tagEnds(_ i: Int) -> Bool {
            i >= le || p[i] == 0x20 || p[i] == 0x09 || p[i] == 0x3E || (p[i] == 0x2F && i + 1 < le && p[i + 1] == 0x3E)
        }
        @inline(__always) func isNameByte(_ c: UInt8) -> Bool {
            ((c | 0x20) >= 0x61 && (c | 0x20) <= 0x7A) || (c >= 0x30 && c <= 0x39)
        }
        let i = at + 1
        guard i < le else { return 0 }
        let c = p[i]
        if c == 0x21 {   // !
            if i + 2 < le && p[i + 1] == 0x2D && p[i + 2] == 0x2D { return 2 }
            if i + 1 < le && (p[i + 1] | 0x20) >= 0x61 && (p[i + 1] | 0x20) <= 0x7A { return 4 }
            if i + 8 <= le && p[i + 1] == 0x5B && InlineParser.tagKey(p, i + 2, i + 7) == BlockParser.cdata && p[i + 7] == 0x5B { return 5 }
            return 0
        }
        if c == 0x3F { return 3 }
        let closing = c == 0x2F
        let ns = closing ? i + 1 : i
        var ne = ns
        while ne < le && isNameByte(p[ne]) { ne += 1 }
        if ne == ns { return 0 }
        let key = InlineParser.tagKey(p, ns, ne)   // 0 when longer than 8 bytes
        if !closing && (key == BlockParser.script || key == BlockParser.pre || key == BlockParser.style || key == BlockParser.textarea) && tagEnds(ne) {
            return 1
        }
        if tagEnds(ne) && BlockParser.isBlockTag(key, p, ns, ne) { return 6 }
        // Type 7: any complete open/close tag alone on the line (can't interrupt a paragraph).
        if !interrupting {
            guard let e = InlineParser.htmlTagEnd(p, at, le) else { return 0 }
            if isBlank(e, le) { return 7 }
        }
        return 0
    }

    static let script = InlineParser.tagKey("script"), pre = InlineParser.tagKey("pre")
    static let style = InlineParser.tagKey("style"), textarea = InlineParser.tagKey("textarea")
    static let cdata = InlineParser.tagKey("cdata")

    /// Type-6 tag names as packed keys (`InlineParser.tagKey`): integer compares instead of a
    /// lowercased String per `<` line. The two names longer than 8 bytes are checked apart.
    static let blockTagKeys: [UInt64] = ["address", "article", "aside", "base", "basefont", "body", "caption",
        "center", "col", "colgroup", "dd", "details", "dialog", "dir", "div", "dl", "dt", "fieldset", "figure",
        "footer", "form", "frame", "frameset", "h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hr", "html", "iframe",
        "legend", "li", "link", "main", "menu", "menuitem", "nav", "noframes", "ol", "optgroup", "option", "p", "param",
        "search", "section", "summary", "table", "tbody", "td", "tfoot", "th", "thead", "title", "tr", "track", "ul",
        "picture", "source"].map { (s: StaticString) in InlineParser.tagKey(s) }

    static func isBlockTag(_ key: UInt64, _ p: UnsafePointer<UInt8>, _ s: Int, _ e: Int) -> Bool {
        if key != 0 {
            for k in blockTagKeys where k == key { return true }
            return false
        }
        if e - s != 10 { return false }
        return lowerEquals(p + s, "blockquote") || lowerEquals(p + s, "figcaption")
    }

    /// ASCII case-insensitive compare of `p[0..<len]` with a lowercase literal.
    static func lowerEquals(_ p: UnsafePointer<UInt8>, _ lit: StaticString) -> Bool {
        let q = lit.utf8Start
        for k in 0..<lit.utf8CodeUnitCount {
            let c = p[k]
            if (c >= 0x41 && c <= 0x5A ? c | 0x20 : c) != q[k] { return false }
        }
        return true
    }

    /// Case-insensitive substring search of a lowercase literal in `p[s..<e]`.
    func containsLower(_ s: Int, _ e: Int, _ needle: StaticString) -> Bool {
        let len = needle.utf8CodeUnitCount
        if e - s < len { return false }
        let first = needle.utf8Start[0]
        var k = s
        while k + len <= e {
            let c = p[k]
            if (c >= 0x41 && c <= 0x5A ? c | 0x20 : c) == first && BlockParser.lowerEquals(p + k, needle) { return true }
            k += 1
        }
        return false
    }

    func htmlEnds(_ s: Int, _ le: Int) -> Bool {
        switch htmlEnd {
        case 1: return containsLower(s, le, "</script>") || containsLower(s, le, "</pre>")
            || containsLower(s, le, "</style>") || containsLower(s, le, "</textarea>")
        case 2: return containsLower(s, le, "-->")
        case 3: return containsLower(s, le, "?>")
        case 4: return containsLower(s, le, ">")
        case 5: return containsLower(s, le, "]]>")
        default: return false
        }
    }

    // MARK: - Tables (GFM)

    func cellCount(_ s: Int, _ e: Int) -> Int {
        inline.splitCells(p, s, e)
    }

    /// The row `p[at..<le]` may join the open table: rendering pads it to the header's column
    /// count, and the cells it can't pay for with its own bytes come out of `tablePadding`.
    /// (A bound from the length: splitting every row's cells here as well would cost every
    /// table.)
    @inline(__always) func tableRowFits(_ at: Int, _ le: Int) -> Bool {
        let unpaid = (aligns.count - tableAlignStart) - (le - at + 1)
        return unpaid <= 0 || payTablePadding(unpaid)
    }

    @inline(never) func payTablePadding(_ cells: Int) -> Bool {
        if cells > tablePadding { return false }
        tablePadding -= cells
        return true
    }

    /// Delimiter row candidate: only `|`, `-`, `:` and blanks, with a `-`. Cheap prefilter run
    /// on every paragraph's second line, before splitting the header into cells.
    @inline(__always) func isDelimiterCandidate(_ at: Int, _ le: Int) -> Bool {
        var dash = false
        for j in at..<le {
            switch p[j] {
            case 0x2D: dash = true
            case 0x7C, 0x3A, 0x20, 0x09: break
            default: return false
            }
        }
        return dash
    }

    /// Parses a delimiter row like `| :-- | :-: | --: |` into `aligns` (starting a new table's
    /// range). Requires the same column count as the header.
    func tableDelimiter(_ at: Int, _ le: Int, headerCells: Int) -> Bool {
        let count = inline.splitCells(p, at, le)
        if count == 0 || count != headerCells { return false }
        var hasPipe = false
        for j in at..<le where p[j] == 0x7C { hasPipe = true; break }
        if !hasPipe && count == 1 { return false }   // a lone `---` is a setext/break
        let start = aligns.count
        for c in 0..<count {
            var a = Int(inline.cells[2 * c]), b = Int(inline.cells[2 * c + 1])
            while a < b && (p[a] == 0x20 || p[a] == 0x09) { a += 1 }
            while b > a && (p[b - 1] == 0x20 || p[b - 1] == 0x09) { b -= 1 }
            if a == b { aligns.count = start; return false }
            let left = p[a] == 0x3A, right = p[b - 1] == 0x3A
            let ds = left ? a + 1 : a, de = right ? b - 1 : b
            if de <= ds { aligns.count = start; return false }
            for k in ds..<de where p[k] != 0x2D { aligns.count = start; return false }
            aligns.append(left && right ? .center : right ? .right : .left)
        }
        tableAlignStart = start
        return true
    }

    // MARK: - Link reference definitions

    /// Removes `[label]: destination "title"` definitions from the start of the open paragraph.
    func stripReferenceDefinitions() {
        guard leafLineCount > 0 else { return }
        // A definition starts with "[" (after up to 3 spaces). Checking first matters:
        // building the joined copy for every paragraph was 22% of parse time.
        var f = Int(lines[leafFirst])
        let fe = Int(lines[leafFirst + 1])
        while f < fe && (p[f] == 0x20 || p[f] == 0x09) { f += 1 }
        if f >= fe || p[f] != 0x5B { return }
        // "[label]" must be followed by ":". When the label closes on the first line, check
        // that before anything else (link-list items like "[Foo](url)" start with "[").
        var k = f + 1
        while true {
            k = findAny(p, k, fe, 0x5C, 0x5B, 0x5D, 0x5D)
            if k >= fe { break }
            let c = p[k]
            if c == 0x5C { k += 2; continue }
            if c == 0x5B { return }   // unescaped "[" can't appear in a label
            if k + 1 >= fe || p[k + 1] != 0x3A { return }   // "]" not followed by ":"
            break
        }
        // The lines joined with "\n" after each (straight from the source when they are
        // contiguous there), then consecutive definitions parsed from a moving offset.
        let count = leafLineCount
        let (b, total) = inline.joinLines(p, lines.p + leafFirst, count, trailingNewline: true)
        var off = 0, li = 0, consumedLines = 0
        var lineEnd = Int(lines[leafFirst + 1] - lines[leafFirst]) + 1   // end of line `li` in the joined bytes
        while off < total {
            guard let d = InlineParser.parseReferenceDefinition(b + off, total - off) else { break }
            // Must end at a line boundary.
            let end = off + d.consumed
            while li < count && lineEnd < end {
                li += 1
                if li < count { lineEnd += Int(lines[leafFirst + 2 * li + 1] - lines[leafFirst + 2 * li]) + 1 }
            }
            guard li < count, lineEnd == end else { break }
            inline.addReference(b + off, d)
            li += 1
            if li < count { lineEnd += Int(lines[leafFirst + 2 * li + 1] - lines[leafFirst + 2 * li]) + 1 }
            consumedLines = li
            off = end
        }
        leafFirst += consumedLines * 2
    }
}
