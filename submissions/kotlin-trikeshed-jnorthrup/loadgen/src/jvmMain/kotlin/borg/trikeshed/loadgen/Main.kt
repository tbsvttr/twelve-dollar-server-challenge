package borg.trikeshed.loadgen

import borg.trikeshed.lib.j
import borg.trikeshed.lib.toSeries
import borg.trikeshed.reactor.JvmTlsCodecBackend
import borg.trikeshed.reactor.TlsApplicationProtocol
import borg.trikeshed.reactor.TlsConfig
import borg.trikeshed.reactor.TlsRecordSession
import borg.trikeshed.reactor.TlsRecordSink
import borg.trikeshed.reactor.TlsRole
import borg.trikeshed.reactor.TlsSupportedGroup
import borg.trikeshed.userspace.UringBackendMode
import java.io.File
import java.io.RandomAccessFile
import java.lang.management.ManagementFactory
import java.nio.file.Files
import java.nio.file.Path
import java.security.KeyStore
import java.util.Base64
import java.util.concurrent.TimeUnit
import kotlin.system.exitProcess

/**
 * The feed workload of bench/load.js without k6 or Go, over the central ring and TLS record path.
 *
 *   loadgen identity DIR               P-256 identity for 127.0.0.1 (keytool): DIR/cert.pem, DIR/key.pem (PKCS#8)
 *   loadgen tlsmem N CERT KEY [GROUP]  N in-memory handshakes: server and client CPU per handshake, retained heap
 *                                     (GROUP: the one key-exchange group both sides enable, e.g. X25519 or P256)
 *   loadgen run key=value ...          the workload; see [runLoad]. Exit 0 only when every pass criterion held.
 */
fun main(args: Array<String>) {
    when (args.firstOrNull()) {
        "identity" -> identity(Path.of(args[1]))
        "tlsmem" -> tlsMemory(args[1].toInt(), args[2], args[3], args.getOrNull(4)?.let(TlsSupportedGroup::valueOf))
        "run" -> exitProcess(if (runLoad(args.drop(1).associate { it.substringBefore('=') to it.substringAfter('=') })) 0 else 1)
        else -> error("usage: loadgen identity DIR | tlsmem N CERT KEY | run key=value...")
    }
}

fun identity(directory: Path) {
    Files.createDirectories(directory)
    val store = directory.resolve("identity.p12")
    Files.deleteIfExists(store)
    val keytool = Path.of(java.lang.System.getProperty("java.home"), "bin", "keytool").toString()
    val run = ProcessBuilder(keytool, "-genkeypair", "-alias", "feed", "-keyalg", "EC", "-groupname", "secp256r1",
        "-sigalg", "SHA256withECDSA", "-dname", "CN=127.0.0.1", "-ext", "SAN=IP:127.0.0.1", "-validity", "30",
        "-storetype", "PKCS12", "-keystore", store.toString(), "-storepass", "changeit", "-keypass", "changeit")
        .redirectErrorStream(true).start()
    val output = run.inputStream.readAllBytes().decodeToString()
    check(run.waitFor(60, TimeUnit.SECONDS) && run.exitValue() == 0) { output }
    val keyStore = KeyStore.getInstance("PKCS12")
    Files.newInputStream(store).use { keyStore.load(it, "changeit".toCharArray()) }
    val mime = Base64.getMimeEncoder(64, "\n".toByteArray())
    fun pem(label: String, der: ByteArray) = "-----BEGIN $label-----\n${mime.encodeToString(der)}\n-----END $label-----\n"
    Files.writeString(directory.resolve("cert.pem"), pem("CERTIFICATE", keyStore.getCertificate("feed").encoded))
    Files.writeString(directory.resolve("key.pem"), pem("PRIVATE" + " KEY", keyStore.getKey("feed", "changeit".toCharArray()).encoded))
    Files.delete(store)
    println("identity: ${directory.resolve("cert.pem")} ${directory.resolve("key.pem")}")
}

/**
 * N handshakes in memory through one backend (one shared context per side). Measured as labelled: the server figure
 * is the CPU of the server session's receive() calls only (not engine creation or begin()); the client figure
 * covers begin() and receive(); the heap figure is the post-GC heap delta per kept server session, which also holds
 * any growth of the shared session caches. Constrained-process measurements, not these, decide capacity.
 */
fun tlsMemory(count: Int, cert: String, key: String, group: TlsSupportedGroup? = null) {
    val backend = JvmTlsCodecBackend()
    val alpn = listOf(TlsApplicationProtocol.HTTP_1_1).toSeries()
    val groups = (if (group == null) TlsSupportedGroup.entries else listOf(group)).toSeries()
    val server = TlsConfig(certificateFile = cert, privateKeyFile = key, hostnameVerification = false, alpnProtocols = alpn,
        supportedGroups = groups)
    val client = TlsConfig(trustStore = cert, hostnameVerification = false, alpnProtocols = alpn, supportedGroups = groups)
    val threads = ManagementFactory.getThreadMXBean()
    class Wire : TlsRecordSink {
        val bytes = java.io.ByteArrayOutputStream()
        override fun plaintext(bytes: ByteArray, from: Int, to: Int) {}
        override fun ciphertext(bytes: ByteArray, from: Int, to: Int) = this.bytes.write(bytes, from, to - from)
        fun take(): ByteArray = bytes.toByteArray().also { bytes.reset() }
    }
    fun measure(n: Int, keep: Boolean): Triple<Long, Long, Array<TlsRecordSession?>> {
        var serverCpu = 0L
        var clientCpu = 0L
        val kept = arrayOfNulls<TlsRecordSession>(if (keep) n else 0)
        for (i in 0 until n) {
            val s = backend.recordSession(server, TlsRole.SERVER j ("" j 0))
            val c = backend.recordSession(client, TlsRole.CLIENT j ("" j 443))
            val sw = Wire()
            val cw = Wire()
            var t = threads.currentThreadCpuTime
            c.begin(cw)
            clientCpu += threads.currentThreadCpuTime - t
            s.begin(sw)
            repeat(8) {
                val toServer = cw.take()
                val toClient = sw.take()
                if (toServer.isNotEmpty()) {
                    t = threads.currentThreadCpuTime
                    check(s.receive(toServer, 0, toServer.size, sw))
                    serverCpu += threads.currentThreadCpuTime - t
                }
                if (toClient.isNotEmpty()) {
                    t = threads.currentThreadCpuTime
                    check(c.receive(toClient, 0, toClient.size, cw))
                    clientCpu += threads.currentThreadCpuTime - t
                }
            }
            check(s.established && c.established) { "handshake $i did not finish" }
            if (keep) kept[i] = s
        }
        return Triple(serverCpu, clientCpu, kept)
    }
    measure(minOf(2000, count), keep = false) // warm the JIT
    val runtime = Runtime.getRuntime()
    fun used(): Long {
        repeat(3) { System.gc(); Thread.sleep(200) }
        return runtime.totalMemory() - runtime.freeMemory()
    }
    val before = used()
    val (serverCpu, clientCpu, kept) = measure(count, keep = true)
    val after = used()
    println("{\"handshakes\":$count,\"serverReceiveCpuMicrosPerHandshake\":${serverCpu / 1000 / count}," +
        "\"clientBeginReceiveCpuMicrosPerHandshake\":${clientCpu / 1000 / count},\"heapDeltaBytesPerKeptServerSession\":${(after - before) / count}," +
        "\"group\":\"${group ?: "default order"}\",\"protocol\":\"${(kept[0] as TlsRecordSession).session?.protocol}\",\"suite\":\"${kept[0]!!.session?.cipherSuite}\"," +
        "\"java\":\"${java.lang.System.getProperty("java.vm.name")} ${java.lang.System.getProperty("java.version")}\"}")
    check(kept.size == count)
}

/** One complete line of the server's STATS_FILE: its wall-clock stamp and the counters the holds are judged by. */
class ServerSnapshot(val t: Long, val live: Long, val established: Long, val accepted: Long, val closed: Long)

/**
 * The newest COMPLETE line (newline-terminated) of the server's STATS_FILE, or null when there is none. A partial
 * last line is ignored; the caller judges freshness by [ServerSnapshot.t].
 */
fun serverSnapshot(file: File?): ServerSnapshot? {
    if (file == null || !file.exists()) return null
    RandomAccessFile(file, "r").use { f ->
        val length = f.length()
        val from = maxOf(0L, length - 16384)
        val bytes = ByteArray((length - from).toInt())
        f.seek(from)
        f.readFully(bytes)
        val text = String(bytes, Charsets.UTF_8)
        val complete = text.substring(0, text.lastIndexOf('\n') + 1)
        val last = complete.split('\n').lastOrNull { it.startsWith("{\"t\":") && it.endsWith("}") } ?: return null
        fun field(name: String): Long? = Regex("\"$name\":(\\d+)").find(last)?.groupValues?.get(1)?.toLong()
        return ServerSnapshot(field("t") ?: return null, field("live") ?: return null, field("established") ?: return null,
            field("accepted") ?: return null, field("closed") ?: return null)
    }
}

/**
 * The feed workload. Keys (defaults): host (127.0.0.1), ports (3000), tls (true), cert (trust anchor PEM), vus (100),
 * ramp (60, seconds), hold (300), threads (4), entries (4096), mode (emulated|native|auto), tokens
 * (seed/tokens.json), seed (1), timeout (60, seconds per request), sources (source IPv4s to bind, round-robin),
 * out (summary directory), serverStats (the server's STATS_FILE: its counters join the timeline and gate the
 * established hold), establish (120: seconds after the ramp for client and server to count every user established),
 * drain (15: seconds for outstanding requests after the run), guard (a cgroup directory whose memory.current freezes
 * the ramp above guardBytes and stops the run above stopBytes), parkMicros (0: workers wait for completions in
 * io_uring_enter; else they park in user space at most this long between completion peeks).
 *
 * The run lasts until both holds have ended: the canonical one at ramp + hold, the established one hold seconds after
 * it started. Pass: workers ended cleanly having seen every CQE; the established hold started, lasted its full length
 * and, on every fresh server sample through it (at most 3 s apart, covering its start and end), client and server
 * both counted every user established; p95 < 500 ms, p99 < 1000 ms and under 1% failed requests (unfinished ones count
 * as failed, and their wait so far is in the quantiles) over the whole run and over the established hold; no failed
 * body check; the memory guard never acted.
 */
fun reasons(counts: java.util.concurrent.atomic.AtomicLongArray): String =
    Reason.NAMES.indices.joinToString(",", "{", "}") { "\"${Reason.NAMES[it]}\":${counts.get(it)}" }

/** Nonzero errno counts as {"errno":count}; the last slot also holds larger errnos. */
fun errnos(counts: java.util.concurrent.atomic.AtomicLongArray): String =
    (0 until counts.length()).filter { counts.get(it) > 0 }.joinToString(",", "{", "}") { "\"$it\":${counts.get(it)}" }

fun runLoad(o: Map<String, String>): Boolean {
    val users = Regex("\"username\":\"([^\"]+)\",\"token\":\"([^\"]+)\"").findAll(File(o["tokens"] ?: "seed/tokens.json").readText())
        .map { it.groupValues[1] to it.groupValues[2] }.toList()
    check(users.isNotEmpty()) { "no tokens" }
    val ports = (o["ports"] ?: "3000").split(',').map { it.trim().toInt() }.toIntArray()
    val plan = Plan(o["host"] ?: "127.0.0.1", ports, (o["tls"] ?: "true").toBoolean(), o["cert"], (o["vus"] ?: "100").toInt(),
        (o["ramp"] ?: "60").toLong() * 1_000_000_000L, (o["hold"] ?: "300").toLong() * 1_000_000_000L,
        (o["threads"] ?: "4").toInt(), (o["entries"] ?: "4096").toInt(), o["mode"]?.let(UringBackendMode::parse), users,
        (o["seed"] ?: "1").toLong(), (o["timeout"] ?: "60").toLong() * 1_000_000_000L,
        (o["sources"] ?: "").split(',').filter { it.isNotBlank() }, (o["parkMicros"] ?: "0").toLong() * 1000L,
        (o["rxWindows"] ?: "256").toInt())
    val serverStats = o["serverStats"]?.let(::File)
    val establishNanos = (o["establish"] ?: "120").toLong() * 1_000_000_000L
    val drainNanos = (o["drain"] ?: "15").toLong() * 1_000_000_000L
    val out = File(o["out"] ?: "loadgen-out").also { it.mkdirs() }
    val workers = (0 until plan.threads).map { id ->
        val mine = (0 until plan.vus).filter { it % plan.threads == id }
        // load.js: user = tokens[(__VU - 1) % tokens.length]; ports alternate so the users share them evenly.
        Worker(plan, id, Array(mine.size) { local -> Vu(mine[local], local, mine[local] % users.size, ports[mine[local] % ports.size]) })
    }
    val threads = workers.mapIndexed { i, w -> Thread(w, "loadgen-$i").also { it.start() } }
    val guard = o["guard"]?.let { File(it, "memory.current") }
    val guardBytes = (o["guardBytes"] ?: "${1900L shl 20}").toLong()
    val stopBytes = (o["stopBytes"] ?: "${2040L shl 20}").toLong()
    val timeline = out.resolve("timeline.jsonl").bufferedWriter()
    var canonicalMin = Long.MAX_VALUE
    var canonicalMax = 0L
    var clientWindowMin = Long.MAX_VALUE
    var serverWindowMin = Long.MAX_VALUE
    var serverLiveWindowMin = Long.MAX_VALUE
    var freshSamples = 0
    var staleSamples = 0
    /** Server lines stamped after the client read them: not this run's clock, never counted as fresh. */
    var futureSamples = 0
    var lastFresh = -1L
    var firstWindowFresh = -1L
    var lastWindowFresh = -1L
    var maxGapMillis = 0L
    var windowStartServer: ServerSnapshot? = null
    var windowEndServer: ServerSnapshot? = null
    var windowStartDisconnects = 0L
    var windowStartHandshakes = 0L
    var holdEnded = false
    var peakEstablished = 0L
    var guardEvent = ""
    var endReason = "both holds ended"
    var lastFinished = 0L
    while (true) {
        Thread.sleep(1000)
        val now = System.nanoTime()
        val established = plan.established.get()
        val snapshot = serverSnapshot(serverStats)
        // The clock is read after the file, so a line the server stamped before writing it is never ahead of it.
        val wall = System.currentTimeMillis()
        if (snapshot != null && snapshot.t > wall) futureSamples++
        // Fresh: a complete line the server wrote in the last 2.5 s (it writes one about every second), not ahead.
        val server = snapshot?.takeIf { it.t <= wall && wall - it.t <= 2500 }
        if (established > peakEstablished) peakEstablished = established
        if (now >= plan.canonicalStart + 5_000_000_000L && now < plan.canonicalEnd) {
            canonicalMin = minOf(canonicalMin, established)
            canonicalMax = maxOf(canonicalMax, established)
        }
        if (plan.establishedStart == Long.MAX_VALUE && now >= plan.canonicalStart && established >= plan.vus &&
            (serverStats == null || (server != null && server.established >= plan.vus))) {
            plan.establishedStart = now
            windowStartServer = server
            windowStartDisconnects = plan.disconnects.get()
            windowStartHandshakes = plan.handshakes.get()
        }
        if (plan.inEstablishedWindow(now)) {
            clientWindowMin = minOf(clientWindowMin, established)
            if (serverStats != null) {
                if (server != null && server.t != lastFresh) {
                    serverWindowMin = minOf(serverWindowMin, server.established)
                    serverLiveWindowMin = minOf(serverLiveWindowMin, server.live)
                    if (firstWindowFresh < 0) firstWindowFresh = server.t
                    if (lastWindowFresh >= 0) maxGapMillis = maxOf(maxGapMillis, server.t - lastWindowFresh)
                    lastWindowFresh = server.t
                    windowEndServer = server
                    freshSamples++
                } else staleSamples++
            }
        }
        if (server != null) lastFresh = server.t
        val memory = guard?.takeIf { it.exists() }?.readText()?.trim()?.toLongOrNull() ?: -1L
        if (memory > stopBytes) {
            guardEvent = "stopped at memory.current=$memory"
            plan.stop = true
        } else if (memory > guardBytes && !plan.frozen) {
            guardEvent = "ramp frozen at memory.current=$memory, ${plan.activated.get()} users"
            plan.frozen = true
        }
        val finished = plan.finished.get()
        timeline.write("{\"t\":$wall,\"elapsed\":${(now - plan.started) / 1_000_000},\"activated\":${plan.activated.get()}," +
            "\"connected\":${plan.connected.get()},\"established\":$established,\"serverT\":${snapshot?.t ?: -1}," +
            "\"serverFresh\":${server != null},\"serverLive\":${server?.live ?: -1},\"serverEstablished\":${server?.established ?: -1}," +
            "\"perSecond\":${finished - lastFinished},\"failures\":${plan.failures.get()},\"connectFailures\":${plan.connectFailures.get()}," +
            "\"disconnects\":${plan.disconnects.get()},\"serverMemory\":$memory," +
            "\"window\":\"${if (plan.inEstablishedWindow(now)) "established" else if (now >= plan.canonicalStart && now < plan.canonicalEnd) "canonical" else ""}\"}\n")
        timeline.flush()
        lastFinished = finished
        if (plan.stop) { endReason = "memory guard stop"; break }
        if (threads.any { !it.isAlive }) { endReason = "a worker ended early"; break }
        if (plan.establishedStart == Long.MAX_VALUE && now >= plan.canonicalStart + establishNanos) {
            endReason = "established hold never started: client $established, server ${server?.established ?: -1} of ${plan.vus} within ${establishNanos / 1_000_000_000} s after the ramp"
            break
        }
        if (now >= plan.canonicalEnd && now >= plan.establishedEnd) {
            holdEnded = true
            break
        }
    }
    val windowDisconnects = plan.disconnects.get() - windowStartDisconnects
    val windowHandshakes = plan.handshakes.get() - windowStartHandshakes
    plan.drainDeadline = System.nanoTime() + drainNanos
    plan.draining = true
    for (t in threads) t.join(drainNanos / 1_000_000 + 20_000)
    timeline.close()
    val alive = threads.filter { it.isAlive }.map { it.name }
    val merged = Array(3) { Array(4) { KindStats() } }
    val connects = Histogram()
    val workerFailures = ArrayList<String>()
    for ((i, w) in workers.withIndex()) {
        if (threads[i].isAlive) continue // its mutable state is not ours to read
        w.failure?.let { workerFailures.add("${threads[i].name}: $it") }
        if (!w.drained) workerFailures.add("${threads[i].name}: SQEs without CQEs at its end")
        connects.add(w.connects)
        for (scope in 0 until 3) for (k in 0 until 4) merged[scope][k].add(w.stats[scope][k])
    }
    fun histogram(h: Histogram) = "{\"count\":${h.total},\"p50\":${h.percentile(50.0)},\"p95\":${h.percentile(95.0)},\"p99\":${h.percentile(99.0)},\"max\":${h.max}}"
    val holdMillis = plan.holdNanos / 1_000_000
    val failed = ArrayList<String>()
    if (alive.isNotEmpty()) failed.add("workers still running: $alive")
    failed.addAll(workerFailures)
    if (plan.establishedStart == Long.MAX_VALUE) failed.add(endReason)
    else {
        if (!holdEnded) failed.add("the established hold did not run its full ${holdMillis / 1000} s: $endReason")
        if (clientWindowMin < plan.vus) failed.add("client established fell to $clientWindowMin of ${plan.vus} in the established hold")
        if (serverStats != null) {
            if (freshSamples == 0 || serverWindowMin < plan.vus) failed.add("server established fell to $serverWindowMin of ${plan.vus} in the established hold")
            val startOffset = if (firstWindowFresh < 0) Long.MAX_VALUE else firstWindowFresh - windowStartServer!!.t
            val endCoverage = if (lastWindowFresh < 0 || firstWindowFresh < 0) 0L else lastWindowFresh - (windowStartServer!!.t)
            if (freshSamples < holdMillis / 1000 - 3 || maxGapMillis > 3000 || startOffset > 3000 || endCoverage < holdMillis - 3000) {
                failed.add("server samples do not cover the established hold: $freshSamples fresh, $staleSamples stale, max gap $maxGapMillis ms, coverage $endCoverage of $holdMillis ms")
            }
        }
    }
    if (plan.establishedStart != Long.MAX_VALUE) {
        val events = plan.holdEventCount.get()
        if (events > 0) failed.add("$events client events in the established hold (first: ${plan.holdEvents.peek()})")
        if (serverStats != null && windowStartServer != null && windowEndServer != null) {
            val acceptedIn = windowEndServer.accepted - windowStartServer.accepted
            val closedIn = windowEndServer.closed - windowStartServer.closed
            if (acceptedIn != 0L || closedIn != 0L) failed.add("server accepted $acceptedIn and closed $closedIn connections in the established hold")
        }
    }
    if (futureSamples > 0) failed.add("$futureSamples server stats lines were stamped ahead of the client's clock")
    if (guardEvent.isNotEmpty()) failed.add("memory guard: $guardEvent")
    val scopes = StringBuilder()
    val histograms = StringBuilder("{")
    for (scope in 0 until 3) {
        val total = KindStats().also { t -> merged[scope].forEach { t.add(it) } }
        val requests = total.ok + total.failed + total.unfinished
        val failRate = if (requests == 0L) 0.0 else (total.failed + total.unfinished).toDouble() / requests
        if (scope != CANONICAL && !(scope == ESTABLISHED && plan.establishedStart == Long.MAX_VALUE)) {
            val name = SCOPES[scope]
            if (total.latency.percentile(95.0) >= 500_000) failed.add("$name p95 ${total.latency.percentile(95.0)} us >= 500 ms")
            if (total.latency.percentile(99.0) >= 1_000_000) failed.add("$name p99 ${total.latency.percentile(99.0)} us >= 1000 ms")
            if (failRate >= 0.01) failed.add("$name failed ${"%.4f".format(failRate)} >= 1%")
            if (requests == 0L) failed.add("$name has no requests")
        }
        if (scope == RUN && total.checksFailed > 0) failed.add("${total.checksFailed} body checks failed")
        if (scope > 0) scopes.append(',')
        scopes.append("\"${SCOPES[scope]}\":{\"requests\":$requests,\"ok\":${total.ok},\"failed\":${total.failed},\"unfinished\":${total.unfinished},")
        scopes.append("\"drained\":${total.drained},\"checksFailed\":${total.checksFailed},\"failRate\":${"%.6f".format(failRate)},\"latencyMicros\":${histogram(total.latency)},\"kinds\":{")
        for (k in 0 until 4) {
            val s = merged[scope][k]
            if (k > 0) scopes.append(',')
            scopes.append("\"${KINDS[k]}\":{\"ok\":${s.ok},\"failed\":${s.failed},\"unfinished\":${s.unfinished},\"drained\":${s.drained},")
            scopes.append("\"checksFailed\":${s.checksFailed},\"latencyMicros\":${histogram(s.latency)}}")
        }
        scopes.append("}}")
        if (scope > 0) histograms.append(',')
        histograms.append("\"${SCOPES[scope]}\":[")
        var first = true
        for (i in total.latency.counts.indices) {
            val n = total.latency.counts[i]
            if (n == 0L) continue
            if (!first) histograms.append(',')
            first = false
            histograms.append("[${total.latency.lower(i)},${total.latency.upper(i)},$n]")
        }
        histograms.append("]")
    }
    histograms.append("}\n")
    out.resolve("histograms.json").writeText(histograms.toString())
    val pass = failed.isEmpty()
    val holdSeconds = plan.holdNanos / 1e9
    val established = plan.establishedStart
    fun min(v: Long) = if (v == Long.MAX_VALUE) -1 else v
    val summary = buildString {
        append("{\"vus\":${plan.vus},\"rampSeconds\":${plan.rampNanos / 1_000_000_000},\"holdSeconds\":$holdSeconds,\"threads\":${plan.threads},")
        append("\"tls\":${plan.tls},\"tlsSession\":\"${plan.protocol.get() ?: ""}\",\"tlsResumption\":\"none: client engines carry no peer host, so no session is offered for resumption\",")
        append("\"ports\":\"${ports.joinToString(",")}\",\"clientWait\":\"${if (plan.parkNanos > 0) "park ${plan.parkNanos / 1000} us" else "io_uring_enter"}\",\"mode\":\"${plan.mode ?: "process"}\",\"clientBackend\":\"${workers.first().backend.replace("\"", "'")}\",")
        append("\"users\":${users.size},\"seed\":${plan.seed},\"activated\":${plan.activated.get()},\"peakEstablished\":$peakEstablished,")
        append("\"handshakes\":${plan.handshakes.get()},\"connectFailures\":${plan.connectFailures.get()},\"tlsFailures\":${plan.tlsFailures.get()},\"tlsRefused\":${plan.tlsRefused.get()},\"sendRetries\":${plan.sendRetries.get()},\"failReasons\":${reasons(plan.failReasons)},\"lostReasons\":${reasons(plan.lostReasons)},\"errnos\":${errnos(plan.errnos)},")
        append("\"disconnects\":${plan.disconnects.get()},\"guard\":\"$guardEvent\",\"end\":\"$endReason\",")
        append("\"canonicalHold\":{\"startSeconds\":${plan.rampNanos / 1e9},\"clientEstablishedMinAfter5s\":${min(canonicalMin)},\"clientEstablishedMax\":$canonicalMax},")
        append("\"establishedHold\":{\"startSeconds\":${if (established == Long.MAX_VALUE) -1.0 else (established - plan.started) / 1e9},")
        append("\"ended\":$holdEnded,\"clientEstablishedMin\":${min(clientWindowMin)},\"serverEstablishedMin\":${min(serverWindowMin)},")
        append("\"serverLiveMin\":${min(serverLiveWindowMin)},\"serverFreshSamples\":$freshSamples,\"serverStaleSamples\":$staleSamples,")
        append("\"serverMaxGapMillis\":$maxGapMillis,\"serverFirstT\":$firstWindowFresh,\"serverLastT\":$lastWindowFresh,")
        append("\"serverAcceptedDelta\":${if (windowStartServer != null && windowEndServer != null) windowEndServer.accepted - windowStartServer.accepted else -1},")
        append("\"serverClosedDelta\":${if (windowStartServer != null && windowEndServer != null) windowEndServer.closed - windowStartServer.closed else -1},")
        append("\"clientHandshakesInWindow\":$windowHandshakes,\"clientDisconnectsInWindow\":$windowDisconnects,")
        append("\"serverFutureSamples\":$futureSamples,\"clientEvents\":${plan.holdEventCount.get()},\"clientEventsKept\":[${plan.holdEvents.joinToString(",")}]},")
        append("\"connectAndHandshakeMicros\":${histogram(connects)},")
        append("\"histogram\":\"quantiles are upper bounds of log-linear buckets (64 per octave, at most 1.6% above the exact value); buckets in histograms.json\",")
        append("\"sampleScope\":\"a request belongs to a hold when its first byte left inside it (k6 http_req_duration: after connect and TLS); drained = finished after the hold ended; unfinished = outstanding at the drain deadline, counted as failed, with the wait until then in the quantiles\",")
        append("\"scopes\":{").append(scopes).append("},")
        append("\"outcome\":{\"pass\":$pass,\"failed\":[${failed.joinToString(",") { "\"" + it.replace("\"", "'") + "\"" }}]}}")
    }
    out.resolve("summary.json").writeText(summary + "\n")
    println(summary)
    return pass
}
