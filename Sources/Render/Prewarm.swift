import AppKit
import CoreText

/// One-time process warm-up, run on a background thread from the extension's `main` while
/// dyld, AppKit and Quick Look's view-service handshake run on the main thread (~180 ms
/// before our first `preparePreviewOfFile`). Without it the first preview of a fresh process
/// paid ~8 ms for first use of fonts, Core Text and lookup tables (9.3 ms vs ~1 ms warm).
/// Everything touched here is thread-safe and built once (static lets, fonts, Core Text's
/// own font caches); nothing is retained beyond what those already keep.
public enum Prewarm {
    public static func run() {
        // Code: mono fonts + ASCII glyph tables, language tables, a few lexers' keyword tables.
        let typo = Typography.standard
        shape("let value = compute(1)", typo.mono.font)
        shape("let value = compute(1)", typo.monoBold.font)
        _ = Language.packedNameMap
        let sample = TextBuffer("import x\nfunc f() -> Int { return 1 } // c\nlet s = \"str\"\n")
        for lang: Language in [.swift, .python, .javascript, .typescript, .rust, .go, .c, .json, .shell, .yaml] {
            lang.lex(sample.base, 0, sample.count, TokenStream(expectedBytes: sample.count))
        }
        // Markdown: parser statics, and Core Text shaping in the body/heading/code fonts.
        _ = MarkdownParser.parse(TextBuffer("# T\n\nA *b* **c** `d` [e](f) &amp; :tada:[^1]\n\n- g\n\n| h |\n|---|\n| i |\n\n<div align=\"center\"><img src=\"x\"></div>\n\n> [!NOTE]\n> j\n\n[^1]: k\n"))
        // (The main-thread font book's fonts: made from the font files, see FontBook.)
        let m = MDMetrics()
        let book = FontBook.main
        for (size, weight) in [(m.body, NSFont.Weight.regular), (m.body, .semibold), (m.headingSize(1), .semibold),
                               (m.headingSize(2), .semibold), (m.headingSize(3), .semibold)] {
            shape("The quick brown fox jumps over 0123", book.font(size, weight: weight))
        }
        shape("code", book.font(m.codeSize, mono: true))
        shape("italic", book.font(m.body, italic: true))
    }

    private static func shape(_ s: String, _ font: CTFont) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: font]))
        _ = CTLineGetTypographicBounds(line, nil, nil, nil)
    }
}
