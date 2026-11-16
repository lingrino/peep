// CommonMark + GFM block structure.
//
// Pass 1 (this file) walks lines once, maintaining a stack of open containers (block quotes
// and list items) and at most one open leaf block. Closed leaves become `PendingBlock`s
// holding the source line ranges of their content. Pass 2 (InlineParser) turns pending
// blocks into rendered text + style runs, after all link reference definitions are known.

struct PendingBlock {
    var kind: MDBlockKind
    var level: UInt8 = 0
    var quoteDepth: UInt8 = 0
    var listDepth: UInt8 = 0
    var marker: MDMarker = .none
    var markerNumber: Int32 = 0
    var list: Int32 = -1                 // innermost enclosing list (for tight/loose)
    var firstInItem = false
    var lineStart: Int32 = 0             // range in BlockParser.lines (pairs of offsets)
    var lineCount: Int32 = 0
    var info: (Int32, Int32) = (0, 0)    // fenced code info string
    var aligns: [MDAlign] = []           // tables
}

struct ListInfo {
    var loose = false
    var firstBlock = 0
    var lastBlock = 0
    var parent: Int32 = -1           // list of the enclosing item, if nested
}

final class BlockParser {
    let p: UnsafePointer<UInt8>
    let n: Int

    enum ContainerKind { case quote, item }
    struct Container {
        var kind: ContainerKind
        var indent = 0               // item: columns required to continue
        var ordered = false
        var bullet: UInt8 = 0        // '-', '+', '*' or '.'/')' for ordered
        var number: Int32 = 0
        var list: Int32 = -1         // index into `lists`
        var emitted = false          // first leaf of the item has been emitted
        var task: MDMarker = .none
        var blankAfterContent = false
        var started = false          // item has had content
    }

    enum Leaf { case none, paragraph, fenced, indented, html, table }

    var stack: [Container] = []
    var leaf = Leaf.none
    var leafLines: [Int32] = []      // pairs (start, end) for the open leaf
    var fenceChar: UInt8 = 0
    var fenceLen = 0
    var fenceIndent = 0
    var fenceInfo: (Int32, Int32) = (0, 0)
    var htmlEnd = 0                  // HTML block end condition (1...7)
    var tableAligns: [MDAlign] = []

    var blocks: [PendingBlock] = []
    var lines: [Int32] = []          // all leaf content lines, pairs (start, end)
    var lists: [ListInfo] = []
    var refs: [String: (String, String)] = [:]
    var footnoteLabels: [String] = []
    var lastLineBlank = false

    init(_ p: UnsafePointer<UInt8>, _ n: Int) {
        self.p = p
        self.n = n
    }

    // MARK: - Driver

    func run() {
        var i = skipFrontMatter()
        while i < n {
            var e = i
            let le = lineEnd(p, i, n)
            e = le
            var ce = e
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
            if p[j] == 0x20 { c += 1 } else if p[j] == 0x09 { c += 4 - c % 4 } else { break }
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
        var pos = ls
        var col = 0
        var matched = 0
        let blank = isBlank(ls, le)

        // 1. Continue open containers.
        while matched < stack.count {
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
        let allMatched = matched == stack.count

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

        // 3. New containers.
        var opened = false
        while true {
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
                continue
            }
            if var item = listMarker(at, le, col: col + ind, interruptsParagraph: leaf == .paragraph && allMatched && !opened) {
                // Continuation indent is relative to where this container's prefix starts.
                item.indent -= col
                // A thematic break that looks like a bullet (`- - -`) is a break.
                if isThematicBreak(at, le) { break }
                if !opened { closeUnmatched(matched); opened = true }
                closeLeaf()
                // Same list continues if the innermost container is an item of a compatible list
                // at this level: handled by `openItem`.
                openItem(item)
                matched = stack.count
                pos = item.contentPos
                col = item.contentCol
                if item.blankStart { break }
                continue
            }
            break
        }

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

    func closeUnmatched(_ matched: Int) {
        if matched < stack.count {
            closeLeaf()
            while stack.count > matched { closeContainer() }
        }
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
        if isThematicBreak(at, le) || atxLevel(at, le) > 0 || isOpeningFence(at, le) { return true }
        if listMarker(at, le, col: col + ind, interruptsParagraph: true) != nil { return true }
        if b == 0x3C && htmlStart(at, le, interrupting: true) > 0 { return true }
        return false
    }

    // MARK: - Leaf blocks

    func leafLine(_ pos: Int, _ le: Int, col: Int, blank: Bool) {
        if blank {
            if leaf == .paragraph || leaf == .table { closeLeaf() }
            else if leaf == .indented { addLine(pos, pos) }   // trailing blanks trimmed at close
            markBlankInItems()
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

        // Setext underline / GFM table delimiter row turn the open paragraph into something else.
        if leaf == .paragraph {
            if let lvl = setextLevel(at, le) {
                emitLeaf(.heading, level: UInt8(lvl))
                return
            }
            if leafLines.count == 2, isDelimiterCandidate(at, le), let aligns = tableDelimiter(at, le, headerCells: cellCount(Int(leafLines[0]), Int(leafLines[1]))) {
                leaf = .table
                tableAligns = aligns
                return
            }
        }
        if leaf == .table {
            if startsBlock(at, le, col: col + ind) { closeLeaf() } else { addLine(at, le); return }
        }

        if isThematicBreak(at, le) {
            closeLeaf()
            startLeaf(.paragraph)
            emitLeaf(.rule)
            itemStarted()
            return
        }
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
        if isOpeningFence(at, le) {
            closeLeaf()
            startLeaf(.fenced)
            fenceChar = p[at]
            var k = at
            while k < le && p[k] == fenceChar { k += 1 }
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
        if p[at] == 0x3C {
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
        }
        // Paragraph text.
        if leaf != .paragraph { closeLeaf(); startLeaf(.paragraph) }
        addLine(at, le)
        itemStarted()
    }

    func startLeaf(_ l: Leaf) {
        leaf = l
        leafLines.removeAll(keepingCapacity: true)
    }

    @inline(__always) func addLine(_ s: Int, _ e: Int) {
        leafLines.append(Int32(s))
        leafLines.append(Int32(e))
    }

    func closeLeaf() {
        switch leaf {
        case .none: return
        case .paragraph:
            stripReferenceDefinitions()
            if !leafLines.isEmpty { emitLeaf(.paragraph) } else { leaf = .none }
        case .fenced: emitLeaf(.code)
        case .indented:
            while leafLines.count >= 2 && isBlank(Int(leafLines[leafLines.count - 2]), Int(leafLines[leafLines.count - 1])) {
                leafLines.removeLast(2)
            }
            emitLeaf(.code)
        case .html: emitLeaf(.html)
        case .table: emitLeaf(.table)
        }
    }

    /// Records the open leaf as a pending block with its container context.
    func emitLeaf(_ kind: MDBlockKind, level: UInt8 = 0) {
        var b = PendingBlock(kind: kind, level: level)
        b.lineStart = Int32(lines.count / 2)
        b.lineCount = Int32(leafLines.count / 2)
        lines.append(contentsOf: leafLines)
        if kind == .code && leaf == .fenced { b.info = fenceInfo }
        if kind == .table { b.aligns = tableAligns }
        var q: UInt8 = 0, l: UInt8 = 0
        for c in stack { if c.kind == .quote { q += 1 } else { l += 1 } }
        b.quoteDepth = q
        b.listDepth = l
        if let k = stack.lastIndex(where: { $0.kind == .item }) {
            b.list = stack[k].list
            if !stack[k].emitted {
                stack[k].emitted = true
                b.firstInItem = true
                b.marker = stack[k].task != .none ? stack[k].task : (stack[k].ordered ? .ordered : .bullet)
                b.markerNumber = stack[k].number
                // Task marker `[ ] ` is stripped from the item's first paragraph.
                if stack[k].task != .none && kind == .paragraph && b.lineCount > 0 {
                    let li = Int(b.lineStart) * 2
                    lines[li] += 4
                    while lines[li] < lines[li + 1] && (p[Int(lines[li])] == 0x20 || p[Int(lines[li])] == 0x09) { lines[li] += 1 }
                }
            }
            lists[Int(b.list)].lastBlock = blocks.count
        }
        blocks.append(b)
        leaf = .none
        leafLines.removeAll(keepingCapacity: true)
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
            while k < le && p[k] >= 0x30 && p[k] <= 0x39 && digits < 10 { number = number * 10 + Int32(p[k] - 0x30); k += 1; digits += 1 }
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
        if let last = lastClosedItem, last.depth == stack.count, last.bullet == s.bullet, last.ordered == s.ordered {
            list = last.list
            if lastLineBlankBeforeItem { lists[Int(list)].loose = true }
        }
        if list < 0 {
            let parent = stack.last(where: { $0.kind == .item })?.list ?? -1
            lists.append(ListInfo(firstBlock: blocks.count, lastBlock: blocks.count, parent: parent))
            list = Int32(lists.count - 1)
        }
        var number = s.number
        if s.ordered, let last = lastClosedItem, last.list == list { number = last.number + 1 }
        stack.append(Container(kind: .item, indent: s.indent, ordered: s.ordered, bullet: s.bullet, number: number,
                               list: list, task: s.task, started: !s.blankStart))
        lastClosedItem = nil
    }

    struct ClosedItem { var depth: Int; var bullet: UInt8; var ordered: Bool; var list: Int32; var number: Int32 }
    var lastClosedItem: ClosedItem?
    var lastLineBlankBeforeItem: Bool { lastLineBlank }

    func closeContainer() {
        closeLeaf()
        guard let c = stack.popLast() else { return }
        if c.kind == .item {
            lastClosedItem = ClosedItem(depth: stack.count, bullet: c.bullet, ordered: c.ordered, list: c.list, number: c.number)
            if !c.emitted {
                // Empty item: still draw its marker.
                var b = PendingBlock(kind: .paragraph)
                b.lineStart = Int32(lines.count / 2)
                b.lineCount = 0
                var q: UInt8 = 0, l: UInt8 = 0
                for k in stack { if k.kind == .quote { q += 1 } else { l += 1 } }
                b.quoteDepth = q
                b.listDepth = l + 1
                b.list = c.list
                b.firstInItem = true
                b.marker = c.task != .none ? c.task : (c.ordered ? .ordered : .bullet)
                b.markerNumber = c.number
                lists[Int(c.list)].lastBlock = blocks.count
                blocks.append(b)
            }
        } else {
            lastClosedItem = nil
        }
    }

    /// A blank line inside an item followed by more content makes the list loose.
    func markBlankInItems() {
        for k in stack.indices where stack[k].kind == .item && stack[k].started {
            stack[k].blankAfterContent = true
        }
        // Only the innermost item's blank matters if more content follows in it; the flag is
        // reset by `itemStarted` when content resumes in the same item... see below.
        pendingBlankItems = true
    }

    var pendingBlankItems = false

    func itemStarted() {
        if let k = stack.lastIndex(where: { $0.kind == .item }) {
            if pendingBlankItems && stack[k].started && stack[k].emitted {
                lists[Int(stack[k].list)].loose = true
            }
            stack[k].started = true
        }
        pendingBlankItems = false
        for k in stack.indices where stack[k].kind == .item { stack[k].blankAfterContent = false }
    }

    // MARK: - Block recognizers

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

    func isOpeningFence(_ at: Int, _ le: Int) -> Bool {
        let c = p[at]
        guard c == 0x60 || c == 0x7E else { return false }
        var k = at
        while k < le && p[k] == c { k += 1 }
        if k - at < 3 { return false }
        if c == 0x60 { for j in k..<le where p[j] == 0x60 { return false } }
        return true
    }

    func isClosingFence(_ at: Int, _ le: Int) -> Bool {
        guard at < le, p[at] == fenceChar else { return false }
        var k = at
        while k < le && p[k] == fenceChar { k += 1 }
        if k - at < fenceLen { return false }
        return isBlank(k, le)
    }

    /// HTML block start condition (CommonMark 4.6), 0 if none.
    func htmlStart(_ at: Int, _ le: Int, interrupting: Bool) -> Int {
        func lowerMatch(_ s: StaticString, _ i: Int) -> Bool {
            let q = s.utf8Start
            let len = s.utf8CodeUnitCount
            if i + len > le { return false }
            for k in 0..<len where (p[i + k] | (p[i + k] >= 0x41 && p[i + k] <= 0x5A ? 0x20 : 0)) != q[k] { return false }
            return true
        }
        func tagEnds(_ i: Int) -> Bool { i >= le || p[i] == 0x20 || p[i] == 0x09 || p[i] == 0x3E || (p[i] == 0x2F && i + 1 < le && p[i + 1] == 0x3E) }
        let i = at + 1
        for t: StaticString in ["script", "pre", "style", "textarea"] where lowerMatch(t, i) && tagEnds(i + t.utf8CodeUnitCount) { return 1 }
        if lowerMatch("!--", i) { return 2 }
        if i < le && p[i] == 0x3F { return 3 }
        if i < le && p[i] == 0x21 && i + 1 < le && ((p[i + 1] | 0x20) >= 0x61 && (p[i + 1] | 0x20) <= 0x7A) { return 4 }
        if lowerMatch("![cdata[", i) { return 5 }
        let closing = i < le && p[i] == 0x2F
        let ns = closing ? i + 1 : i
        var ne = ns
        while ne < le && ((p[ne] | 0x20) >= 0x61 && (p[ne] | 0x20) <= 0x7A || (p[ne] >= 0x30 && p[ne] <= 0x39)) { ne += 1 }
        if ne > ns && tagEnds(ne) {
            let name = String(decoding: UnsafeBufferPointer(start: p + ns, count: ne - ns), as: UTF8.self).lowercased()
            if BlockParser.blockTags.contains(name) { return 6 }
        }
        // Type 7: any complete open/close tag alone on the line (can't interrupt a paragraph).
        if !interrupting && ne > ns {
            var k = ne
            if let e = InlineParser.htmlTagEnd(p, at, le) { k = e } else { return 0 }
            if isBlank(k, le) { return 7 }
        }
        return 0
    }

    func htmlEnds(_ s: Int, _ le: Int) -> Bool {
        let line = UnsafeBufferPointer(start: p + s, count: le - s)
        func has(_ needle: String) -> Bool {
            let nb = Array(needle.utf8)
            if nb.count > line.count { return false }
            outer: for k in 0...(line.count - nb.count) {
                for j in 0..<nb.count {
                    var c = line[k + j]
                    if c >= 0x41 && c <= 0x5A { c |= 0x20 }
                    if c != nb[j] { continue outer }
                }
                return true
            }
            return false
        }
        switch htmlEnd {
        case 1: return has("</script>") || has("</pre>") || has("</style>") || has("</textarea>")
        case 2: return has("-->")
        case 3: return has("?>")
        case 4: return has(">")
        case 5: return has("]]>")
        default: return false
        }
    }

    static let blockTags: Set<String> = ["address", "article", "aside", "base", "basefont", "blockquote", "body", "caption",
        "center", "col", "colgroup", "dd", "details", "dialog", "dir", "div", "dl", "dt", "fieldset", "figcaption", "figure",
        "footer", "form", "frame", "frameset", "h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hr", "html", "iframe",
        "legend", "li", "link", "main", "menu", "menuitem", "nav", "noframes", "ol", "optgroup", "option", "p", "param",
        "search", "section", "summary", "table", "tbody", "td", "tfoot", "th", "thead", "title", "tr", "track", "ul", "picture", "source"]

    // MARK: - Tables (GFM)

    func cellCount(_ s: Int, _ e: Int) -> Int {
        InlineParser.splitCells(p, s, e).count
    }

    /// Parses a delimiter row like `| :-- | :-: | --: |`. Requires the same column count as the header.
    /// Only `|`, `-`, `:` and blanks, with a `-`. Cheap prefilter run on every paragraph's
    /// second line, before splitting the header into cells (4% of parse time without it).
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

    func tableDelimiter(_ at: Int, _ le: Int, headerCells: Int) -> [MDAlign]? {
        let cells = InlineParser.splitCells(p, at, le)
        if cells.isEmpty || cells.count != headerCells { return nil }
        var hasPipe = false
        for j in at..<le where p[j] == 0x7C { hasPipe = true; break }
        if !hasPipe && cells.count == 1 { return nil }   // a lone `---` is a setext/break
        var aligns: [MDAlign] = []
        for (s, e) in cells {
            var a = s, b = e
            while a < b && (p[a] == 0x20 || p[a] == 0x09) { a += 1 }
            while b > a && (p[b - 1] == 0x20 || p[b - 1] == 0x09) { b -= 1 }
            if a == b { return nil }
            let left = p[a] == 0x3A, right = p[b - 1] == 0x3A
            let ds = left ? a + 1 : a, de = right ? b - 1 : b
            if de <= ds { return nil }
            for k in ds..<de where p[k] != 0x2D { return nil }
            aligns.append(left && right ? .center : right ? .right : .left)
        }
        return aligns
    }

    // MARK: - Link reference definitions

    /// Removes `[label]: destination "title"` definitions from the start of the open paragraph.
    func stripReferenceDefinitions() {
        guard leafLines.count >= 2 else { return }
        // A definition starts with "[" (after up to 3 spaces). Checking first matters:
        // building the scratch copy for every paragraph was 22% of parse time.
        var f = Int(leafLines[0])
        let fe = Int(leafLines[1])
        while f < fe && (p[f] == 0x20 || p[f] == 0x09) { f += 1 }
        if f >= fe || p[f] != 0x5B { return }
        // "[label]" must be followed by ":". When the label closes on the first line, check
        // that before copying anything (link-list items like "[Foo](url)" start with "[").
        var k = f + 1
        while k < fe {
            let c = p[k]
            if c == 0x5C { k += 2; continue }
            if c == 0x5B { return }   // unescaped "[" can't appear in a label
            if c == 0x5D { if k + 1 >= fe || p[k + 1] != 0x3A { return }; break }
            k += 1
        }
        // Join the lines (definitions may span lines) into one scratch copy, then parse
        // consecutive definitions from a moving offset (one copy, not one per definition:
        // changelogs end with hundreds of them).
        var total = 0
        for k in stride(from: 0, to: leafLines.count, by: 2) { total += Int(leafLines[k + 1] - leafLines[k]) + 1 }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(total)
        var lineEnds: [Int] = []
        lineEnds.reserveCapacity(leafLines.count / 2)
        if refs.isEmpty { refs.reserveCapacity(16) }
        for k in stride(from: 0, to: leafLines.count, by: 2) {
            let s = Int(leafLines[k]), e = Int(leafLines[k + 1])
            bytes.append(contentsOf: UnsafeBufferPointer(start: p + s, count: e - s))
            bytes.append(0x0A)
            lineEnds.append(bytes.count)
        }
        var off = 0, li = 0, consumedLines = 0
        bytes.withUnsafeBufferPointer { buf in
            let b = buf.baseAddress!
            while off < buf.count {
                guard let (consumed, label, dest, title) = InlineParser.parseReferenceDefinition(b + off, buf.count - off) else { break }
                // Must end at a line boundary.
                let end = off + consumed
                while li < lineEnds.count && lineEnds[li] < end { li += 1 }
                guard li < lineEnds.count, lineEnds[li] == end else { break }
                let key = InlineParser.normalizeLabel(label)
                if refs[key] == nil { refs[key] = (dest, title) }
                li += 1
                consumedLines = li
                off = end
            }
        }
        leafLines.removeFirst(consumedLines * 2)
    }
}
