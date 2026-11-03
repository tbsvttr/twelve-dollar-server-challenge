package borg.trikeshed.loadgen.reactor

import borg.trikeshed.htx.PPID_HTX11
import borg.trikeshed.lib.*
import borg.trikeshed.loadgen.*
import borg.trikeshed.sctp.Ppid
import borg.trikeshed.sctp.SctpTcb
import borg.trikeshed.sctp.SctpUdpPort
import borg.trikeshed.sctp.SctpUpper
import borg.trikeshed.userspace.nio.ByteBuffer
import borg.trikeshed.userspace.nio.channels.*
import borg.trikeshed.userspace.nio.channels.spi.ChannelOperations
import borg.trikeshed.userspace.nio.channels.spi.ReactorOperations
import borg.trikeshed.userspace.nio.file.spi.FileOperations
import borg.trikeshed.userspace.nio.platform.spi.platformGetRandom
import kotlinx.coroutines.*
import kotlin.coroutines.coroutineContext
import kotlin.random.Random
import kotlin.time.TimeSource

/**
 * The user's connection. TCP: its descriptor (-1: none) and, while a response is being read, its bytes. SCTP: its
 * association and the reply it awaits.
 */
class Connection(val source: Ipv4?) {
    var fd = -1
    var rx: ByteArray? = null
    var size = 0
    var tcb: SctpTcb? = null
    var awaiting: CompletableDeferred<Reply>? = null
}

/** A finished exchange: the HTTP status and the body text; or, with status < 0, the [Reason] it failed for. */
typealias Reply = Join<Int, String>

/**
 * bench/load.js: one coroutine and one keep-alive connection per user, the k6 steps and sleeps of the JVM generator,
 * its body checks, and its run/canonical-hold accounting. The transport is the subclass's: [exchange] one request,
 * [drop] a failed connection, [release] it when the user stops.
 */
abstract class Load(
    val host: String,
    val port: Port,
    val sources: Series<Ipv4>,
    val vus: Int,
    val first: Int,
    val rampNanos: Long,
    val holdNanos: Long,
    val timeoutMillis: Long,
    val users: Series<Twin<String>>,
    val seed: Long,
) {
    val clock = TimeSource.Monotonic.markNow()
    fun now(): Long = clock.elapsedNow().inWholeNanoseconds
    val started = 1_000_000_000L
    val canonicalStart get() = started + rampNanos
    val canonicalEnd get() = canonicalStart + holdNanos
    val stats = Array(3) { Array(4) { KindStats() } }
    val failReasons = LongArray(Reason.NAMES.size)
    var established = 0L
    var peakEstablished = 0L
    var connectFailures = 0L
    var disconnects = 0L
    var draining = false

    /** What the summary names as the client's transport. */
    abstract val backend: String

    /** One request on [c], connected first when it has no connection: the status and body, or a failure [Reason]. */
    abstract suspend fun exchange(c: Connection, request: ByteArray): Reply

    /** [c]'s connection after a failure, counted as a disconnect. */
    abstract fun drop(c: Connection)

    /** [c]'s connection when its user stops. */
    abstract fun release(c: Connection)

    fun record(kind: Int, start: Long, end: Long, ok: Boolean, checkFailed: Boolean) {
        val micros = (end - start) / 1000
        for ((scope, inScope) in s_[RUN j true, CANONICAL j (start >= canonicalStart && start < canonicalEnd)].view) {
            if (!inScope) continue
            val s = stats[scope][kind]
            s.latency.record(micros)
            if (ok) s.ok++ else s.failed++
            if (checkFailed) s.checksFailed++
            if (scope == CANONICAL && end >= canonicalEnd) s.drained++
        }
    }

    fun requestBytes(path: String, token: String?, body: String?): ByteArray {
        val head = StringBuilder(192)
        head.append(if (body == null) "GET " else "POST ").append(path).append(" HTTP/1.1\r\nHost: ").append(host)
            .append(':').append(port).append("\r\nUser-Agent: trikeshed-loadgen\r\n")
        if (body != null) head.append("Authorization: Bearer ").append(token).append("\r\nContent-Type: application/json\r\n")
            .append("Content-Length: ").append(body.encodeToByteArray().size).append("\r\n")
        head.append("\r\n")
        if (body != null) head.append(body)
        return head.toString().encodeToByteArray()
    }

    /** One timed request of [kind]: recorded, checked; the post id a feed picked, else [postId]; null when it failed. */
    suspend fun step(c: Connection, kind: Int, request: ByteArray, random: Random, postId: Long, author: String): Long? {
        val start = now()
        val (status, text) = exchange(c, request)
        val end = now()
        if (status < 0) {
            drop(c)
            failReasons[-status]++
            record(kind, start, end, ok = false, checkFailed = false)
            return null
        }
        val statusOk = when (kind) { LIKE -> status == 200 || status == 201; CREATE -> status == 201; else -> status == 200 }
        if (!statusOk) failReasons[Reason.STATUS]++
        var picked = postId
        val checked = statusOk && when (kind) {
            FEED -> ids(text).let { found -> (found.size == 20).also { if (it) picked = found[random.nextInt(found.size)] } }
            POST -> text.startsWith("{\"post\":{\"id\":$postId,")
            LIKE -> text.startsWith("{\"liked\":true,\"already_liked\":") && text.endsWith(",\"post_id\":$postId}")
            else -> text.contains("\"author\":\"$author\"") && text.endsWith("\"like_count\":0}}")
        }
        record(kind, start, end, statusOk, statusOk && !checked)
        return if (statusOk && checked) picked else null
    }

    suspend fun pause(random: Random, lo: Double, hi: Double) = delay(((lo + random.nextDouble() * (hi - lo)) * 1000).toLong())

    /** One user, load.js's loop: feed, 3-7 s, post, 3-8 s, like 15%, create 2%, 5-15 s. */
    suspend fun user(index: Int) {
        val random = Random(seed * 1_000_003 + index)
        val (name, token) = users[(first + index) % users.size]
        val c = Connection(if (sources.size == 0) null else sources[index % sources.size])
        delay((started + rampNanos * index / vus - now()).coerceAtLeast(0) / 1_000_000)
        delay((random.nextDouble() * 5000).toLong())
        var postId = 0L
        var iter = 0
        while (!draining) {
            val feed = step(c, FEED, requestBytes("/feed", null, null), random, postId, name)
            pause(random, 3.0, 7.0)
            if (feed == null || draining) { iter++; continue }
            postId = feed
            step(c, POST, requestBytes("/posts/$postId", null, null), random, postId, name)
            pause(random, 3.0, 8.0)
            if (!draining && random.nextDouble() < 0.15)
                step(c, LIKE, requestBytes("/posts/$postId/like", token, ""), random, postId, name)
            if (!draining && random.nextDouble() < 0.02)
                step(c, CREATE, requestBytes("/posts", token, "{\"body\":\"$name says hi (VU ${first + index + 1}, iter $iter)\"}"), random, postId, name)
            iter++
            pause(random, 5.0, 15.0)
        }
        release(c)
    }

    fun summary(): Join<String, String> {
        val scopes = StringBuilder()
        val histograms = StringBuilder("{")
        val failed = mutableListOf<String>()
        for ((scope, name) in SCOPES.withIndex()) {
            val total = KindStats().also { t -> for (k in stats[scope]) t.add(k) }
            val requests = total.ok + total.failed + total.unfinished
            val failRate = if (requests == 0L) 0.0 else (total.failed + total.unfinished).toDouble() / requests
            if (scope == RUN) {
                if (total.latency.percentile(95.0) >= 500_000) failed.add("run p95 ${total.latency.percentile(95.0)} us >= 500 ms")
                if (total.latency.percentile(99.0) >= 1_000_000) failed.add("run p99 ${total.latency.percentile(99.0)} us >= 1000 ms")
                if (failRate >= 0.01) failed.add("run failed $failRate >= 1%")
                if (total.checksFailed > 0) failed.add("${total.checksFailed} body checks failed")
            }
            if (scope > 0) { scopes.append(','); histograms.append(',') }
            val h = total.latency
            scopes.append("\"$name\":{\"requests\":$requests,\"ok\":${total.ok},\"failed\":${total.failed},\"unfinished\":${total.unfinished},")
                .append("\"drained\":${total.drained},\"checksFailed\":${total.checksFailed},\"failRate\":$failRate,")
                .append("\"latencyMicros\":{\"count\":${h.total},\"p50\":${h.percentile(50.0)},\"p95\":${h.percentile(95.0)},\"p99\":${h.percentile(99.0)},\"max\":${h.max}}}")
            histograms.append("\"$name\":[")
            var any = false
            for ((i, n) in h.counts.withIndex()) if (n > 0) {
                if (any) histograms.append(',')
                any = true
                histograms.append("[${h.lower(i)},${h.upper(i)},$n]")
            }
            histograms.append("]")
        }
        histograms.append("}\n")
        val reasons = Reason.NAMES.withIndex().joinToString(",", "{", "}") { (i, n) -> "\"$n\":${failReasons[i]}" }
        val summary = "{\"vus\":$vus,\"first\":$first,\"rampSeconds\":${rampNanos / 1_000_000_000},\"holdSeconds\":${holdNanos / 1_000_000_000}," +
            "\"clientBackend\":\"$backend\",\"peakEstablished\":$peakEstablished," +
            "\"connectFailures\":$connectFailures,\"disconnects\":$disconnects,\"failReasons\":$reasons,\"scopes\":{$scopes}," +
            "\"outcome\":{\"pass\":${failed.isEmpty()},\"failed\":[${failed.joinToString(",") { "\"$it\"" }}]}}\n"
        return summary j histograms.toString()
    }
}

/** [Load] over [ChannelRunner]: TCP keep-alive connections; dials bind a source alias on a port from SourcePorts. */
class ReactorLoad(
    val runner: ChannelRunner,
    val handle: ChannelOperations.ChannelHandle,
    host: String, port: Port, sources: Series<Ipv4>, vus: Int, first: Int, rampNanos: Long, holdNanos: Long,
    timeoutMillis: Long, users: Series<Twin<String>>, seed: Long,
) : Load(host, port, sources, vus, first, rampNanos, holdNanos, timeoutMillis, users, seed) {
    override val backend: String get() = "ChannelRunner over the context's ReactorOperations"

    override fun drop(c: Connection) {
        c.rx = null
        c.size = 0
        if (c.fd < 0) return
        runner.close(c.fd)
        c.fd = -1
        established--
        disconnects++
    }

    override suspend fun exchange(c: Connection, request: ByteArray): Reply {
        if (c.fd < 0) {
            val fd = runner.tcpDial(host, port, c.source)
            if (fd < 0) { connectFailures++; return -Reason.CONNECT j "" }
            c.fd = fd
            if (++established > peakEstablished) peakEstablished = established
        }
        var sent = 0
        while (sent < request.size) {
            check(handle.writev(c.fd, ByteBuffer(request, sent, request.size - sent)) >= 0) { "SEND not queued" }
            handle.submit()
            val n = handle.wait(1).single().res
            if (n == -11) { runner.writeAsync(c.fd, timeoutMillis) ?: return -Reason.REQUEST_TIMEOUT j ""; continue }
            if (n <= 0) return -Reason.SEND j ""
            sent += n
        }
        while (true) {
            runner.readAsync(c.fd, timeoutMillis) ?: return -Reason.REQUEST_TIMEOUT j ""
            val rx = c.rx?.let { if (c.size == it.size) it.copyOf(it.size * 2) else it } ?: ByteArray(16 * 1024)
            c.rx = rx
            check(handle.readv(c.fd, ByteBuffer(rx, c.size, rx.size - c.size)) >= 0) { "RECV not queued" }
            handle.submit()
            val n = handle.wait(1).single().res
            if (n == -11) continue
            if (n == 0) return -Reason.EOF j ""
            if (n < 0) return -Reason.RECV j ""
            c.size += n
            val head = headEnd(rx, c.size)
            if (head < 0) continue
            val length = contentLength(rx, head)
            if (length < 0 || c.size < head + 4 + length) continue
            val status = (rx[9] - 48) * 100 + (rx[10] - 48) * 10 + (rx[11] - 48)
            val text = rx.decodeToString(head + 4, head + 4 + length).trimEnd()
            c.rx = null
            c.size = 0
            return status j text
        }
    }

    override fun release(c: Connection) {
        if (c.fd >= 0) { runner.close(c.fd); c.fd = -1; established-- }
    }
}

/**
 * [Load] over SCTP: every user is one association of [sctp]'s single UDP socket, a request is one HTX 1.1 message and
 * its response is one message back, so there is no reader loop and no scan for the response's end.
 */
class SctpLoad(
    val server: Endpoint,
    host: String, port: Port, vus: Int, first: Int, rampNanos: Long, holdNanos: Long,
    timeoutMillis: Long, users: Series<Twin<String>>, seed: Long,
) : Load(host, port, emptySeriesOf(), vus, first, rampNanos, holdNanos, timeoutMillis, users, seed), SctpUpper {
    override val backend: String get() = "SCTP over one UDP socket (SctpUdpPort)"
    lateinit var sctp: SctpUdpPort

    override suspend fun exchange(c: Connection, request: ByteArray): Reply {
        var t = c.tcb
        if (t == null) {
            val up = CompletableDeferred<Reply>()
            c.awaiting = up
            t = sctp.connect(server)
            t.upperData = c
            c.tcb = t
            val opened = withTimeoutOrNull(timeoutMillis) { up.await() }
            if (opened == null || opened.a < 0) {
                connectFailures++
                c.tcb = null
                sctp.table.abort(t)
                return -Reason.CONNECT j ""
            }
            if (++established > peakEstablished) peakEstablished = established
        }
        val reply = CompletableDeferred<Reply>()
        c.awaiting = reply
        sctp.submit(t, PPID_HTX11, request, 0, request.size)
        return withTimeoutOrNull(timeoutMillis) { reply.await() } ?: (-Reason.REQUEST_TIMEOUT j "")
    }

    override fun drop(c: Connection) {
        val t = c.tcb ?: return
        c.tcb = null
        c.awaiting = null
        sctp.table.abort(t)
        established--
        disconnects++
    }

    override fun release(c: Connection) {
        val t = c.tcb ?: return
        c.tcb = null
        sctp.table.close(t)
        sctp.kick.trySend(Unit)
        established--
    }

    override fun associated(tcb: SctpTcb) {
        val c = tcb.upperData as? Connection ?: return
        c.awaiting?.let { c.awaiting = null; it.complete(0 j "") }
    }

    /** The whole HTTP/1.1 response in one message: its status and body text. */
    override fun message(tcb: SctpTcb, ppid: Ppid, bytes: ByteArray, offset: Int, length: Int) {
        val c = tcb.upperData as? Connection ?: return
        val w = c.awaiting ?: return
        c.awaiting = null
        val m = bytes.copyOfRange(offset, offset + length)
        val head = headEnd(m, m.size)
        if (head < 0 || m.size < 12) { w.complete(-Reason.RECV j ""); return }
        val n = contentLength(m, head)
        val end = if (n < 0) m.size else minOf(m.size, head + 4 + n)
        val status = (m[9] - 48) * 100 + (m[10] - 48) * 10 + (m[11] - 48)
        w.complete(status j m.decodeToString(head + 4, end).trimEnd())
    }

    override fun closed(tcb: SctpTcb) {
        val c = tcb.upperData as? Connection ?: return
        if (c.tcb === tcb) { c.tcb = null; established--; disconnects++ }
        c.awaiting?.let { c.awaiting = null; it.complete(-Reason.EOF j "") }
    }
}

fun headEnd(bytes: ByteArray, size: Int): Int {
    var i = 3
    while (i < size) {
        if (bytes[i] == 10.toByte() && bytes[i - 1] == 13.toByte() && bytes[i - 2] == 10.toByte() && bytes[i - 3] == 13.toByte()) return i - 3
        i++
    }
    return -1
}

/** Content-Length of the head ending at [end], or -1. */
fun contentLength(bytes: ByteArray, end: Int): Int {
    val head = bytes.decodeToString(0, end).lowercase()
    val at = head.indexOf("content-length:")
    if (at < 0) return -1
    val value = CharSeries(head.substring(at + 15)).trim
    return value.decimal(9, Int.MAX_VALUE) ?: -1
}

fun ids(text: String): LongArray {
    val found = LongArray(32)
    var count = 0
    var at = text.indexOf("{\"id\":")
    while (at >= 0 && count < found.size) {
        var i = at + 6
        var value = 0L
        while (i < text.length && text[i].isDigit()) { value = value * 10 + (text[i] - '0'); i++ }
        found[count++] = value
        at = text.indexOf("{\"id\":", i)
    }
    return found.copyOf(count)
}

/**
 * The client run, from options as `key=value`: host, port, vus, first (index of this process's first user), ramp, hold
 * and drain (seconds), timeout (ms), seed, tokens (file), out (directory), sources (ipv4Range list:
 * 192.168.50.201-208). Elements come from the context by Key: ChannelOperations, ReactorOperations, FileOperations.
 */
suspend fun runLoad(o: Map<String, String>): Boolean = coroutineScope {
    val context = coroutineContext
    val channels = requireNotNull(context[ChannelOperations]) { "no ChannelOperations in the context" }
    val reactor = requireNotNull(context[ReactorOperations]) { "no ReactorOperations in the context" }
    val files = requireNotNull(context[FileOperations]) { "no FileOperations in the context" }
    val vus = (o["vus"] ?: "100").toInt()
    val sources = o["sources"]?.let { text ->
        val ranges = requireNotNull(parseWhole(text) { list { ipv4Range() } }) { "sources must be ipv4Range{,ipv4Range}: $text" }
        val all = mutableListOf<Ipv4>()
        for (range in ranges.view) for (address in range.view) all.add(address)
        all.toSeries()
    } ?: emptySeriesOf()
    val tokens = files.readAllBytes(o["tokens"] ?: "seed/tokens.json").decodeToString()
    val users = Regex("\"username\":\"([^\"]+)\",\"token\":\"([^\"]+)\"").findAll(tokens)
        .map { it.groupValues[1] j it.groupValues[2] }.toList().toSeries()
    val host = o["host"] ?: "127.0.0.1"
    val port = (o["port"] ?: "3000").toInt()
    val first = (o["first"] ?: "0").toInt()
    val ramp = (o["ramp"] ?: "60").toLong() * 1_000_000_000
    val hold = (o["hold"] ?: "300").toLong() * 1_000_000_000
    val timeout = (o["timeout"] ?: "60000").toLong()
    val seed = (o["seed"] ?: "1").toLong()
    val crowd = SupervisorJob(context[Job])
    // transport=sctp: every user an association of one UDP socket on the first source alias; otherwise TCP per user.
    val load: Load
    val stop: suspend () -> Unit
    if (o["transport"] == "sctp") {
        val server = requireNotNull(parseWhole("$host:$port") { endpoint() }) { "transport=sctp needs host as an address: $host" }
        val source = if (sources.size > 0) sources[0] else requireNotNull(parseWhole("0.0.0.0") { ipv4() })
        val sctpLoad = SctpLoad(server, host, port, vus, first, ramp, hold, timeout, users, seed)
        val secret = ByteArray(32).also { platformGetRandom(it) }
        sctpLoad.sctp = SctpUdpPort(channels, reactor, source j SourcePorts.configured().next(source), sctpLoad, secret).open()
        val loop = launch { sctpLoad.sctp.run() }
        load = sctpLoad
        stop = { sctpLoad.sctp.stop(); loop.join(); sctpLoad.sctp.close() }
    } else {
        val runner = ChannelRunner(channels, reactor, capacity = vus + 1)
        load = ReactorLoad(runner, channels.openChannel(64), host, port, sources, vus, first, ramp, hold, timeout, users, seed)
        val loop = runner.run(this)
        stop = { runner.drain(); loop.join() }
    }
    for (index in 0 until vus) launch(crowd) { load.user(index) }
    delay((load.canonicalEnd - load.now()) / 1_000_000)
    load.draining = true
    withTimeoutOrNull((o["drain"] ?: "15").toLong() * 1000) { crowd.children.forEach { it.join() } }
    crowd.cancelAndJoin()
    stop()
    val (summary, histograms) = load.summary()
    val out = o["out"] ?: "loadgen-out"
    files.write("$out/summary.json", summary)
    files.write("$out/histograms.json", histograms)
    print(summary)
    summary.contains("\"pass\":true")
}
