import Darwin

/// Lists a tar stream from its 512-byte headers, skipping file contents (free for plain tar,
/// decoded-and-discarded for gzip/xz). Handles ustar prefixes, GNU long names and pax
/// headers. Stops at `deadline` (nanotime, 0 = none) with `complete = false`.
enum TarReader {
    static func read(_ src: inout some ByteSource, into l: ArchiveListing, deadline: UInt64) {
        let h = UnsafeMutablePointer<UInt8>.allocate(capacity: 512)
        defer { h.deallocate() }
        var longName: [UInt8]?
        var paxPath: [UInt8]?, paxSize: UInt64?, paxTime: Int64?
        var zeros = 0
        var first = true
        /// Skips member data in chunks so one huge (compressed) member can't overrun the budget.
        func skip(_ n: Int) -> Bool {
            var left = n
            while left > 0 {
                let k = min(left, 4 << 20)
                guard src.skip(k) else { return false }
                left -= k
                if deadline != 0 && left > 0 && nanotime() > deadline { l.complete = false; return false }
            }
            return true
        }
        while true {
            if deadline != 0 && nanotime() > deadline { l.complete = false; return }
            guard src.read(h, 512) == 512 else { break }
            if isZero(h) {
                zeros += 1
                if zeros == 2 { break }
                continue
            }
            zeros = 0
            guard checksumOK(h) else {
                if first { l.error = "not a tar archive" } else { l.error = "damaged after \(l.count) entries" }
                return
            }
            first = false
            let type = h[156]
            let size = paxSize ?? number(h + 124, 12)
            let padded = Int((size + 511) & ~511)
            switch type {
            case 0x4C:   // GNU long name: the next entry's name is this entry's data
                var d = [UInt8](repeating: 0, count: Int(size))
                guard d.withUnsafeMutableBufferPointer({ src.read($0.baseAddress!, Int(size)) }) == Int(size),
                      src.skip(padded - Int(size)) else { return }
                if let z = d.firstIndex(of: 0) { d.removeSubrange(z...) }
                longName = d
                continue
            case 0x78:   // pax extended header for the next entry
                var d = [UInt8](repeating: 0, count: Int(size))
                guard d.withUnsafeMutableBufferPointer({ src.read($0.baseAddress!, Int(size)) }) == Int(size),
                      src.skip(padded - Int(size)) else { return }
                parsePax(d, path: &paxPath, size: &paxSize, time: &paxTime)
                continue
            case 0x67, 0x4B:   // pax global header, GNU long link name
                guard skip(padded) else { return }
                continue
            default:
                break
            }
            var flags: UInt8 = 0
            if type == 0x35 { flags |= ArchiveListing.Flag.dir }
            if type == 0x32 || type == 0x31 { flags |= ArchiveListing.Flag.link }
            let time = paxTime ?? Int64(number(h + 136, 12))
            let isDir = flags & ArchiveListing.Flag.dir != 0
            if let name = longName ?? paxPath {
                name.withUnsafeBufferPointer { l.add(name: $0, size: isDir ? 0 : size, time: l.packUnix(time), flags: flags) }
            } else {
                var name = [UInt8]()
                if memcmp(h + 257, "ustar", 5) == 0 && h[345] != 0 {
                    name.append(contentsOf: UnsafeBufferPointer(start: h + 345, count: strnlen(h + 345, 155)))
                    name.append(0x2F)
                }
                name.append(contentsOf: UnsafeBufferPointer(start: h, count: strnlen(h, 100)))
                name.withUnsafeBufferPointer { l.add(name: $0, size: isDir ? 0 : size, time: l.packUnix(time), flags: flags) }
            }
            longName = nil; paxPath = nil; paxSize = nil; paxTime = nil
            // Links and folders carry no data even when a size is recorded.
            if type != 0x35 && type != 0x32 && type != 0x31 {
                guard skip(padded) else { return }
            }
        }
    }

    @inline(__always) static func isZero(_ h: UnsafePointer<UInt8>) -> Bool {
        var v: UInt64 = 0
        let w = UnsafeRawPointer(h).assumingMemoryBound(to: UInt64.self)
        for i in 0..<64 { v |= w[i] }
        return v == 0
    }

    /// Header checksum: the sum of all bytes with the checksum field read as spaces.
    static func checksumOK(_ h: UnsafePointer<UInt8>) -> Bool {
        var sum: UInt64 = 0
        for i in 0..<512 { sum += UInt64(i >= 148 && i < 156 ? 0x20 : h[i]) }
        return sum == number(h + 148, 8)
    }

    /// Octal (space/NUL padded) or GNU base-256 (high bit set) numeric field.
    static func number(_ p: UnsafePointer<UInt8>, _ n: Int) -> UInt64 {
        if p[0] & 0x80 != 0 {
            var v: UInt64 = UInt64(p[0] & 0x7F)
            for i in 1..<n { v = v << 8 | UInt64(p[i]) }
            return v
        }
        var v: UInt64 = 0
        var i = 0
        while i < n && (p[i] == 0x20 || p[i] == 0) { i += 1 }
        while i < n && p[i] >= 0x30 && p[i] <= 0x37 { v = v << 3 | UInt64(p[i] - 0x30); i += 1 }
        return v
    }

    /// "len key=value\n" records; we use path, size and mtime.
    static func parsePax(_ d: [UInt8], path: inout [UInt8]?, size: inout UInt64?, time: inout Int64?) {
        var i = 0
        while i < d.count {
            var len = 0
            var j = i
            while j < d.count && d[j] >= 0x30 && d[j] <= 0x39 { len = len * 10 + Int(d[j] - 0x30); j += 1 }
            guard len > 0, j < d.count, d[j] == 0x20, i + len <= d.count else { return }
            let rec = d[(j + 1)..<(i + len - 1)]   // without the trailing "\n"
            if let eq = rec.firstIndex(of: 0x3D) {
                let key = rec[rec.startIndex..<eq], value = rec[(eq + 1)...]
                if key.elementsEqual("path".utf8) { path = Array(value) }
                else if key.elementsEqual("size".utf8) { size = UInt64(String(decoding: value, as: UTF8.self)) }
                else if key.elementsEqual("mtime".utf8) {
                    let s = String(decoding: value, as: UTF8.self)
                    time = Int64(s.split(separator: ".").first ?? "")
                }
            }
            i += len
        }
    }
}

/// Opens and lists an archive. `budgetNanos` bounds the time spent (0 = list everything);
/// a listing that hit the budget has `complete == false`.
public enum ArchiveReader {
    public static func list(path: String, kind: ArchiveKind, budgetNanos: UInt64) -> ArchiveListing {
        let l = ArchiveListing(kind: kind)
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        if fd < 0 { l.error = "unreadable"; return l }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { l.error = "unreadable"; return l }
        let size = Int(st.st_size)
        l.fileSize = UInt64(size)
        let deadline = budgetNanos == 0 ? 0 : nanotime() + budgetNanos
        switch kind {
        case .zip:
            ZipReader.read(fd: fd, size: size, into: l)
        case .tar:
            var src = FileSource(fd: fd, size: size)
            TarReader.read(&src, into: l, deadline: deadline)
        case .tarGzip, .tarXz:
            guard var src = DecompressSource(fd: fd, size: size, format: kind == .tarGzip ? .gzip : .xz) else {
                l.error = "not a \(kind == .tarGzip ? "gzip" : "xz") file"; return l
            }
            TarReader.read(&src, into: l, deadline: deadline)
        }
        return l
    }
}
