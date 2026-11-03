package borg.trikeshed.loadgen

import borg.trikeshed.lib.j
import borg.trikeshed.lib.toSeries
import borg.trikeshed.reactor.JvmTlsCodecBackend
import borg.trikeshed.reactor.JvmTlsRecordSession
import borg.trikeshed.reactor.TlsApplicationProtocol
import borg.trikeshed.reactor.TlsConfig
import borg.trikeshed.reactor.TlsRecordSession
import borg.trikeshed.reactor.TlsRecordSink
import borg.trikeshed.reactor.TlsSendOutcome
import borg.trikeshed.reactor.TlsRole
import borg.trikeshed.userspace.LiburingFacade
import borg.trikeshed.userspace.UringBackendMode
import borg.trikeshed.userspace.UringCompletion
import borg.trikeshed.userspace.noDelay
import borg.trikeshed.userspace.openLiburingFacade
import java.lang.foreign.Arena
import java.lang.foreign.MemorySegment
import java.lang.foreign.ValueLayout
import java.time.Instant
import java.time.temporal.ChronoUnit
import java.util.SplittableRandom
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicLongArray
import java.util.concurrent.locks.LockSupport
import java.util.concurrent.atomic.AtomicReference

const val OP_SOCKET = 1L
const val OP_CONNECT = 2L
const val OP_POLL_IN = 3L
const val OP_RECV = 4L
const val OP_SEND = 5L
const val OP_CLOSE = 6L
const val OP_BIND = 7L
const val OP_POLL_OUT = 8L
const val POLLOUT = 4
const val POLLERR = 8
const val POLLHUP = 0x10
const val RX = 17 * 1024
const val TX = 16 * 1024
const val WINDOWS = 256
const val STRAY = 0xFFFFFL

/** The shared plan every worker reads. */
class Plan(
    val host: String, val ports: IntArray, val tls: Boolean, val trust: String?, val vus: Int, val rampNanos: Long,
    val holdNanos: Long, val threads: Int, val entries: Int, val mode: UringBackendMode?, val users: List<Pair<String, String>>,
    val seed: Long, val timeoutNanos: Long, val sources: List<String>,
    /** 0: wait for completions in io_uring_enter. Else park in user space for at most this long between peeks. */
    val parkNanos: Long = 0L,
    /** Receive windows per worker (the tiny-pool regression uses 1). */
    val rxWindows: Int = WINDOWS,
) {
    val started = System.nanoTime() + 1_000_000_000L
    val canonicalStart get() = started + rampNanos
    val canonicalEnd get() = canonicalStart + holdNanos
    @Volatile var establishedStart = Long.MAX_VALUE
    val establishedEnd get() = establishedStart.let { if (it == Long.MAX_VALUE) it else it + holdNanos }
    @Volatile var frozen = false
    @Volatile var stop = false
    @Volatile var draining = false
    @Volatile var drainDeadline = Long.MAX_VALUE
    val established = AtomicLong()
    val connected = AtomicLong()
    val handshakes = AtomicLong()
    val connectFailures = AtomicLong()
    val tlsFailures = AtomicLong()
    /** Failed requests by [Reason], and connections ended by [Reason]; no payload or credential is kept. */
    val failReasons = AtomicLongArray(Reason.NAMES.size)
    val lostReasons = AtomicLongArray(Reason.NAMES.size)
    /** Transport CQE errors by errno (the last slot collects any larger errno). */
    val errnos = AtomicLongArray(160)
    /** Requests a TLS session refused (closed, or BACKPRESSURE): each one lost its connection. */
    val tlsRefused = AtomicLong()
    val disconnects = AtomicLong()
    val activated = AtomicLong()
    val finished = AtomicLong()
    val failures = AtomicLong()
    val windowHandshakes = AtomicLong()
    val windowDisconnects = AtomicLong()
    /** SENDs that found the socket's buffer full (-EAGAIN) and were retried once it was writable. */
    val sendRetries = AtomicLong()
    val protocol = AtomicReference<String?>(null)
    val tlsBackend = JvmTlsCodecBackend()
    val tlsConfig = TlsConfig(trustStore = trust, hostnameVerification = false,
        alpnProtocols = listOf(TlsApplicationProtocol.HTTP_1_1).toSeries())

    fun inEstablishedWindow(at: Long): Boolean = establishedStart.let { it != Long.MAX_VALUE && at >= it && at < it + holdNanos }

    /**
     * Client events inside the established hold, each stamped with the wall clock when it happened: every
     * (re)connection, dropped connection (a timeout's included), failed request and unexpected status. All are counted;
     * the first [HOLD_EVENT_LIMIT] are kept. Any one of them interrupts the hold, however briefly, between samples.
     */
    val holdEvents = java.util.concurrent.ConcurrentLinkedQueue<String>()
    val holdEventCount = AtomicLong()

    fun holdEvent(at: Long, kind: String, reason: Int, vu: Int) {
        if (!inEstablishedWindow(at)) return
        if (holdEventCount.incrementAndGet() > HOLD_EVENT_LIMIT) return
        val why = if (reason in Reason.NAMES.indices) Reason.NAMES[reason] else "-"
        holdEvents.add("{\"t\":${System.currentTimeMillis()},\"holdMillis\":${(at - establishedStart) / 1_000_000},\"kind\":\"$kind\",\"reason\":\"$why\",\"vu\":$vu}")
    }
}

/** One virtual user: a person browsing the feed with think time, on its own keep-alive connection. */
class Vu(val index: Int, val local: Int, val user: Int, val port: Int) {
    var fd = -1
    var gen = 0
    var tls: TlsRecordSession? = null
    var connected = false
    var established = false
    var connecting = false
    var iter = 0
    var postId = 0L
    var step = 0
    var kind = -1
    var sentAt = 0L
    var connectAt = 0L
    var seq = 0
    var response: ByteArray? = null
    var responseSize = 0
    var out: ByteArray? = null
    var outSize = 0
    var sending = false
    var sendLen = 0
    var sendDone = 0
    var polling = false
    var receiving = false
    /** Holding a place in its worker's window queue ([RxPlaces]); like the watch and the RECV, one at most. */
    var rxQueued = false
    var request: ByteArray? = null
}

/**
 * Users waiting for a receive window, in order. A place names the user's connection generation, so a place left by a
 * connection that closed (a timeout, a reset) is void: a reconnected user never inherits it, and never gets a RECV on
 * its new socket while that socket's watch is armed. A user holds at most one place, and none while it watches or
 * reads.
 */
class RxPlaces(val users: Array<Vu>) {
    val places = ArrayDeque<Long>()
    val size: Int get() = places.size

    fun queue(v: Vu) {
        check(!v.rxQueued && !v.polling && !v.receiving) { "user ${v.index}: a second place, watch or read" }
        v.rxQueued = true
        places.addLast((v.local.toLong() shl 28) or v.gen.toLong())
    }

    /** The next user whose place is still its own and who may read now, or null; void places are dropped. */
    fun next(): Vu? {
        while (places.isNotEmpty()) {
            val place = places.removeFirst()
            val v = users[(place ushr 28).toInt()]
            if (v.gen != (place and 0x0FFFFFFFL).toInt() || !v.rxQueued) continue
            v.rxQueued = false
            if (v.connected && !v.receiving && !v.polling) return v
        }
        return null
    }
}

/**
 * One thread's share of the users over its own ring. The worker owns its ring, sockets and window arena: when it ends
 * it closes every socket, waits for every CQE, closes the ring and only then releases the windows.
 */
class Worker(val plan: Plan, val id: Int, val vus: Array<Vu>) : Runnable {
    val stats = Array(3) { Array(4) { KindStats() } }
    val connects = Histogram()
    @Volatile var failure: Throwable? = null
    @Volatile var drained = false
    val ring: LiburingFacade = openLiburingFacade(plan.entries, plan.mode)
    val backend: String = ring.availability
    val arena = Arena.ofShared()
    val rx = arena.allocate((RX * plan.rxWindows).toLong(), 64)
    val tx = arena.allocate((TX * WINDOWS).toLong(), 64)
    val rxFree = IntArray(plan.rxWindows) { it }
    var rxTop = plan.rxWindows
    val txFree = IntArray(WINDOWS) { it }
    var txTop = WINDOWS
    val txOf = IntArray(vus.size) { -1 }
    val waitRx = RxPlaces(vus)
    val waitTx = ArrayDeque<Vu>()
    val rxHeap = ByteArray(RX)
    val addresses = HashMap<Int, MemorySegment>()
    val sourceAddresses = plan.sources.map { address(it, 0) }
    val random = SplittableRandom(plan.seed + id)
    var heapTime = LongArray(1024)
    var heapVu = IntArray(1024)
    var heapSeq = IntArray(1024)
    var heapSize = 0
    var current: Vu? = null
    val plain = java.io.ByteArrayOutputStream()
    val sink = object : TlsRecordSink {
        override fun plaintext(bytes: ByteArray, from: Int, to: Int) = plain.write(bytes, from, to - from)
        override fun ciphertext(bytes: ByteArray, from: Int, to: Int) = append(current!!, bytes, from, to)
    }
    /** CQEs reaped and not yet handled, in order; a stage that finds the ring full reaps into it wherever it runs. */
    var batch = LongArray(1024)
    var batchRes = IntArray(1024)
    var batchCount = 0
    var batchHead = 0
    var handling = false
    var nextActivation = 0
    var sqes = 0L
    var outstanding = 0
    var strays = 0L

    fun address(host: String, port: Int): MemorySegment = arena.allocate(16).also { a ->
        val octets = host.split('.').map { it.toInt() }
        a.set(ValueLayout.JAVA_BYTE, 0, 2)
        a.set(ValueLayout.JAVA_BYTE, 2, (port shr 8).toByte())
        a.set(ValueLayout.JAVA_BYTE, 3, port.toByte())
        for (i in 0 until 4) a.set(ValueLayout.JAVA_BYTE, 4L + i, octets[i].toByte())
    }

    /** op 4 bits, user 20 bits, window 12 bits (RECV/SEND), connection generation 28 bits. */
    fun token(v: Vu, op: Long, window: Int = 0): Long =
        (v.gen.toLong() shl 36) or (window.toLong() shl 24) or (v.local.toLong() shl 4) or op

    /** CLOSE of a socket whose connection was abandoned before its SOCKET CQE: no user owns it. */
    fun strayToken(): Long = ((strays++ and 0x0FFFFFFFL) shl 36) or (STRAY shl 4) or OP_CLOSE

    override fun run() {
        var error: Throwable? = null
        try {
            loop()
        } catch (t: Throwable) {
            error = t
        }
        try {
            drained = shutdown()
        } catch (t: Throwable) {
            if (error == null) error = t else error.addSuppressed(t)
        }
        val ringClosed = ring.close().exceptionOrNull()
        if (ringClosed != null) if (error == null) error = ringClosed else error.addSuppressed(ringClosed)
        if (drained) arena.close()
        failure = error
    }

    fun loop() {
        while (!plan.stop) {
            val now = System.nanoTime()
            if (plan.draining && (outstanding == 0 || now >= plan.drainDeadline)) break
            if (!plan.draining) activate(now)
            while (heapSize > 0 && heapTime[0] <= now) {
                val v = vus[heapVu[0]]
                val seq = heapSeq[0]
                pop()
                if (v.seq == seq) fire(v, now)
            }
            if (batchHead < batchCount) drainBatch()
            ring.submit().getOrThrow()
            val wake = if (heapSize > 0) heapTime[0] - System.nanoTime() else 50_000_000L
            val first = if (plan.parkNanos > 0L) {
                // Parked in user space rather than in io_uring_enter, a completion only queues task work for this
                // thread (COOP_TASKRUN) instead of waking it: on loopback the server's send then pays no wakeup of
                // the client. The park's syscall exit runs the queued work, so the CQEs are there to peek.
                ring.peekCqe().getOrThrow() ?: run {
                    LockSupport.parkNanos(wake.coerceIn(1_000L, plan.parkNanos))
                    ring.peekCqe().getOrThrow()
                }
            } else ring.waitCqeTimeout(wake.coerceIn(100_000L, 50_000_000L)).getOrThrow()
            if (first != null) process(first)
        }
        val end = System.nanoTime()
        for (v in vus) {
            val kind = v.kind
            if (kind < 0) continue
            v.kind = -1
            terminated(kind, v.sentAt, end)
        }
    }

    /** A request still outstanding when the worker ends: the wait so far joins the histograms, counted as unfinished. */
    fun terminated(kind: Int, start: Long, end: Long) {
        val micros = (end - start) / 1000
        for (scope in 0 until 3) {
            if (!inScope(scope, start)) continue
            val s = stats[scope][kind]
            s.latency.record(micros)
            s.unfinished++
        }
    }

    /** Every socket closes; true once every SQE has its CQE (within 10 s). */
    fun shutdown(): Boolean {
        for (v in vus) if (v.fd >= 0 || v.connecting) closeFd(v)
        val start = System.nanoTime()
        while (sqes > 0 || batchHead < batchCount) {
            if (System.nanoTime() - start > 10_000_000_000L) return false
            if (batchHead < batchCount) {
                drainBatch()
                continue
            }
            ring.submit().getOrThrow()
            val first = ring.waitCqeTimeout(50_000_000L).getOrThrow() ?: continue
            process(first)
        }
        return true
    }

    fun process(first: UringCompletion) {
        add(first)
        while (true) add(ring.peekCqe().getOrThrow() ?: break)
        drainBatch()
    }

    /** Handles every queued CQE in order; CQEs a handler's stage reaps join the queue and this same pass. */
    fun drainBatch() {
        if (handling) return
        handling = true
        try {
            while (batchHead < batchCount) {
                val i = batchHead++
                handle(batch[i], batchRes[i])
            }
            batchHead = 0
            batchCount = 0
        } finally {
            handling = false
        }
    }

    fun add(c: UringCompletion) {
        if (batchCount == batch.size) {
            batch = batch.copyOf(batchCount * 2)
            batchRes = batchRes.copyOf(batchCount * 2)
        }
        batch[batchCount] = c.userData
        batchRes[batchCount] = c.res
        batchCount++
        sqes--
    }

    inline fun stage(op: () -> Result<Unit>) {
        if (op().isFailure) {
            ring.submit().getOrThrow()
            while (true) add(ring.peekCqe().getOrThrow() ?: break)
            op().getOrThrow()
        }
        sqes++
    }

    /** Users start evenly over the ramp, as k6's ramping-vus does; a frozen ramp starts no more. */
    fun activate(now: Long) {
        while (nextActivation < vus.size && !plan.frozen) {
            val v = vus[nextActivation]
            val at = plan.started + plan.rampNanos * v.index / plan.vus
            if (at > now) return
            nextActivation++
            plan.activated.incrementAndGet()
            // load.js: the first iteration sleeps 0-5 s to spread users that start in the same tick.
            schedule(v, now + (random.nextDouble() * 5e9).toLong())
        }
    }

    fun schedule(v: Vu, at: Long) {
        v.seq++
        push(at, v.local, v.seq)
    }

    fun push(at: Long, vu: Int, seq: Int) {
        if (heapSize == heapTime.size) {
            heapTime = heapTime.copyOf(heapSize * 2); heapVu = heapVu.copyOf(heapSize * 2); heapSeq = heapSeq.copyOf(heapSize * 2)
        }
        var i = heapSize++
        while (i > 0) {
            val parent = (i - 1) / 2
            if (heapTime[parent] <= at) break
            heapTime[i] = heapTime[parent]; heapVu[i] = heapVu[parent]; heapSeq[i] = heapSeq[parent]
            i = parent
        }
        heapTime[i] = at; heapVu[i] = vu; heapSeq[i] = seq
    }

    fun pop() {
        val last = --heapSize
        if (last == 0) return
        val t = heapTime[last]; val vu = heapVu[last]; val sq = heapSeq[last]
        var i = 0
        while (true) {
            var child = 2 * i + 1
            if (child >= last) break
            if (child + 1 < last && heapTime[child + 1] < heapTime[child]) child++
            if (heapTime[child] >= t) break
            heapTime[i] = heapTime[child]; heapVu[i] = heapVu[child]; heapSeq[i] = heapSeq[child]
            i = child
        }
        heapTime[i] = t; heapVu[i] = vu; heapSeq[i] = sq
    }

    fun between(lo: Double, hi: Double): Long = ((lo + random.nextDouble() * (hi - lo)) * 1e9).toLong()

    /** A timer: the next step of load.js, or the request in flight timing out. Draining starts no new request. */
    fun fire(v: Vu, now: Long) {
        if (v.kind >= 0) {
            // The deadline drops the connection: a disconnect like any other, counted and stamped as one.
            val reason = if (v.established) Reason.REQUEST_TIMEOUT else Reason.SETUP_TIMEOUT
            plan.disconnects.incrementAndGet()
            plan.lostReasons.incrementAndGet(reason)
            if (plan.inEstablishedWindow(now)) plan.windowDisconnects.incrementAndGet()
            plan.holdEvent(now, "disconnect", reason, v.index)
            drop(v)
            fail(v, now, reason)
            return
        }
        if (plan.draining) return
        when (v.step) {
            0 -> request(v, FEED, "/feed", null)
            1 -> request(v, POST, "/posts/${v.postId}", null)
            2 -> {
                if (random.nextDouble() < 0.15) request(v, LIKE, "/posts/${v.postId}/like", ByteArray(0))
                else { v.step = 3; fire(v, now) }
            }
            3 -> {
                if (random.nextDouble() < 0.02) {
                    val (name, _) = plan.users[v.user]
                    val body = "{\"body\":\"$name says hi at ${Instant.now().truncatedTo(ChronoUnit.MILLIS)} (VU ${v.index + 1}, iter ${v.iter})\"}"
                    request(v, CREATE, "/posts", body.encodeToByteArray())
                } else { v.step = 4; fire(v, now) }
            }
            4 -> {
                v.iter++
                v.step = 0
                schedule(v, now + between(5.0, 15.0))
            }
        }
    }

    fun request(v: Vu, kind: Int, path: String, body: ByteArray?) {
        val head = StringBuilder(160)
        head.append(if (body == null) "GET " else "POST ").append(path).append(" HTTP/1.1\r\nHost: ").append(plan.host)
            .append(':').append(v.port).append("\r\nUser-Agent: trikeshed-loadgen\r\n")
        if (body != null) {
            head.append("Authorization: Bearer ").append(plan.users[v.user].second).append("\r\nContent-Type: application/json\r\n")
                .append("Content-Length: ").append(body.size).append("\r\n")
        }
        head.append("\r\n")
        val bytes = head.toString().encodeToByteArray().let { if (body == null || body.isEmpty()) it else it + body }
        v.kind = kind
        outstanding++
        v.request = bytes
        v.responseSize = 0
        v.sentAt = System.nanoTime()
        schedule(v, v.sentAt + plan.timeoutNanos)
        if (!v.connected) connect(v) else if (v.established) transmit(v)
    }

    fun connect(v: Vu) {
        if (v.connecting) return
        v.connecting = true
        v.gen = (v.gen + 1) and 0x0FFFFFFF
        v.connectAt = System.nanoTime()
        stage { ring.prepSocket(2, 1, 0, token(v, OP_SOCKET)) }
    }

    /** The request's first byte leaves now: k6's http_req_duration starts here, after connecting and TLS. */
    fun transmit(v: Vu) {
        val bytes = v.request ?: return
        v.request = null
        v.sentAt = System.nanoTime()
        val session = v.tls
        if (session == null) append(v, bytes, 0, bytes.size) else {
            current = v
            val outcome = session.send(bytes, 0, bytes.size, sink)
            current = null
            if (outcome != TlsSendOutcome.ACCEPTED) {
                // A request is far below pendingLimit, so this is a closed session (or one stalled that long).
                plan.tlsRefused.incrementAndGet()
                lost(v, Reason.TLS_REFUSED)
                return
            }
        }
        flush(v)
        pollIn(v)
    }

    fun append(v: Vu, bytes: ByteArray, from: Int, to: Int) {
        val n = to - from
        val prior = v.out
        val into = if (prior == null) ByteArray(maxOf(n, 512)) else if (v.outSize + n > prior.size) prior.copyOf(maxOf(prior.size * 2, v.outSize + n)) else prior
        bytes.copyInto(into, v.outSize, from, to)
        v.out = into
        v.outSize += n
    }

    fun flush(v: Vu) {
        if (v.sending || v.outSize == 0 || !v.connected) return
        if (txTop == 0) { waitTx.addLast(v); return }
        startSend(v, txFree[--txTop])
    }

    fun startSend(v: Vu, window: Int) {
        val out = v.out!!
        val n = minOf(TX, v.outSize)
        MemorySegment.copy(out, 0, tx, ValueLayout.JAVA_BYTE, window.toLong() * TX, n)
        out.copyInto(out, 0, n, v.outSize)
        v.outSize -= n
        txOf[v.local] = window
        v.sending = true
        v.sendLen = n
        v.sendDone = 0
        postSend(v)
    }

    fun postSend(v: Vu) {
        val window = txOf[v.local]
        val at = tx.address() + window.toLong() * TX + v.sendDone
        stage { ring.prepSend(v.fd, at, v.sendLen - v.sendDone, 0, token(v, OP_SEND, window)) }
    }

    fun releaseTx(window: Int) {
        while (waitTx.isNotEmpty()) {
            val next = waitTx.removeFirst()
            if (next.connected && !next.sending && next.outSize > 0) { startSend(next, window); return }
        }
        txFree[txTop++] = window
    }

    fun pollIn(v: Vu) {
        if (v.polling || v.receiving || v.rxQueued || !v.connected) return
        v.polling = true
        stage { ring.prepPollAdd(v.fd, 1, token(v, OP_POLL_IN)) }
    }

    fun handle(userData: Long, res: Int) {
        val op = userData and 0xF
        val local = (userData ushr 4) and 0xFFFFFL
        if (local == STRAY) return
        val v = vus[local.toInt()]
        val window = ((userData ushr 24) and 0xFFFL).toInt()
        val current = v.gen == (userData ushr 36).toInt()
        when (op) {
            // Windows return at their CQE whatever became of the connection that used them.
            OP_RECV -> received(v, window, res, current && v.connected)
            OP_SEND -> {
                if (!(current && v.connected && v.sending)) { releaseTx(window); return }
                if (res > 0) {
                    v.sendDone += res
                    if (v.sendDone < v.sendLen) { postSend(v); return }
                    v.sending = false
                    txOf[v.local] = -1
                    releaseTx(window)
                    flush(v)
                } else if (res == -11) {
                    // The socket's send buffer is full: the window and what was sent of it stay this connection's,
                    // and the rest goes once the socket is writable, as the server does.
                    plan.sendRetries.incrementAndGet()
                    stage { ring.prepPollAdd(v.fd, POLLOUT, token(v, OP_POLL_OUT, window)) }
                } else {
                    v.sending = false
                    txOf[v.local] = -1
                    releaseTx(window)
                    errno(res)
                    lost(v, Reason.SEND)
                }
            }
            OP_POLL_OUT -> {
                // A stale watch (its connection closed, which cancels it) still returns the window it held.
                if (!(current && v.connected && v.sending)) { releaseTx(window); return }
                if (res < 0 || ((res and (POLLERR or POLLHUP)) != 0 && (res and POLLOUT) == 0)) {
                    v.sending = false
                    txOf[v.local] = -1
                    releaseTx(window)
                    errno(res)
                    lost(v, Reason.SEND)
                } else postSend(v)
            }
            OP_SOCKET -> {
                if (!current || !v.connecting) {
                    if (res >= 0) stage { ring.prepClose(res, strayToken()) }
                    return
                }
                if (res < 0) { plan.connectFailures.incrementAndGet(); errno(res); v.connecting = false; fail(v, System.nanoTime(), Reason.CONNECT); return }
                v.fd = res
                noDelay(res)
                if (sourceAddresses.isNotEmpty()) {
                    val source = sourceAddresses[v.index % sourceAddresses.size]
                    stage { ring.prepBind(res, source.address(), 16, token(v, OP_BIND)) }
                } else startConnect(v)
            }
            OP_BIND -> if (current && v.connecting) {
                if (res < 0) { plan.connectFailures.incrementAndGet(); errno(res); closeFd(v); fail(v, System.nanoTime(), Reason.CONNECT) } else startConnect(v)
            }
            OP_CONNECT -> if (current && v.connecting) {
                v.connecting = false
                if (res < 0) { plan.connectFailures.incrementAndGet(); errno(res); closeFd(v); fail(v, System.nanoTime(), Reason.CONNECT); return }
                v.connected = true
                plan.connected.incrementAndGet()
                if (!plan.tls) {
                    established(v)
                    transmit(v)
                    return
                }
                val session = plan.tlsBackend.recordSession(plan.tlsConfig, TlsRole.CLIENT j ("" j v.port))
                v.tls = session
                this.current = v
                session.begin(sink)
                this.current = null
                flush(v)
                pollIn(v)
            }
            OP_POLL_IN -> if (current && v.connected && v.polling) {
                v.polling = false
                if (res < 0) { errno(res); lost(v, Reason.RECV); return }
                if (v.receiving || v.rxQueued) return
                if (rxTop == 0) waitRx.queue(v) else recv(v, rxFree[--rxTop])
            }
            OP_CLOSE -> {}
        }
    }

    fun established(v: Vu) {
        val now = System.nanoTime()
        v.established = true
        plan.established.incrementAndGet()
        plan.handshakes.incrementAndGet()
        if (plan.inEstablishedWindow(now)) plan.windowHandshakes.incrementAndGet()
        plan.holdEvent(now, "connected", -1, v.index)
        connects.record((now - v.connectAt) / 1000)
        val session = v.tls?.session
        if (session != null && plan.protocol.get() == null) plan.protocol.compareAndSet(null, "${session.protocol} ${session.cipherSuite}")
    }

    fun startConnect(v: Vu) {
        val target = addresses.getOrPut(v.port) { address(plan.host, v.port) }
        stage { ring.prepConnect(v.fd, target.address(), 16, token(v, OP_CONNECT)) }
    }

    fun recv(v: Vu, window: Int) {
        check(!v.receiving && !v.polling && !v.rxQueued) { "user ${v.index}: a second read" }
        v.receiving = true
        stage { ring.prepRecv(v.fd, rx.address() + window.toLong() * RX, RX, 0, token(v, OP_RECV, window)) }
    }

    /** A window back from its CQE goes to the next user waiting for one, else to the pool. */
    fun releaseRx(window: Int) {
        val next = waitRx.next()
        if (next != null) { recv(next, window); return }
        rxFree[rxTop++] = window
    }

    fun received(v: Vu, window: Int, res: Int, fresh: Boolean) {
        if (fresh && res > 0) MemorySegment.copy(rx, ValueLayout.JAVA_BYTE, window.toLong() * RX, rxHeap, 0, res)
        releaseRx(window)
        if (!fresh) return
        v.receiving = false
        if (res == -11) { pollIn(v); return }
        if (res == 0) { lost(v, Reason.EOF); return }
        if (res < 0) { errno(res); lost(v, Reason.RECV); return }
        val session = v.tls
        if (session == null) { body(v, rxHeap, 0, res); return }
        plain.reset()
        current = v
        val open = session.receive(rxHeap, 0, res, sink)
        current = null
        if (!v.established && session.established) established(v)
        if (!open) {
            val failed = (session as? JvmTlsRecordSession)?.failure != null
            if (failed) plan.tlsFailures.incrementAndGet()
            lost(v, if (failed) Reason.TLS else Reason.TLS_CLOSED)
            return
        }
        flush(v)
        if (v.established && v.request != null) { transmit(v); return }
        if (plain.size() > 0) body(v, plain.toByteArray(), 0, plain.size()) else if (v.kind >= 0) pollIn(v)
    }

    /** Response bytes: complete once the head and Content-Length bytes are in; then checked and timed. */
    fun body(v: Vu, bytes: ByteArray, from: Int, to: Int) {
        val n = to - from
        val prior = v.response
        val into = if (prior == null) ByteArray(maxOf(8192, n)) else if (v.responseSize + n > prior.size) prior.copyOf(maxOf(prior.size * 2, v.responseSize + n)) else prior
        bytes.copyInto(into, v.responseSize, from, to)
        v.response = into
        v.responseSize += n
        val head = indexOf(into, v.responseSize, "\r\n\r\n")
        if (head < 0) { pollIn(v); return }
        val length = header(into, head, "content-length:") ?: -1
        if (length < 0 || v.responseSize < head + 4 + length) { pollIn(v); return }
        val status = (into[9] - 48) * 100 + (into[10] - 48) * 10 + (into[11] - 48)
        val text = String(into, head + 4, length, Charsets.UTF_8).trimEnd()
        v.responseSize = 0
        v.response = null
        complete(v, status, text)
    }

    fun inScope(scope: Int, start: Long): Boolean = when (scope) {
        RUN -> true
        CANONICAL -> start >= plan.canonicalStart && start < plan.canonicalEnd
        else -> plan.inEstablishedWindow(start)
    }

    fun scopeEnd(scope: Int): Long = when (scope) {
        RUN -> Long.MAX_VALUE
        CANONICAL -> plan.canonicalEnd
        else -> plan.establishedEnd
    }

    fun record(kind: Int, start: Long, end: Long, ok: Boolean, checkFailed: Boolean) {
        val micros = (end - start) / 1000
        for (scope in 0 until 3) {
            if (!inScope(scope, start)) continue
            val s = stats[scope][kind]
            s.latency.record(micros)
            if (ok) s.ok++ else s.failed++
            if (checkFailed) s.checksFailed++
            if (end >= scopeEnd(scope)) s.drained++
        }
        plan.finished.incrementAndGet()
        if (!ok) plan.failures.incrementAndGet()
        outstanding--
    }

    fun complete(v: Vu, status: Int, text: String) {
        val now = System.nanoTime()
        val kind = v.kind
        if (kind < 0) return
        v.kind = -1
        v.seq++ // the timeout timer of this request is void
        val statusOk = when (kind) { LIKE -> status == 200 || status == 201; CREATE -> status == 201; else -> status == 200 }
        var checked = statusOk
        when (kind) {
            FEED -> if (statusOk) {
                val ids = ids(text)
                checked = ids.size == 20
                if (checked) v.postId = ids[random.nextInt(ids.size)]
            }
            POST -> if (statusOk) checked = text.startsWith("{\"post\":{\"id\":${v.postId},")
            LIKE -> if (statusOk) checked = text.startsWith("{\"liked\":true,\"already_liked\":") && text.endsWith(",\"post_id\":${v.postId}}")
            CREATE -> if (statusOk) checked = text.contains("\"author\":\"${plan.users[v.user].first}\"") && text.endsWith("\"like_count\":0}}")
        }
        if (!statusOk) {
            plan.failReasons.incrementAndGet(Reason.STATUS)
            plan.holdEvent(now, "failed", Reason.STATUS, v.index)
        }
        record(kind, v.sentAt, now, statusOk, statusOk && !checked)
        advance(v, kind, statusOk && checked, now)
    }

    /** load.js after a request: a failed feed sleeps 3-7 s and starts over; every other check failure carries on. */
    fun advance(v: Vu, kind: Int, ok: Boolean, now: Long) {
        if (kind == FEED && !ok) { v.step = 0; v.iter++; schedule(v, now + between(3.0, 7.0)); return }
        when (kind) {
            FEED -> { v.step = 1; schedule(v, now + between(3.0, 7.0)) }
            POST -> { v.step = 2; schedule(v, now + between(3.0, 8.0)) }
            LIKE -> { v.step = 3; fire(v, now) }
            CREATE -> { v.step = 4; fire(v, now) }
        }
    }

    /** The request in flight failed without a response (timeout, connect or transport failure), as k6 status 0. */
    fun fail(v: Vu, now: Long, reason: Int) {
        val kind = v.kind
        if (kind < 0) return
        plan.failReasons.incrementAndGet(reason)
        plan.holdEvent(now, "failed", reason, v.index)
        v.kind = -1
        v.seq++
        record(kind, v.sentAt, now, ok = false, checkFailed = false)
        advance(v, kind, false, now)
    }

    /** The connection ended under a request or between them: reconnect at the next request. */
    fun lost(v: Vu, reason: Int) {
        val now = System.nanoTime()
        plan.disconnects.incrementAndGet()
        plan.lostReasons.incrementAndGet(reason)
        if (plan.inEstablishedWindow(now)) plan.windowDisconnects.incrementAndGet()
        plan.holdEvent(now, "disconnect", reason, v.index)
        drop(v)
        fail(v, now, reason)
    }

    fun errno(res: Int) {
        if (res < 0) plan.errnos.incrementAndGet(minOf(-res, plan.errnos.length() - 1))
    }

    fun drop(v: Vu) {
        if (v.established) plan.established.decrementAndGet()
        if (v.connected) plan.connected.decrementAndGet()
        closeFd(v)
    }

    fun closeFd(v: Vu) {
        if (v.fd >= 0) {
            val fd = v.fd
            stage { ring.prepClose(fd, token(v, OP_CLOSE)) }
        }
        v.fd = -1
        v.connected = false
        v.established = false
        v.connecting = false
        v.tls = null
        v.out = null
        v.outSize = 0
        v.response = null
        v.responseSize = 0
        v.polling = false
        v.receiving = false
        v.rxQueued = false
        v.sending = false
        txOf[v.local] = -1
        // SQEs still in flight for this connection carry its generation; their CQEs return their windows.
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
}

fun indexOf(bytes: ByteArray, size: Int, pattern: String): Int {
    val p = pattern.encodeToByteArray()
    outer@ for (i in 0..size - p.size) {
        for (j in p.indices) if (bytes[i + j] != p[j]) continue@outer
        return i
    }
    return -1
}

fun header(bytes: ByteArray, end: Int, name: String): Int? {
    val text = String(bytes, 0, end, Charsets.ISO_8859_1).lowercase()
    val at = text.indexOf(name)
    if (at < 0) return null
    var i = at + name.length
    while (i < text.length && text[i] == ' ') i++
    var value = 0
    while (i < text.length && text[i].isDigit()) { value = value * 10 + (text[i] - '0'); i++ }
    return value
}
