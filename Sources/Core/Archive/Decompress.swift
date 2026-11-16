import Compression
import Darwin

/// Sequential bytes from a file, raw or decompressed.
protocol ByteSource {
    /// Reads up to `n` bytes (fewer only at the end). Returns the count.
    mutating func read(_ dst: UnsafeMutablePointer<UInt8>, _ n: Int) -> Int
    /// Skips `n` bytes; false if the data ended first.
    mutating func skip(_ n: Int) -> Bool
}

/// An uncompressed file: skipping is free (`pread` at a moved offset).
struct FileSource: ByteSource {
    let fd: Int32
    let size: Int
    var offset = 0

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
        offset += n
        return offset <= size
    }
}

/// gzip or xz, decoded as a stream with Apple's Compression framework (zlib's raw DEFLATE
/// after the gzip header, or LZMA's xz container). Skipping still has to decode.
final class DecompressSource: ByteSource {
    enum Format { case gzip, xz }

    private let fd: Int32
    private let fileSize: Int
    private var fileOffset: Int
    private let stream: UnsafeMutablePointer<compression_stream>
    private let input: UnsafeMutablePointer<UInt8>
    private let output: UnsafeMutablePointer<UInt8>
    private static let chunk = 1 << 20
    private var outPos = 0, outLen = 0
    private var inputDone = false, streamDone = false
    /// Original file name stored in a gzip header, if any.
    private(set) var storedName: String?

    private var streamReady = false

    init?(fd: Int32, size: Int, format: Format) {
        // Validate before allocating: a failed init of a class still runs deinit once all
        // stored properties are set (an early cleanup here was a double free).
        var start = 0
        var name: String?
        if format == .gzip {
            guard let (s, n) = DecompressSource.gzipHeader(fd: fd, size: size) else { return nil }
            start = s
            name = n
        }
        self.fd = fd
        fileSize = size
        fileOffset = start
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

    /// Start of the DEFLATE data and the stored name (RFC 1952 header).
    private static func gzipHeader(fd: Int32, size: Int) -> (Int, String?)? {
        var h = [UInt8](repeating: 0, count: min(size, 64 << 10))
        let n = h.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, 0) }
        guard n >= 18, h[0] == 0x1F, h[1] == 0x8B, h[2] == 8 else { return nil }
        let flags = h[3]
        var i = 10
        if flags & 4 != 0 { guard i + 2 <= n else { return nil }; i += 2 + Int(h[i]) + Int(h[i + 1]) << 8 }
        var name: String?
        if flags & 8 != 0 {
            let s = i
            while i < n && h[i] != 0 { i += 1 }
            name = String(decoding: h[s..<min(i, n)], as: UTF8.self)
            i += 1
        }
        if flags & 16 != 0 { while i < n && h[i] != 0 { i += 1 }; i += 1 }
        if flags & 2 != 0 { i += 2 }
        return i < n ? (i, name) : nil
    }

    /// Decodes the next block of output; false when the stream ended.
    private func fill() -> Bool {
        if streamDone { return false }
        outPos = 0
        outLen = 0
        while outLen == 0 {
            if stream.pointee.src_size == 0 && !inputDone {
                let want = min(DecompressSource.chunk, fileSize - fileOffset)
                let r = want > 0 ? pread(fd, input, want, off_t(fileOffset)) : 0
                if r <= 0 { inputDone = true } else {
                    fileOffset += r
                    stream.pointee.src_ptr = UnsafePointer(input)
                    stream.pointee.src_size = r
                }
            }
            stream.pointee.dst_ptr = output
            stream.pointee.dst_size = DecompressSource.chunk
            let flags = inputDone ? Int32(bitPattern: COMPRESSION_STREAM_FINALIZE.rawValue) : 0
            let st = compression_stream_process(stream, flags)
            outLen = DecompressSource.chunk - stream.pointee.dst_size
            if st == COMPRESSION_STATUS_END || st == COMPRESSION_STATUS_ERROR { streamDone = true; break }
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
    /// the name stored in the gzip header (if any).
    public static func load(path: String, gzip: Bool, limit: Int, budgetNanos: UInt64) -> (TextBuffer, Bool, String?)? {
        let deadline = nanotime() + budgetNanos
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        if fd < 0 { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0,
              let src = DecompressSource(fd: fd, size: Int(st.st_size), format: gzip ? .gzip : .xz) else { return nil }
        var out = ByteOutput(capacity: min(limit, max(64 << 10, Int(st.st_size) * 4)))
        var more = false
        while true {
            out.reserve(1 << 20)
            let want = min(1 << 20, limit - out.count)
            if want <= 0 || nanotime() > deadline { more = src.skip(1); break }
            let r = src.read(out.base + out.count, want)
            out.count += r
            if r < want { break }
        }
        return (out.finish(), more, src.storedName)
    }
}
