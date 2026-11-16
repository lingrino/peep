import AppKit
import CoreText

/// Colors for one appearance. Token colors are indexed by `TokenKind.rawValue`.
/// Palettes follow Xcode's default light/dark themes so code looks at home on macOS.
public final class Palette: @unchecked Sendable {
    public let isDark: Bool
    public let background: CGColor
    public let text: CGColor
    public let secondaryText: CGColor     // gutter numbers, muted UI
    public let selection: CGColor
    public let findMatch: CGColor
    public let findCurrent: CGColor
    public let blockBackground: CGColor   // markdown code blocks, inline code, table header
    public let border: CGColor            // table borders, rules, quote bars
    public let link: CGColor
    /// GitHub alert accents, indexed by `MDAlert.rawValue` (0 unused).
    public let alert: [CGColor]
    /// Per-TokenKind foreground and whether to use the bold font.
    public let tokenColors: [CGColor]
    public let tokenBold: [Bool]

    init(dark: Bool) {
        isDark = dark
        func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
            CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: a)
        }
        var colors = [CGColor](repeating: c(0), count: TokenKind.allCases.count)
        var bold = [Bool](repeating: false, count: TokenKind.allCases.count)
        func set(_ k: TokenKind, _ hex: UInt32, bold b: Bool = false) {
            colors[Int(k.rawValue)] = c(hex); bold[Int(k.rawValue)] = b
        }
        if dark {
            background = c(0x1F1F24); text = c(0xDFDFE0); secondaryText = c(0x6C6C75)
            selection = c(0x3F638B); findMatch = c(0x8A7A22, 0.55); findCurrent = c(0xD4A52A)
            blockBackground = c(0x2A2A31); border = c(0x3A3A42); link = c(0x5E9BFF)
            alert = [border, c(0x4493F8), c(0x3FB950), c(0xAB7DF8), c(0xD29922), c(0xF85149)]
            set(.plain, 0xDFDFE0); set(.comment, 0x7F8C98); set(.keyword, 0xFC5FA3, bold: true)
            set(.type, 0x5DD8FF); set(.function, 0x67B7A4); set(.string, 0xFC6A5D); set(.escape, 0xD0BF69)
            set(.number, 0xD0BF69); set(.constant, 0xFC5FA3); set(.builtin, 0xFC5FA3, bold: true)
            set(.variable, 0x41A1C0); set(.property, 0xA167E6); set(.attribute, 0xBF8555)
            set(.preprocessor, 0xFD8F3F); set(.operatorKind, 0xDFDFE0); set(.punctuation, 0xDFDFE0)
            set(.tag, 0xFC5FA3); set(.attrName, 0xBF8555); set(.regex, 0xFC6A5D)
            set(.heading, 0x5DD8FF, bold: true); set(.emphasis, 0xDFDFE0); set(.strong, 0xDFDFE0, bold: true)
            set(.link, 0x5E9BFF); set(.code, 0xFC6A5D); set(.listMarker, 0xFC5FA3); set(.quote, 0x7F8C98)
            set(.inserted, 0x7EE787); set(.deleted, 0xFF7B72); set(.meta, 0xA167E6); set(.label, 0xBF8555)
            set(.invalid, 0xFF453A)
        } else {
            background = c(0xFFFFFF); text = c(0x1F1F24); secondaryText = c(0xA3A3AB)
            selection = c(0xB4D7FF); findMatch = c(0xFFE873, 0.6); findCurrent = c(0xFFC531)
            blockBackground = c(0xF5F5F7); border = c(0xDCDCE0); link = c(0x0B63CE)
            alert = [border, c(0x0969DA), c(0x1A7F37), c(0x8250DF), c(0x9A6700), c(0xD1242F)]
            set(.plain, 0x1F1F24); set(.comment, 0x5D6C79); set(.keyword, 0xAD3DA4, bold: true)
            set(.type, 0x0B4F79); set(.function, 0x326D74); set(.string, 0xC41A16); set(.escape, 0x1C00CF)
            set(.number, 0x1C00CF); set(.constant, 0xAD3DA4); set(.builtin, 0xAD3DA4, bold: true)
            set(.variable, 0x0F68A0); set(.property, 0x6C36A9); set(.attribute, 0x815F03)
            set(.preprocessor, 0x78492A); set(.operatorKind, 0x1F1F24); set(.punctuation, 0x1F1F24)
            set(.tag, 0xAD3DA4); set(.attrName, 0x815F03); set(.regex, 0xC41A16)
            set(.heading, 0x0B4F79, bold: true); set(.emphasis, 0x1F1F24); set(.strong, 0x1F1F24, bold: true)
            set(.link, 0x0B63CE); set(.code, 0xC41A16); set(.listMarker, 0xAD3DA4); set(.quote, 0x5D6C79)
            set(.inserted, 0x1A7F37); set(.deleted, 0xCF222E); set(.meta, 0x6C36A9); set(.label, 0x815F03)
            set(.invalid, 0xFF3B30)
        }
        tokenColors = colors
        tokenBold = bold
    }

    public static let light = Palette(dark: false)
    public static let dark = Palette(dark: true)

    @MainActor public static func current(for view: NSView) -> Palette {
        view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    }
}

/// A monospaced font with precomputed metrics and an ASCII glyph table, so ASCII lines can be
/// drawn with `CTFontDrawGlyphs` without any shaping.
public final class MonoFont: @unchecked Sendable {
    public let font: CTFont
    public let ascent: CGFloat
    public let descent: CGFloat
    public let advance: CGFloat
    /// Glyph for each byte 0x00...0x7F (control characters map to the space glyph).
    public let glyphs: UnsafeMutablePointer<CGGlyph>

    public init(_ font: CTFont) {
        self.font = font
        ascent = CTFontGetAscent(font)
        descent = CTFontGetDescent(font)
        glyphs = .allocate(capacity: 128)
        var chars = [UniChar](repeating: 0x20, count: 128)
        for i in 0x20..<0x7F { chars[i] = UniChar(i) }
        _ = CTFontGetGlyphsForCharacters(font, chars, glyphs, 128)
        var g = glyphs[0x4D]   // 'M'
        var adv = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &g, &adv, 1)
        advance = adv.width
    }

    deinit { glyphs.deallocate() }
}

/// Fonts and line metrics shared by the code and markdown renderers.
public final class Typography: @unchecked Sendable {
    public let codeSize: CGFloat
    public let mono: MonoFont
    public let monoBold: MonoFont
    public let lineHeight: CGFloat
    /// Distance from a line box's top to its baseline.
    public let baselineOffset: CGFloat

    public init(codeSize: CGFloat = 12) {
        self.codeSize = codeSize
        let regular = NSFont.monospacedSystemFont(ofSize: codeSize, weight: .regular) as CTFont
        let bold = NSFont.monospacedSystemFont(ofSize: codeSize, weight: .semibold) as CTFont
        mono = MonoFont(regular)
        monoBold = MonoFont(bold)
        // ~1.42x the font size, snapped to half points (whole device pixels at 2x).
        lineHeight = (codeSize * 1.42 * 2).rounded() / 2
        let glyphBox = mono.ascent + mono.descent
        baselineOffset = ((lineHeight - glyphBox) / 2 + mono.ascent).rounded(.toNearestOrAwayFromZero)
    }

    public static let standard = Typography()
}
