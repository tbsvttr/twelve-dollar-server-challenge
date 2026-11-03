package borg.trikeshed.components

import borg.trikeshed.collections.LongTable
import borg.trikeshed.parse.confix.KnownSchema
import borg.trikeshed.parse.confix.KnownShape
import kotlin.time.TimeSource

/** The target this binary was built for, as its build names it. */
expect val platformName: String

/** What this platform's build provides beyond the common code, stated, not inferred. */
expect val capabilities: String

/**
 * Writes [bytes] to a new file at [path] and reads it back, [rounds] times; a checksum of what was read, or null when
 * this platform's build has no file API.
 */
expect fun fileRoundTrip(path: String, bytes: ByteArray, rounds: Int): Long?

/** A writable scratch path for [name] on this platform. */
expect fun scratchPath(name: String): String

fun line(case: String, n: Long, nanos: Long, extra: String = "") =
    println("{\"platform\":\"$platformName\",\"case\":\"$case\",\"ops\":$n,\"nsPerOp\":${(nanos * 10 / n) / 10.0}$extra}")

/**
 * TrikeShed components on every target this build can make: the known-schema JSON plan (the feed's JWT payload and
 * a POST body), LongTable (the userspace identity tables), and a file round trip where the platform has a file API.
 * Single-threaded, every loop bounded; one JSON line per case.
 */
fun main() {
    println("{\"platform\":\"$platformName\",\"capabilities\":\"$capabilities\"}")
    val payload = """{"sub":"12345","username":"user12345","iat":1760000000,"exp":1893456000}""".encodeToByteArray()
    val body = """{"body":"Lorem ipsum dolor sit amet, consectetur adipiscing elit, caf\u00e9 \"quoted\" text"}""".encodeToByteArray()
    val claims = KnownSchema("sub", "username", "exp").reader()
    val posts = KnownSchema("body").reader()
    var sink = 0L
    val n = 500_000
    repeat(2) { round ->
        var t = TimeSource.Monotonic.markNow()
        for (i in 0 until n) {
            check(claims.scan(payload) == KnownShape.OBJECT)
            sink += claims.positiveDecimal(0) + claims.text(1)!!.length + claims.number(2).toLong()
        }
        if (round == 1) line("known-schema jwt-payload", n.toLong(), t.elapsedNow().inWholeNanoseconds)
        t = TimeSource.Monotonic.markNow()
        for (i in 0 until n) {
            check(posts.scan(body) == KnownShape.OBJECT)
            sink += posts.text(0)!!.length
        }
        if (round == 1) line("known-schema post-body", n.toLong(), t.elapsedNow().inWholeNanoseconds)
    }
    repeat(2) { round ->
        val table = LongTable<Long>()
        val keys = 200_000
        val t = TimeSource.Monotonic.markNow()
        var x = 0x9E3779B97F4A7C15uL.toLong()
        for (i in 0 until keys) {
            x = x * 6364136223846793005L + 1442695040888963407L
            table.put(x, i.toLong())
        }
        x = 0x9E3779B97F4A7C15uL.toLong()
        for (i in 0 until keys) {
            x = x * 6364136223846793005L + 1442695040888963407L
            sink += table[x] ?: error("lost key")
        }
        x = 0x9E3779B97F4A7C15uL.toLong()
        for (i in 0 until keys) {
            x = x * 6364136223846793005L + 1442695040888963407L
            table.remove(x)
        }
        check(table.size == 0)
        if (round == 1) line("LongTable put+get+remove", 3L * keys, t.elapsedNow().inWholeNanoseconds)
    }
    val bytes = ByteArray(64 * 1024) { (it * 31).toByte() }
    val rounds = 200
    val t = TimeSource.Monotonic.markNow()
    val sum = fileRoundTrip(scratchPath("trikeshed-component.bin"), bytes, rounds)
    val nanos = t.elapsedNow().inWholeNanoseconds
    if (sum == null) println("{\"platform\":\"$platformName\",\"case\":\"file round trip\",\"supported\":false}")
    else line("file round trip 64KiB write+read", rounds.toLong(), nanos, ",\"mbPerSecond\":${(2.0 * bytes.size * rounds / 1e6) / (nanos / 1e9)}")
    println("{\"platform\":\"$platformName\",\"sink\":${sink + (sum ?: 0)}}")
}
