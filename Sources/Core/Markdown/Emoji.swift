import Darwin

/// GitHub emoji shortcodes: `:tada:` renders as 🎉. The names and emoji are one static string
/// (`EmojiTable.swift`); this indexes it with an open-addressing hash table built once per
/// process (`Prewarm` builds it at launch, so no preview waits for it).
enum Emoji {
    /// Slot: name offset in `table` (20 bits) | name length << 20 | emoji length << 26; 0 = empty.
    /// The emoji follows its name and one space.
    nonisolated(unsafe) static let slots: UnsafeMutablePointer<UInt32> = build()
    static let mask = 4095   // 1,913 names: load under one half

    @inline(__always) static func hash(_ p: UnsafePointer<UInt8>, _ n: Int) -> Int {
        var h: UInt32 = 2_166_136_261   // FNV-1a
        for k in 0..<n { h = (h ^ UInt32(p[k])) &* 16_777_619 }
        return Int(h)
    }

    private static func build() -> UnsafeMutablePointer<UInt32> {
        let s = UnsafeMutablePointer<UInt32>.allocate(capacity: mask + 1)
        s.initialize(repeating: 0, count: mask + 1)
        let p = table.utf8Start, n = table.utf8CodeUnitCount
        var i = 0
        while i < n {
            var sp = i
            while p[sp] != 0x20 { sp += 1 }
            var e = sp + 1
            while e < n && p[e] != 0x0A { e += 1 }
            var h = hash(p + i, sp - i) & mask
            while s[h] != 0 { h = (h + 1) & mask }
            s[h] = UInt32(i) | UInt32(sp - i) << 20 | UInt32(e - sp - 1) << 26
            i = e + 1
        }
        return s
    }

    /// The emoji (UTF-8) for shortcode `p[0..<n]` (without colons), if there is one.
    static func lookup(_ p: UnsafePointer<UInt8>, _ n: Int) -> UnsafeBufferPointer<UInt8>? {
        let base = table.utf8Start
        var h = hash(p, n) & mask
        while true {
            let v = slots[h]
            if v == 0 { return nil }
            let off = Int(v & 0xFFFFF), len = Int(v >> 20 & 63)
            if len == n && memcmp(base + off, p, n) == 0 {
                return UnsafeBufferPointer(start: base + off + n + 1, count: Int(v >> 26))
            }
            h = (h + 1) & mask
        }
    }

    @inline(__always) static func isNameByte(_ c: UInt8) -> Bool {
        (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39) || c == 0x5F || c == 0x2B || c == 0x2D
    }
}
