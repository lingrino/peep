import Darwin

/// Lists a ZIP from its central directory alone (the end record, then the directory), no
/// decompression, so the size of the archive barely matters.
///
/// Every number in the end records is untrusted: ZIP64 fields are 64-bit, so they're
/// converted with `Int(exactly:)` and range-checked without sums that can overflow.
enum ZipReader {
    /// Central directories larger than this are listed up to this many bytes.
    static let maxDirectoryBytes = 256 << 20
    /// The directory is read this much at a time: the time budget is checked between reads
    /// (a 256 MB directory read and parsed at once took the main thread well past 25 ms),
    /// and memory holds one chunk instead of the whole directory.
    static let chunk = 1 << 20
    /// Largest directory entry: 46 fixed bytes plus name, extra field and comment (16-bit
    /// lengths). An unfinished entry carried over to the next read is shorter than this.
    static let maxEntryBytes = 46 + 3 * 65_535

    static func read(fd: Int32, size: Int, into l: ArchiveListing, deadline: UInt64 = 0,
                     cancelled: () -> Bool = { false }) {
        // End of central directory: 22 bytes + up to 64 KB of comment, at the very end.
        let tailLen = min(size, 22 + 65_535 + 20)
        var tail = [UInt8](repeating: 0, count: tailLen)
        guard tail.withUnsafeMutableBufferPointer({ preadAll(fd, $0.baseAddress, tailLen, offset: size - tailLen) }) else {
            l.error = "unreadable"; return
        }
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
            var z = [UInt8](repeating: 0, count: 56)
            if let rec = Int(exactly: le64(tail, eocd - 12)), rec <= size - 56,
               z.withUnsafeMutableBufferPointer({ preadAll(fd, $0.baseAddress, 56, offset: rec) }), le32(z, 0) == 0x0606_4B50 {
                guard let e = Int(exactly: le64(z, 32)), let s = Int(exactly: le64(z, 40)), let o = Int(exactly: le64(z, 48)) else {
                    l.error = "damaged central directory"; return
                }
                entries = e
                cdSize = s
                cdOffset = o
            }
        }
        guard cdOffset >= 0, cdSize >= 0, cdOffset <= size, cdSize <= size - cdOffset else {
            l.error = "damaged central directory"; return
        }
        let total = min(cdSize, maxDirectoryBytes)
        let cap = max(1, total <= chunk ? total : chunk + maxEntryBytes)   // small: one read
        let p = UnsafeMutablePointer<UInt8>.allocate(capacity: cap)
        defer { p.deallocate() }
        l.names.reserveCapacity(min(total, l.maxNameBytes))
        l.nameEnd.reserveCapacity(min(entries, total / 46, l.maxEntries))   // (`entries` is only a hint)
        var have = 0    // bytes in the buffer
        var read = 0    // directory bytes read so far
        var i = 0       // next entry in the buffer
        reading: while true {
            // Keep the unfinished entry, append the next chunk.
            if i > 0 {
                memmove(p, p + i, have - i)
                have -= i
                i = 0
            }
            let want = min(cap - have, total - read)
            if want > 0 {
                guard preadAll(fd, p + have, want, offset: cdOffset + read) else { l.error = "unreadable"; return }
                have += want
                read += want
            }
            let last = read == total
            while i + 46 <= have {
                guard le32(p, i) == 0x0201_4B50 else { break reading }
                let gp = le16(p, i + 8)
                let time = le16(p, i + 12), date = le16(p, i + 14)
                var usize = UInt64(le32(p, i + 24))
                let nameLen = Int(le16(p, i + 28)), extraLen = Int(le16(p, i + 30)), commentLen = Int(le16(p, i + 32))
                let ext = le32(p, i + 38)
                let nameAt = i + 46
                let next = nameAt + nameLen + extraLen + commentLen
                if next > have && !last { break }   // finish it after the next read
                guard nameAt + nameLen + extraLen <= have, l.hasRoom(forName: nameLen) else { break reading }
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
                i = next
            }
            if last { break }
            if (deadline != 0 && nanotime() > deadline) || cancelled() { l.complete = false; return }
        }
        if cdSize > total && l.error == nil { l.error = "directory too large, listing truncated" }
    }

    static func preadAll(_ fd: Int32, _ buf: UnsafeMutablePointer<UInt8>?, _ want: Int, offset: Int) -> Bool {
        guard let buf else { return want == 0 }
        var got = 0
        while got < want {
            let r = pread(fd, buf + got, want - got, off_t(offset + got))
            if r < 0 { if errno == EINTR { continue }; return false }
            if r == 0 { return false }
            got += r
        }
        return true
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
