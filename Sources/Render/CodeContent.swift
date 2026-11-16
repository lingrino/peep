import AppKit
import CoreText

/// Source code: one line per text line, no wrapping, monospaced columns.
///
/// Drawing has two paths per line:
///  - ASCII (the common case): glyphs come from a 128-entry table and x = column * advance,
///    then `CTFontDrawGlyphs` per token run. No shaping, no attributed strings.
///  - Anything else: a CTLine built for just that line (handles fallback fonts, emoji,
///    combining marks, bidi). Hit testing and selection use the same CTLine.
@MainActor
public final class CodeContent: DocumentContent {
    public let text: TextBuffer
    public let lines: LineIndex
    public private(set) var tokens: TokenStream?
    let typo: Typography
    public let language: Language

    let padX: CGFloat = 12
    let padY: CGFloat = 8
    let gutterPadLeft: CGFloat = 14
    let gutterPadRight: CGFloat = 10
    public let gutterWidth: CGFloat
    public private(set) var size: CGSize = .zero

    /// Lines longer than this (bytes) are drawn truncated in the CTLine path.
    static let maxShapedLine = 16_384

    // Reused per-draw scratch storage for glyph runs.
    nonisolated(unsafe) private var glyphs: UnsafeMutablePointer<CGGlyph>
    nonisolated(unsafe) private var positions: UnsafeMutablePointer<CGPoint>
    private var scratchCap = 4096

    public init(text: TextBuffer, lines: LineIndex, tokens: TokenStream?, language: Language,
                typography: Typography = .standard, lineNumbers: Bool = true) {
        self.text = text
        self.lines = lines
        self.tokens = tokens
        self.language = language
        typo = typography
        glyphs = .allocate(capacity: scratchCap)
        positions = .allocate(capacity: scratchCap)
        var digits = 2
        var n = lines.count
        while n >= 100 { digits += 1; n /= 10 }
        gutterWidth = lineNumbers ? (gutterPadLeft + CGFloat(digits) * typography.mono.advance + gutterPadRight).rounded(.up) : 0
        size = CGSize(width: (padX * 2 + CGFloat(lines.maxColumns) * typo.mono.advance).rounded(.up),
                      height: padY * 2 + CGFloat(lines.count) * typo.lineHeight)
    }

    deinit {
        glyphs.deallocate()
        positions.deallocate()
    }

    public func setTokens(_ t: TokenStream) { tokens = t }

    public func layout(width: CGFloat) -> Bool { false }

    @inline(__always) func lineTop(_ i: Int) -> CGFloat { padY + CGFloat(i) * typo.lineHeight }

    @inline(__always) func lineAt(y: CGFloat) -> Int {
        max(0, min(lines.count - 1, Int(((y - padY) / typo.lineHeight).rounded(.down))))
    }

    // MARK: - Per-line geometry

    /// Shaped representation of a non-ASCII line.
    struct Shaped {
        let line: CTLine
        let start: Int
        let end: Int
    }

    @inline(__always)
    func isSimple(_ s: Int, _ e: Int) -> Bool { UnsafePointer(text.base + s).isASCII(e - s) }

    /// End of the shortest prefix of line [s, e) that surely reaches `columns`: every
    /// character advances at least one column (tabs and wide glyphs more), so counting
    /// characters bounds it. Zero-width combining marks can undercount; callers add margin.
    func visiblePrefixEnd(_ s: Int, _ e: Int, columns: Int) -> Int {
        if e - s <= columns { return e }   // bytes >= characters
        let p = text.base
        var n = 0
        var i = s
        while i < e {
            if p[i] & 0xC0 != 0x80 {
                if n == columns { return i }
                n &+= 1
            }
            i &+= 1
        }
        return e
    }

    /// x (content space) of byte `o` within line [s, e).
    func x(of o: Int, line s: Int, _ e: Int, shaped: Shaped?) -> CGFloat {
        if let sh = shaped {
            let idx = utf16Count(sh.start, min(o, sh.end))
            return padX + CTLineGetOffsetForStringIndex(sh.line, idx, nil)
        }
        return padX + CGFloat(LineIndex.columns(text.base, s, min(o, e))) * typo.mono.advance
    }

    /// UTF-16 code units in bytes [s, o).
    @inline(__always)
    func utf16Count(_ s: Int, _ o: Int) -> Int {
        var n = 0
        var i = s
        let p = text.base
        while i < o {
            let b = p[i]
            if b < 0x80 { n &+= 1; i &+= 1 }
            else if b >= 0xF0 { n &+= 2; i &+= 4 }
            else if b >= 0xE0 { n &+= 1; i &+= 3 }
            else if b >= 0xC0 { n &+= 1; i &+= 2 }
            else { i &+= 1 }
        }
        return n
    }

    /// Byte offset of UTF-16 index `u` within a line starting at `s` (clamped to `e`).
    func byteOffset(utf16 u: Int, _ s: Int, _ e: Int) -> Int {
        var n = 0
        var i = s
        let p = text.base
        while i < e && n < u {
            let b = p[i]
            if b < 0x80 { n &+= 1; i &+= 1 }
            else if b >= 0xF0 { n &+= 2; i &+= 4 }
            else if b >= 0xE0 { n &+= 1; i &+= 3 }
            else { n &+= 1; i &+= 2 }
        }
        return min(i, e)
    }

    func shape(_ s: Int, _ e0: Int, palette: Palette) -> Shaped {
        var e = min(e0, s + CodeContent.maxShapedLine)
        while e > s && e < e0 && text.base[e] & 0xC0 == 0x80 { e -= 1 }   // char boundary
        let str = CFStringCreateWithBytes(nil, text.base + s, e - s, CFStringBuiltInEncodings.UTF8.rawValue, false)
            ?? ("" as CFString)
        let attr = CFAttributedStringCreateMutable(nil, 0)!
        CFAttributedStringReplaceString(attr, CFRange(location: 0, length: 0), str)
        let len = CFAttributedStringGetLength(attr)
        CFAttributedStringBeginEditing(attr)
        CFAttributedStringSetAttribute(attr, CFRange(location: 0, length: len), kCTFontAttributeName, typo.mono.font)
        CFAttributedStringSetAttribute(attr, CFRange(location: 0, length: len), kCTForegroundColorAttributeName, palette.text)
        CFAttributedStringSetAttribute(attr, CFRange(location: 0, length: len), kCTParagraphStyleAttributeName, tabStyle)
        if let t = tokens {
            var k = t.first(after: s)
            var u = 0
            var pos = s
            while k < t.count && t.start(k) < e {
                let ts = max(t.start(k), s), te = min(t.end(k), e)
                let kind = t.kinds[k]
                u += utf16Count(pos, ts)
                let ulen = utf16Count(ts, te)
                if kind != 0 && ulen > 0 {
                    let r = CFRange(location: u, length: ulen)
                    CFAttributedStringSetAttribute(attr, r, kCTForegroundColorAttributeName, palette.tokenColors[Int(kind)])
                    if palette.tokenBold[Int(kind)] {
                        CFAttributedStringSetAttribute(attr, r, kCTFontAttributeName, typo.monoBold.font)
                    }
                }
                u += ulen
                pos = te
                k += 1
            }
        }
        CFAttributedStringEndEditing(attr)
        return Shaped(line: CTLineCreateWithAttributedString(attr), start: s, end: e)
    }

    lazy var tabStyle: CTParagraphStyle = {
        var interval = CGFloat(LineIndex.tabWidth) * typo.mono.advance
        var tabs: CFArray = [] as CFArray
        return withUnsafePointer(to: &interval) { ip in
            withUnsafePointer(to: &tabs) { tp in
                let settings = [
                    CTParagraphStyleSetting(spec: .defaultTabInterval, valueSize: MemoryLayout<CGFloat>.size, value: ip),
                    CTParagraphStyleSetting(spec: .tabStops, valueSize: MemoryLayout<CFArray>.size, value: tp),
                ]
                return CTParagraphStyleCreate(settings, settings.count)
            }
        }
    }()

    // MARK: - Drawing

    public func draw(_ ctx: CGContext, rect: CGRect, palette: Palette, highlights h: Highlights) {
        let lh = typo.lineHeight
        let first = lineAt(y: rect.minY)
        let last = lineAt(y: rect.maxY)
        let adv = typo.mono.advance
        var mi = h.firstMatch(endingAfter: lines.start(first))
        for i in first...last {
            let y = lineTop(i)
            if y > rect.maxY { break }
            if y + lh < rect.minY { continue }
            let s = lines.start(i), e = lines.end(i)
            let next = Int(lines.starts[i + 1])   // includes the newline
            // Only the part of the line that can reach this tile's right edge is classified,
            // shaped and drawn: an 8 KB minified line with one non-ASCII character was being
            // shaped whole, once per tile (14 ms first paint).
            let pe = visiblePrefixEnd(s, e, columns: Int((rect.maxX - padX) / adv) + 32)
            let simple = isSimple(s, pe)
            let shaped = simple ? nil : shape(s, pe, palette: palette)

            // Selection background.
            if h.selEnd > h.selStart && h.selStart < next && h.selEnd > s {
                let x0 = h.selStart <= s ? padX : x(of: h.selStart, line: s, pe, shaped: shaped)
                let x1 = h.selEnd > e ? max(rect.maxX, x(of: e, line: s, pe, shaped: shaped) + adv) : x(of: h.selEnd, line: s, pe, shaped: shaped)
                ctx.setFillColor(palette.selection)
                ctx.fill(CGRect(x: x0, y: y, width: max(1, x1 - x0), height: lh))
            }
            // Find matches.
            while mi < h.matchCount {
                let ms = Int(h.matches[2 * mi]), me = Int(h.matches[2 * mi + 1])
                if ms >= next { break }
                let a = max(ms, s), b = min(me, e)
                if b > a || (ms < next && me > s) {
                    let x0 = x(of: a, line: s, pe, shaped: shaped)
                    let x1 = b > a ? x(of: b, line: s, pe, shaped: shaped) : x0 + adv / 2
                    let r = CGRect(x: x0 - 1, y: y + 1, width: x1 - x0 + 2, height: lh - 2)
                    ctx.setFillColor(mi == h.current ? palette.findCurrent : palette.findMatch)
                    ctx.addPath(CGPath(roundedRect: r, cornerWidth: 3, cornerHeight: 3, transform: nil))
                    ctx.fillPath()
                }
                if me > next { break }   // continues on the next line
                mi += 1
            }

            let baseline = y + typo.baselineOffset
            if let sh = shaped {
                ctx.textPosition = CGPoint(x: padX, y: baseline)
                CTLineDraw(sh.line, ctx)
                // CTLineDraw advances the text position (part of the text matrix); the glyph
                // fast path below positions glyphs absolutely and must start from zero.
                ctx.textPosition = .zero
            } else {
                drawASCII(ctx, s, pe, baseline: baseline, minX: rect.minX, maxX: rect.maxX, palette: palette)
            }
        }
    }

    /// Glyph positions are in *text space*: the text matrix flips y for our flipped
    /// context, so positions carry a negated baseline.
    private func drawASCII(_ ctx: CGContext, _ s: Int, _ e: Int, baseline: CGFloat, minX: CGFloat, maxX: CGFloat, palette: Palette) {
        let p = text.base
        let adv = typo.mono.advance
        let c0 = max(0, Int((minX - padX) / adv) - 1)
        let c1 = Int((maxX - padX) / adv) + 2
        let tw = LineIndex.tabWidth
        var b = s
        var col = 0
        // Jump straight to the first visible column when the line has no tabs.
        if c0 > 0 && memchr(p + s, 0x09, e - s) == nil {
            b = s + min(c0, e - s)
            col = b - s
        }
        if e - b > scratchCap { growScratch(e - b) }
        var tok = -1
        var tokEnd = Int.max
        var kind: UInt8 = 0
        if let t = tokens, t.count > 0 {
            tok = t.first(after: b)
            if tok < t.count { tokEnd = t.end(tok); kind = t.kinds[tok] } else { tok = -1 }
        }
        var n = 0
        var runKind = kind
        let table = typo.mono.glyphs
        let tableBold = typo.monoBold.glyphs
        // `glyphs` holds raw bytes until a run is flushed, then maps them through the
        // regular or bold glyph table (both fonts share the advance).
        @inline(__always) func flush() {
            if n == 0 { return }
            ctx.setFillColor(palette.tokenColors[Int(runKind)])
            let bold = palette.tokenBold[Int(runKind)]
            let tbl = bold ? tableBold : table
            for k in 0..<n { glyphs[k] = tbl[Int(glyphs[k])] }
            CTFontDrawGlyphs(bold ? typo.monoBold.font : typo.mono.font, glyphs, positions, n, ctx)
            n = 0
        }
        while b < e && col < c1 {
            if b >= tokEnd, let t = tokens {
                tok += 1
                if tok < t.count { tokEnd = t.end(tok); kind = t.kinds[tok] } else { tokEnd = Int.max; kind = 0 }
            }
            let ch = p[b]
            b &+= 1
            if ch <= 0x20 {
                col = ch == 0x09 ? (col / tw + 1) * tw : col + 1
                continue
            }
            if col >= c0 {
                if kind != runKind { flush(); runKind = kind }
                glyphs[n] = CGGlyph(ch)
                positions[n] = CGPoint(x: padX + CGFloat(col) * adv, y: -baseline)
                n &+= 1
            }
            col &+= 1
        }
        flush()
    }

    private func growScratch(_ n: Int) {
        glyphs.deallocate(); positions.deallocate()
        scratchCap = max(n, scratchCap * 2)
        glyphs = .allocate(capacity: scratchCap)
        positions = .allocate(capacity: scratchCap)
    }

    public func drawGutter(_ ctx: CGContext, rect: CGRect, palette: Palette) {
        let first = lineAt(y: rect.minY), last = lineAt(y: rect.maxY)
        let adv = typo.mono.advance
        let right = gutterWidth - gutterPadRight
        let table = typo.mono.glyphs
        if (last - first + 1) * 12 > scratchCap { growScratch((last - first + 1) * 12) }
        var n = 0
        for i in first...last {
            let baseline = lineTop(i) + typo.baselineOffset
            var v = i + 1
            var x = right
            repeat {
                x -= adv
                glyphs[n] = table[0x30 + v % 10]
                positions[n] = CGPoint(x: x, y: -baseline)
                n += 1
                v /= 10
            } while v > 0
        }
        ctx.setFillColor(palette.secondaryText)
        CTFontDrawGlyphs(typo.mono.font, glyphs, positions, n, ctx)
    }

    // MARK: - Hit testing & ranges

    public func offset(at p: CGPoint) -> Int {
        if p.y < padY { return 0 }
        if p.y >= lineTop(lines.count) { return text.count }
        let i = lineAt(y: p.y)
        let s = lines.start(i), e = lines.end(i)
        if !isSimple(s, e) {
            let sh = shape(s, e, palette: .light)
            let u = CTLineGetStringIndexForPosition(sh.line, CGPoint(x: p.x - padX, y: 0))
            return byteOffset(utf16: max(0, u), s, sh.end)
        }
        let target = (p.x - padX) / typo.mono.advance
        if target <= 0 { return s }
        let tw = LineIndex.tabWidth
        var col = 0
        var b = s
        while b < e {
            let ch = text.base[b]
            let next = ch == 0x09 ? (col / tw + 1) * tw : col + 1
            if CGFloat(col + next) / 2 >= target { return b }
            col = next
            b += 1
        }
        return e
    }

    public func rect(for start: Int, _ end: Int) -> CGRect {
        let i = lines.line(containing: start)
        let s = lines.start(i), e = lines.end(i)
        let sh = isSimple(s, e) ? nil : shape(s, e, palette: .light)
        let x0 = x(of: start, line: s, e, shaped: sh)
        let x1 = x(of: min(end, e), line: s, e, shaped: sh)
        return CGRect(x: x0, y: lineTop(i), width: max(x1 - x0, typo.mono.advance), height: typo.lineHeight)
    }

    public func verticalExtent(_ start: Int, _ end: Int) -> (CGFloat, CGFloat) {
        let a = lines.line(containing: start), b = lines.line(containing: max(start, end))
        return (lineTop(a), lineTop(b) + typo.lineHeight)
    }

    public func wordRange(at o: Int) -> (Int, Int) {
        let cc = ByteClass.standard
        let i = lines.line(containing: o)
        let s = lines.start(i), e = lines.end(i)
        if o >= e { return (max(s, e - 1) < e ? e - 1 : e, e) }
        let p = text.base
        if !cc.isIdent(p[o]) {
            if cc.isSpace(p[o]) {   // whitespace run
                var a = o, b = o
                while a > s && p[a - 1] == p[o] { a -= 1 }
                while b < e && p[b] == p[o] { b += 1 }
                return (a, b)
            }
            var b = o + 1
            while b < e && p[b] & 0xC0 == 0x80 { b += 1 }
            return (o, b)
        }
        var a = o, b = o
        while a > s && cc.isIdent(p[a - 1]) { a -= 1 }
        while b < e && cc.isIdent(p[b]) { b += 1 }
        return (a, b)
    }

    public func lineRange(at o: Int) -> (Int, Int) {
        let i = lines.line(containing: o)
        return (lines.start(i), min(text.count, Int(lines.starts[i + 1])))
    }
}
