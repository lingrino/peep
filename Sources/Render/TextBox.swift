import AppKit
import CoreText

/// Custom attribute keys read back at draw time (Core Text doesn't draw these itself).
enum MDAttr {
    static let inlineCode = NSAttributedString.Key("PeepInlineCode")     // rounded background
    static let kbd = NSAttributedString.Key("PeepKbd")                   // key cap box
    static let strike = NSAttributedString.Key("PeepStrike")             // line through
    static let image = NSAttributedString.Key("PeepImage")               // Int: image index
}

/// One laid-out run of rich text (a paragraph, heading, code block or table cell): a CTFrame
/// placed in content space plus the mapping back to the document's UTF-8 text range.
final class TextBox: @unchecked Sendable {
    private(set) var rect: CGRect    // content space (y down); built in local space, then translated
    let start: Int                   // UTF-8 range in the document text
    let end: Int
    let lines: [CTLine]
    private(set) var baselines: [CGFloat]   // content-space y of each baseline
    let lineX: [CGFloat]                    // content-space x of each line origin
    private(set) var lineTop: [CGFloat]
    private(set) var lineBottom: [CGFloat]
    /// UTF-16 offset for each UTF-8 byte of the range (nil when the range is ASCII).
    let utf16: [Int32]?
    let utf16Count: Int

    /// UTF-16 offset of each line's frame within the box (nil: one frame, all zero). Lines
    /// from a later frame report string indices relative to that frame's substring.
    private let lineBase: [Int]?

    /// Frame sizes. A box is one frame unless it is long: Core Text's line breaking is
    /// quadratic in the length of a paragraph (it isn't greedy, it weighs the whole paragraph:
    /// 100 KB took 0.41 s, 200 KB 1.6 s, 1 MB 32 s on the main thread), and a frame is bounded
    /// by its path height (blocks past 1,000,000 pt were cut). So a long box is laid out as
    /// consecutive frames: cut after a newline when there is one (layout identical but for
    /// rounding: < 0.5 pt), else, inside a paragraph longer than `longParagraph`, in windows
    /// whose last lines are dropped and re-laid out by the next window (breaks then differ
    /// slightly from one huge paragraph's; nobody reads 16 KB paragraphs for their rag).
    static let longParagraph = 16_384
    static let maxFrame = 262_144
    private static let paragraphWindow = 16_384, windowLookahead = 1_024

    init(attributed: NSAttributedString, origin: CGPoint, width: CGFloat, start: Int, end: Int,
         text: TextBuffer, lineGap: CGFloat = 0) {
        self.start = start
        self.end = end
        let len = attributed.length
        // One layout pass per frame: frame into a very tall rect, measure from the lines (skips
        // CTFramesetterSuggestFrameSizeWithConstraints, which would lay out a second time).
        let h: CGFloat = 1_000_000
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: max(1, width), height: h), transform: nil)
        var ls: [CTLine] = []
        var origins: [CGPoint] = []   // y: baseline from the box's first frame top (down)
        var bases: [Int] = []
        if len <= TextBox.longParagraph {
            let setter = CTFramesetterCreateWithAttributedString(attributed)
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: len), path, nil)
            ls = (CTFrameGetLines(frame) as? [CTLine]) ?? []
            var o = [CGPoint](repeating: .zero, count: ls.count)
            if !ls.isEmpty { CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &o) }
            origins = o.map { CGPoint(x: $0.x, y: h - $0.y) }
        } else {
            let str = attributed.string as NSString
            var pos = 0
            var top: CGFloat = 0
            var nl = -1   // the next newline at or after the last search (len: none); reused by
                          // a long paragraph's windows, which would otherwise rescan its rest
            while pos < len {
                // Whole paragraphs up to maxFrame units; a long paragraph gets windows.
                var cut = pos, exact = true
                while cut < len {
                    if nl < cut {
                        let f = str.range(of: "\n", options: .literal, range: NSRange(location: cut, length: len - cut)).location
                        nl = f == NSNotFound ? len : f
                    }
                    let paraEnd = min(len, nl + 1)
                    if paraEnd - cut > TextBox.longParagraph {
                        if cut > pos { break }
                        cut = min(paraEnd, pos + TextBox.paragraphWindow)
                        exact = cut == paraEnd
                        break
                    }
                    if paraEnd - pos > TextBox.maxFrame && cut > pos { break }
                    cut = paraEnd
                }
                let sub = attributed.attributedSubstring(from: NSRange(location: pos, length: cut - pos))
                let setter = CTFramesetterCreateWithAttributedString(sub)
                let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, nil)
                let fl = (CTFrameGetLines(frame) as? [CTLine]) ?? []
                if fl.isEmpty { break }
                var o = [CGPoint](repeating: .zero, count: fl.count)
                CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &o)
                var keep = fl.count
                if !exact {   // drop lines near the window's end (they saw a fake paragraph end)
                    let limit = cut - pos - TextBox.windowLookahead
                    while keep > 1 {
                        let r = CTLineGetStringRange(fl[keep - 1])
                        if r.location + r.length <= limit { break }
                        keep -= 1
                    }
                }
                // A later frame starts where the previous one's last line ends (its descent and
                // leading below the baseline); its own first-line offset follows.
                if let last = ls.last {
                    var desc: CGFloat = 0, lead: CGFloat = 0
                    _ = CTLineGetTypographicBounds(last, nil, &desc, &lead)
                    top = origins[origins.count - 1].y + desc + lead
                }
                for i in 0..<keep {
                    ls.append(fl[i])
                    origins.append(CGPoint(x: o[i].x, y: top + h - o[i].y))
                    bases.append(pos)
                }
                // Next frame: after the last kept line (also when the frame filled its height).
                let r = CTLineGetStringRange(fl[keep - 1])
                pos += max(1, r.location + r.length)
            }
        }
        lineBase = bases.isEmpty ? nil : bases
        lines = ls
        var b: [CGFloat] = [], x: [CGFloat] = [], t: [CGFloat] = [], bt: [CGFloat] = []
        b.reserveCapacity(ls.count)
        // Core Text puts a paragraph style's extra line height above *every* line, including
        // the first, which would give each box dead space at its top (paragraph pitch 3em
        // instead of ~2.5em). Shift so the first line's top (half the line gap above its
        // ascent) is the box top.
        var shift: CGFloat = 0
        if let l = ls.first {
            var asc: CGFloat = 0
            _ = CTLineGetTypographicBounds(l, &asc, nil, nil)
            shift = origins[0].y - asc - lineGap / 2
        }
        for (i, l) in ls.enumerated() {
            var asc: CGFloat = 0, desc: CGFloat = 0, lead: CGFloat = 0
            _ = CTLineGetTypographicBounds(l, &asc, &desc, &lead)
            let base = origin.y + origins[i].y - shift
            b.append(base)
            x.append(origin.x + origins[i].x)
            t.append(base - asc - lineGap / 2)
            bt.append(base + desc + lineGap / 2)
        }
        baselines = b
        lineX = x
        lineTop = t
        lineBottom = bt
        let height = ceil((bt.last ?? origin.y) - origin.y) + 1
        rect = CGRect(x: origin.x, y: origin.y, width: width, height: height)
        utf16Count = len
        let p = text.base + start
        if UnsafePointer(p).isASCII(end - start) {
            utf16 = nil
        } else {
            var map = [Int32](repeating: 0, count: end - start + 1)
            var u: Int32 = 0
            var i = 0
            while i < end - start {
                map[i] = u
                let c = p[i]
                if c & 0xC0 != 0x80 { u += c >= 0xF0 ? 2 : 1 }
                i += 1
            }
            map[end - start] = u
            utf16 = map
        }
    }

    private var placedTop: CGFloat = 0

    /// Places the box's block at content-space `top` (boxes are laid out block-local, in
    /// parallel). Absolute, not relative: a block laid out synchronously is stacked again when
    /// background layout lands, and translating twice put its text at 2·top.
    func place(top: CGFloat) {
        translate(top - placedTop)
        placedTop = top
    }

    private func translate(_ dy: CGFloat) {
        if dy == 0 { return }
        rect.origin.y += dy
        for i in baselines.indices {
            baselines[i] += dy
            lineTop[i] += dy
            lineBottom[i] += dy
        }
    }

    @inline(__always) func u16(_ o: Int) -> Int {
        let k = max(0, min(o, end) - start)
        return utf16.map { Int($0[k]) } ?? k
    }

    /// UTF-8 offset for a UTF-16 index within the box.
    func u8(_ u: Int) -> Int {
        guard let map = utf16 else { return start + max(0, min(u, end - start)) }
        var lo = 0, hi = map.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) >> 1
            if Int(map[mid]) <= u { lo = mid } else { hi = mid - 1 }
        }
        return start + lo
    }

    func line(at y: CGFloat) -> Int {
        if lines.isEmpty { return -1 }
        for i in 0..<lines.count where y < lineBottom[i] { return i }
        return lines.count - 1
    }

    // MARK: - Drawing

    @MainActor
    func draw(_ ctx: CGContext, rect clip: CGRect, palette: Palette, highlights h: Highlights,
              content: MarkdownContent) {
        guard rect.intersects(clip) else { return }
        for i in lines.indices {
            if lineBottom[i] < clip.minY { continue }
            if lineTop[i] > clip.maxY { break }
            let line = lines[i]
            let range = CTLineGetStringRange(line), lb = lineBase?[i] ?? 0
            let lStart = u8(lb + range.location), lEnd = u8(lb + range.location + range.length)
            // Selection / matches behind the text.
            if h.selEnd > h.selStart && h.selStart < lEnd + 1 && h.selEnd > lStart {
                let a = max(h.selStart, lStart), b = min(h.selEnd, lEnd)
                var x0 = lineX[i] + CTLineGetOffsetForStringIndex(line, u16(a) - lb, nil)
                var x1 = lineX[i] + CTLineGetOffsetForStringIndex(line, u16(b) - lb, nil)
                if h.selEnd > lEnd { x1 = max(x1, rect.maxX) }
                if h.selStart <= lStart && i == 0 { x0 = min(x0, lineX[i]) }
                ctx.setFillColor(palette.selection)
                ctx.fill(CGRect(x: x0, y: lineTop[i], width: max(2, x1 - x0), height: lineBottom[i] - lineTop[i]))
            }
            var mi = h.firstMatch(endingAfter: lStart)
            while mi < h.matchCount {
                let ms = Int(h.matches[2 * mi]), me = Int(h.matches[2 * mi + 1])
                if ms >= lEnd { break }
                let a = max(ms, lStart), b = min(me, lEnd)
                if b > a {
                    let x0 = lineX[i] + CTLineGetOffsetForStringIndex(line, u16(a) - lb, nil)
                    let x1 = lineX[i] + CTLineGetOffsetForStringIndex(line, u16(b) - lb, nil)
                    ctx.setFillColor(mi == h.current ? palette.findCurrent : palette.findMatch)
                    let r = CGRect(x: x0 - 1, y: lineTop[i] + 1, width: x1 - x0 + 2, height: lineBottom[i] - lineTop[i] - 2)
                    ctx.addPath(CGPath(roundedRect: r, cornerWidth: 3, cornerHeight: 3, transform: nil))
                    ctx.fillPath()
                }
                if me > lEnd { break }
                mi += 1
            }
            decorate(ctx, line: line, index: i, palette: palette, content: content, before: true)
            ctx.textPosition = CGPoint(x: lineX[i], y: baselines[i])
            CTLineDraw(line, ctx)
            decorate(ctx, line: line, index: i, palette: palette, content: content, before: false)
        }
    }

    /// Inline code/kbd backgrounds (before text), strikethrough and images (after).
    @MainActor
    private func decorate(_ ctx: CGContext, line: CTLine, index i: Int, palette: Palette, content: MarkdownContent, before: Bool) {
        guard let runs = CTLineGetGlyphRuns(line) as? [CTRun] else { return }
        for run in runs {
            let attrs = CTRunGetAttributes(run) as NSDictionary
            let code = attrs[MDAttr.inlineCode] != nil, kbd = attrs[MDAttr.kbd] != nil
            let strike = attrs[MDAttr.strike] != nil
            let image = attrs[MDAttr.image] as? Int
            if !(code || kbd || strike || image != nil) { continue }
            var asc: CGFloat = 0, desc: CGFloat = 0
            let w = CGFloat(CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), &asc, &desc, nil))
            var pos = CGPoint.zero
            CTRunGetPositions(run, CFRange(location: 0, length: 1), &pos)
            let x = lineX[i] + pos.x
            let base = baselines[i]
            if before && (code || kbd) {
                let r = CGRect(x: x - 3, y: base - asc - 2, width: w + 6, height: asc + desc + 4)
                ctx.setFillColor(palette.blockBackground)
                ctx.addPath(CGPath(roundedRect: r, cornerWidth: 4, cornerHeight: 4, transform: nil))
                ctx.fillPath()
                if kbd {
                    ctx.setStrokeColor(palette.border)
                    ctx.setLineWidth(1)
                    ctx.addPath(CGPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 4, cornerHeight: 4, transform: nil))
                    ctx.strokePath()
                }
            } else if !before && strike {
                let font = attrs[kCTFontAttributeName] as! CTFont
                let y = base - CTFontGetXHeight(font) / 2
                ctx.setFillColor((attrs[kCTForegroundColorAttributeName] as! CGColor?) ?? palette.text)
                ctx.fill(CGRect(x: x, y: y - 0.5, width: w, height: 1))
            } else if !before, let idx = image {
                content.drawImage(idx, in: CGRect(x: x, y: base - asc, width: w, height: asc + desc), ctx: ctx)
            }
        }
    }

    // MARK: - Hit testing

    func offset(at p: CGPoint) -> Int {
        let i = line(at: p.y)
        if i < 0 { return start }
        if p.y < (lineTop.first ?? rect.minY) { return start }
        let u = CTLineGetStringIndexForPosition(lines[i], CGPoint(x: p.x - lineX[i], y: 0))
        return u8(max(0, u) + (lineBase?[i] ?? 0))
    }

    func rect(for a: Int, _ b: Int) -> CGRect {
        let ua = u16(a)
        for i in lines.indices {
            let r = CTLineGetStringRange(lines[i]), lb = lineBase?[i] ?? 0
            if ua >= lb + r.location && ua <= lb + r.location + r.length {
                let x0 = CTLineGetOffsetForStringIndex(lines[i], ua - lb, nil)
                let x1 = CTLineGetOffsetForStringIndex(lines[i], u16(b) - lb, nil)
                return CGRect(x: lineX[i] + x0, y: lineTop[i], width: max(4, x1 - x0), height: lineBottom[i] - lineTop[i])
            }
        }
        return CGRect(x: rect.minX, y: rect.minY, width: 4, height: 16)
    }

    /// UTF-8 offset of the character whose glyph is under `p` (nil: not over text).
    func characterOffset(at p: CGPoint) -> Int? {
        let i = line(at: p.y)
        if i < 0 || p.y < lineTop[i] || p.y > lineBottom[i] { return nil }
        let x = p.x - lineX[i]
        guard let runs = CTLineGetGlyphRuns(lines[i]) as? [CTRun] else { return nil }
        for run in runs {
            let n = CTRunGetGlyphCount(run)
            if n == 0 { continue }
            var pos = [CGPoint](repeating: .zero, count: n), adv = [CGSize](repeating: .zero, count: n)
            var idx = [CFIndex](repeating: 0, count: n)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &pos)
            CTRunGetAdvances(run, CFRange(location: 0, length: 0), &adv)
            CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &idx)
            for g in 0..<n where x >= pos[g].x && x < pos[g].x + max(adv[g].width, 1) { return u8(idx[g] + (lineBase?[i] ?? 0)) }
        }
        return nil
    }
}
