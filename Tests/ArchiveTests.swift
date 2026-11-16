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

/// Names column of a rendered listing (indentation kept, columns dropped).
func listedNames(_ path: String, _ kind: ArchiveKind) -> [String] {
    let l = ArchiveReader.list(path: path, kind: kind, budgetNanos: 0)
    let (t, _) = l.render(title: "t")
    let s = t.string(0, t.count)
    return s.split(separator: "\n").dropFirst(2).map { String($0.dropFirst(9 + 2 + 16 + 2)) }
}

func tarHeader(_ name: String, size: Int = 0, type: UInt8 = 0x30, prefix: String = "") -> [UInt8] {
    var h = [UInt8](repeating: 0, count: 512)
    func put(_ s: String, _ at: Int) { for (i, b) in s.utf8.enumerated() { h[at + i] = b } }
    put(name, 0)
    put("0000644", 100)
    put(String(size, radix: 8).leftPad(11), 124)
    put("14000000000", 136)
    h[156] = type
    put("ustar", 257); put("00", 263)
    if !prefix.isEmpty { put(prefix, 345) }
    put("        ", 148)
    let sum = h.reduce(0) { $0 + Int($1) }
    put(String(sum, radix: 8).leftPad(6) + "\0 ", 148)
    return h
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
        expectEqual(ArchiveListing.dateString(l.time[0]), "2025-10-16 12:00")
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
]
