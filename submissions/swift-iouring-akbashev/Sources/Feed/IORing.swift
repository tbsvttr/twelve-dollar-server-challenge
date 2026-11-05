// Swift's side of io_uring (ioring.h): a ring that one thread owns, the requests the server makes of it and the
// completions it reads back. The shape follows swift-system's IORing (prepare requests, submit, consume completions),
// with the socket requests that one doesn't offer yet: multishot accept into direct descriptors, multishot receive
// into provided buffers, send, shutdown and close.
import CIORing
import Glibc

/// An io_uring instance with a table of direct descriptors and a ring of provided receive buffers. Noncopyable: it
/// owns its mappings, and only the thread that created it may submit (IORING_SETUP_SINGLE_ISSUER).
nonisolated struct IORing: ~Copyable, ~Sendable {
    private var raw = ioring()
    private var buffers = ioring_bufs()

    /// What the server asks of a ring.
    enum Request {
        /// Accepts connections on `listener` until cancelled, each into a free direct descriptor.
        case acceptMultishot(listener: Int32)
        /// Receives on direct descriptor `slot` until it fails, each chunk into a provided buffer.
        case receiveMultishot(slot: UInt32)
        /// Sends all of `bytes` (which must stay put until the completion).
        case send(slot: UInt32, bytes: UnsafeRawBufferPointer)
        /// Shuts the socket down both ways, which ends its multishot receive, and closes it after that. Only the close
        /// completes with the user data; the shutdown completes with 0.
        case shutdownAndClose(slot: UInt32)
        /// Shuts the socket down both ways (when a send is still in flight: the close comes after it). Completes with
        /// user data 0.
        case shutdown(slot: UInt32)
        case close(slot: UInt32)
        /// Reads a plain descriptor (an eventfd) into `buffer`, which must stay put until the completion.
        case read(fd: Int32, buffer: UnsafeMutableRawBufferPointer)
        /// Cancels the request submitted with `userData`.
        case cancel(userData: UInt64)
    }

    struct Completion {
        let userData: UInt64
        /// The request's result: a count, a descriptor slot, or -errno.
        let result: Int32
        let flags: UInt32

        /// A multishot request is still armed.
        var hasMore: Bool { flags & UInt32(IORING_CQE_F_MORE) != 0 }

        /// The provided buffer a receive filled, if any.
        var buffer: UInt16? {
            flags & UInt32(IORING_CQE_F_BUFFER) != 0 ? UInt16(truncatingIfNeeded: flags >> UInt32(IORING_CQE_BUFFER_SHIFT)) : nil
        }
    }

    /// A ring of `queueDepth` submissions and `completionDepth` completions, `files` direct descriptors and `bufferCount`
    /// receive buffers of `bufferSize` bytes. Only this thread submits to it (SINGLE_ISSUER), and it posts completions
    /// when this thread asks for them (DEFER_TASKRUN), so they come in batches, without interrupts.
    init(queueDepth: UInt32, completionDepth: UInt32, files: UInt32, bufferCount: UInt32, bufferSize: UInt32) throws(SystemError) {
        let flags = UInt32(IORING_SETUP_SINGLE_ISSUER) | UInt32(IORING_SETUP_DEFER_TASKRUN) | UInt32(IORING_SETUP_SUBMIT_ALL)
        var rc = ioring_init(&raw, queueDepth, completionDepth, flags | UInt32(IORING_SETUP_NO_SQARRAY))
        if rc == -EINVAL { rc = ioring_init(&raw, queueDepth, completionDepth, flags) }
        guard rc == 0 else { throw SystemError("io_uring_setup", -rc) }
        rc = ioring_register_files_sparse(&raw, files)
        guard rc == 0 else { throw SystemError("io_uring_register files", -rc) }
        rc = ioring_bufs_init(&raw, &buffers, bufferCount, bufferSize, 0)
        guard rc == 0 else { throw SystemError("io_uring_register buffer ring", -rc) }
    }

    deinit {
        var raw = raw
        var buffers = buffers
        ioring_bufs_exit(&raw, &buffers)
        ioring_exit(&raw)
    }

    // ---------- submitting ----------

    /// The next free submission entry; when the queue is full, what is in it is submitted first.
    @inline(__always) private mutating func entry() -> UnsafeMutablePointer<io_uring_sqe> {
        if let sqe = ioring_get_sqe(&raw) { return sqe }
        _ = ioring_enter(&raw, 0, -1)
        guard let sqe = ioring_get_sqe(&raw) else { fatalError("io_uring submission queue stuck") }
        return sqe
    }

    /// Prepares `request`; it goes to the kernel with the next `submit`.
    @inline(__always) mutating func prepare(_ request: Request, userData: UInt64) {
        switch request {
        case .acceptMultishot(let listener):
            ioring_prep_accept_direct_multishot(entry(), listener, userData)
        case .receiveMultishot(let slot):
            ioring_prep_recv_multishot(entry(), slot, buffers.group, userData)
        case .send(let slot, let bytes):
            ioring_prep_send(entry(), slot, bytes.baseAddress, UInt32(bytes.count), userData)
        case .shutdownAndClose(let slot):
            // Both entries in one go, so the link can't be split by a submission in between.
            if ioring_sq_space(&raw) < 2 { _ = ioring_enter(&raw, 0, -1) }
            ioring_prep_shutdown(entry(), slot, 1, 0)
            ioring_prep_close_direct(entry(), slot, userData)
        case .shutdown(let slot):
            ioring_prep_shutdown(entry(), slot, 0, 0)
        case .close(let slot):
            ioring_prep_close_direct(entry(), slot, userData)
        case .read(let fd, let buffer):
            ioring_prep_read(entry(), fd, buffer.baseAddress, UInt32(buffer.count), userData)
        case .cancel(let target):
            ioring_prep_cancel(entry(), target, userData)
        }
    }

    /// Submits what was prepared, then waits for `count` completions or `timeoutNanos` (negative: no timeout).
    /// Completions are posted here (DEFER_TASKRUN) even when not waiting. Returns the number submitted or -errno.
    @inline(__always) @discardableResult
    mutating func submit(waitingFor count: UInt32 = 0, timeoutNanos: Int64 = -1) -> Int32 {
        ioring_enter(&raw, count, timeoutNanos)
    }

    // ---------- completions ----------

    /// The next completion, consumed; the kernel sees the space at `finishCompletions()`.
    @inline(__always) mutating func nextCompletion() -> Completion? {
        guard let cqe = ioring_peek_cqe(&raw) else { return nil }
        let completion = Completion(userData: cqe.pointee.user_data, result: cqe.pointee.res, flags: cqe.pointee.flags)
        ioring_cq_advance(&raw)
        return completion
    }

    /// Hands the consumed completions' space and the recycled buffers back to the kernel.
    @inline(__always) mutating func finishCompletions() {
        ioring_cq_publish(&raw)
        ioring_bufs_publish(&buffers)
    }

    // ---------- provided buffers ----------

    /// The first `count` bytes of provided buffer `id`: valid until the buffer is recycled.
    @inline(__always) func buffer(_ id: UInt16, count: Int) -> UnsafeBufferPointer<UInt8> {
        let base = UnsafeRawPointer(buffers.base! + Int(id) * Int(buffers.size)).assumingMemoryBound(to: UInt8.self)
        return UnsafeBufferPointer(start: base, count: count)
    }

    /// Gives buffer `id` back to the kernel (at the next `finishCompletions()`).
    @inline(__always) mutating func recycle(_ id: UInt16) {
        ioring_bufs_recycle(&buffers, id)
    }
}
