import Darwin

/// Archive formats Peep lists (by file name).
public enum ArchiveKind: Sendable {
    case zip, tar, tarGzip, tarXz

    public var label: String {
        switch self {
        case .zip: "ZIP archive"
        case .tar: "tar archive"
        case .tarGzip: "gzip-compressed tar archive"
        case .tarXz: "xz-compressed tar archive"
        }
    }

    /// ZIP containers that are not documents with previews of their own (Office files and
    /// EPUB are ZIPs too, but Apple's previewers render those).
    static let zipExtensions: Set<String> = [
        "zip", "jar", "war", "ear", "aar", "whl", "egg", "apk", "aab", "ipa", "xpi", "vsix", "nupkg",
        "crate", "kmz", "sketch", "mcpack", "cbz",
    ]

    /// Every extension to register with Quick Look (`peep-dev types`).
    public static let registeredExtensions: [String] =
        zipExtensions.sorted() + ["tar", "tgz", "taz", "txz", "gz", "xz"]

    /// Kind for a file name, or nil. ".tar.gz" needs the double suffix; a lone ".gz" is a
    /// compressed single file, not an archive (see `SingleFileCompression`).
    public static func of(fileName: String) -> ArchiveKind? {
        let n = fileName.lowercased()
        guard let dot = n.lastIndex(of: ".") else { return nil }
        let ext = n[n.index(after: dot)...]
        if zipExtensions.contains(String(ext)) { return .zip }
        switch ext {
        case "tar": return .tar
        case "tgz", "taz": return .tarGzip
        case "txz": return .tarXz
        case "gz": return n.hasSuffix(".tar.gz") ? .tarGzip : nil
        case "xz": return n.hasSuffix(".tar.xz") ? .tarXz : nil
        default: return nil
        }
    }
}

/// Entries of an archive in struct-of-arrays form; names live in one byte buffer.
public final class ArchiveListing: @unchecked Sendable {
    public let kind: ArchiveKind
    var names: [UInt8] = []
    var nameEnd: [UInt32] = []   // entry i's name: names[nameEnd[i-1] ..< nameEnd[i]]
    var size: [UInt64] = []
    var time: [Int64] = []       // local time packed as YYYYMMDDhhmm, 0 = unknown
    var flags: [UInt8] = []      // see Flag
    /// Bytes on disk (the archive file).
    public var fileSize: UInt64 = 0
    /// False when reading stopped at the time budget (the rest is listed in the background).
    public var complete = true
    public var error: String?
    /// Placeholder for a listing still being rendered: its entry count.
    public var pendingEntries = 0

    enum Flag {
        static let dir: UInt8 = 1, link: UInt8 = 2, encrypted: UInt8 = 4
    }

    public var count: Int { nameEnd.count }
    /// Bytes of all names (rendering is linear in them).
    public var nameBytes: Int { names.count }

    public init(kind: ArchiveKind) { self.kind = kind }

    // MARK: - Limits
    //
    // Headers declare whatever they like, and a crafted archive compresses ~1000:1 (a tar.gz
    // of empty headers, a ZIP of 64 KB names nesting thousands of folders). Without limits a
    // listing grew to gigabytes in the preview process. Real archives stay far below them
    // (big node_modules tarballs: ~150k entries); a listing that reaches one says so in its
    // summary line. Instance properties so tests can use small ones.

    /// Entries listed at most.
    public var maxEntries = 1_000_000
    /// Name bytes kept at most (all entries). Also keeps `nameEnd` (UInt32) in range.
    public var maxNameBytes = 64 << 20
    /// Lines rendered at most (files plus folders, which paths can imply in any number).
    public var maxLines = 2_000_000
    /// Bytes of rendered listing at most, plus one line (~60 bytes a line for real archives,
    /// counted as up to ~100 here). Also keeps the text's UInt32 offsets in range.
    public var maxBytes = 128 << 20

    /// Whether another entry with an `n`-byte name fits; when not, the listing stops there
    /// and says so.
    func hasRoom(forName n: Int) -> Bool {
        if count < maxEntries && n <= maxNameBytes - names.count { return true }
        if error == nil { error = "first \(ArchiveListing.grouped(count)) entries" }
        return false
    }

    func add(name: UnsafeBufferPointer<UInt8>, size s: UInt64, time t: Int64, flags f: UInt8) {
        names.append(contentsOf: name)
        nameEnd.append(UInt32(truncatingIfNeeded: names.count))
        size.append(s)
        time.append(t)
        flags.append(f)
    }

    // MARK: - Times

    /// Packs a DOS date/time (ZIP; already local time) as YYYYMMDDhhmm.
    static func packDOS(date: UInt16, time: UInt16) -> Int64 {
        if date == 0 { return 0 }
        let y = Int64(date >> 9) + 1980, mo = Int64((date >> 5) & 15), d = Int64(date & 31)
        let h = Int64(time >> 11), mi = Int64((time >> 5) & 63)
        return ((((y * 100 + mo) * 100 + d) * 100 + h) * 100) + mi
    }

    /// UTC-day -> local offset cache: one localtime_r per distinct day instead of per entry.
    private var offsetDay = Int64.min
    private var offsetSeconds: Int64 = 0

    /// Last second of year 9999 (UTC): later times are damage, and shown as unknown (the
    /// date arithmetic below overflowed on huge base-256 or pax mtimes).
    static let maxUnixSeconds: Int64 = 253_402_300_799

    /// Packs Unix seconds (tar) as local YYYYMMDDhhmm. Arithmetic civil date (Hinnant) with
    /// the local UTC offset looked up once per day.
    func packUnix(_ secs: Int64) -> Int64 {
        if secs <= 0 || secs > ArchiveListing.maxUnixSeconds { return 0 }
        let day = secs / 86_400
        if day != offsetDay {
            var t = time_t(secs)
            var tmv = tm()
            localtime_r(&t, &tmv)
            offsetDay = day
            offsetSeconds = Int64(tmv.tm_gmtoff)
        }
        let local = secs + offsetSeconds
        let z = local / 86_400 + 719_468
        let rem = local % 86_400
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        let y = yoe + era * 400 + (m <= 2 ? 1 : 0)
        return ((((y * 100 + m) * 100 + d) * 100 + rem / 3600) * 100) + (rem % 3600) / 60
    }

    // MARK: - Rendering

    /// Folder tree built from the entries: folders implied by paths exist even without an
    /// entry of their own. Arrays indexed by folder id; folder 0 is the root.
    private struct Tree {
        var nameS: [Int32] = [0], nameE: [Int32] = [0]   // component range in `names`
        var entry: [Int32] = [-1]                        // explicit folder entry, or -1
        var dirs: [[Int32]] = [[]]                       // child folders
        var files: [[(entry: Int32, s: Int32, e: Int32)]] = [[]]
    }

    /// Builds the tree. Consecutive entries nearly always share their parent folders, so each
    /// entry is first matched against the previous entry's folder chain (byte compares); a
    /// hash lookup only happens for a folder not on that chain. Linear in the name bytes.
    /// Stops (`cut`) at `maxNodes` folders + files, or once their lines could take
    /// `maxBytes` (a 64 KB name can imply 32k folders, each a line indented 256 columns).
    /// Bounding the text here, not while writing it, keeps the tree no bigger than what is
    /// shown (it was built for 2 million lines when the text had room for 470k), and the
    /// render loop free of checks (one per line cost 1.5%).
    private func buildTree(_ p: UnsafePointer<UInt8>, maxNodes: Int, maxBytes: Int) -> (tree: Tree, cut: Bool) {
        var t = Tree()
        var nodes = 0, bytes = 0
        /// The most `render` can write for a line: columns (29), indentation (at most 256),
        /// the name (2 bytes per byte when transcoded from Latin-1), "/", "  (encrypted)",
        /// newline.
        @inline(__always) func lineBytes(_ depth: Int, _ c: (Int, Int)) -> Int {
            44 + min(2 + 2 * depth, 256) + 2 * (c.1 - c.0)
        }
        var index: [UInt64: [Int32]] = [:]   // hash(parent, name) -> folder ids
        var chain: [(s: Int, e: Int, id: Int32)] = []
        var comps: [(Int, Int)] = []
        @inline(__always) func same(_ a: (Int, Int), _ b: (Int, Int)) -> Bool {
            a.1 - a.0 == b.1 - b.0 && memcmp(p + a.0, p + b.0, a.1 - a.0) == 0
        }
        func folder(_ parent: Int32, _ s: Int, _ e: Int) -> Int32 {
            var h: UInt64 = 0xCBF2_9CE4_8422_2325 ^ UInt64(UInt32(bitPattern: parent))
            for k in s..<e { h = (h ^ UInt64(p[k])) &* 0x100_0000_01B3 }
            if let ids = index[h] {
                for id in ids where same((Int(t.nameS[Int(id)]), Int(t.nameE[Int(id)])), (s, e)) { return id }
            }
            let id = Int32(t.nameS.count)
            t.nameS.append(Int32(s)); t.nameE.append(Int32(e)); t.entry.append(-1)
            t.dirs.append([]); t.files.append([])
            t.dirs[Int(parent)].append(id)
            index[h, default: []].append(id)
            return id
        }
        var start = 0
        for i in 0..<count {
            var s = start, e = Int(nameEnd[i])
            start = e
            var dir = flags[i] & Flag.dir != 0
            while e > s && p[e - 1] == 0x2F { e -= 1; dir = true }
            // Components, dropping empty ones and "." (leading "./", "a//b").
            comps.removeAll(keepingCapacity: true)
            while s < e {
                var j = s
                while j < e && p[j] != 0x2F { j += 1 }
                if j > s && !(j - s == 1 && p[s] == 0x2E) { comps.append((s, j)) }
                s = j + 1
            }
            if comps.isEmpty { continue }
            // macOS metadata, noise in a listing: resource-fork folders in ZIPs (__MACOSX/) and
            // AppleDouble files ("._name", extended attributes) in tarballs made on a Mac.
            if comps[0].1 - comps[0].0 == 8 && memcmp(p + comps[0].0, "__MACOSX", 8) == 0 { continue }
            if !dir, let last = comps.last, last.1 - last.0 > 2 && p[last.0] == 0x2E && p[last.0 + 1] == 0x5F { continue }
            let dirCount = dir ? comps.count : comps.count - 1
            var parent: Int32 = 0
            var j = 0
            while j < dirCount && j < chain.count && same((chain[j].s, chain[j].e), comps[j]) { parent = chain[j].id; j += 1 }
            chain.removeLast(chain.count - j)
            while j < dirCount {
                if nodes >= maxNodes || bytes >= maxBytes { return (t, true) }
                let before = t.nameS.count
                parent = folder(parent, comps[j].0, comps[j].1)
                if t.nameS.count != before { nodes += 1; bytes += lineBytes(j, comps[j]) }
                chain.append((comps[j].0, comps[j].1, parent))
                j += 1
            }
            if dir {
                if t.entry[Int(parent)] < 0 { t.entry[Int(parent)] = Int32(i) }
            } else {
                if nodes >= maxNodes || bytes >= maxBytes { return (t, true) }
                let c = comps[comps.count - 1]
                nodes += 1
                bytes += lineBytes(comps.count - 1, c)
                t.files[Int(parent)].append((Int32(i), Int32(c.0), Int32(c.1)))
            }
        }
        return (t, false)
    }

    /// Case-insensitive (ASCII) name order, then bytewise.
    @inline(__always)
    private static func less(_ p: UnsafePointer<UInt8>, _ a0: Int, _ a1: Int, _ b0: Int, _ b1: Int) -> Bool {
        var x = a0, y = b0, raw = 0
        while x < a1 && y < b1 {
            var c = p[x], d = p[y]
            if raw == 0 && c != d { raw = c < d ? -1 : 1 }
            if c >= 0x41 && c <= 0x5A { c |= 0x20 }
            if d >= 0x41 && d <= 0x5A { d |= 0x20 }
            if c != d { return c < d }
            x += 1; y += 1
        }
        if a1 - a0 != b1 - b0 { return a1 - a0 < b1 - b0 }
        return raw < 0
    }

    /// The listing as text plus syntax tokens: a summary, then a tree (folders first,
    /// case-insensitive), sizes and dates in muted columns. Folders implied by file paths
    /// are shown even when the archive has no entry for them. At most `maxLines` lines and
    /// about `maxBytes` bytes (the summary says when the listing was shortened).
    ///
    /// `lineBudget`: nil instead when the tree has more lines than that, found before any
    /// text is made (implied folders make the line count unknowable from the entry count);
    /// the caller then renders in the background.
    public func render(title: String, lineBudget: Int = .max) -> (TextBuffer, TokenStream)? {
        var body = ByteOutput(capacity: names.count + count * 40 + 256)
        var spans: [(Int32, Int32, TokenKind)] = []
        spans.reserveCapacity(count * 2)
        var files = 0, folders = 0
        var total: UInt64 = 0
        var shortened = false
        let sizeWidth = 9, dateWidth = 16

        let overBudget = names.withUnsafeBufferPointer { nb -> Bool in
            guard let p = nb.baseAddress else { return false }
            let (tree, cut) = buildTree(p, maxNodes: min(lineBudget, maxLines), maxBytes: maxBytes)
            if cut && lineBudget < maxLines { return true }
            shortened = cut
            var t = tree
            for d in 0..<t.dirs.count {
                t.dirs[d].sort { ArchiveListing.less(p, Int(t.nameS[Int($0)]), Int(t.nameE[Int($0)]), Int(t.nameS[Int($1)]), Int(t.nameE[Int($1)])) }
                t.files[d].sort { ArchiveListing.less(p, Int($0.s), Int($0.e), Int($1.s), Int($1.e)) }
            }
            /// A path component, transcoded from Latin-1 when it isn't valid UTF-8 (old ZIPs;
            /// always valid output). Control characters become "?" (a newline in a name must
            /// not break the listing), C1 controls from the fallback too.
            func appendName(_ s: Int, _ e: Int) {
                let o = body.count
                if ArchiveListing.validUTF8(p, s, e) {
                    body.bytes(p + s, e - s)
                } else {
                    for k in s..<e {
                        let c = p[k]
                        if c < 0x80 { body.byte(c) }
                        else if c < 0xA0 { body.byte(0x3F) }
                        else { body.byte(0xC0 | (c >> 6)); body.byte(0x80 | (c & 0x3F)) }
                    }
                }
                for k in o..<body.count where body.base[k] < 0x20 || body.base[k] == 0x7F { body.base[k] = 0x3F }
            }
            func line(depth: Int, s: Int, e: Int, entry: Int, isDir: Bool) {
                let c0 = body.count
                // Columns written as bytes (String interpolation per line was a quarter of
                // the render time on a 150k-entry archive).
                body.reserve(sizeWidth + 2 + dateWidth)
                if !isDir && entry >= 0 {
                    var tmp: (UInt64, UInt64) = (0, 0)
                    let n = withUnsafeMutableBytes(of: &tmp) { ArchiveListing.sizeBytes(size[entry], $0.baseAddress!.assumingMemoryBound(to: UInt8.self)) }
                    body.spaces(sizeWidth - n)
                    withUnsafeBytes(of: &tmp) { body.bytes($0.baseAddress!.assumingMemoryBound(to: UInt8.self), n) }
                } else {
                    body.spaces(sizeWidth)
                }
                body.spaces(2)
                if entry >= 0 && time[entry] != 0 {
                    ArchiveListing.dateBytes(time[entry], body.base + body.count)
                    body.count += dateWidth
                } else {
                    body.spaces(dateWidth)
                }
                spans.append((Int32(c0), Int32(body.count), .comment))
                body.spaces(2 + 2 * depth)
                let n0 = body.count
                appendName(s, e)
                if isDir { body.byte(0x2F) }
                let f = entry >= 0 ? flags[entry] : 0
                if isDir { spans.append((Int32(n0), Int32(body.count), .type)) }
                else if f & Flag.link != 0 { spans.append((Int32(n0), Int32(body.count), .link)) }
                if f & Flag.encrypted != 0 {
                    let t0 = body.count
                    body.string("  (encrypted)")
                    spans.append((Int32(t0), Int32(body.count), .deleted))
                }
                body.byte(0x0A)
            }
            // Depth-first with an explicit stack (archives can nest deeply). The tree's size
            // bounds the text (`buildTree`).
            var stack: [(dir: Int32, depth: Int, next: Int)] = [(0, -1, 0)]
            while let top = stack.last {
                let d = Int(top.dir)
                if top.next < t.dirs[d].count {
                    stack[stack.count - 1].next += 1
                    let c = t.dirs[d][top.next]
                    line(depth: top.depth + 1, s: Int(t.nameS[Int(c)]), e: Int(t.nameE[Int(c)]), entry: Int(t.entry[Int(c)]), isDir: true)
                    folders += 1
                    stack.append((c, top.depth + 1, 0))
                    continue
                }
                for f in t.files[d] {
                    line(depth: top.depth + 1, s: Int(f.s), e: Int(f.e), entry: Int(f.entry), isDir: false)
                    files += 1
                    total &+= size[Int(f.entry)]
                }
                stack.removeLast()
            }
            return false
        }
        if overBudget {
            body.base.deallocate()
            return nil
        }

        // Summary, then the tree.
        var out = ByteOutput(capacity: body.count + 512)
        let tokens = TokenStream(expectedBytes: body.count + 512)
        out.string(title)
        tokens.add(0, out.count, .heading)
        out.byte(0x0A)
        let s0 = out.count
        var summary = pendingEntries > 0
            ? "\(kind.label) · \(ArchiveListing.grouped(pendingEntries)) entries"
            : "\(kind.label) · \(ArchiveListing.counted(files, "file")) · \(ArchiveListing.counted(folders, "folder"))"
        if total > 0 {
            summary += " · \(ArchiveListing.sizeString(total)) unpacked"
            if fileSize > 0 { summary += ", \(ArchiveListing.sizeString(fileSize)) on disk" }
        }
        if !complete { summary += " · listing…" }
        if shortened { summary += " · first \(ArchiveListing.grouped(files + folders)) lines shown" }
        if let error { summary += " · \(error)" }
        out.string(summary)
        tokens.add(s0, out.count, .meta)
        out.byte(0x0A)
        out.byte(0x0A)
        let off = out.count
        out.bytes(body.base, body.count)
        for (a, b, k) in spans { tokens.add(off + Int(a), off + Int(b), k) }
        body.base.deallocate()
        tokens.finish(out.count)
        return (out.finish(), tokens)
    }

    /// Scalar UTF-8 check for a short range, by the decoder's strict rule (no overlongs,
    /// surrogates or code points past U+10FFFF: the renderer relies on valid UTF-8, and a
    /// laxer check here let such names through to it). Names live in a plain array, not a
    /// padded buffer: the length a lead byte announces is bounds-checked before
    /// `sequenceLength` reads that far.
    static func validUTF8(_ p: UnsafePointer<UInt8>, _ s: Int, _ e: Int) -> Bool {
        var i = s
        while i < e {
            let c = p[i]
            if c < 0x80 { i += 1; continue }
            let need = c >= 0xF0 ? 4 : c >= 0xE0 ? 3 : 2
            if need > e - i || Decoder.sequenceLength(p + i) != need { return false }
            i += need
        }
        return true
    }

    static func counted(_ n: Int, _ noun: String) -> String {
        "\(ArchiveListing.grouped(n)) \(noun)\(n == 1 ? "" : "s")"
    }

    static func grouped(_ n: Int) -> String {
        let s = String(n)
        if n < 1000 { return s }
        var out = ""
        for (i, ch) in s.enumerated() {
            if i > 0 && (s.count - i) % 3 == 0 { out.append(",") }
            out.append(ch)
        }
        return out
    }

    /// Finder-style decimal units: "999 B", "4.2 KB", "12.0 MB".
    static func sizeString(_ n: UInt64) -> String {
        if n < 1000 { return "\(n) B" }
        let units = ["KB", "MB", "GB", "TB", "PB"]
        var v = Double(n) / 1000
        var u = 0
        while v >= 999.95 && u < units.count - 1 { v /= 1000; u += 1 }
        let tenths = Int((v * 10).rounded())
        return "\(tenths / 10).\(tenths % 10) \(units[u])"
    }

    /// `sizeString` as bytes (at most 10); returns the length.
    static func sizeBytes(_ n: UInt64, _ o: UnsafeMutablePointer<UInt8>) -> Int {
        var k = 0
        func int(_ v: UInt64) {
            var x = v, len = 0
            repeat { len += 1; x /= 10 } while x > 0
            x = v
            for i in stride(from: len - 1, through: 0, by: -1) { o[k + i] = UInt8(48 + x % 10); x /= 10 }
            k += len
        }
        if n < 1000 {
            int(n); o[k] = 0x20; o[k + 1] = 0x42; return k + 2   // " B"
        }
        let units: [(UInt8, UInt8)] = [(0x4B, 0x42), (0x4D, 0x42), (0x47, 0x42), (0x54, 0x42), (0x50, 0x42)]
        // Rounded tenths of n / div, split so nothing overflows (n * 10 did for sizes from
        // ~1.8e18, which archive headers can claim). n / div * 10 <= 1.9e17 (div >= 1000),
        // n % div * 10 < 1e16 (div <= 1e15).
        @inline(__always) func tenthsOf(_ div: UInt64) -> UInt64 { n / div * 10 + (n % div * 10 + div / 2) / div }
        var div: UInt64 = 1000, u = 0
        while u < 4 && tenthsOf(div) >= 10_000 { div *= 1000; u += 1 }
        let tenths = tenthsOf(div)
        int(tenths / 10)
        o[k] = 0x2E; o[k + 1] = UInt8(48 + tenths % 10); o[k + 2] = 0x20
        o[k + 3] = units[u].0; o[k + 4] = units[u].1
        return k + 5
    }

    /// "YYYY-MM-DD hh:mm" (16 bytes) from the packed form (non-negative: `packDOS` and
    /// `packUnix` produce nothing else; each field is two digits by construction).
    static func dateBytes(_ packed: Int64, _ o: UnsafeMutablePointer<UInt8>) {
        var v = max(0, packed)
        let mi = v % 100; v /= 100
        let h = v % 100; v /= 100
        let d = v % 100; v /= 100
        let mo = v % 100; v /= 100
        let y = min(9999, v)
        o[0] = UInt8(48 + y / 1000); o[1] = UInt8(48 + y / 100 % 10); o[2] = UInt8(48 + y / 10 % 10); o[3] = UInt8(48 + y % 10)
        o[4] = 0x2D; o[5] = UInt8(48 + mo / 10); o[6] = UInt8(48 + mo % 10)
        o[7] = 0x2D; o[8] = UInt8(48 + d / 10); o[9] = UInt8(48 + d % 10)
        o[10] = 0x20; o[11] = UInt8(48 + h / 10); o[12] = UInt8(48 + h % 10)
        o[13] = 0x3A; o[14] = UInt8(48 + mi / 10); o[15] = UInt8(48 + mi % 10)
    }
}
