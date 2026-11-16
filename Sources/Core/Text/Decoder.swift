// Turns raw file bytes into valid UTF-8 (or classifies the file as binary).
//
// Fast path: valid UTF-8 without BOM is returned as-is (no copy). Everything else is
// transcoded once into a new TextBuffer.

public enum TextEncoding: UInt8, Sendable {
    case utf8, utf8BOM, utf16LE, utf16BE, utf32LE, utf32BE, windows1252
}

public enum DecodeResult: Sendable {
    case text(TextBuffer, TextEncoding, repaired: Bool)
    case binary
}

public enum Decoder {
    /// How much of the head of the file to inspect for NUL bytes when sniffing binaries.
    static let sniffBytes = 64 * 1024

    public static func decode(_ raw: TextBuffer, truncated: Bool = false) -> DecodeResult {
        let p = UnsafePointer(raw.base)
        let n = raw.count

        // Byte-order marks.
        if n >= 4 && p[0] == 0xFF && p[1] == 0xFE && p[2] == 0 && p[3] == 0 {
            return .text(transcodeUTF32(p + 4, n - 4, bigEndian: false), .utf32LE, repaired: false)
        }
        if n >= 4 && p[0] == 0 && p[1] == 0 && p[2] == 0xFE && p[3] == 0xFF {
            return .text(transcodeUTF32(p + 4, n - 4, bigEndian: true), .utf32BE, repaired: false)
        }
        if n >= 2 && p[0] == 0xFF && p[1] == 0xFE {
            return .text(transcodeUTF16(p + 2, n - 2, bigEndian: false), .utf16LE, repaired: false)
        }
        if n >= 2 && p[0] == 0xFE && p[1] == 0xFF {
            return .text(transcodeUTF16(p + 2, n - 2, bigEndian: true), .utf16BE, repaired: false)
        }
        if n >= 3 && p[0] == 0xEF && p[1] == 0xBB && p[2] == 0xBF {
            let body = UnsafeRawBufferPointer(start: p + 3, count: n - 3)
            switch validateUTF8(p + 3, n - 3, truncated: truncated) {
            case .valid: return .text(TextBuffer(copying: body), .utf8BOM, repaired: false)
            case .invalid: return .text(repairUTF8(p + 3, n - 3), .utf8BOM, repaired: true)
            }
        }

        // NUL bytes: binary, unless it looks like BOM-less UTF-16.
        let head = min(n, sniffBytes)
        if memchr(p, 0, head) != nil {
            if let be = looksLikeUTF16(p, head) {
                return .text(transcodeUTF16(p, n, bigEndian: be), be ? .utf16BE : .utf16LE, repaired: false)
            }
            return .binary
        }

        switch validateUTF8(p, n, truncated: truncated) {
        case .valid:
            return .text(raw, .utf8, repaired: false)
        case .invalid(let bad):
            // A handful of bad sequences in a big file: it's UTF-8 with damage. Otherwise it
            // is almost certainly a legacy single-byte encoding.
            if bad * 1000 < n && bad < 64 {
                return .text(repairUTF8(p, n), .utf8, repaired: true)
            }
            return .text(transcodeWindows1252(p, n), .windows1252, repaired: false)
        }
    }

    enum Validity { case valid, invalid(Int) }

    /// Validates UTF-8. Counts invalid sequences (capped) so callers can pick a fallback.
    /// When `truncated`, an incomplete sequence at the very end is not an error.
    static func validateUTF8(_ p: UnsafePointer<UInt8>, _ n: Int, truncated: Bool) -> Validity {
        var i = 0
        var bad = 0
        while i < n {
            // ASCII fast path, 64 then 16 bytes at a time. Padding makes over-reads safe;
            // lanes past `n` are zero (ASCII) so they never cause a false negative.
            if i &+ 64 <= n {
                let v = load16(p + i) | load16(p + i + 16) | load16(p + i + 32) | load16(p + i + 48)
                if highBitNibbles(v) == 0 { i &+= 64; continue }
            }
            let m = highBitNibbles(load16(p + i))
            if m == 0 { i &+= 16; continue }
            i &+= m.trailingZeroBitCount >> 2
            if i >= n { break }
            let len = sequenceLength(p + i)
            if len == 0 {
                if truncated && n - i < 4 && isIncompletePrefix(p + i, n - i) { break }
                bad &+= 1
                if bad > 1 << 20 { return .invalid(bad) }
                i &+= 1
            } else {
                i &+= len
            }
        }
        return bad == 0 ? .valid : .invalid(bad)
    }

    /// Length of the valid UTF-8 sequence starting at `s` (which has a non-ASCII lead byte),
    /// or 0 if invalid. Reads up to 3 bytes ahead (padding makes that safe; padding bytes are
    /// 0 which are never valid continuation bytes).
    @inline(__always)
    static func sequenceLength(_ s: UnsafePointer<UInt8>) -> Int {
        let b0 = s[0]
        @inline(__always) func cont(_ b: UInt8) -> Bool { b & 0xC0 == 0x80 }
        if b0 < 0xC2 { return 0 }
        if b0 < 0xE0 { return cont(s[1]) ? 2 : 0 }
        if b0 < 0xF0 {
            let b1 = s[1]
            let ok1 = b0 == 0xE0 ? (b1 >= 0xA0 && b1 <= 0xBF) : b0 == 0xED ? (b1 >= 0x80 && b1 <= 0x9F) : cont(b1)
            return ok1 && cont(s[2]) ? 3 : 0
        }
        if b0 < 0xF5 {
            let b1 = s[1]
            let ok1 = b0 == 0xF0 ? (b1 >= 0x90 && b1 <= 0xBF) : b0 == 0xF4 ? (b1 >= 0x80 && b1 <= 0x8F) : cont(b1)
            return ok1 && cont(s[2]) && cont(s[3]) ? 4 : 0
        }
        return 0
    }

    static func isIncompletePrefix(_ s: UnsafePointer<UInt8>, _ avail: Int) -> Bool {
        let b0 = s[0]
        let need = b0 >= 0xF0 ? 4 : b0 >= 0xE0 ? 3 : b0 >= 0xC2 ? 2 : 0
        if need == 0 || avail >= need { return false }
        for k in 1..<avail where s[k] & 0xC0 != 0x80 { return false }
        return true
    }

    /// Copies UTF-8, replacing each invalid byte with U+FFFD.
    static func repairUTF8(_ p: UnsafePointer<UInt8>, _ n: Int) -> TextBuffer {
        let out = TextBuffer.allocate(n * 3)
        var o = 0
        var i = 0
        while i < n {
            let b = p[i]
            if b < 0x80 { out[o] = b; o &+= 1; i &+= 1; continue }
            let len = sequenceLength(p + i)
            if len == 0 {
                out[o] = 0xEF; out[o + 1] = 0xBF; out[o + 2] = 0xBD
                o &+= 3; i &+= 1
            } else {
                for k in 0..<len { out[o + k] = p[i + k] }
                o &+= len; i &+= len
            }
        }
        return shrink(out, o, allocated: n * 3)
    }

    static func looksLikeUTF16(_ p: UnsafePointer<UInt8>, _ n: Int) -> Bool? {
        guard n >= 4 else { return nil }
        var evenZero = 0, oddZero = 0
        var i = 0
        while i + 1 < n {
            if p[i] == 0 { evenZero &+= 1 }
            if p[i + 1] == 0 { oddZero &+= 1 }
            i &+= 2
        }
        let pairs = n / 2
        // Mostly-ASCII UTF-16: one byte of every pair is zero, the other almost never.
        if oddZero * 10 > pairs * 7 && evenZero * 20 < pairs { return false }   // LE
        if evenZero * 10 > pairs * 7 && oddZero * 20 < pairs { return true }    // BE
        return nil
    }

    static func transcodeUTF16(_ p: UnsafePointer<UInt8>, _ n: Int, bigEndian: Bool) -> TextBuffer {
        let units = n / 2
        let cap = units * 3
        let out = TextBuffer.allocate(cap)
        var o = 0
        var i = 0
        @inline(__always) func unit(_ k: Int) -> UInt32 {
            let a = UInt32(p[2 * k]), b = UInt32(p[2 * k + 1])
            return bigEndian ? (a << 8 | b) : (b << 8 | a)
        }
        while i < units {
            var c = unit(i)
            i &+= 1
            if c >= 0xD800 && c < 0xDC00, i < units {
                let d = unit(i)
                if d >= 0xDC00 && d < 0xE000 {
                    c = 0x10000 + ((c - 0xD800) << 10) + (d - 0xDC00)
                    i &+= 1
                } else { c = 0xFFFD }
            } else if c >= 0xD800 && c < 0xE000 { c = 0xFFFD }
            o &+= encodeScalar(c, out + o)
        }
        return shrink(out, o, allocated: cap)
    }

    static func transcodeUTF32(_ p: UnsafePointer<UInt8>, _ n: Int, bigEndian: Bool) -> TextBuffer {
        let units = n / 4
        let cap = units * 4
        let out = TextBuffer.allocate(cap)
        var o = 0
        for k in 0..<units {
            let b = (UInt32(p[4 * k]), UInt32(p[4 * k + 1]), UInt32(p[4 * k + 2]), UInt32(p[4 * k + 3]))
            var c = bigEndian ? (b.0 << 24 | b.1 << 16 | b.2 << 8 | b.3) : (b.3 << 24 | b.2 << 16 | b.1 << 8 | b.0)
            if c > 0x10FFFF || (c >= 0xD800 && c < 0xE000) { c = 0xFFFD }
            o &+= encodeScalar(c, out + o)
        }
        return shrink(out, o, allocated: cap)
    }

    /// Windows-1252 (a superset of Latin-1 for printable text) to UTF-8.
    static func transcodeWindows1252(_ p: UnsafePointer<UInt8>, _ n: Int) -> TextBuffer {
        // 0x80-0x9F in Windows-1252; 0 marks undefined code points (mapped to U+FFFD).
        let c1: [UInt16] = [
            0x20AC, 0, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0, 0x017D, 0,
            0, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0, 0x017E, 0x0178,
        ]
        let cap = n * 3
        let out = TextBuffer.allocate(cap)
        var o = 0
        for i in 0..<n {
            let b = p[i]
            if b < 0x80 { out[o] = b; o &+= 1; continue }
            var c = UInt32(b)
            if b < 0xA0 { c = UInt32(c1[Int(b) - 0x80]); if c == 0 { c = 0xFFFD } }
            o &+= encodeScalar(c, out + o)
        }
        return shrink(out, o, allocated: cap)
    }

    @inline(__always)
    static func encodeScalar(_ c: UInt32, _ o: UnsafeMutablePointer<UInt8>) -> Int {
        if c < 0x80 { o[0] = UInt8(c); return 1 }
        if c < 0x800 {
            o[0] = UInt8(0xC0 | c >> 6); o[1] = UInt8(0x80 | c & 0x3F); return 2
        }
        if c < 0x10000 {
            o[0] = UInt8(0xE0 | c >> 12); o[1] = UInt8(0x80 | (c >> 6) & 0x3F); o[2] = UInt8(0x80 | c & 0x3F); return 3
        }
        o[0] = UInt8(0xF0 | c >> 18); o[1] = UInt8(0x80 | (c >> 12) & 0x3F)
        o[2] = UInt8(0x80 | (c >> 6) & 0x3F); o[3] = UInt8(0x80 | c & 0x3F)
        return 4
    }

    /// Wraps an over-allocated output buffer, moving it into a right-sized one when the
    /// slack is large (keeps memory proportional to the text).
    static func shrink(_ p: UnsafeMutablePointer<UInt8>, _ n: Int, allocated: Int) -> TextBuffer {
        if allocated - n < 1 << 16 {
            (p + n).initialize(repeating: 0, count: TextBuffer.padding)
            return TextBuffer(owning: p, count: n)
        }
        let q = TextBuffer.allocate(n)
        memcpy(q, p, n)
        p.deallocate()
        return TextBuffer(owning: q, count: n)
    }
}

import Darwin
