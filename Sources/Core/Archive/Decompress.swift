import Compression
import Darwin

/// Sequential bytes from a file, raw or decompressed.
protocol ByteSource {
    /// Reads up to `n` bytes (fewer only at the end). Returns the count.
    mutating func read(_ dst: UnsafeMutablePointer<UInt8>, _ n: Int) -> Int
    /// Skips `n` bytes; false if the data ended first.
    mutating func skip(_ n: Int) -> Bool
    /// The data ended early because a deadline passed or the reader was cancelled, not
    /// because there was no more.
    var cutShort: Bool { get }
}

/// An uncompressed file: skipping is free (`pread` at a moved offset).
struct FileSource: ByteSource {
    let fd: Int32
    let size: Int
    var offset = 0
    var cutShort: Bool { false }

    mutating func read(_ dst: UnsafeMutablePointer<UInt8>, _ n: Int) -> Int {
        var got = 0
        while got < n {
            let r = pread(fd, dst + got, n - got, off_t(offset + got))
            if r < 0 && errno == EINTR { continue }
            if r <= 0 { break }
            got += r
        }
        offset += got
        return got
    }

    mutating func skip(_ n: Int) -> Bool {
        guard n <= size - offset else { offset = size; return false }   // (no overflowing sum)
        offset += n
        return true
    }
}

/// gzip or xz, decoded as a stream with Apple's Compression framework (zlib's raw DEFLATE
/// after the gzip header, or LZMA's xz container). Skipping still has to decode.
///
/// gzip files can hold several members back to back (`cat a.gz b.gz` is valid gzip; so are
/// BGZF files, 64 KB per member): each is decoded in turn. The decoder reads ahead of what
/// it decodes, so where a member's compressed data ends isn't known: see `nextMember`.
final class DecompressSource: ByteSource {
    enum Format { case gzip, xz }

    private let fd: Int32
    private let fileSize: Int
    private var fileOffset: Int
    private let format: Format
    private let stream: UnsafeMutablePointer<compression_stream>
    private let input: UnsafeMutablePointer<UInt8>
    private let output: UnsafeMutablePointer<UInt8>
    private static let chunk = 1 << 20
    private var outPos = 0, outLen = 0
    private var inputDone = false, streamDone = false
    /// `input` holds the file's bytes `bufStart ..< fileOffset`; the decoder was given them up
    /// to `fed`, in slices of `feed` bytes.
    private var bufStart: Int
    private var fed: Int
    /// The decoder copies up to 64 KB of what it is given into its own buffer: a member is
    /// given small slices at first (doubling), so a tiny one costs ~2 µs, not a 64 KB copy.
    private var feed = chunk
    /// Original file name stored in a gzip header, if any.
    private(set) var storedName: String?
    /// Current gzip member: where its compressed data starts, its output so far, whether
    /// its end was reached.
    private var memberStart: Int
    private var memberOut: UInt64 = 0
    private var memberEnded = false
    /// Members so far, and output of all of them.
    private var members = 1
    private var totalOut: UInt64 = 0
    /// Checked between gzip members (each costs a scan and a decoder reset, ~2 µs: a crafted
    /// file of millions of empty 20-byte members decodes nothing for seconds otherwise).
    /// Time and size budgets elsewhere are counted in output, which such a file never makes.
    /// `cancelled` is also checked per block of output.
    var deadline: UInt64 = 0
    var cancelled: (() -> Bool)?
    private(set) var cutShort = false

    private var streamReady = false

    init?(fd: Int32, size: Int, format: Format) {
        // Validate before allocating: a failed init of a class still runs deinit once all
        // stored properties are set (an early cleanup here was a double free).
        var start = 0
        var name: String?
        if format == .gzip {
            guard size >= 18 else { return nil }
            var h = [UInt8](repeating: 0, count: min(size, 64 << 10))
            let n = h.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, 0) }
            guard let (s, nm) = h.withUnsafeBufferPointer({ DecompressSource.gzipHeader($0.baseAddress!, max(0, n)) }) else { return nil }
            start = s
            name = nm
        }
        self.fd = fd
        fileSize = size
        fileOffset = start
        bufStart = start
        fed = start
        memberStart = start
        self.format = format
        storedName = name
        stream = .allocate(capacity: 1)
        input = .allocate(capacity: DecompressSource.chunk)
        output = .allocate(capacity: DecompressSource.chunk)
        let algo = format == .gzip ? COMPRESSION_ZLIB : COMPRESSION_LZMA
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, algo) == COMPRESSION_STATUS_OK else { return nil }
        streamReady = true
        stream.pointee.src_size = 0
    }

    deinit {
        if streamReady { compression_stream_destroy(stream) }
        stream.deallocate()
        input.deallocate()
        output.deallocate()
    }

    /// A gzip member header (RFC 1952) at `h[0..<n]`: its length (where the DEFLATE data
    /// starts) and stored name; nil if it isn't one or doesn't end within `n`. The FEXTRA
    /// length is the file's word: checked against `n` before anything is read past it.
    static func gzipHeader(_ h: UnsafePointer<UInt8>, _ n: Int) -> (Int, String?)? {
        guard n >= 18, h[0] == 0x1F, h[1] == 0x8B, h[2] == 8 else { return nil }
        let flags = h[3]
        var i = 10
        if flags & 4 != 0 {
            guard i + 2 <= n else { return nil }
            i += 2 + Int(h[i]) + Int(h[i + 1]) << 8
            guard i <= n else { return nil }
        }
        var name: String?
        if flags & 8 != 0 {
            let s = i
            while i < n && h[i] != 0 { i += 1 }
            name = String(decoding: UnsafeBufferPointer(start: h + s, count: i - s), as: UTF8.self)
            i += 1
        }
        if flags & 16 != 0 { while i < n && h[i] != 0 { i += 1 }; i += 1 }
        if flags & 2 != 0 { i += 2 }
        return i < n ? (i, name) : nil
    }

    /// How far past a member's end the decoder may already have read: it keeps a 64 KB
    /// input buffer on macOS 27 (measured: 65,516 bytes past the end of a small member), with
    /// a margin for other versions. A larger read-ahead would only make later members missed,
    /// as before members were supported.
    static let readAhead = 256 << 10

    /// Starts the next gzip member, if one follows the member that just ended.
    ///
    /// The decoder takes input in chunks and reads ahead, so the member's end is somewhere in
    /// the last `readAhead` bytes it took. The next header is found there by its magic
    /// (1F 8B 08, reserved flag bits clear) right after the member's trailer, whose last 4
    /// bytes are its output size mod 2^32: 56 bits that compressed data matches by chance
    /// about once in 2^56 positions. Nothing found: the file ends (or trailing garbage).
    ///
    /// Works in the input buffer when it holds the bytes (members smaller than a read: the
    /// next member continues from the buffer), else reads them.
    private func nextMember() -> Bool {
        memberEnded = false
        totalOut &+= memberOut
        if (deadline != 0 && nanotime() > deadline) || cancelled?() == true { cutShort = true; return false }
        // More than a member per KB of output (past the first thousand) is crafted, not
        // BGZF (64 KB per member) or concatenated files: the data ends here.
        if members >= 1024 && UInt64(members) > totalOut >> 10 { return false }
        let taken = fed - stream.pointee.src_size
        // Header position q: the DEFLATE end (>= 2 bytes into the member) plus the 8-byte
        // trailer; a whole member is at least 20 bytes.
        let lo = max(memberStart + 2 + 8, taken - DecompressSource.readAhead)
        let hi = min(taken + 8, fileSize - 20)
        guard lo <= hi else { return false }
        // Window: ISIZE of a header at lo through the magic of a header at hi.
        if lo - 4 < bufStart || hi + 4 > fileOffset {
            let len = hi + 4 - (lo - 4)   // <= readAhead + 16: fits the buffer
            guard ZipReader.preadAll(fd, input, len, offset: lo - 4) else { return false }
            bufStart = lo - 4
            fileOffset = bufStart + len
        }
        let w = input, b = bufStart   // w[x - b]: the byte at file offset x
        let size = UInt32(truncatingIfNeeded: memberOut)
        var q = -1
        var k = lo - b
        while k <= hi - b {
            guard let f = memchr(w + k, 0x1F, hi - b - k + 1) else { break }
            k = w.distance(to: f.assumingMemoryBound(to: UInt8.self))
            if w[k + 1] == 0x8B && w[k + 2] == 8 && w[k + 3] & 0xE0 == 0
                && (UInt32(w[k - 4]) | UInt32(w[k - 3]) << 8 | UInt32(w[k - 2]) << 16 | UInt32(w[k - 1]) << 24) == size {
                q = b + k
                break
            }
            k += 1
        }
        guard q >= 0 else { return false }
        var header = DecompressSource.gzipHeader(w + (q - b), fileOffset - q)
        if header == nil {   // doesn't end in the buffer (or isn't one): read it whole
            let n = min(64 << 10, fileSize - q)
            guard ZipReader.preadAll(fd, input, n, offset: q) else { return false }
            bufStart = q
            fileOffset = q + n
            header = DecompressSource.gzipHeader(input, n)
        }
        guard let (h, _) = header else { return false }
        compression_stream_destroy(stream)
        streamReady = false
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return false }
        streamReady = true
        // The buffer's bytes after the header are the new member's (gzipHeader ends before
        // the end of what it was given: at least one byte), fed from there.
        memberStart = q + h
        fed = memberStart
        feed = 512
        stream.pointee.src_size = 0
        memberOut = 0
        members += 1
        inputDone = false
        return true
    }

    /// Decodes the next block of output; false when the stream ended (or was cancelled: a
    /// tar listing skips huge members a megabyte at a time, here).
    private func fill() -> Bool {
        outPos = 0
        outLen = 0
        if let c = cancelled, c() { cutShort = true; streamDone = true; return false }
        while outLen == 0 {
            if streamDone { return false }
            if memberEnded && !nextMember() { streamDone = true; return false }
            if stream.pointee.src_size == 0 && fed == fileOffset && !inputDone {
                let want = min(DecompressSource.chunk, fileSize - fileOffset)
                let r = want > 0 ? pread(fd, input, want, off_t(fileOffset)) : 0
                if r <= 0 { inputDone = true } else {
                    bufStart = fileOffset
                    fileOffset += r
                }
            }
            if stream.pointee.src_size == 0 && fed < fileOffset {
                let k = min(feed, fileOffset - fed)
                stream.pointee.src_ptr = UnsafePointer(input + (fed - bufStart))
                stream.pointee.src_size = k
                fed += k
                feed = min(feed * 2, DecompressSource.chunk)
            }
            stream.pointee.dst_ptr = output
            stream.pointee.dst_size = DecompressSource.chunk
            let flags = inputDone ? Int32(bitPattern: COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            let st = compression_stream_process(stream, flags)
            outLen = DecompressSource.chunk - stream.pointee.dst_size
            memberOut &+= UInt64(outLen)
            if st == COMPRESSION_STATUS_ERROR { streamDone = true; break }
            if st == COMPRESSION_STATUS_END {
                // gzip: the next member (if any) starts on the next call, after this output.
                if format == .gzip { memberEnded = true } else { streamDone = true; break }
                continue
            }
            if inputDone && outLen == 0 { streamDone = true; break }
        }
        return outLen > 0
    }

    func read(_ dst: UnsafeMutablePointer<UInt8>, _ n: Int) -> Int {
        var got = 0
        while got < n {
            if outPos >= outLen && !fill() { break }
            let k = min(n - got, outLen - outPos)
            memcpy(dst + got, output + outPos, k)
            outPos += k
            got += k
        }
        return got
    }

    func skip(_ n: Int) -> Bool {
        var left = n
        while left > 0 {
            if outPos >= outLen && !fill() { return false }
            let k = min(left, outLen - outPos)
            outPos += k
            left -= k
        }
        return true
    }
}

/// A single compressed file (".log.gz", "data.json.xz"): decompressed up to a limit and then
/// previewed like the file it contains.
public enum SingleFileCompression {
    /// "x.json.gz" -> ("x.json", .gzip); nil for other names (and for .tar.gz, an archive).
    public static func inner(of fileName: String) -> (String, Bool)? {
        let n = fileName.lowercased()
        if n.hasSuffix(".tar.gz") || n.hasSuffix(".tar.xz") { return nil }
        if n.hasSuffix(".gz") { return (String(fileName.dropLast(3)), true) }
        if n.hasSuffix(".xz") { return (String(fileName.dropLast(3)), false) }
        return nil
    }

    /// Decompresses up to `limit` bytes. Returns the bytes, whether more data followed, and
    /// the name stored in the gzip header (if any). Output cut short (limit, time budget)
    /// ends on a UTF-8 character boundary: see `FileLoader.load`.
    public static func load(path: String, gzip: Bool, limit: Int, budgetNanos: UInt64) -> (TextBuffer, Bool, String?)? {
        let deadline = nanotime() + budgetNanos
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        if fd < 0 { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0,
              let src = DecompressSource(fd: fd, size: max(0, Int(st.st_size)), format: gzip ? .gzip : .xz) else { return nil }
        src.deadline = deadline
        let size = max(0, Int(st.st_size))   // (a sparse file can claim any size: no `* 4` overflow)
        var out = ByteOutput(capacity: size > limit / 4 ? limit : max(64 << 10, size * 4))
        var more = false
        while true {
            out.reserve(1 << 20)
            let want = min(1 << 20, limit - out.count)
            if want <= 0 || nanotime() > deadline { more = src.skip(1) || src.cutShort; break }
            let r = src.read(out.base + out.count, want)
            out.count += r
            if r < want { more = src.cutShort; break }
        }
        if more { out.count = Decoder.completeEnd(out.base, out.count) }
        return (out.finish(), more, src.storedName)
    }
}
