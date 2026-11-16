import AppKit
import CoreText
import os

/// Markdown block layout, run in parallel across blocks.
///
/// Each block is laid out independently in *local* coordinates (block top = 0) by
/// `MarkdownLayout.block`, which is nonisolated and touches only immutable inputs (`LayoutEnv`).
/// `MarkdownContent.relayout` runs it over all blocks with `concurrentPerform`, then stacks the
/// results on the main thread (gaps, quote bars, list markers depend on neighbors).
/// Core Text shaping is ~70% of layout cost, so this scales almost linearly with P-cores.

struct MDMetrics: Sendable {
    let body: CGFloat = 13
    var gap: CGFloat { body * 0.95 }
    var tightGap: CGFloat { body * 0.25 }
    let maxWidth: CGFloat = 880
    let padX: CGFloat = 28
    let padTop: CGFloat = 22
    let listIndent: CGFloat = 24
    let quoteIndent: CGFloat = 18
    let codePad: CGFloat = 12
    var codeSize: CGFloat { (body * 0.88).rounded() + 0.5 }

    func headingSize(_ level: UInt8) -> CGFloat {
        switch level {
        case 1: return (body * 1.9).rounded()
        case 2: return (body * 1.5).rounded()
        case 3: return (body * 1.25).rounded()
        case 4: return body + 1
        case 5: return body
        default: return body - 0.5
        }
    }

    func lineGap(_ size: CGFloat, _ multiple: CGFloat = 1.5) -> CGFloat { size * (multiple - 1.2) }
}

/// Fonts by (size, weight, italic, mono), shared by layout threads.
final class FontBook: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var fonts: [Int: NSFont] = [:]

    func font(_ size: CGFloat, weight: NSFont.Weight = .regular, italic: Bool = false, mono: Bool = false) -> NSFont {
        let key = Int(size * 4) << 8 | Int((weight.rawValue + 1) * 10) << 2 | (italic ? 2 : 0) | (mono ? 1 : 0)
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        if let f = fonts[key] { return f }
        var f = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        if italic, let i = NSFont(descriptor: f.fontDescriptor.withSymbolicTraits(.italic), size: size) { f = i }
        fonts[key] = f
        return f
    }
}

enum DecoRole: Sendable { case border, blockBackground, secondary, text, accent }

enum Deco: @unchecked Sendable {
    case fill(CGRect, DecoRole, CGFloat)
    case line(CGRect, DecoRole)
    case bullet(CGPoint, Int)                 // center, depth
    case label(CTLine, CGPoint)               // ordered list number, right-aligned origin
    case check(CGRect, Bool)

    func offset(_ dy: CGFloat) -> Deco {
        switch self {
        case .fill(let r, let role, let rad): return .fill(r.offsetBy(dx: 0, dy: dy), role, rad)
        case .line(let r, let role): return .line(r.offsetBy(dx: 0, dy: dy), role)
        case .bullet(let p, let d): return .bullet(CGPoint(x: p.x, y: p.y + dy), d)
        case .label(let l, let p): return .label(l, CGPoint(x: p.x, y: p.y + dy))
        case .check(let r, let done): return .check(r.offsetBy(dx: 0, dy: dy), done)
        }
    }
}

struct PlacedDeco: @unchecked Sendable {
    var minY: CGFloat
    var maxY: CGFloat
    var deco: Deco
}

/// Everything layout needs, immutable for the duration of one relayout.
struct LayoutEnv: @unchecked Sendable {
    let doc: MarkdownDocument
    let palette: Palette
    let m: MDMetrics
    let fonts: FontBook
    let imageSizes: [CGSize]
    let x0: CGFloat
    let contentW: CGFloat
}

struct BlockLayout: @unchecked Sendable {
    var boxes: [TextBox] = []
    var decos: [PlacedDeco] = []
    var height: CGFloat = 0
    var firstBaseline: CGFloat?
    var right: CGFloat = 0
}

/// Background layout of the blocks after the synchronous prefix.
final class PendingLayout: @unchecked Sendable {
    let first: Int
    let count: Int
    let x0: CGFloat
    let prefix: ArraySlice<BlockLayout>
    let env: LayoutEnv
    private(set) var results: [BlockLayout] = []
    private let done = DispatchGroup()
    /// Whether `run` has been called or scheduled (main thread only).
    var started = false

    init(first: Int, count: Int, x0: CGFloat, prefix: ArraySlice<BlockLayout>, env: LayoutEnv) {
        self.first = first
        self.count = count
        self.x0 = x0
        self.prefix = prefix
        self.env = env
        done.enter()
    }

    func run() {
        let env = self.env
        let buf = UnsafeMutableBufferPointer<BlockLayout>.allocate(capacity: count)
        nonisolated(unsafe) let base = buf.baseAddress!
        let chunk = max(8, count / 48)
        let chunks = (count + chunk - 1) / chunk
        let first = self.first, count = self.count
        DispatchQueue.concurrentPerform(iterations: chunks) { c in
            for i in (c * chunk)..<min(count, (c + 1) * chunk) {
                (base + i).initialize(to: MarkdownLayout.block(first + i, env))
            }
        }
        results = Array(buf)
        _ = buf.deinitialize()
        buf.deallocate()
        done.leave()
    }

    func wait() { done.wait() }
}

enum MarkdownLayout {
    /// Cheap height guess for a block not laid out yet (only affects the scroll bar until
    /// the background layout lands).
    static func estimate(_ bi: Int, _ env: LayoutEnv) -> BlockLayout {
        let b = env.doc.blocks[bi]
        let m = env.m
        let bytes = CGFloat(b.textEnd - b.textStart)
        let charsPerLine = max(20, env.contentW / (m.body * 0.5))
        var h: CGFloat
        switch b.kind {
        case .code:
            var lines: CGFloat = 1
            let p = env.doc.text.base
            for i in Int(b.textStart)..<Int(b.textEnd) where p[i] == 0x0A { lines += 1 }
            h = lines * m.codeSize * 1.45 + 2 * m.codePad
        case .heading: h = m.headingSize(b.level) * 1.4 + (b.level <= 2 ? m.body * 0.5 : 0)
        case .rule: h = m.body * 0.8 + 2
        case .table:
            let t = env.doc.tables[Int(b.table)]
            h = CGFloat(t.rows) * (m.body * 1.35 + 14)
        default: h = (bytes / charsPerLine).rounded(.up) * m.body * 1.5
        }
        var out = BlockLayout()
        out.height = max(m.body, h)
        out.right = env.x0 + env.contentW
        if b.marker != .none { out.firstBaseline = m.body }
        return out
    }

    static func block(_ bi: Int, _ env: LayoutEnv) -> BlockLayout {
        let b = env.doc.blocks[bi]
        let m = env.m
        let indent = CGFloat(b.quoteDepth) * m.quoteIndent + CGFloat(b.listDepth) * m.listIndent
        let bx = env.x0 + indent
        let bw = max(60, env.contentW - indent)
        var out = BlockLayout()
        out.right = env.x0 + env.contentW
        var y: CGFloat = 0
        switch b.kind {
        case .paragraph, .html, .footnote:
            let a = inline(env, b.textStart, b.textEnd, runs: b.runStart..<b.runEnd, font: env.fonts.font(m.body),
                           color: b.quoteDepth > 0 ? env.palette.secondaryText : env.palette.text, align: b.align)
            let box = TextBox(attributed: a, origin: CGPoint(x: bx, y: 0), width: bw, start: Int(b.textStart),
                              end: Int(b.textEnd), text: env.doc.text, lineGap: m.lineGap(m.body))
            out.boxes.append(box)
            y = box.rect.maxY
        case .heading:
            let size = m.headingSize(b.level)
            let a = inline(env, b.textStart, b.textEnd, runs: b.runStart..<b.runEnd, font: env.fonts.font(size, weight: .semibold),
                           color: b.level == 6 ? env.palette.secondaryText : env.palette.text, align: b.align, lineHeight: 1.25)
            let box = TextBox(attributed: a, origin: CGPoint(x: bx, y: 0), width: bw, start: Int(b.textStart),
                              end: Int(b.textEnd), text: env.doc.text, lineGap: m.lineGap(size, 1.25))
            out.boxes.append(box)
            y = box.rect.maxY
            if b.level <= 2 {
                y += m.body * 0.45
                out.decos.append(PlacedDeco(minY: y, maxY: y + 1, deco: .line(CGRect(x: bx, y: y, width: bw, height: 1), .border)))
                y += 1
            }
        case .code:
            let a = code(env, b)
            let box = TextBox(attributed: a, origin: CGPoint(x: bx + m.codePad, y: m.codePad), width: bw - 2 * m.codePad,
                              start: Int(b.textStart), end: Int(b.textEnd), text: env.doc.text, lineGap: m.lineGap(m.codeSize, 1.45))
            let bg = CGRect(x: bx, y: 0, width: bw, height: box.rect.height + 2 * m.codePad)
            if b.output {   // notebook output: a rule at the left, no fill (code cells keep theirs)
                out.decos.append(PlacedDeco(minY: 0, maxY: bg.maxY, deco: .fill(CGRect(x: bx, y: 0, width: 2, height: bg.height), .border, 1)))
            } else {
                out.decos.append(PlacedDeco(minY: 0, maxY: bg.maxY, deco: .fill(bg, .blockBackground, 6)))
            }
            out.boxes.append(box)
            y = bg.maxY
        case .rule:
            y = m.body * 0.4
            out.decos.append(PlacedDeco(minY: y, maxY: y + 2, deco: .fill(CGRect(x: bx, y: y, width: bw, height: 2), .border, 1)))
            y += 2 + m.body * 0.4
        case .table:
            y = table(env, Int(b.table), x: bx, width: bw, into: &out)
        }
        if b.marker != .none {
            if let first = out.boxes.first, let base = first.baselines.first {
                out.firstBaseline = base
            } else {
                out.firstBaseline = m.body   // empty item: marker on its own line
                y = max(y, m.body * 1.4)
            }
        }
        out.height = y
        return out
    }

    /// Rich text for `[start, end)` of the rendered text with the given runs applied.
    static func inline(_ env: LayoutEnv, _ start: Int32, _ end: Int32, runs: Range<Int32>, font base: NSFont, color: CGColor,
                       align: MDAlign, lineHeight: CGFloat = 1.5) -> NSAttributedString {
        let doc = env.doc
        let s = doc.text.string(Int(start), Int(end))
        let ps = NSMutableParagraphStyle()
        ps.lineHeightMultiple = lineHeight
        ps.alignment = align == .center ? .center : align == .right ? .right : .natural
        let a = NSMutableAttributedString(string: s, attributes: [.font: base, .foregroundColor: color, .paragraphStyle: ps])
        if runs.isEmpty { return a }
        let map = Utf16Map(doc.text, Int(start), Int(end))
        let size = base.pointSize
        let baseBold = (base.fontDescriptor.symbolicTraits.contains(.bold))
        for ri in runs {
            let r = doc.runs[Int(ri)]
            let range = NSRange(location: map[Int(r.start)], length: map[Int(r.end)] - map[Int(r.start)])
            if range.length <= 0 { continue }
            let st = r.style
            if st.contains(.image) {
                let sz = Int(r.ref) < env.imageSizes.count ? env.imageSizes[Int(r.ref)] : CGSize(width: 16, height: 16)
                a.addAttribute(kCTRunDelegateAttributeName as NSAttributedString.Key, value: runDelegate(width: sz.width, ascent: sz.height), range: range)
                a.addAttribute(MDAttr.image, value: Int(r.ref), range: range)
                a.addAttribute(.foregroundColor, value: CGColor.clear, range: range)
                continue
            }
            var f = base
            if st.contains(.code) || st.contains(.kbd) {
                f = env.fonts.font((size * 0.88).rounded() + 0.5, weight: st.contains(.strong) ? .semibold : .regular, mono: true)
                a.addAttribute(st.contains(.kbd) ? MDAttr.kbd : MDAttr.inlineCode, value: true, range: range)
            } else if st.contains(.strong) || st.contains(.emphasis) || st.contains(.superscript) || st.contains(.subscriptStyle) {
                let sz = st.contains(.superscript) || st.contains(.subscriptStyle) ? size * 0.75 : size
                f = env.fonts.font(sz, weight: st.contains(.strong) || baseBold ? .semibold : .regular, italic: st.contains(.emphasis))
            }
            a.addAttribute(.font, value: f, range: range)
            // Baseline offsets are negated: we draw in a flipped context (text matrix y = -1),
            // where Core Text's "up" offset lands below the baseline.
            if st.contains(.superscript) { a.addAttribute(ctBaselineOffset, value: -size * 0.38, range: range) }
            if st.contains(.subscriptStyle) { a.addAttribute(ctBaselineOffset, value: size * 0.18, range: range) }
            if st.contains(.strike) { a.addAttribute(MDAttr.strike, value: true, range: range) }
            if st.contains(.link) {
                a.addAttribute(.foregroundColor, value: env.palette.link, range: range)
                a.addAttribute(MDAttr.link, value: Int(r.ref), range: range)
            }
        }
        return a
    }

    /// Code block: monospaced, syntax colored with the same lexers as code previews.
    static func code(_ env: LayoutEnv, _ b: MDBlock) -> NSAttributedString {
        let doc = env.doc
        let m = env.m
        let s = doc.text.string(Int(b.textStart), Int(b.textEnd))
        let f = env.fonts.font(m.codeSize, mono: true)
        let bold = env.fonts.font(m.codeSize, weight: .semibold, mono: true)
        let ps = NSMutableParagraphStyle()
        ps.lineHeightMultiple = 1.45
        ps.defaultTabInterval = 4 * CTFontGetAdvanceForGlyphMonospaced(f)
        ps.tabStops = []
        let a = NSMutableAttributedString(string: s, attributes: [.font: f, .foregroundColor: env.palette.text, .paragraphStyle: ps])
        if b.language != .plain && b.textEnd > b.textStart {
            let tokens = TokenStream(expectedBytes: Int(b.textEnd - b.textStart))
            // Lex in place: the byte after the block is "\n", which ends every token cleanly.
            b.language.lex(doc.text.base, Int(b.textStart), Int(b.textEnd), tokens)
            let map = Utf16Map(doc.text, Int(b.textStart), Int(b.textEnd))
            var k = tokens.first(after: Int(b.textStart))
            while k < tokens.count && tokens.start(k) < Int(b.textEnd) {
                let kind = tokens.kinds[k]
                if kind != 0 {
                    let ts = max(tokens.start(k), Int(b.textStart)), te = min(tokens.end(k), Int(b.textEnd))
                    let range = NSRange(location: map[ts], length: map[te] - map[ts])
                    a.addAttribute(.foregroundColor, value: env.palette.tokenColors[Int(kind)], range: range)
                    if env.palette.tokenBold[Int(kind)] { a.addAttribute(.font, value: bold, range: range) }
                }
                k += 1
            }
        }
        return a
    }

    static func runDelegate(width: CGFloat, ascent: CGFloat) -> CTRunDelegate {
        let p = UnsafeMutablePointer<CGSize>.allocate(capacity: 1)
        p.initialize(to: CGSize(width: width, height: ascent))
        var cb = CTRunDelegateCallbacks(version: kCTRunDelegateVersion1, dealloc: { $0.deallocate() },
                                        getAscent: { $0.assumingMemoryBound(to: CGSize.self).pointee.height },
                                        getDescent: { _ in 0 },
                                        getWidth: { $0.assumingMemoryBound(to: CGSize.self).pointee.width })
        return CTRunDelegateCreate(&cb, p)!
    }

    /// GFM table: natural column widths if they fit, else wide columns shrink (min 80pt).
    static func table(_ env: LayoutEnv, _ ti: Int, x: CGFloat, width: CGFloat, into out: inout BlockLayout) -> CGFloat {
        let t = env.doc.tables[ti]
        let m = env.m
        let cols = t.columns, rows = t.rows
        if cols == 0 || rows == 0 { return 0 }
        let padH: CGFloat = 12, padV: CGFloat = 6
        let headerFont = env.fonts.font(m.body, weight: .semibold), cellFont = env.fonts.font(m.body)
        var strings: [NSAttributedString] = []
        strings.reserveCapacity(t.cells.count)
        var natural = [CGFloat](repeating: 40, count: cols)
        for (i, c) in t.cells.enumerated() {
            let a = inline(env, c.textStart, c.textEnd, runs: c.runStart..<c.runEnd, font: i < cols ? headerFont : cellFont,
                           color: env.palette.text, align: t.aligns[i % cols], lineHeight: 1.35)
            strings.append(a)
            let line = CTLineCreateWithAttributedString(a)
            natural[i % cols] = max(natural[i % cols], CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)) + 2 * padH + 1)
        }
        var widths = natural
        let total = natural.reduce(0, +)
        if total > width {
            let minW: CGFloat = 80
            let flexible = natural.map { max(0, $0 - minW) }.reduce(0, +)
            let excess = total - width
            for c in 0..<cols where natural[c] > minW {
                widths[c] = max(minW, (natural[c] - excess * (natural[c] - minW) / max(1, flexible)).rounded(.down))
            }
        }
        let tableW = widths.reduce(0, +)
        out.right = max(out.right, x + tableW)
        var rowY: CGFloat = 0
        for r in 0..<rows {
            var cx = x
            var rowH: CGFloat = 0
            for c in 0..<cols {
                let i = r * cols + c
                let cell = t.cells[i]
                let box = TextBox(attributed: strings[i], origin: CGPoint(x: cx + padH, y: rowY + padV),
                                  width: widths[c] - 2 * padH, start: Int(cell.textStart), end: Int(cell.textEnd),
                                  text: env.doc.text, lineGap: m.lineGap(m.body, 1.35))
                out.boxes.append(box)
                rowH = max(rowH, box.rect.height + 2 * padV)
                cx += widths[c]
            }
            let rowRect = CGRect(x: x, y: rowY, width: tableW, height: rowH)
            if r % 2 == 0 { out.decos.append(PlacedDeco(minY: rowRect.minY, maxY: rowRect.maxY, deco: .fill(rowRect, .blockBackground, 0))) }
            out.decos.append(PlacedDeco(minY: rowRect.maxY - 0.5, maxY: rowRect.maxY + 0.5,
                                        deco: .line(CGRect(x: x, y: rowRect.maxY - 0.5, width: tableW, height: 1), .border)))
            var vx = x
            for c in 0...cols {
                out.decos.append(PlacedDeco(minY: rowRect.minY, maxY: rowRect.maxY,
                                            deco: .line(CGRect(x: vx - 0.5, y: rowRect.minY, width: 1, height: rowH), .border)))
                if c < cols { vx += widths[c] }
            }
            rowY += rowH
        }
        out.decos.append(PlacedDeco(minY: -0.5, maxY: 0.5, deco: .line(CGRect(x: x, y: -0.5, width: tableW, height: 1), .border)))
        return rowY
    }
}

/// Advance of a monospaced font (used for tab stops).
func CTFontGetAdvanceForGlyphMonospaced(_ f: NSFont) -> CGFloat {
    var g = CGGlyph(0)
    var ch = UniChar(0x20)
    CTFontGetGlyphsForCharacters(f as CTFont, &ch, &g, 1)
    var adv = CGSize.zero
    CTFontGetAdvancesForGlyphs(f as CTFont, .horizontal, &g, &adv, 1)
    return adv.width
}
