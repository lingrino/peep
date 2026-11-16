let textTests: [Test] = [
    Test("lines: basic") {
        let b = TextBuffer("a\nbc\r\n\ndef")
        let li = LineIndex(b)
        expectEqual(li.count, 4)
        expectEqual(b.string(li.start(0), li.end(0)), "a")
        expectEqual(b.string(li.start(1), li.end(1)), "bc")
        expectEqual(b.string(li.start(2), li.end(2)), "")
        expectEqual(b.string(li.start(3), li.end(3)), "def")
    },
    Test("lines: trailing newline adds no line") {
        expectEqual(LineIndex(TextBuffer("a\nb\n")).count, 2)
        expectEqual(LineIndex(TextBuffer("")).count, 1)
        expectEqual(LineIndex(TextBuffer("\n")).count, 1)
        expectEqual(LineIndex(TextBuffer("\n\n")).count, 2)
    },
    Test("lines: long input crosses SIMD blocks") {
        var s = ""
        for i in 0..<1000 { s += String(repeating: "x", count: i % 97) + "\n" }
        let b = TextBuffer(s)
        let li = LineIndex(b)
        expectEqual(li.count, 1000)
        for i in 0..<1000 { expectEqual(li.end(i) - li.start(i), i % 97) }
        expectEqual(li.maxColumns, 96)
        expectEqual(li.line(containing: 0), 0)
        expectEqual(li.line(containing: li.start(500)), 500)
        expectEqual(li.line(containing: li.start(500) - 1), 499)
    },
    Test("columns: tabs and utf8") {
        let b = TextBuffer("\tab\té\u{1F600}x")
        let n = LineIndex.columns(b.base, 0, b.count)
        // tab->4, a b ->6, tab->8, é ->9, emoji ->10, x ->11
        expectEqual(n, 11)
    },
    Test("decode: utf8 passthrough is zero-copy") {
        let b = TextBuffer("héllo")
        guard case .text(let t, let enc, let rep) = Decoder.decode(b) else { return expect(false) }
        expect(t === b)
        expectEqual(enc, .utf8)
        expect(!rep)
    },
    Test("decode: BOMs") {
        let u8 = ([0xEF, 0xBB, 0xBF, 0x41] as [UInt8]).withUnsafeBytes { TextBuffer(copying: $0) }
        if case .text(let t, .utf8BOM, _) = Decoder.decode(u8) { expectEqual(t.string(0, t.count), "A") } else { expect(false) }
        let le: [UInt8] = [0xFF, 0xFE, 0x41, 0x00, 0xE9, 0x00, 0x3D, 0xD8, 0x00, 0xDE]
        let b = le.withUnsafeBytes { TextBuffer(copying: $0) }
        if case .text(let t, .utf16LE, _) = Decoder.decode(b) { expectEqual(t.string(0, t.count), "Aé\u{1F600}") } else { expect(false) }
        let be: [UInt8] = [0xFE, 0xFF, 0x00, 0x41, 0x00, 0x42]
        let b2 = be.withUnsafeBytes { TextBuffer(copying: $0) }
        if case .text(let t, .utf16BE, _) = Decoder.decode(b2) { expectEqual(t.string(0, t.count), "AB") } else { expect(false) }
    },
    Test("decode: binary and bomless utf16") {
        let bin: [UInt8] = [0x7F, 0x45, 0x4C, 0x46, 0x00, 0x01, 0x02, 0x00, 0xFF, 0x13]
        if case .binary = Decoder.decode(bin.withUnsafeBytes { TextBuffer(copying: $0) }) {} else { expect(false) }
        var le: [UInt8] = []
        for c in "hello world, this is utf16".utf16 { le += [UInt8(c & 0xFF), UInt8(c >> 8)] }
        if case .text(let t, .utf16LE, _) = Decoder.decode(le.withUnsafeBytes { TextBuffer(copying: $0) }) {
            expectEqual(t.string(0, t.count), "hello world, this is utf16")
        } else { expect(false) }
    },
    Test("decode: windows-1252 fallback") {
        let w: [UInt8] = Array("caf".utf8) + [0xE9, 0x20, 0x93, 0x71, 0x94] + Array(" na".utf8) + [0xEF, 0x76, 0x65]
        if case .text(let t, .windows1252, _) = Decoder.decode(w.withUnsafeBytes { TextBuffer(copying: $0) }) {
            expectEqual(t.string(0, t.count), "café \u{201C}q\u{201D} naïve")
        } else { expect(false) }
    },
    Test("decode: mostly-utf8 with one bad byte is repaired") {
        var bytes = Array(String(repeating: "ok é ", count: 2000).utf8)
        bytes[5000] = 0xFF
        if case .text(let t, .utf8, true) = Decoder.decode(bytes.withUnsafeBytes { TextBuffer(copying: $0) }) {
            expect(t.string(0, t.count).contains("\u{FFFD}"))
        } else { expect(false) }
    },
    Test("decode: utf8 validation edge cases") {
        func valid(_ b: [UInt8]) -> Bool {
            let t = b.withUnsafeBytes { TextBuffer(copying: $0) }
            if case .valid = Decoder.validateUTF8(t.base, t.count, truncated: false) { return true }
            return false
        }
        expect(valid([0xE2, 0x82, 0xAC]))
        expect(!valid([0xC0, 0x80]))           // overlong
        expect(!valid([0xED, 0xA0, 0x80]))     // surrogate
        expect(!valid([0xF4, 0x90, 0x80, 0x80])) // > U+10FFFF
        expect(!valid([0xE2, 0x82]))           // truncated
        expect(valid(Array(String(repeating: "aé€😀", count: 100).utf8)))
    },
]
