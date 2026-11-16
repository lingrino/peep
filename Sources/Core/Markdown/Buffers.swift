import Darwin

// Raw growable buffers for the markdown parser's hot loops.
//
// Swift `Array.append` on a class property checks uniqueness through a runtime call on every
// append, and `append(contentsOf:)` of a slice goes through generic code: together ~20% of
// parse time before these. Here an append is a capacity compare and a store. The parser
// objects own the buffers and free them when done.

struct RawArray<T: BitwiseCopyable> {
    var p: UnsafeMutablePointer<T>
    var count = 0
    var cap: Int

    init(capacity: Int) {
        cap = max(8, capacity)
        p = .allocate(capacity: cap)
    }

    func free() { p.deallocate() }

    @inline(__always) var isEmpty: Bool { count == 0 }

    @inline(__always) subscript(i: Int) -> T {
        get { p[i] }
        nonmutating set { p[i] = newValue }
    }

    @inline(__always) var last: T {
        get { p[count &- 1] }
        nonmutating set { p[count &- 1] = newValue }
    }

    @inline(__always) mutating func append(_ v: T) {
        if count == cap { grow(count &+ 1) }
        (p + count).initialize(to: v)
        count &+= 1
    }

    @inline(never) mutating func grow(_ need: Int) {
        var c = cap &* 2
        while c < need { c &*= 2 }
        let q = UnsafeMutablePointer<T>.allocate(capacity: c)
        q.initialize(from: p, count: count)
        p.deallocate()
        p = q
        cap = c
    }

    @inline(__always) mutating func removeLast(_ k: Int = 1) { count &-= k }

    mutating func remove(at i: Int) {
        memmove(p + i, p + i + 1, (count - i - 1) * MemoryLayout<T>.stride)
        count -= 1
    }

    /// Removes `[a, b)`.
    mutating func removeSubrange(_ a: Int, _ b: Int) {
        if b <= a { return }
        memmove(p + a, p + b, (count - b) * MemoryLayout<T>.stride)
        count -= b - a
    }

    func toArray() -> [T] { Array(UnsafeBufferPointer(start: p, count: count)) }
}

/// Growable byte buffer with `TextBuffer.padding` bytes of slack past `cap`, allocated like a
/// TextBuffer so the finished bytes become one without a copy. Vector copies may write up to
/// 15 bytes past `count` (into the slack) and read up to 15 bytes past the end of a padded
/// source.
struct ByteBuf {
    var p: UnsafeMutablePointer<UInt8>
    var count = 0
    var cap: Int

    init(capacity: Int) {
        cap = max(64, capacity)
        p = UnsafeMutableRawPointer.allocate(byteCount: cap + TextBuffer.padding, alignment: 128)
            .assumingMemoryBound(to: UInt8.self)
    }

    func free() { p.deallocate() }

    @inline(__always) var last: UInt8 { p[count &- 1] }

    @inline(__always) mutating func append(_ b: UInt8) {
        if count >= cap { grow(count &+ 1) }
        p[count] = b
        count &+= 1
    }

    /// Appends `n` bytes from a padded source (readable 16 bytes past `n`).
    @inline(__always) mutating func appendPadded(_ s: UnsafePointer<UInt8>, _ n: Int) {
        if count &+ n > cap { grow(count &+ n) }
        copyPadded(p + count, s, n)
        count &+= n
    }

    /// Appends `n` bytes from any source.
    @inline(__always) mutating func append(_ s: UnsafePointer<UInt8>, _ n: Int) {
        if count &+ n > cap { grow(count &+ n) }
        memcpy(p + count, s, n)
        count &+= n
    }

    mutating func append(_ s: StaticString) { append(s.utf8Start, s.utf8CodeUnitCount) }

    mutating func append(_ s: String) {
        var s = s
        s.withUTF8 { if let b = $0.baseAddress { append(b, $0.count) } }
    }

    /// Appends a Unicode scalar as UTF-8.
    mutating func appendScalar(_ v: UInt32) {
        if v < 0x80 { append(UInt8(v)); return }
        if count &+ 4 > cap { grow(count &+ 4) }
        if v < 0x800 {
            p[count] = UInt8(0xC0 | v >> 6); p[count + 1] = UInt8(0x80 | v & 0x3F); count += 2
        } else if v < 0x10000 {
            p[count] = UInt8(0xE0 | v >> 12); p[count + 1] = UInt8(0x80 | v >> 6 & 0x3F)
            p[count + 2] = UInt8(0x80 | v & 0x3F); count += 3
        } else {
            p[count] = UInt8(0xF0 | v >> 18); p[count + 1] = UInt8(0x80 | v >> 12 & 0x3F)
            p[count + 2] = UInt8(0x80 | v >> 6 & 0x3F); p[count + 3] = UInt8(0x80 | v & 0x3F); count += 4
        }
    }

    @inline(never) mutating func grow(_ need: Int) {
        var c = cap &* 2
        while c < need { c &*= 2 }
        let q = UnsafeMutableRawPointer.allocate(byteCount: c + TextBuffer.padding, alignment: 128)
            .assumingMemoryBound(to: UInt8.self)
        memcpy(q, p, count)
        p.deallocate()
        p = q
        cap = c
    }

    /// Hands the bytes to a TextBuffer (zeroed padding). The ByteBuf must not be used after.
    func finish() -> TextBuffer {
        (p + count).initialize(repeating: 0, count: TextBuffer.padding)
        return TextBuffer(owning: p, count: count)
    }

    func string(_ s: Int, _ e: Int) -> String {
        String(decoding: UnsafeBufferPointer(start: p + s, count: max(0, e - s)), as: UTF8.self)
    }
}

/// Copies `n` bytes. Short copies (the common case: words, link texts, code spans) use
/// 16-byte vectors with no call, reading and writing up to 15 bytes past `n`: both sides
/// must be padded buffers.
@inline(__always)
func copyPadded(_ dst: UnsafeMutablePointer<UInt8>, _ src: UnsafePointer<UInt8>, _ n: Int) {
    if n <= 48 {
        var k = 0
        while k < n {
            UnsafeMutableRawPointer(dst + k).storeBytes(of: load16(src + k), as: V16.self)
            k &+= 16
        }
    } else {
        memcpy(dst, src, n)
    }
}

/// A byte range in a document's string store (`MarkdownDocument.strings`).
struct StrRange: BitwiseCopyable {
    var start: Int32
    var end: Int32
    static let none = StrRange(start: -1, end: -1)
    @inline(__always) var isNone: Bool { start < 0 }
}
