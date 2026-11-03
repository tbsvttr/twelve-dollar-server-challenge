package borg.trikeshed.feed

import borg.trikeshed.lib.j
import borg.trikeshed.lib.toSeries
import borg.trikeshed.reactor.JvmTlsCodecBackend
import borg.trikeshed.reactor.TlsApplicationProtocol
import borg.trikeshed.reactor.TlsConfig
import borg.trikeshed.reactor.TlsRecordSession
import borg.trikeshed.reactor.TlsRole
import borg.trikeshed.userspace.LiburingFacade
import borg.trikeshed.userspace.UringBackendMode
import borg.trikeshed.userspace.openLiburingFacade
import borg.trikeshed.userspace.reuseAddress
import java.io.File
import java.lang.foreign.Arena
import java.lang.foreign.ValueLayout

/** What [openRingServer] builds: listeners on [host]:[ports], a ring of SQ depth [entries], TLS when [cert] and [key]. */
class RingOptions(
    val host: String = "127.0.0.1",
    val ports: List<Int> = listOf(3000),
    val entries: Int = 4096,
    val mode: UringBackendMode? = null,
    val cert: String? = null,
    val key: String? = null,
    val rxWindows: Int = 512,
    val txWindows: Int = 512,
    val commitWindowNanos: Long = COMMIT_WINDOW_NANOS,
    val drainNanos: Long = 3_000_000_000L,
    val shutdownNanos: Long = 10_000_000_000L,
    /** Record sessions to use instead of JSSE ones from [cert] and [key] (another TLS implementation, a test double). */
    val sessions: (() -> TlsRecordSession)? = null,
    /** Accepted connections allowed mid-handshake before the listeners pause (RingServer admission). */
    val maxHandshaking: Int = 2048,
)

/**
 * Opens the ring, its listeners and the TLS identity; on any failure what was opened is closed again (listeners by
 * ring CLOSE, then the ring) before the failure is thrown. The server owns all of it from here: its run closes it.
 */
fun openRingServer(options: RingOptions, feed: Feed, store: FeedStore): RingServer {
    val ring = openLiburingFacade(options.entries, options.mode)
    val listeners = ArrayList<Int>(options.ports.size)
    try {
        for ((i, port) in options.ports.withIndex()) listeners.add(listen(ring, options.host, port, -1L - 4L * i))
        val tls: (() -> TlsRecordSession)? = if (options.sessions != null) options.sessions else if (options.cert != null && options.key != null) {
            val backend = JvmTlsCodecBackend()
            // ALPN offers http/1.1 only: this server speaks no h2.
            val config = TlsConfig(certificateFile = options.cert, privateKeyFile = options.key, hostnameVerification = false,
                alpnProtocols = listOf(TlsApplicationProtocol.HTTP_1_1).toSeries())
            backend.contexts.context(config, TlsRole.SERVER) // the identity loads once, here, or the server does not start
            val route = TlsRole.SERVER j ("" j 0)
            ({ backend.recordSession(config, route) })
        } else null
        return RingServer(ring, feed, store, tls, listeners.toIntArray(), options.rxWindows, options.txWindows,
            options.commitWindowNanos, options.drainNanos, options.shutdownNanos, options.maxHandshaking)
    } catch (failure: Throwable) {
        for ((i, fd) in listeners.withIndex()) {
            runCatching { ring.one(-1000L - i) { ring.prepClose(fd, it) } }.exceptionOrNull()?.let(failure::addSuppressed)
        }
        ring.close().exceptionOrNull()?.let(failure::addSuppressed)
        throw failure
    }
}

/**
 * The feed over the central ring. Environment: HOST; PORTS (comma-separated, one listener each, same process) or
 * PORT; TRIKESHED_URING_MODE native|emulated|auto (native: the FFM kernel io_uring, refused where it cannot be set
 * up); URING_ENTRIES, the SQ depth (default 4096; Linux caps it at 32768); TLS_CERT and TLS_KEY, a PEM chain and
 * PKCS#8 key, for HTTPS; RX_WINDOWS and TX_WINDOWS, the pooled receive and send windows; STATS_FILE, where a JSON
 * line of counters lands about once a second.
 */
fun serveRing(env: Map<String, String>, feed: Feed, store: FeedStore) {
    val options = RingOptions(
        host = env["HOST"] ?: "127.0.0.1",
        ports = (env["PORTS"] ?: env["PORT"] ?: "3000").split(',').map { it.trim().toInt() },
        entries = (env["URING_ENTRIES"] ?: "4096").toInt(),
        mode = env["TRIKESHED_URING_MODE"]?.let(UringBackendMode::parse),
        cert = env["TLS_CERT"], key = env["TLS_KEY"],
        rxWindows = (env["RX_WINDOWS"] ?: "512").toInt(), txWindows = (env["TX_WINDOWS"] ?: "512").toInt(),
        maxHandshaking = (env["MAX_HANDSHAKING"] ?: "2048").toInt(),
    )
    val server = openRingServer(options, feed, store)
    var stats: java.io.BufferedWriter? = null
    var hook: Thread? = null
    var running = false
    try {
        stats = env["STATS_FILE"]?.let { File(it).bufferedWriter() }
        val identity = "\"pid\":${ProcessHandle.current().pid()},\"started\":${System.currentTimeMillis()}," +
            "\"ports\":\"${options.ports.joinToString(",")}\",\"tls\":${options.cert != null && options.key != null}," +
            "\"entries\":${options.entries},\"mode\":\"${options.mode ?: "process"}\",\"backend\":\"${json(server.backend)}\""
        println("{$identity}")
        stats?.apply { write("{\"kind\":\"start\",$identity}\n"); flush() }
        val loop = Thread.currentThread()
        hook = Thread {
            server.stopping = true
            loop.join(15_000)
        }
        Runtime.getRuntime().addShutdownHook(hook)
        running = true
        val writer = stats
        server.run { s ->
            val line = buildString {
                append("{\"t\":").append(System.currentTimeMillis())
                for ((name, value) in s.counters()) append(",\"").append(name).append("\":").append(value)
                if (s.stopping) append(",\"stopping\":true,\"drained\":").append(s.drained)
                append("}\n")
            }
            writer?.apply { write(line); flush() }
        }
    } catch (failure: Throwable) {
        // Before run the server owns its ring and listeners but nothing has closed them yet.
        if (!running) runCatching { server.close() }.exceptionOrNull()?.let(failure::addSuppressed)
        throw failure
    } finally {
        runCatching { stats?.close() }
        // A normal return leaves no hook behind; during VM shutdown removal is refused, and the hook is what stopped us.
        hook?.let { h -> runCatching { Runtime.getRuntime().removeShutdownHook(h) } }
    }
}

fun json(text: String): String = text.replace("\\", "\\\\").replace("\"", "\\\"")

/** A listening socket made by ring SQEs: SOCKET, SO_REUSEADDR, BIND, LISTEN (backlog 65535); closed on failure. */
fun listen(ring: LiburingFacade, host: String, port: Int, token: Long): Int {
    val fd = ring.one(token) { ring.prepSocket(2, 1, 0, it) }
    check(fd >= 0) { "socket: $fd" }
    try {
        check(reuseAddress(fd) == 0) { "SO_REUSEADDR on $fd" }
        Arena.ofConfined().use { arena ->
            val address = arena.allocate(16)
            val octets = host.split('.').map { it.toInt() }
            require(octets.size == 4) { "HOST must be IPv4 dotted: $host" }
            address.set(ValueLayout.JAVA_BYTE, 0, 2)
            address.set(ValueLayout.JAVA_BYTE, 2, (port shr 8).toByte())
            address.set(ValueLayout.JAVA_BYTE, 3, port.toByte())
            for (i in 0 until 4) address.set(ValueLayout.JAVA_BYTE, 4L + i, octets[i].toByte())
            val bound = ring.one(token - 1) { ring.prepBind(fd, address.address(), 16, it) }
            check(bound == 0) { "bind $host:$port: $bound" }
        }
        val listening = ring.one(token - 2) { ring.prepListen(fd, 65535, it) }
        check(listening == 0) { "listen $host:$port: $listening" }
        return fd
    } catch (failure: Throwable) {
        runCatching { ring.one(token - 3) { ring.prepClose(fd, it) } }.exceptionOrNull()?.let(failure::addSuppressed)
        throw failure
    }
}

/** Stages one SQE as [token], submits, and waits for its CQE: setup before the loop owns the ring. */
internal inline fun LiburingFacade.one(token: Long, stage: (Long) -> Result<Unit>): Int {
    stage(token).getOrThrow()
    submit().getOrThrow()
    while (true) {
        val completion = waitCqeTimeout(5_000_000_000L).getOrThrow() ?: error("no CQE for $token within 5 s")
        if (completion.userData == token) return completion.res
    }
}
