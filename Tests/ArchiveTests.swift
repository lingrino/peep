import Darwin

/// Writes bytes to a fresh temporary file and returns its path.
func tempFile(_ bytes: [UInt8], suffix: String) -> String {
    var template = Array("/tmp/peep-test-XXXXXX\(suffix)".utf8CString)
    let fd = template.withUnsafeMutableBufferPointer { mkstemps($0.baseAddress!, Int32(suffix.utf8.count)) }
    precondition(fd >= 0)
    _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    close(fd)
    return String(cString: template.withUnsafeBufferPointer { $0.baseAddress! })
}

func removeFile(_ path: String) { unlink(path) }

/// Names column of a rendered listing (indentation kept, columns dropped).
func listedNames(_ path: String, _ kind: ArchiveKind) -> [String] {
    rendered(ArchiveReader.list(path: path, kind: kind, budgetNanos: 0)).names
}

/// A listing's summary line and names column (indentation kept); fails the test when the
/// text isn't valid UTF-8 (the renderer relies on it).
func rendered(_ l: ArchiveListing, file: StaticString = #fileID, line: UInt = #line) -> (summary: String, names: [String]) {
    guard let (t, _) = l.render(title: "t") else { expect(false, "no render", file: file, line: line); return ("", []) }
    expect(isValidUTF8(t), "listing is not valid UTF-8", file: file, line: line)
    let lines = t.string(0, t.count).split(separator: "\n", omittingEmptySubsequences: false)
    return (String(lines[1]), lines.dropFirst(3).filter { !$0.isEmpty }.map { String($0.dropFirst(9 + 2 + 16 + 2)) })
}

/// The date column as the listing shows it.
func date(_ packed: Int64) -> String {
    var b = [UInt8](repeating: 0, count: 16)
    b.withUnsafeMutableBufferPointer { ArchiveListing.dateBytes(packed, $0.baseAddress!) }
    return String(decoding: b, as: UTF8.self)
}

func isValidUTF8(_ t: TextBuffer) -> Bool {
    if case .valid = Decoder.validateUTF8(t.base, t.count) { return true }
    return false
}

/// A ustar header. `nameBytes`, `sizeField` and `mtimeField` replace the name and the raw
/// numeric fields (base-256, out-of-range values).
func tarHeader(_ name: String, size: Int = 0, type: UInt8 = 0x30, prefix: String = "",
               nameBytes: [UInt8]? = nil, sizeField: [UInt8]? = nil, mtimeField: [UInt8]? = nil) -> [UInt8] {
    var h = [UInt8](repeating: 0, count: 512)
    func put(_ s: String, _ at: Int) { for (i, b) in s.utf8.enumerated() { h[at + i] = b } }
    func put(_ b: [UInt8], _ at: Int) { for (i, x) in b.enumerated() { h[at + i] = x } }
    if let nameBytes { put(nameBytes, 0) } else { put(name, 0) }
    put("0000644", 100)
    if let sizeField { put(sizeField, 124) } else { put(String(size, radix: 8).leftPad(11), 124) }
    if let mtimeField { put(mtimeField, 136) } else { put("14000000000", 136) }
    h[156] = type
    put("ustar", 257); put("00", 263)
    if !prefix.isEmpty { put(prefix, 345) }
    put("        ", 148)
    let sum = h.reduce(0) { $0 + Int($1) }
    put(String(sum, radix: 8).leftPad(6) + "\0 ", 148)
    return h
}

func padded(_ b: [UInt8]) -> [UInt8] { b + [UInt8](repeating: 0, count: (512 - b.count % 512) % 512) }

/// A pax record ("len key=value\n") with its length computed.
func paxRecord(_ key: String, _ value: [UInt8]) -> [UInt8] {
    let body = Array(" \(key)=".utf8) + value + [0x0A]
    var len = body.count + 1
    while String(len).utf8.count + body.count != len { len += 1 }
    return Array(String(len).utf8) + body
}

/// Tar bytes in memory, for TarReader without a file.
struct MemorySource: ByteSource {
    let bytes: [UInt8]
    var offset = 0
    var cutShort: Bool { false }
    mutating func read(_ dst: UnsafeMutablePointer<UInt8>, _ n: Int) -> Int {
        let k = min(n, bytes.count - offset)
        if k > 0 { bytes.withUnsafeBufferPointer { _ = memcpy(dst, $0.baseAddress! + offset, k) } }
        offset += k
        return k
    }
    mutating func skip(_ n: Int) -> Bool {
        guard n <= bytes.count - offset else { offset = bytes.count; return false }
        offset += n
        return true
    }
}

func listTar(_ bytes: [UInt8], maxEntries: Int? = nil, cancelled: () -> Bool = { false }) -> ArchiveListing {
    let l = ArchiveListing(kind: .tar)
    if let maxEntries { l.maxEntries = maxEntries }
    var src = MemorySource(bytes: bytes)
    TarReader.read(&src, into: l, deadline: 0, cancelled: cancelled)
    return l
}

func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }
func le64(_ v: UInt64) -> [UInt8] { (0..<8).map { UInt8(truncatingIfNeeded: v >> (8 * $0)) } }

/// ZIP with raw names and extra fields; `zip64` puts a ZIP64 end record + locator (with the
/// given entries / directory size / offset / record offset) before the end record.
func zipRaw(_ entries: [(name: [UInt8], size: UInt32, extra: [UInt8])],
            zip64: (entries: UInt64, size: UInt64, offset: UInt64, record: UInt64?)? = nil) -> [UInt8] {
    var cd = [UInt8]()
    for e in entries {
        cd += [0x50, 0x4B, 1, 2] + le16(45) + le16(45) + le16(0) + le16(8) + le16(0x6000) + le16(0x5B50)
        cd += le32(0) + le32(e.size) + le32(e.size) + le16(e.name.count) + le16(e.extra.count) + le16(0)
        cd += le16(0) + le16(0) + le32(0) + le32(0) + e.name + e.extra
    }
    let pre = [UInt8](repeating: 0, count: 30)
    var z = pre + cd
    if let z64 = zip64 {
        let rec = UInt64(z.count)
        z += le32(0x0606_4B50) + le64(44) + le16(45) + le16(45) + le32(0) + le32(0)
        z += le64(z64.entries) + le64(z64.entries) + le64(z64.size) + le64(z64.offset)
        z += le32(0x0706_4B50) + le32(0) + le64(z64.record ?? rec) + le32(1)
    }
    z += [0x50, 0x4B, 5, 6] + le16(0) + le16(0) + le16(entries.count) + le16(entries.count)
    z += le32(UInt32(cd.count)) + le32(UInt32(pre.count)) + le16(0)
    return z
}

func listZip(_ bytes: [UInt8]) -> ArchiveListing {
    let path = tempFile(bytes, suffix: ".zip")
    defer { unlink(path) }
    return ArchiveReader.list(path: path, kind: .zip, budgetNanos: 0)
}

func crc32(_ d: [UInt8]) -> UInt32 {
    var c: UInt32 = 0xFFFF_FFFF
    for b in d {
        c ^= UInt32(b)
        for _ in 0..<8 { c = c & 1 != 0 ? (c >> 1) ^ 0xEDB8_8320 : c >> 1 }
    }
    return ~c
}

/// One gzip member with stored (uncompressed) DEFLATE blocks: exact bytes, no encoder.
func gzipMember(_ d: [UInt8], name: String? = nil) -> [UInt8] {
    var m: [UInt8] = [0x1F, 0x8B, 8, name == nil ? 0 : 8, 0, 0, 0, 0, 0, 3]
    if let name { m += Array(name.utf8) + [0] }
    var i = 0
    repeat {
        let n = min(65_535, d.count - i)
        m += [i + n == d.count ? 1 : 0] + le16(n) + le16(~n & 0xFFFF) + d[i..<(i + n)]
        i += n
    } while i < d.count
    return m + le32(crc32(d)) + le32(UInt32(truncatingIfNeeded: d.count))
}

/// Decompressed bytes of a .gz (whole, or up to `limit`), and whether more followed.
func gunzip(_ gz: [UInt8], limit: Int = 1 << 30) -> (String, Bool) {
    let path = tempFile(gz, suffix: ".txt.gz")
    defer { unlink(path) }
    guard let (t, more, _) = SingleFileCompression.load(path: path, gzip: true, limit: limit, budgetNanos: 10_000_000_000) else {
        return ("<nil>", false)
    }
    expect(isValidUTF8(t))
    return (t.string(0, t.count), more)
}

func padded(_ s: String) -> [UInt8] {
    var b = Array(s.utf8)
    b += [UInt8](repeating: 0, count: (512 - b.count % 512) % 512)
    return b
}

extension String {
    func leftPad(_ n: Int) -> String { String(repeating: "0", count: max(0, n - count)) + self }
}

/// Minimal ZIP: central directory + end record (the reader never looks at local headers).
func zipBytes(_ entries: [(String, UInt32, Bool)]) -> [UInt8] {
    var cd = [UInt8]()
    func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
    func le32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24)] }
    for (name, size, encrypted) in entries {
        cd += [0x50, 0x4B, 1, 2] + le16(20) + le16(20) + le16(encrypted ? 1 : 0) + le16(8)
        cd += le16(0x6000) + le16(0x5B50)   // 15:00, 2025-10-16
        cd += le32(0) + le32(size / 2) + le32(size) + le16(name.utf8.count) + le16(0) + le16(0)
        cd += le16(0) + le16(0) + le32(0) + le32(0) + Array(name.utf8)
    }
    let pre = [UInt8](repeating: 0, count: 30)   // stands in for the local headers + data
    var z = pre + cd
    z += [0x50, 0x4B, 5, 6] + le16(0) + le16(0) + le16(entries.count) + le16(entries.count)
    z += le32(UInt32(cd.count)) + le32(UInt32(pre.count)) + le16(0)
    return z
}

let archiveTests: [Test] = [
    Test("archive: tar headers, prefixes, pax and long names, AppleDouble hidden") {
        var tar = tarHeader("src/", type: 0x35)
        tar += tarHeader("main.swift", size: 5, prefix: "src") + padded("hello")
        tar += tarHeader("./._main.swift", size: 3) + padded("xyz")
        tar += tarHeader("PaxHeader", size: 28, type: 0x78) + padded("28 path=docs/a-long-name.md\n")
        tar += tarHeader("ignored")
        tar += tarHeader("././@LongLink", size: 14, type: 0x4C) + padded("lib/Zeta.swift")
        tar += tarHeader("lib/short")
        tar += [UInt8](repeating: 0, count: 1024)
        let path = tempFile(tar, suffix: ".tar")
        defer { unlink(path) }
        expectEqual(listedNames(path, .tar), ["docs/", "  a-long-name.md", "lib/", "  Zeta.swift", "src/", "  main.swift"])
        // Control characters in names (here from a malformed pax record) can't break lines.
        let bad = tarHeader("x", size: 0, type: 0x78) + tarHeader("a\nb\u{1}c") + [UInt8](repeating: 0, count: 1024)
        let p2 = tempFile(bad, suffix: ".tar")
        defer { unlink(p2) }
        expectEqual(listedNames(p2, .tar), ["a?b?c"])
    },
    Test("archive: zip central directory, folders first, case-insensitive, encrypted") {
        let z = zipBytes([("b.txt", 1500, false), ("a/x.txt", 10, true), ("A/y", 20, false), ("__MACOSX/a/._x.txt", 1, false)])
        let path = tempFile(z, suffix: ".zip")
        defer { unlink(path) }
        expectEqual(listedNames(path, .zip), ["A/", "  y", "a/", "  x.txt  (encrypted)", "b.txt"])
        let l = ArchiveReader.list(path: path, kind: .zip, budgetNanos: 0)
        expectEqual(l.count, 4)
        expectEqual(date(l.time[0]), "2025-10-16 12:00")
    },
    Test("archive: dates as rendered (dateBytes)") {
        expectEqual(date(ArchiveListing.packDOS(date: 0x5B50, time: 0x6000)), "2025-10-16 12:00")
        expectEqual(date(ArchiveListing.packDOS(date: 0x21, time: 0)), "1980-01-01 00:00")
        expectEqual(date(ArchiveListing.packDOS(date: 0xFFFF, time: 0xFFFF)), "2107-15-31 31:63")   // garbage in, digits out
        let l = ArchiveListing(kind: .tar)
        let packed = l.packUnix(1_700_000_000)   // 2023-11-14 22:13 UTC; local time varies
        expect(date(packed).hasPrefix("2023-11-1"))
        expectEqual(date(99_991_231_2359), "9999-12-31 23:59")
        expectEqual(date(12_345_678_901_234_567), "9999-01-23 45:67")   // years clamp to 4 digits
        expectEqual(date(-5), "0000-00-00 00:00")
        // Out-of-range Unix times (huge base-256 or pax mtimes) are unknown (0), not an overflow.
        for t: Int64 in [0, -1, .min, .max, ArchiveListing.maxUnixSeconds + 1] { expectEqual(l.packUnix(t), 0) }
        expect(date(l.packUnix(ArchiveListing.maxUnixSeconds)).hasPrefix("9999-"))
    },
    Test("archive: kinds, sizes, not-an-archive") {
        expectEqual(ArchiveKind.of(fileName: "x.tar.gz"), .tarGzip); expectEqual(ArchiveKind.of(fileName: "x.gz"), nil)
        expectEqual(ArchiveKind.of(fileName: "a.WHL"), .zip); expectEqual(ArchiveKind.of(fileName: "x.txz"), .tarXz)
        expectEqual(ArchiveListing.sizeString(999), "999 B"); expectEqual(ArchiveListing.sizeString(1500), "1.5 KB")
        expectEqual(ArchiveListing.sizeString(999_960), "1.0 MB"); expectEqual(ArchiveListing.sizeString(12_345_678_901), "12.3 GB")
        var b = [UInt8](repeating: 0, count: 16)
        for n: UInt64 in [0, 999, 1000, 999_949, 999_950, 1_234_567, 5_000_000_000_000] {
            let k = b.withUnsafeMutableBufferPointer { ArchiveListing.sizeBytes(n, $0.baseAddress!) }
            expectEqual(String(decoding: b[0..<k], as: UTF8.self), ArchiveListing.sizeString(n))
        }
        let path = tempFile(Array("just text, not a zip".utf8), suffix: ".zip")
        defer { unlink(path) }
        expectEqual(ArchiveReader.list(path: path, kind: .zip, budgetNanos: 0).error, "not a ZIP archive")
    },
    Test("archive: names invalid as UTF-8 by the decoder's rule come out valid") {
        // Each class the old check let through (one crashed the renderer), and a cut sequence.
        let bad: [[UInt8]] = [
            [0x61, 0xF5, 0x80, 0x80],         // lead byte past F4
            [0x61, 0xED, 0xA0, 0x80],         // surrogate U+D800
            [0x61, 0xC0, 0xAF],               // overlong "/"
            [0x61, 0xE0, 0x80, 0xAF],         // overlong, 3 bytes
            [0x61, 0xF0, 0x80, 0x80, 0xAF],   // overlong, 4 bytes
            [0x61, 0xF4, 0x90, 0x80, 0x80],   // past U+10FFFF
            [0x61, 0xE2, 0x82],               // cut short
        ]
        func valid(_ b: [UInt8]) -> Bool { b.withUnsafeBufferPointer { ArchiveListing.validUTF8($0.baseAddress!, 0, b.count) } }
        for b in bad { expect(!valid(b), "\(b)") }
        for s in ["é", "€", "😀", "\u{10FFFF}", "\u{D7FF}", "\u{E000}", "plain"] { expect(valid(Array(s.utf8)), s) }
        // Same verdict as the decoder on random bytes around every boundary.
        var rng = SystemRandomNumberGenerator()
        let alphabet: [UInt8] = [0x41, 0x80, 0x8F, 0x90, 0x9F, 0xA0, 0xBF, 0xC0, 0xC1, 0xC2, 0xDF, 0xE0, 0xED, 0xEF, 0xF0, 0xF4, 0xF5, 0xFF]
        for _ in 0..<5000 {
            let b = (0..<Int.random(in: 1...6, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! }
            expectEqual(valid(b), isValidUTF8(b.withUnsafeBytes { TextBuffer(copying: $0) }), "\(b)")
        }
        // Through listings: Latin-1 fallback, C0 and C1 controls as "?".
        let z = rendered(listZip(zipRaw(bad.map { ($0 + Array(".txt".utf8), 1, []) } + [(Array("ok-é.txt".utf8), 1, [])])))
        expectEqual(z.names.count, bad.count + 1)
        expect(z.names.contains("ok-é.txt"))
        expect(z.names.contains("aí\u{A0}?.txt"))
        var tar = tarHeader("", nameBytes: [0x61, 0xF5, 0x80, 0x80])
        let pax = paxRecord("path", [0x64, 0x2F, 0xED, 0xA0, 0x80])
        tar += tarHeader("PaxHeader", size: pax.count, type: 0x78) + padded(pax) + tarHeader("ignored")
        let long: [UInt8] = [0x62, 0xF4, 0x90, 0x80, 0x80]
        tar += tarHeader("././@LongLink", size: long.count, type: 0x4C) + padded(long) + tarHeader("short")
        tar += [UInt8](repeating: 0, count: 1024)
        expectEqual(rendered(listTar(tar)).names, ["d/", "  í\u{A0}?", "aõ??", "bô???"])
    },
    Test("archive: long names and pax headers can't allocate what a header declares") {
        // 64 GiB declared in a 1.5 KB file: skipped (and the data ends), never allocated.
        for type: UInt8 in [0x4C, 0x78] {
            let t0 = nanotime()
            let l = listTar(tarHeader("././@LongLink", type: type, sizeField: Array("777777777777".utf8)) + [UInt8](repeating: 0, count: 1024))
            expectEqual(l.count, 0)
            expect(nanotime() - t0 < 50_000_000)
        }
        // Over the limit but present: skipped; the next entry keeps its own name.
        let big = [UInt8](repeating: 0x61, count: TarReader.maxMetaBytes + 1)
        for type: UInt8 in [0x4C, 0x78] {
            let t = tarHeader("x", size: big.count, type: type) + padded(big) + tarHeader("next.txt", size: 3) + padded("abc")
                + [UInt8](repeating: 0, count: 1024)
            expectEqual(rendered(listTar(t)).names, ["next.txt"])
        }
    },
    Test("archive: out-of-range numbers are damage or unknown, not traps") {
        // ZIP64: fields at or past 2^63, a sum that overflows, record offsets past Int.
        for c: (UInt64, UInt64, UInt64) in [(1 << 63, 0, 30), (1, 1 << 63, 30), (1, 10, 1 << 63), (1, 1 << 62, 1 << 62), (.max, .max, .max)] {
            let l = listZip(zipRaw([], zip64: (c.0, c.1, c.2, nil)))
            expectEqual(l.count, 0)
            expectEqual(l.error, "damaged central directory")
        }
        for rec: UInt64 in [1 << 63, (1 << 63) - 10, .max, 1 << 40] {
            expectEqual(listZip(zipRaw([], zip64: (1, 0, 30, rec))).count, 0)   // record ignored
        }
        expectEqual(listZip(zipRaw([], zip64: (1 << 62, 0, 30, nil))).count, 0)   // `entries` is only a hint
        // Entry sizes up to 2^64 - 1 (ZIP64 extra field) render.
        let zs = listZip(zipRaw([(Array("big.bin".utf8), 0xFFFF_FFFF, le16(1) + le16(8) + le64(.max))]))
        expectEqual(zs.size, [.max])
        expect(rendered(zs).summary.contains("18446.7 PB unpacked"))
        var b = [UInt8](repeating: 0, count: 16)
        for n: UInt64 in [1_850_000_000_000_000_000, .max, .max - 1, 999_999_999_999_999_999, 999_950_000_000_000_000] {
            let k = b.withUnsafeMutableBufferPointer { ArchiveListing.sizeBytes(n, $0.baseAddress!) }
            expectEqual(String(decoding: b[0..<k], as: UTF8.self), ArchiveListing.sizeString(n))
        }
        // Tar: sizes >= 2^63 (base-256) and past 64 bits are damage; huge mtimes are unknown.
        let zeros = [UInt8](repeating: 0, count: 1024)
        let size63: [UInt8] = [0x80, 0, 0, 0, 0x80, 0, 0, 0, 0, 0, 0, 0]
        expectEqual(listTar(tarHeader("big", sizeField: size63) + zeros).error, "damaged after 0 entries")
        let past64: [UInt8] = [0x80, 1] + [UInt8](repeating: 0, count: 10)
        expectEqual(past64.withUnsafeBufferPointer { TarReader.number($0.baseAddress!, 12) }, .max)
        expectEqual(size63.withUnsafeBufferPointer { TarReader.number($0.baseAddress!, 12) }, 1 << 63)
        for m: [UInt8] in [[0x80] + [UInt8](repeating: 0xFF, count: 11), [0x80, 0, 0, 0, 0x7F] + [UInt8](repeating: 0xFF, count: 7)] {
            let l = listTar(tarHeader("m", mtimeField: m) + zeros)
            expectEqual(l.count, 1)
            expectEqual(l.time, [0])
        }
        // Pax: records "1 ", 0 and 20-digit lengths, huge mtime and size values.
        var path: [UInt8]?, size: UInt64?, time: Int64?
        for r in ["1 ", "0 ", "3 \n", "99999999999999999999 path=x\n", "18446744073709551616 path=x\n", "12 path=x\n"] {
            TarReader.parsePax(Array(r.utf8), path: &path, size: &size, time: &time)
        }
        expectEqual(path, nil)
        TarReader.parsePax(paxRecord("mtime", Array("99999999999999999999".utf8)), path: &path, size: &size, time: &time)
        expectEqual(time, nil)
        for (key, value) in [("mtime", "9223372036854775807"), ("size", "18446744073709551615")] {
            let p = paxRecord(key, Array(value.utf8))
            let l = listTar(tarHeader("PaxHeader", size: p.count, type: 0x78) + padded(p) + tarHeader("f") + zeros)
            if key == "size" { expectEqual(l.error, "damaged after 0 entries") } else { expectEqual(l.time, [0]) }
        }
        // gzip: FEXTRA length past the header, with FNAME after it.
        let hdr: [UInt8] = [0x1F, 0x8B, 8, 4 | 8, 0, 0, 0, 0, 0, 3] + le16(0xFFFF) + [UInt8](repeating: 0, count: 20)
        expect(hdr.withUnsafeBufferPointer { DecompressSource.gzipHeader($0.baseAddress!, $0.count) } == nil)
        expectEqual(gunzip(hdr).0, "<nil>")
    },
    Test("archive: listing limits (entries, lines, bytes), render budget, cancellation") {
        var t = [UInt8]()
        for i in 0..<50 { t += tarHeader("f\(i)") }
        t += [UInt8](repeating: 0, count: 1024)
        let l = listTar(t, maxEntries: 20)
        expectEqual(l.count, 20)
        expect(rendered(l).summary.hasSuffix("· first 20 entries"))
        let c = listTar(t, cancelled: { true })
        expectEqual(c.count, 0)
        expect(!c.complete)
        // Implied folders: 3 entries with 64 KB names imply ~96k folders.
        let deep = (0..<3).map { k in (Array("d\(k)/".utf8) + Array(String(repeating: "a/", count: 32_000).utf8) + [0x66], UInt32(1), [UInt8]()) }
        let z = listZip(zipRaw(deep))
        expectEqual(z.count, 3)
        expect(z.render(title: "t", lineBudget: 1000) == nil)
        z.maxLines = 1000
        let r = rendered(z)
        expectEqual(r.names.count, 1000)
        expect(r.summary.contains("first 1,000 lines shown"))
        z.maxLines = 2_000_000
        z.maxBytes = 100_000
        let (text, _) = z.render(title: "t")!
        expect(text.count < 100_000 + 1000)
        expect(isValidUTF8(text))
    },
    Test("archive: gzip members are all decoded; a cut ends between characters") {
        let a = gzipMember(Array("first\n".utf8)), b = gzipMember(Array("second\n".utf8), name: "n.txt")
        expectEqual(gunzip(a + b).0, "first\nsecond\n")
        expectEqual(gunzip(a + a).0, "first\nfirst\n")
        expectEqual(gunzip(a + [UInt8](repeating: 0, count: 100)).0, "first\n")   // trailing zeros
        // A member longer than the decoder's read-ahead, then a short one.
        let long = (0..<300_000).map { UInt8(0x61 + $0 % 26) }
        expectEqual(gunzip(gzipMember(long) + b).0.utf8.count, 300_007)
        // Many members (BGZF-like) are fine; thousands of empty ones end the data.
        let parts = (0..<1100).flatMap { gzipMember(Array(String(repeating: "\($0 % 10)", count: 1100).utf8)) }
        expectEqual(gunzip(parts).0.utf8.count, 1100 * 1100)
        let empties = (0..<3000).flatMap { _ in gzipMember([]) } + gzipMember(Array("x".utf8))
        expectEqual(gunzip(empties).0, "")
        // The limit falls inside a character: it is dropped whole.
        let (s, more) = gunzip(gzipMember(Array(String(repeating: "€", count: 1000).utf8)), limit: 1000)
        expect(more)
        expectEqual(s, String(repeating: "€", count: 333))
        // A tar stream split across members.
        let tar = tarHeader("a.txt", size: 600) + padded([UInt8](repeating: 0x61, count: 600)) + tarHeader("b.txt")
            + [UInt8](repeating: 0, count: 1024)
        let p = tempFile(gzipMember(Array(tar[0..<700])) + gzipMember(Array(tar[700...])), suffix: ".tar.gz")
        defer { unlink(p) }
        expectEqual(listedNames(p, .tarGzip), ["a.txt", "b.txt"])
    },
    Test("archive: a pax size is for the next entry, not a long name in between") {
        let pax = paxRecord("size", Array("5".utf8))
        var t = tarHeader("PaxHeader", size: pax.count, type: 0x78) + padded(pax)
        let long = Array("dir/long-name.txt".utf8)
        t += tarHeader("././@LongLink", size: long.count, type: 0x4C) + padded(long)
        t += tarHeader("short", size: 0) + padded("12345")   // the header says 0, pax says 5
        t += tarHeader("after.txt", size: 2) + padded("ok") + [UInt8](repeating: 0, count: 1024)
        let l = listTar(t)
        expectEqual(rendered(l).names, ["dir/", "  long-name.txt", "after.txt"])
        expectEqual(l.size, [5, 2])
    },
]
