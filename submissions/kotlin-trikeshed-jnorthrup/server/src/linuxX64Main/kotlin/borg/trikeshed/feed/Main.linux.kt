package borg.trikeshed.feed

import borg.trikeshed.sctp.SctpUdpPort
import borg.trikeshed.userspace.nio.channels.endpoint
import borg.trikeshed.userspace.nio.channels.parseWhole
import borg.trikeshed.userspace.nio.channels.spi.PosixChannelOperations
import borg.trikeshed.userspace.nio.channels.spi.PosixReactorOperations
import borg.trikeshed.userspace.nio.platform.spi.platformGetRandom
import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.toKString
import kotlinx.coroutines.runBlocking
import platform.posix.getenv

/**
 * Configured by SQLITE_PATH, JWT_SECRET, HOST and PORT: the Xio states over io_uring direct descriptors. TRANSPORT=sctp
 * serves the same feed over SCTP on UDP HOST:PORT instead ([SctpFeed]); the TCP path is unchanged.
 */
@OptIn(ExperimentalForeignApi::class)
fun main() {
    fun env(name: String): String? = getenv(name)?.toKString()
    val store = SqliteStore(env("SQLITE_PATH") ?: error("SQLITE_PATH is not set"))
    val feed = Feed(store, Bearer((env("JWT_SECRET") ?: error("JWT_SECRET is not set")).encodeToByteArray()), epochSeconds())
    val host = env("HOST") ?: "127.0.0.1"
    val port = (env("PORT") ?: "3000").toInt()
    if (env("TRANSPORT") == "sctp") {
        val at = parseWhole(if (':' in host) "[$host]:$port" else "$host:$port") { endpoint() } ?: error("HOST is not an address: $host")
        val secret = ByteArray(32).also { platformGetRandom(it) }
        val sctp = SctpFeed(feed, store)
        runBlocking {
            sctp.port = SctpUdpPort(PosixChannelOperations(), PosixReactorOperations(), at, sctp, secret).open()
            sctp.serve()
        }
        return
    }
    // COMMIT_WINDOW_US: the group-commit window in microseconds, for measuring its knee; unset keeps COMMIT_WINDOW_NANOS.
    val window = env("COMMIT_WINDOW_US")?.toLongOrNull()?.let { it * 1_000L } ?: COMMIT_WINDOW_NANOS
    Xio(Poller(host, port), feed, store, window).init()
}
