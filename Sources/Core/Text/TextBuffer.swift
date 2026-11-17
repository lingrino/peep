import Darwin

/// Immutable bytes in one heap block, followed by `padding` zero bytes.
///
/// The padding is load-bearing: SIMD kernels read whole 16/64-byte blocks and may run up to
/// `padding` bytes past `count` without a bounds check (they discard lanes past the end).
/// The byte at `count` is always 0, which scalar scanners use as a sentinel.
///
/// After `Decoder.decode` the bytes are always valid UTF-8 (no BOM).
public final class TextBuffer: @unchecked Sendable {
    public static let padding = 64

    public let base: UnsafeMutablePointer<UInt8>
    public let count: Int

    /// Takes ownership of `base`, which must have `count + padding` bytes allocated with
    /// `TextBuffer.allocate` and zeroed padding.
    init(owning base: UnsafeMutablePointer<UInt8>, count: Int) {
        self.base = base
        self.count = count
    }

    deinit { base.deallocate() }

    /// Allocates `count + padding` bytes, 128-byte aligned (an Apple Silicon cache line),
    /// with the padding zeroed. Contents of the first `count` bytes are uninitialized.
    static func allocate(_ count: Int) -> UnsafeMutablePointer<UInt8> {
        let raw = UnsafeMutableRawPointer.allocate(byteCount: count + padding, alignment: 128)
        (raw + count).initializeMemory(as: UInt8.self, repeating: 0, count: padding)
        return raw.assumingMemoryBound(to: UInt8.self)
    }

    public convenience init(copying bytes: UnsafeRawBufferPointer) {
        let p = TextBuffer.allocate(bytes.count)
        if let src = bytes.baseAddress { memcpy(p, src, bytes.count) }
        self.init(owning: p, count: bytes.count)
    }

    public convenience init(_ string: String) {
        var s = string
        let (p, n) = s.withUTF8 { u in
            let p = TextBuffer.allocate(u.count)
            if let src = u.baseAddress { memcpy(p, src, u.count) }
            return (p, u.count)
        }
        self.init(owning: p, count: n)
    }

    @inline(__always) public var bytes: UnsafeBufferPointer<UInt8> {
        UnsafeBufferPointer(start: base, count: count)
    }

    @inline(__always) public subscript(i: Int) -> UInt8 { base[i] }

    /// Decodes `[start, end)` as a Swift String (UTF-8; invalid sequences are repaired).
    public func string(_ start: Int, _ end: Int) -> String {
        String(decoding: UnsafeBufferPointer(start: base + start, count: max(0, end - start)), as: UTF8.self)
    }
}

public enum LoadError: Error {
    case open(Int32)
    case read(Int32)
}

public struct LoadedFile: Sendable {
    public let raw: TextBuffer
    /// File size on disk (may exceed `raw.count` when truncated).
    public let fileSize: Int
    /// Bytes skipped at the start (tail loads of logs).
    public var offset = 0
    public var truncated: Bool { fileSize > raw.count }
}

public enum FileLoader {
    /// Reads up to `limit` bytes of the file at `path` into a padded buffer.
    ///
    /// `read(2)` into our own buffer beats `mmap` here: we touch every byte anyway (decode +
    /// line index), we need the zeroed padding, and a page-cache memcpy runs at tens of GB/s.
    ///
    /// `tail`: when the file is larger than `limit`, read its *end* instead (logs), starting
    /// at the first line that begins within the last `limit` bytes.
    ///
    /// A load cut short starts and ends on a UTF-8 character boundary (for text that is
    /// UTF-8): the renderer relies on valid UTF-8, and a character cut in two at either end
    /// would not be. At most 3 bytes are dropped at each end.
    public static func load(path: String, limit: Int, tail: Bool = false) throws(LoadError) -> LoadedFile {
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        if fd < 0 { throw .open(errno) }
        defer { close(fd) }
        var st = stat()
        if fstat(fd, &st) != 0 { throw .open(errno) }
        let size = max(0, Int(st.st_size))
        var start = 0
        if tail && size > limit {
            start = size - limit
            // Begin at a line start: probe a little and skip the partial first line (or, with
            // no newline nearby, the rest of a character cut in two).
            var probe = [UInt8](repeating: 0, count: 64 << 10)
            let n = probe.withUnsafeMutableBytes { pread(fd, $0.baseAddress, $0.count, off_t(start)) }
            if n > 0 {
                if let nl = probe[0..<n].firstIndex(of: 0x0A) { start += nl + 1 }
                else { start += probe.withUnsafeBufferPointer { Decoder.continuationBytes($0.baseAddress!, n) } }
            }
        }
        let want = min(size - start, limit)
        let p = TextBuffer.allocate(want)
        var got = 0
        while got < want {
            let n = pread(fd, p + got, want - got, off_t(start + got))
            if n < 0 {
                if errno == EINTR { continue }
                p.deallocate()
                throw .read(errno)
            }
            if n == 0 { break }
            got += n
        }
        let end = start + got < size ? Decoder.completeEnd(p, got) : got   // cut short
        if end < want { (p + end).initialize(repeating: 0, count: TextBuffer.padding) }
        var f = LoadedFile(raw: TextBuffer(owning: p, count: end), fileSize: size)
        f.offset = start
        return f
    }
}
