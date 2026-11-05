// Noncopyable owners of memory. A buffer has exactly one owner and moves instead of being copied, so it owns its bytes
// outright: an append checks capacity and copies, with no copy-on-write check and no reference count, and the memory
// goes when the owner does. What reads a buffer borrows a `Span` of it, whose lifetime the compiler ties to the borrow.
// Neither is Sendable (`~Sendable`): they stay on the loop's thread, and the compiler flags any place one would cross.

/// A growable byte buffer. An empty one holds no memory, so an idle connection costs nothing.
nonisolated struct ByteBuffer: ~Copyable, ~Sendable {
    private var base: UnsafeMutablePointer<UInt8>?
    private(set) var count = 0
    private(set) var capacity = 0

    init() {}

    init(capacity: Int) {
        if capacity > 0 {
            base = .allocate(capacity: capacity)
            self.capacity = capacity
        }
    }

    deinit {
        base?.deallocate()
    }

    @inline(__always) var isEmpty: Bool { count == 0 }

    /// Room for `n` more bytes; the end of the bytes, where they go.
    @inline(__always) private mutating func reserve(_ n: Int) -> UnsafeMutablePointer<UInt8> {
        if count + n > capacity { grow(to: count + n) }
        return base.unsafelyUnwrapped + count
    }

    @inline(never) private mutating func grow(to needed: Int) {
        let next = Swift.max(needed, capacity * 2, 64)
        let fresh = UnsafeMutablePointer<UInt8>.allocate(capacity: next)
        if let base {
            fresh.update(from: base, count: count)
            base.deallocate()
        }
        base = fresh
        capacity = next
    }

    @inline(__always) mutating func append(_ byte: UInt8) {
        reserve(1).pointee = byte
        count += 1
    }

    @inline(__always) mutating func append(_ raw: UnsafeRawBufferPointer) {
        guard let source = raw.baseAddress, raw.count > 0 else { return }
        UnsafeMutableRawPointer(reserve(raw.count)).copyMemory(from: source, byteCount: raw.count)
        count += raw.count
    }

    @inline(__always) mutating func append(_ literal: StaticString) {
        append(UnsafeRawBufferPointer(start: literal.utf8Start, count: literal.utf8CodeUnitCount))
    }

    @inline(__always) mutating func append(_ span: Span<UInt8>) {
        span.withUnsafeBytes { append($0) }
    }

    @inline(__always) mutating func append(_ other: borrowing [UInt8]) {
        other.withUnsafeBytes { append($0) }
    }

    @inline(__always) mutating func append(repeating byte: UInt8, count n: Int) {
        guard n > 0 else { return }
        reserve(n).update(repeating: byte, count: n)
        count += n
    }

    @inline(__always) subscript(i: Int) -> UInt8 {
        get {
            precondition(i >= 0 && i < count)
            return base.unsafelyUnwrapped[i]
        }
        set {
            precondition(i >= 0 && i < count)
            base.unsafelyUnwrapped[i] = newValue
        }
    }

    /// Writes `span` over the bytes at `offset` (the buffer already holds them).
    @inline(__always) mutating func store(_ span: Span<UInt8>, at offset: Int) {
        precondition(offset >= 0 && offset + span.count <= count)
        span.withUnsafeBytes { UnsafeMutableRawPointer(base.unsafelyUnwrapped + offset).copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
    }

    /// Moves the `count` bytes at `from` down to `to`, over the ones in between.
    @inline(__always) mutating func moveDown(from: Int, to: Int, count n: Int) {
        precondition(to >= 0 && to <= from && from + n <= count)
        (base.unsafelyUnwrapped + to).update(from: base.unsafelyUnwrapped + from, count: n)
    }

    /// Keeps the memory.
    @inline(__always) mutating func removeAll() {
        count = 0
    }

    /// Frees the memory.
    @inline(__always) mutating func release() {
        base?.deallocate()
        base = nil
        count = 0
        capacity = 0
    }

    @inline(__always) mutating func truncate(_ n: Int) {
        if n < count { count = Swift.max(n, 0) }
    }

    /// Drops the first `n` bytes.
    @inline(__always) mutating func removeFirst(_ n: Int) {
        precondition(n >= 0 && n <= count)
        if n < count { base.unsafelyUnwrapped.update(from: base.unsafelyUnwrapped + n, count: count - n) }
        count -= n
    }

    var span: Span<UInt8> {
        @_lifetime(borrow self) borrowing get {
            let span = Span(_unsafeElements: UnsafeBufferPointer(start: base, count: count))
            return _overrideLifetime(span, borrowing: self)
        }
    }

    @inline(__always) func withBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R {
        try body(UnsafeRawBufferPointer(start: base, count: count))
    }
}

/// A growable array of noncopyable elements: the reactor's rings, and each ring's connection slots, each holding its
/// own buffers. Elements are reached in place through `unsafeAddress`, never copied.
nonisolated struct UniqueArray<Element: ~Copyable>: ~Copyable, ~Sendable {
    private var base: UnsafeMutablePointer<Element>
    private(set) var count: Int = 0
    private var capacity: Int

    init(capacity: Int = 0) {
        self.capacity = Swift.max(capacity, 1)
        base = .allocate(capacity: self.capacity)
    }

    deinit {
        base.deinitialize(count: count)
        base.deallocate()
    }

    @inline(__always) subscript(i: Int) -> Element {
        unsafeAddress { UnsafePointer(base + i) }
        unsafeMutableAddress { base + i }
    }

    @inline(__always) mutating func append(_ element: consuming Element) {
        if count == capacity { grow(to: count + 1) }
        (base + count).initialize(to: element)
        count += 1
    }

    @inline(__always) mutating func popLast() -> Element? {
        guard count > 0 else { return nil }
        count -= 1
        return (base + count).move()
    }

    @inline(never) private mutating func grow(to needed: Int) {
        let next = Swift.max(needed, capacity * 2)
        let fresh = UnsafeMutablePointer<Element>.allocate(capacity: next)
        fresh.moveInitialize(from: base, count: count)
        base.deallocate()
        base = fresh
        capacity = next
    }
}

