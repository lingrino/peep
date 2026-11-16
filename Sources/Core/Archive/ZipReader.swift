import Darwin

/// Lists a ZIP from its central directory alone: two `pread`s (the end record, then the
/// directory), no decompression, so the size of the archive barely matters.
enum ZipReader {
    /// Central directories larger than this are listed up to this many bytes.
    static let maxDirectoryBytes = 256 << 20

    static func read(fd: Int32, size: Int, into l: ArchiveListing) {
        // End of central directory: 22 bytes + up to 64 KB of comment, at the very end.
        let tailLen = min(size, 22 + 65_535 + 20)
        var tail = [UInt8](repeating: 0, count: tailLen)
        guard preadAll(fd, &tail, offset: size - tailLen) else { l.error = "unreadable"; return }
        var eocd = -1
        var k = tailLen - 22
        while k >= 0 {
            if tail[k] == 0x50 && tail[k + 1] == 0x4B && tail[k + 2] == 5 && tail[k + 3] == 6 { eocd = k; break }
            k -= 1
        }
        guard eocd >= 0 else { l.error = "not a ZIP archive"; return }
        var entries = Int(le16(tail, eocd + 10))
        var cdSize = Int(le32(tail, eocd + 12))
        var cdOffset = Int(le32(tail, eocd + 16))
        // ZIP64: the locator sits just before the end record and points at the ZIP64 record.
        if eocd >= 20 && le32(tail, eocd - 20) == 0x0706_4B50 {
            let rec = Int(le64(tail, eocd - 12))
            var z = [UInt8](repeating: 0, count: 56)
            if rec >= 0 && rec + 56 <= size && preadAll(fd, &z, offset: rec) && le32(z, 0) == 0x0606_4B50 {
                entries = Int(le64(z, 32))
                cdSize = Int(le64(z, 40))
                cdOffset = Int(le64(z, 48))
            }
        }
        guard cdOffset >= 0, cdSize >= 0, cdOffset + cdSize <= size else { l.error = "damaged central directory"; return }
        let n = min(cdSize, maxDirectoryBytes)
        var cd = [UInt8](repeating: 0, count: n)
        guard preadAll(fd, &cd, offset: cdOffset) else { l.error = "unreadable"; return }
        l.names.reserveCapacity(n)
        l.nameEnd.reserveCapacity(entries)
        cd.withUnsafeBufferPointer { b in
            let p = b.baseAddress!
            var i = 0
            while i + 46 <= n && le32(p, i) == 0x0201_4B50 {
                let gp = le16(p, i + 8)
                let time = le16(p, i + 12), date = le16(p, i + 14)
                var usize = UInt64(le32(p, i + 24))
                let nameLen = Int(le16(p, i + 28)), extraLen = Int(le16(p, i + 30)), commentLen = Int(le16(p, i + 32))
                let ext = le32(p, i + 38)
                let nameAt = i + 46
                guard nameAt + nameLen + extraLen <= n else { break }
                if usize == 0xFFFF_FFFF {   // ZIP64 extra field (id 1) holds the real size first
                    var x = nameAt + nameLen
                    let xe = x + extraLen
                    while x + 4 <= xe {
                        let id = le16(p, x), len = Int(le16(p, x + 2))
                        if id == 1 && len >= 8 && x + 12 <= xe { usize = le64(p, x + 4); break }
                        x += 4 + len
                    }
                }
                var f: UInt8 = 0
                if gp & 1 != 0 { f |= ArchiveListing.Flag.encrypted }
                if nameLen > 0 && p[nameAt + nameLen - 1] == 0x2F { f |= ArchiveListing.Flag.dir }
                if (ext >> 16) & 0xF000 == 0xA000 { f |= ArchiveListing.Flag.link }   // Unix symlink mode
                l.add(name: UnsafeBufferPointer(start: p + nameAt, count: nameLen), size: usize,
                      time: ArchiveListing.packDOS(date: date, time: time), flags: f)
                i = nameAt + nameLen + extraLen + commentLen
            }
            if cdSize > n { l.error = "directory too large, listing truncated" }
        }
    }

    static func preadAll(_ fd: Int32, _ buf: inout [UInt8], offset: Int) -> Bool {
        let want = buf.count
        var got = 0
        let ok = buf.withUnsafeMutableBytes { b -> Bool in
            while got < want {
                let r = pread(fd, b.baseAddress! + got, want - got, off_t(offset + got))
                if r < 0 { if errno == EINTR { continue }; return false }
                if r == 0 { return false }
                got += r
            }
            return true
        }
        return ok
    }

    @inline(__always) static func le16(_ p: UnsafePointer<UInt8>, _ i: Int) -> UInt16 {
        UInt16(p[i]) | UInt16(p[i + 1]) << 8
    }
    @inline(__always) static func le32(_ p: UnsafePointer<UInt8>, _ i: Int) -> UInt32 {
        UInt32(p[i]) | UInt32(p[i + 1]) << 8 | UInt32(p[i + 2]) << 16 | UInt32(p[i + 3]) << 24
    }
    @inline(__always) static func le64(_ p: UnsafePointer<UInt8>, _ i: Int) -> UInt64 {
        UInt64(le32(p, i)) | UInt64(le32(p, i + 4)) << 32
    }
    static func le16(_ a: [UInt8], _ i: Int) -> UInt16 { a.withUnsafeBufferPointer { le16($0.baseAddress!, i) } }
    static func le32(_ a: [UInt8], _ i: Int) -> UInt32 { a.withUnsafeBufferPointer { le32($0.baseAddress!, i) } }
    static func le64(_ a: [UInt8], _ i: Int) -> UInt64 { a.withUnsafeBufferPointer { le64($0.baseAddress!, i) } }
}
