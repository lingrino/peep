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
            if case .valid = Decoder.validateUTF8(t.base, t.count) { return true }
            return false
        }
        expect(valid([0xE2, 0x82, 0xAC]))
        expect(!valid([0xC0, 0x80]))           // overlong
        expect(!valid([0xED, 0xA0, 0x80]))     // surrogate
        expect(!valid([0xF4, 0x90, 0x80, 0x80])) // > U+10FFFF
        expect(!valid([0xE2, 0x82]))           // truncated
        expect(valid(Array(String(repeating: "aé€😀", count: 100).utf8)))
    },
    Test("decode: loads cut short end and start between characters") {
        func end(_ b: [UInt8]) -> Int { b.withUnsafeBufferPointer { Decoder.completeEnd($0.baseAddress!, b.count) } }
        expectEqual(end([0x61, 0xE2, 0x82, 0xAC]), 4)
        expectEqual(end([0x61, 0xE2, 0x82]), 1)
        expectEqual(end([0x61, 0xE2]), 1)
        expectEqual(end([0xF0, 0x9F, 0x98]), 0)
        expectEqual(end([0xF0, 0x9F, 0x98, 0x80]), 4)
        expectEqual(end([0x61, 0xC3]), 1)
        expectEqual(end([0x80, 0x80, 0x80, 0x80]), 4)   // not a cut character: left to validation
        func lead(_ b: [UInt8]) -> Int { b.withUnsafeBufferPointer { Decoder.continuationBytes($0.baseAddress!, b.count) } }
        expectEqual(lead([0x82, 0xAC, 0x61]), 2)
        expectEqual(lead([0x61, 0x80]), 0)
        expectEqual(lead([0x80, 0x80, 0x80, 0x80]), 3)
        // An incomplete sequence at the end is invalid (it passed as valid in truncated loads,
        // and the renderer crashed on it).
        let t = ([0x61, 0xE2, 0x82] as [UInt8]).withUnsafeBytes { TextBuffer(copying: $0) }
        if case .valid = Decoder.validateUTF8(t.base, t.count) { expect(false) }
        // FileLoader: limits inside a character, tail loads starting inside one (no newline).
        let path = tempFile(Array(String(repeating: "€", count: 3000).utf8), suffix: ".log")
        defer { removeFile(path) }
        for limit in [1000, 1001, 1002, 4000] {
            for tail in [false, true] {
                let f = try! FileLoader.load(path: path, limit: limit, tail: tail)
                expect(f.raw.count >= limit - 2 && f.raw.count % 3 == 0, "\(limit) \(tail): \(f.raw.count)")
                expect(f.truncated)
                guard case .text(let d, .utf8, false) = Decoder.decode(f.raw) else { expect(false); continue }
                expect(d === f.raw)   // valid as loaded: no repair copy
            }
        }
    },
]

let searchTests: [Test] = [
    Test("search: basics and case folding") {
        let t = TextBuffer("Hello hello HELLO hel\nhelLo")
        func f(_ q: String, _ cs: Bool) -> [Int] {
            let m = Search.find(t, Array(q.utf8), caseSensitive: cs)
            return (0..<m.count).map { m.start($0) }
        }
        expectEqual(f("hello", false), [0, 6, 12, 22])
        expectEqual(f("hello", true), [6])
        expectEqual(f("Hello", true), [0])
        expectEqual(f("l", true).count, 6)
        expectEqual(f("x", false), [])
        expect(Search.isCaseSensitive(Array("Hi".utf8)))
        expect(!Search.isCaseSensitive(Array("hi".utf8)))
    },
    Test("search: non-overlapping, block boundaries, long needles") {
        let t = TextBuffer(String(repeating: "a", count: 100))
        let m = Search.find(t, Array("aa".utf8), caseSensitive: true)
        expectEqual(m.count, 50)
        var s = String(repeating: "x", count: 1000)
        s += "The Quick Brown Fox Jumps Over"
        s += String(repeating: "y", count: 37)
        let t2 = TextBuffer(s)
        let m2 = Search.find(t2, Array("the quick brown fox jumps over".utf8), caseSensitive: false)
        expectEqual(m2.count, 1)
        expectEqual(m2.start(0), 1000)
        // Match touching the very end of the text.
        let m3 = Search.find(t2, Array("yyy".utf8), caseSensitive: true)
        expectEqual(m3.end(m3.count - 1) <= t2.count, true)
        expectEqual(m3.count, 12)
    },
    Test("search: matches brute force on random text") {
        var rng = SystemRandomNumberGenerator()
        let alphabet = Array("abAB \n€x".utf8)
        for _ in 0..<200 {
            let n = Int.random(in: 0..<300, using: &rng)
            let bytes = (0..<n).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &rng)] }
            let q = (0..<Int.random(in: 1...4, using: &rng)).map { _ in alphabet[Int.random(in: 0..<4, using: &rng)] }
            let t = bytes.withUnsafeBytes { TextBuffer(copying: $0) }
            for cs in [true, false] {
                let m = Search.find(t, q, caseSensitive: cs)
                var want: [Int] = []
                var i = 0
                func eq(_ a: UInt8, _ b: UInt8) -> Bool {
                    cs ? a == b : (a >= 65 && a <= 90 ? a | 32 : a) == (b >= 65 && b <= 90 ? b | 32 : b)
                }
                while i + q.count <= n {
                    if (0..<q.count).allSatisfy({ eq(bytes[i + $0], q[$0]) }) { want.append(i); i += q.count } else { i += 1 }
                }
                expectEqual((0..<m.count).map { m.start($0) }, want)
            }
        }
    },
    Test("json: minified input is re-indented") {
        func f(_ s: String) -> String { let t = JSONFormatter.format(TextBuffer(s)); return t.string(0, t.count) }
        expectEqual(f(#"{"a":[1,2,{}],"b":"x,{\"y"}"#), "{\n  \"a\": [\n    1,\n    2,\n    {}\n  ],\n  \"b\": \"x,{\\\"y\"\n}\n")
        expectEqual(f("[ ]"), "[]\n")
        expectEqual(f(#"{"a":1}{"b":2}"#), "{\n  \"a\": 1\n}\n{\n  \"b\": 2\n}\n")
        expectEqual(f("]]}{ garbage, \"unterminated"), "]\n]\n}\n{\n  garbage,\n  \"unterminated\n")
        let deep = String(repeating: "[", count: 200) + String(repeating: "]", count: 200)
        expect(f(deep).utf8.count < 40_000)   // indentation is capped (uncapped: ~80 KB)
        expect(JSONFormatter.looksMinified(TextBuffer(String(repeating: #"{"k":"value"},"#, count: 100))))
        expect(!JSONFormatter.looksMinified(TextBuffer(String(repeating: "{\n  \"k\": 1\n},\n", count: 100))))
    },
    Test("json: output limit, stop note, cancellation") {
        // Brackets grow 82x: stopped near the limit, at a token boundary.
        let deep = TextBuffer(String(repeating: "[", count: 100_000))
        let f = JSONFormatter.format(deep, count: deep.count, outputLimit: 1_000_000, stopNote: "stopped")
        expect(f.consumed >= 12_000 && f.consumed < deep.count && f.consumed % JSONFormatter.slice == 0)
        expect(f.noteStart >= 1_000_000 && f.noteStart < 1_000_000 + 82 * JSONFormatter.slice + 100)   // over by < one slice
        expectEqual(f.text.string(f.noteStart, f.text.count), "stopped\n")
        let all = JSONFormatter.format(deep)   // what was formatted is the full output's beginning
        expectEqual(all.string(0, f.noteStart - 1), f.text.string(0, f.noteStart - 1))
        // Under the limit: everything, no note.
        let small = TextBuffer(#"{"a":[1,2],"b":"x"}"#)
        let g = JSONFormatter.format(small, count: small.count, outputLimit: 1 << 20, stopNote: "x")
        expectEqual(g.consumed, small.count)
        expectEqual(g.noteStart, g.text.count)
        expectEqual(g.text.string(0, g.text.count), JSONFormatter.format(small).string(0, JSONFormatter.format(small).count))
        // Cancelled: stops at the first poll (every `checkInterval` bytes of output), no note.
        nonisolated(unsafe) var polls = 0
        let big = TextBuffer(String(repeating: "[1,2,3],", count: 400_000))
        let h = JSONFormatter.format(big, count: big.count, outputLimit: .max, stopNote: "x", cancelled: { polls += 1; return true })
        expectEqual(polls, 1)
        expect(h.consumed < big.count)
        expectEqual(h.noteStart, h.text.count)
        expect(h.text.count >= JSONFormatter.checkInterval && h.text.count < JSONFormatter.checkInterval + 82 * JSONFormatter.slice)
    },
]
