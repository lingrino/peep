import Darwin

/// Growable byte output that becomes a `TextBuffer` (same allocation and padding contract),
/// for generated text: formatted JSON, archive listings.
struct ByteOutput {
    var base: UnsafeMutablePointer<UInt8>
    var count = 0
    var capacity: Int

    /// "\n" followed by spaces: a newline plus indentation is one memcpy.
    nonisolated(unsafe) static let indent: UnsafeMutablePointer<UInt8> = {
        let p = UnsafeMutablePointer<UInt8>.allocate(capacity: 257)
        p[0] = 0x0A
        (p + 1).initialize(repeating: 0x20, count: 256)
        return p
    }()

    init(capacity: Int) {
        self.capacity = max(64, capacity)
        base = TextBuffer.allocate(self.capacity)
    }

    @inline(__always) mutating func reserve(_ k: Int) {
        if count &+ k <= capacity { return }
        var c = capacity * 2
        while c < count + k { c *= 2 }
        let nb = TextBuffer.allocate(c)
        memcpy(nb, base, count)
        base.deallocate()
        base = nb
        capacity = c
    }

    @inline(__always) mutating func byte(_ b: UInt8) {
        reserve(1)
        base[count] = b
        count &+= 1
    }

    @inline(__always) mutating func bytes(_ p: UnsafePointer<UInt8>, _ k: Int) {
        if k <= 0 { return }
        reserve(k)
        memcpy(base + count, p, k)
        count &+= k
    }

    mutating func string(_ s: String) {
        var s = s
        s.withUTF8 { if let b = $0.baseAddress { bytes(b, $0.count) } }
    }

    /// `k` spaces.
    @inline(__always) mutating func spaces(_ k: Int) {
        if k > 0 { bytes(ByteOutput.indent + 1, min(k, 256)) }
    }

    /// Newline plus 2-space indentation for `depth` (capped).
    @inline(__always) mutating func newline(_ depth: Int, maxDepth: Int) {
        bytes(ByteOutput.indent, 1 + 2 * min(depth, maxDepth, 128))
    }

    /// Hands the bytes to a TextBuffer (zeroing the padding after the content).
    mutating func finish() -> TextBuffer {
        (base + count).initialize(repeating: 0, count: TextBuffer.padding)
        return TextBuffer(owning: base, count: count)
    }
}
