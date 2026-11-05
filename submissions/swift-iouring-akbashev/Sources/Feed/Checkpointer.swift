// The one effect that leaves the main thread: copying the WAL back into the database file, whose fsync would otherwise
// stall the loop. An actor on a thread of its own at the lowest priority (nice 19), so on one CPU it runs while the
// loop waits, with a SQLite connection of its own. The loop starts a checkpoint without waiting for it, and learns that
// it finished from an eventfd its ring reads: a completion like any other.
import CSQLite
import Glibc
import Synchronization
import Syscalls

actor Checkpointer {
    nonisolated let executor: ThreadExecutor
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }

    private let db: OpaquePointer
    /// Written when a checkpoint is done.
    private let done: Int32

    init(path: String, done: Int32) throws(StoreError) {
        db = try SQLite.open(path, cacheKiB: 8 * 1024)
        self.done = done
        executor = ThreadExecutor(name: "checkpoint", nice: 19)
    }

    /// A PASSIVE checkpoint: it copies what no reader still needs and never waits for the loop's transaction.
    func checkpoint() {
        sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_PASSIVE, nil, nil)
        var one: UInt64 = 1
        _ = sys_write(done, &one, 8)
    }
}

/// A serial executor with a thread of its own, for an actor that is an effect: jobs queue under a Mutex, and the thread
/// sleeps in a blocking read of an eventfd that `enqueue` writes.
nonisolated final class ThreadExecutor: SerialExecutor, TaskExecutor {
    private let jobs = Mutex<[UnownedJob]>([])
    private let wake: Int32
    private let threadID = Atomic<UInt>(0)

    init(name: String, nice: Int32) {
        wake = sys_eventfd(0, Sys.EFD_CLOEXEC)
        guard wake >= 0 else { fatalError("eventfd: \(errno)") }
        Self.startThread(name: name) { [self] in
            // This thread only: the main thread keeps its priority.
            _ = sys_setpriority(0, UInt32(sys_gettid()), nice)
            run()
        }
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        jobs.withLock { $0.append(job) }
        var one: UInt64 = 1
        _ = sys_write(wake, &one, 8)
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }

    func isIsolatingCurrentContext() -> Bool? {
        threadID.load(ordering: .relaxed) == UInt(bitPattern: Int(bitPattern: pthread_self()))
    }

    func checkIsolated() {
        if isIsolatingCurrentContext() != true { fatalError("not on this executor's thread") }
    }

    private func run() -> Never {
        threadID.store(UInt(bitPattern: Int(bitPattern: pthread_self())), ordering: .relaxed)
        var batch: [UnownedJob] = []
        while true {
            jobs.withLock { swap(&batch, &$0) }
            if batch.isEmpty {
                var value: UInt64 = 0
                _ = sys_read(wake, &value, 8)
                continue
            }
            for job in batch {
                job.runSynchronously(isolatedTo: asUnownedSerialExecutor(), taskExecutor: asUnownedTaskExecutor())
            }
            batch.removeAll(keepingCapacity: true)
        }
    }

    /// A thread's body on its way through pthread_create.
    private final class ThreadStart: Sendable {
        let name: String
        let body: @Sendable () -> Void
        init(name: String, body: @escaping @Sendable () -> Void) {
            self.name = name
            self.body = body
        }
    }

    private static func startThread(name: String, _ body: @escaping @Sendable () -> Void) {
        let start = Unmanaged.passRetained(ThreadStart(name: name, body: body)).toOpaque()
        var thread = pthread_t()
        let rc = pthread_create(&thread, nil, { raw in
            let start = Unmanaged<ThreadStart>.fromOpaque(raw!).takeRetainedValue()
            _ = sys_pthread_setname_np(pthread_self(), String(start.name.prefix(15)))
            start.body()
            return nil
        }, start)
        if rc != 0 { fatalError("pthread_create: \(rc)") }
        pthread_detach(thread)
    }
}
