// The server: configuration, then the reactor's loop. One CPU, one thread for requests: the main thread, whose actor
// everything in the server belongs to (the target's default isolation). The checkpointer is the one actor besides it.
import Glibc
import Syscalls

@main
struct Feed {
    static func main() {
        guard let databasePath = env("SQLITE_PATH") else { fatalError("SQLITE_PATH must be set") }
        guard let jwtSecret = env("JWT_SECRET") else { fatalError("JWT_SECRET must be set") }
        let host = env("HOST") ?? "0.0.0.0"
        let port = UInt16(envInt("PORT", 80))
        let started = Sys.monotonicNanos()

        // A ring's table of direct descriptors can't be larger than the descriptor limit (65,535 on the box), so the
        // limit sets one ring's connections; more rings take the rest.
        let nofile = Sys.raiseNofileLimit()
        let files = UInt32(envInt("RING_FILES", min(nofile, 1 << 20)))
        let settings = Reactor.Settings(
            files: files, margin: min(1024, Int(files) / 8), maxRings: envInt("MAX_RINGS", 16),
            queueDepth: 4096, bufferCount: UInt32(envInt("RING_BUFFERS", 4096)), bufferSize: 2048,
            batch: UInt32(envInt("PASS_BATCH", 64)), windowNanos: Int64(envInt("PASS_WINDOW_US", 1000)) * 1000,
            directReads: envInt("BTREE_READS", 1) != 0)

        // Checkpoints off the main thread (an actor of their own), or in the loop with CHECKPOINT_THREAD=0.
        let checkpointDone = sys_eventfd(0, Sys.EFD_CLOEXEC)
        let reactor: Reactor
        do {
            let checkpointer = envInt("CHECKPOINT_THREAD", 1) != 0 ? try Checkpointer(path: databasePath, done: checkpointDone) : nil
            reactor = try Reactor(signer: TokenSigner(secret: Array(jwtSecret.utf8)), host: host, port: port,
                                  databasePath: databasePath, started: started, settings: settings,
                                  checkpointer: checkpointer, checkpointDone: checkpointDone)
        } catch {
            fatalError("\(error)")
        }
        Sys.logLine("listening on \(host):\(port): io_uring, \(files) connections per ring, pass of \(settings.batch) "
            + "completions or \(settings.windowNanos / 1000) us, reads \(reactor.directReads ? "off the B-trees" : "through SQL")")
        reactor.run()
    }
}

extension Feed {
    private static func env(_ name: String) -> String? {
        getenv(name).map { String(cString: $0) }
    }

    private static func envInt(_ name: String, _ fallback: Int) -> Int {
        env(name).flatMap { Int($0) } ?? fallback
    }
}
