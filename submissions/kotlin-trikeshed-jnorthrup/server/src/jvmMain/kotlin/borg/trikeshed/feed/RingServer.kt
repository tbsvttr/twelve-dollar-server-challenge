package borg.trikeshed.feed

import borg.trikeshed.reactor.JvmTlsRecordSession
import borg.trikeshed.reactor.TlsRecordSession
import borg.trikeshed.reactor.TlsRecordSink
import borg.trikeshed.reactor.TlsSendOutcome
import borg.trikeshed.userspace.LiburingFacade
import borg.trikeshed.userspace.UringCompletion
import borg.trikeshed.userspace.noDelay
import java.lang.foreign.Arena
import java.lang.foreign.MemorySegment
import java.lang.foreign.ValueLayout

const val OP_ACCEPT = 1L
const val OP_LISTEN_POLL = 2L
const val OP_POLL_IN = 3L
const val OP_RECV = 4L
const val OP_SEND = 5L
const val OP_CLOSE = 6L
const val OP_POLL_OUT = 7L
const val OP_LISTEN_CLOSE = 8L
const val OP_STRAY_CLOSE = 9L
const val OP_PROBE = 10L
const val POLLIN = 1
const val POLLOUT = 4
const val POLLERR = 8
const val POLLHUP = 0x10

/** Handled CQEs between the handshakes a loop that never runs dry still starts: the share handshakes keep. */
const val HANDSHAKE_SLICE = 128

/** Liveness probes in flight at most; each that finds its client still waiting starts one handshake. */
const val MAX_PROBES = 16

/** One drain pass handles at most this many CQEs, or runs at most [PASS_NANOS]; the rest waits for the next pass. */
const val PASS_CQES = 4096
const val PASS_NANOS = 20_000_000L

/** Accepts one loop pass may chain by submitting the next ACCEPT at once. */
const val ACCEPT_BURST = 256

/** One RECV window: a whole TLS record (16 KiB plaintext plus header and tag) fits. */
const val RX_WINDOW: Int = 17 * 1024

/** One SEND window; longer output leaves in several SENDs. */
const val TX_WINDOW: Int = 32 * 1024

/** A connection of [RingServer]. Its slot and generation name its SQEs; at most one SQE per kind is in flight. */
class RingConn(val slot: Int, val gen: Int, val fd: Int) {
    var tls: TlsRecordSession? = null
    var established = false
    /** Request bytes held across reads, as Xio's cursor. */
    var cursor: ByteArray? = null
    var cursorSize = 0
    /** Plaintext responses waiting for the open write transaction's COMMIT. */
    var held: ByteArray? = null
    var heldSize = 0
    var deferred = false
    /** Bytes for the socket not yet in a SEND: ciphertext under TLS. */
    var out: ByteArray? = null
    var outFrom = 0
    var outTo = 0
    /** The SEND in flight: its window, the bytes in it and how many the CQEs reported sent. */
    var sendWindow = -1
    var sendLen = 0
    var sendDone = 0
    var recvWindow = -1
    var polling = false
    /** Waiting in the server's queue for a receive window: like the watch and the RECV, one at most. */
    var rxQueued = false
    /** The client's first flight, held until its handshake's turn; null once the session has it. */
    var hello: ByteArray? = null
    var helloSize = 0
    var helloDone = false
    /** The liveness probe before the handshake (POLL_ADD of POLLIN|POLLOUT) is in flight. */
    var probing = false
    var pollingOut = false
    /** No more requests are read; the output drains (held responses included), then close_notify, then CLOSE. */
    var closing = false
    /** Closing, but the TLS session still holds plaintext a handshake must finish before close_notify: keep reading. */
    var awaitTls = false
    /** CLOSE submitted, and its CQE seen. */
    var closeSent = false
    var closeDone = false
    val busy: Boolean get() = polling || pollingOut || probing || recvWindow >= 0 || sendWindow >= 0
}

/**
 * The feed over the central uring contract: one thread owns [ring] (the FFM kernel io_uring on Linux, or the
 * emulated ring over JvmReadiness), the SQLite connection, and every connection's [TlsRecordSession] when
 * [sessions] gives one (HTTPS), else plain HTTP.
 *
 * A connection at rest holds one POLL_ADD(POLLIN) and no buffer. Readiness takes a receive window from a bounded
 * pool for one RECV; its bytes are decrypted, framed and answered exactly as Xio does, group commit included; the
 * output leaves in SENDs from pooled windows, each held until its CQE, a partial SEND continuing where its CQE
 * stopped. A connection closes as Xio closes one: after its last response (one waiting for a COMMIT included) has
 * been sent, then close_notify under TLS; a failed COMMIT closes the connections whose responses waited for it.
 *
 * Handshakes wait their turn. A client's first flight is held, and handshakes start in arrival order whenever no CQE
 * waits, plus one per [HANDSHAKE_SLICE] handled CQEs while the loop never runs dry, so a burst of handshakes (about a
 * millisecond of CPU each) cannot hold established requests back, nor can requests starve handshakes. Just before
 * its handshake a connection is probed with a POLL_ADD of POLLIN|POLLOUT, which completes at once: a client that
 * closed or reset while it waited is closed without the handshake and counted ([abandoned]).
 *
 * The server owns [ring] and [listeners]: [run] closes them when it returns. Sessions from [sessions] must not call
 * back into this server or into another session from their sinks (the record sessions' non-reentrant contract).
 */
class RingServer(
    val ring: LiburingFacade,
    val feed: Feed,
    val store: FeedStore,
    val sessions: (() -> TlsRecordSession)?,
    val listeners: IntArray,
    rxWindows: Int = 512,
    txWindows: Int = 512,
    val commitWindowNanos: Long = COMMIT_WINDOW_NANOS,
    /** On stop: how long connections may drain their output before they are aborted, and the bound on every CQE. */
    val drainNanos: Long = 3_000_000_000L,
    val shutdownNanos: Long = 10_000_000_000L,
    /**
     * Admission: at most this many accepted connections without a finished handshake. Past it a listener takes no
     * ACCEPT until one finishes or closes, so the backlog waits in the kernel's listen queue (bytes in the kernel,
     * no session, no heap) instead of in this process, where p10 held 131k descriptors and ran its heap out.
     */
    val maxHandshaking: Int = 2048,
) {
    val arena = Arena.ofShared()
    val rx: MemorySegment = arena.allocate(RX_WINDOW.toLong() * rxWindows, 64)
    val tx: MemorySegment = arena.allocate(TX_WINDOW.toLong() * txWindows, 64)
    val rxFree = IntArray(rxWindows) { it }
    var rxTop = rxWindows
    val txFree = IntArray(txWindows) { it }
    var txTop = txWindows
    val rxHeap = ByteArray(RX_WINDOW)
    var conns = arrayOfNulls<RingConn>(1024)
    var gens = IntArray(1024)
    var freeSlots = IntArray(1024)
    var freeTop = 0
    var slotsUsed = 0
    val waitingRx = ArrayDeque<RingConn>()
    val waitingTx = ArrayDeque<RingConn>()
    val request = Request()
    val send = Out()
    val plain = Out()
    val deferred = ArrayList<RingConn>()
    var windowOpen = false
    var openedAt = 0L
    var reportedAt = 0L
    val paused = BooleanArray(listeners.size)
    var anyPaused = false
    /** Connections whose first flight waits for its handshake, in arrival order (closed ones are skipped). */
    val handshakes = ArrayDeque<RingConn>()
    var probes = 0
    /** Handshakes not started because the client had closed or reset while it waited. */
    var abandoned = 0L
    /** First flights given to their sessions. */
    var handshakesStarted = 0L
    /** The most CQEs reaped and not yet handled at one time. */
    var maxQueued = 0L
    /** Watches not armed because the connection already read or waited for a window (each a duplicate prevented). */
    var rxGuarded = 0L

    /** Times a listener stopped accepting because [maxHandshaking] connections were mid-handshake. */
    var acceptPauses = 0L
    var reporter: (RingServer) -> Unit = {}

    /** The largest drain so far (CQEs handled in one pass) and the longest one. */
    var maxBatch = 0L
    var maxBatchNanos = 0L
    /** The most a commit settled after its window closed. */
    var commitLateMaxNanos = 0L
    /**
     * CQEs reaped and not yet handled, in order: [batchHead] is the next to handle. A stage that finds the ring full
     * reaps into this queue wherever it runs, inside a handler or not, and every reaped CQE is handled exactly once.
     */
    var batchData = LongArray(1024)
    var batchRes = IntArray(1024)
    var batchCount = 0
    var batchHead = 0
    var handling = false
    var started = false
    var current: RingConn? = null
    val sink = object : TlsRecordSink {
        override fun plaintext(bytes: ByteArray, from: Int, to: Int) = plain.raw(bytes, from, to)
        override fun ciphertext(bytes: ByteArray, from: Int, to: Int) = enqueue(current!!, bytes, from, to)
    }

    var accepted = 0L
    var acceptErrors = 0L
    var closed = 0L
    var requests = 0L
    var tlsFailures = 0L
    /** Connections ended because their TLS session refused a response (see TlsSendOutcome.BACKPRESSURE). */
    var tlsBackpressure = 0L
    /** Connections open, and of those the ones whose TLS handshake finished (all of them under plain HTTP). */
    var live = 0
    var established = 0
    var peakLive = 0
    var peakEstablished = 0
    var loops = 0L
    var cqes = 0L
    /** SQEs staged whose CQE has not arrived; slots not yet free. */
    var inFlight = 0L
    var occupied = 0
    /** Connections the stop aborted because their output had not drained in time. */
    var unfinished = 0
    /** The stop saw every CQE, so the windows' memory was released. */
    var drained = false
    /** Stages the ring refused until a submit and reap made room; of those, the ones outside a CQE handler. */
    var fullRing = 0L
    var fullRingOutsideHandler = 0L
    /** Loop turns that found CQEs queued (reaped by a stage outside a handler) right before they would have waited. */
    var queuedBeforeWait = 0L

    /** What executes the SQEs, as the ring describes its backend. */
    val backend: String get() = ring.availability

    @Volatile var stopping = false

    /**
     * Serves until [stopping], then stops (see [shutdown]) and closes the ring; [report] runs about once a second
     * and once at the end. A failure of the loop, of the stop or of closing the ring is thrown after the cleanup.
     */
    fun run(report: (RingServer) -> Unit = {}) {
        check(!started) { "a RingServer runs once" }
        started = true
        var failure: Throwable? = null
        try {
            serve(report)
        } catch (error: Throwable) {
            failure = error
        }
        failure = release(failure, report)
        if (failure != null) throw failure
        check(drained) { "stop: $inFlight SQEs without a CQE after ${shutdownNanos / 1_000_000} ms" }
    }

    /** Closes a server that never ran: its listeners, its ring and its windows. Nothing once it has run. */
    fun close() {
        if (started) return
        started = true
        release(null) {}?.let { throw it }
        check(drained) { "close: $inFlight SQEs without a CQE after ${shutdownNanos / 1_000_000} ms" }
    }

    /** The stop, then the ring, then (once every CQE is in) the windows: [failure] with whatever these add. */
    fun release(failure: Throwable?, report: (RingServer) -> Unit): Throwable? {
        var error = failure
        try {
            drained = shutdown()
        } catch (t: Throwable) {
            if (error == null) error = t else error.addSuppressed(t)
        }
        val ringClosed = ring.close().exceptionOrNull()
        if (ringClosed != null) if (error == null) error = ringClosed else error.addSuppressed(ringClosed)
        // Windows an SQE may still name stay mapped: only a drained stop releases them.
        if (drained) arena.close()
        try {
            report(this)
        } catch (t: Throwable) {
            if (error == null) error = t else error.addSuppressed(t)
        }
        return error
    }

    fun serve(report: (RingServer) -> Unit) {
        reporter = report
        reportedAt = System.nanoTime()
        for (i in listeners.indices) stage { ring.prepAccept(listeners[i], listenerToken(i, OP_ACCEPT)) }
        while (!stopping) {
            if (batchHead < batchCount) {
                // A bounded pass: with CQEs still queued the loop neither waits nor skips its stop check.
                drainBatch()
                ring.submit().getOrThrow()
                tick()
                if (batchHead < batchCount) continue
            }
            // No CQE waits: waiting handshakes take the loop (their probes complete at once, the handshakes follow).
            if (handshakes.isNotEmpty()) admitHandshakes(MAX_PROBES)
            ring.submit().getOrThrow()
            // A stage() above that found the ring full reaped CQEs into the queue: handle them before any wait.
            if (batchHead < batchCount) {
                queuedBeforeWait++
                continue
            }
            val now = System.nanoTime()
            val timeout = if (windowOpen) maxOf(100_000L, openedAt + commitWindowNanos - now) else 250_000_000L
            val first = ring.waitCqeTimeout(timeout).getOrThrow()
            loops++
            if (first != null) process(first)
            tick()
        }
    }

    /**
     * The loop's timers: the commit window (opened by the first pending write, settled once it has been open
     * [commitWindowNanos]) and the once-a-second report. Also checked between CQEs of a long drain, so a burst of
     * handshakes cannot hold a commit or a report back for the whole batch.
     */
    fun tick() {
        if (store.pending) {
            val at = monoNanos()
            if (!windowOpen) {
                windowOpen = true
                openedAt = at
            }
            val late = at - openedAt - commitWindowNanos
            if (late >= 0) {
                if (late > commitLateMaxNanos) commitLateMaxNanos = late
                windowOpen = false
                settle()
            }
        }
        val now = System.nanoTime()
        if (now - reportedAt >= 1_000_000_000L) {
            reportedAt = now
            reporter(this)
        }
    }

    /**
     * The stop: listeners close (their pending ACCEPT ends), the open commit settles, every connection stops reading
     * and drains its output, TLS ones ending with close_notify, for at most [drainNanos]; what remains is aborted.
     * True once every staged SQE has its CQE and every slot is free, within [shutdownNanos].
     */
    fun shutdown(): Boolean {
        stopping = true
        for (i in listeners.indices) stage { ring.prepClose(listeners[i], listenerToken(i, OP_LISTEN_CLOSE)) }
        if (store.pending) settle()
        for (slot in 0 until slotsUsed) {
            val c = conns[slot] ?: continue
            if (c.closeSent) continue
            c.closing = true
            flushOut(c)
        }
        val start = System.nanoTime()
        var aborted = false
        while (inFlight > 0 || occupied > 0 || batchHead < batchCount) {
            val elapsed = System.nanoTime() - start
            if (elapsed >= shutdownNanos) return false
            if (!aborted && elapsed >= drainNanos) {
                aborted = true
                for (slot in 0 until slotsUsed) {
                    val c = conns[slot] ?: continue
                    if (c.closeSent) continue
                    unfinished++
                    abort(c)
                }
            }
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

    fun counters(): Map<String, Long> = linkedMapOf(
        "live" to live.toLong(), "established" to established.toLong(), "peakLive" to peakLive.toLong(),
        "peakEstablished" to peakEstablished.toLong(), "accepted" to accepted, "acceptErrors" to acceptErrors,
        "closed" to closed, "requests" to requests, "tlsFailures" to tlsFailures, "tlsBackpressure" to tlsBackpressure, "loops" to loops, "cqes" to cqes,
        "inFlight" to inFlight, "occupied" to occupied.toLong(), "unfinished" to unfinished.toLong(),
        "rxFree" to rxTop.toLong(), "txFree" to txTop.toLong(), "rxWaiting" to waitingRx.size.toLong(),
        "txWaiting" to waitingTx.size.toLong(), "fullRing" to fullRing, "fullRingOutsideHandler" to fullRingOutsideHandler,
        "queuedBeforeWait" to queuedBeforeWait,
        "acceptPauses" to acceptPauses, "handshaking" to (live - established).toLong(), "handshakeQueue" to handshakes.size.toLong(),
        "handshakesStarted" to handshakesStarted, "abandoned" to abandoned, "probes" to probes.toLong(), "maxQueued" to maxQueued, "rxGuarded" to rxGuarded, "maxBatch" to maxBatch, "maxBatchMicros" to maxBatchNanos / 1000, "commitLateMaxMicros" to commitLateMaxNanos / 1000,
    ) + ring.counters()

    fun token(c: RingConn, op: Long): Long = (c.gen.toLong() shl 36) or (c.slot.toLong() shl 4) or op
    fun listenerToken(index: Int, op: Long): Long = (index.toLong() shl 4) or op

    /** Every CQE now available joins the queue before any is handled, so the SQEs handlers stage find CQ room. */
    fun process(first: UringCompletion) {
        add(first)
        absorbAccepting()
        drainBatch()
    }

    /**
     * At a point between handlers: the CQEs the kernel has completed join the batch, except accepts, which are taken
     * at once, each next ACCEPT submitted so a connection already queued completes now. The listen queue then drains
     * while the batch holds seconds of handshakes, instead of overflowing behind them (dropped ACKs and SYN
     * retransmissions cost seconds each).
     */
    fun absorbAccepting() {
        var burst = 0
        while (true) {
            val c = ring.peekCqe().getOrThrow() ?: return
            if (c.userData and 0xF == OP_ACCEPT && burst < ACCEPT_BURST) {
                inFlight--
                cqes++
                burst++
                listenerEvent(((c.userData ushr 4) and 0xFFFFFFFFL).toInt(), OP_ACCEPT, c.res)
                ring.submit().getOrThrow()
            } else add(c)
        }
    }

    /**
     * One pass over the queued CQEs, in order, each handled exactly once: CQEs a handler's stage reaps, and accepts
     * absorbed between handlers, join the queue. A pass ends after [PASS_CQES] CQEs or [PASS_NANOS], so however fast
     * completions arrive the callers' stop and deadline checks run between passes; the handled prefix is then
     * reclaimed, so the queue holds only unhandled CQEs (p11's single pass handled 1.23M CQEs in 130 s into arrays
     * that only grew).
     */
    fun drainBatch() {
        if (handling) return
        handling = true
        val began = System.nanoTime()
        var handled = 0L
        try {
            while (batchHead < batchCount) {
                val data = batchData[batchHead]
                val res = batchRes[batchHead]
                batchHead++
                handled++
                handle(data, res)
                val periodic = handled and 63 == 0L
                if (periodic || data and 0xF == OP_ACCEPT) {
                    // A drain can run for seconds: the timers run, the SQEs staged so far (responses, accepts) go to
                    // the kernel now rather than when the drain ends, queued connections are accepted ahead of the
                    // queue, and waiting handshakes keep their share.
                    if (periodic) {
                        tick()
                        if (handled % HANDSHAKE_SLICE == 0L) admitHandshakes(1)
                    }
                    ring.submit().getOrThrow()
                    absorbAccepting()
                    if (periodic && (handled >= PASS_CQES || System.nanoTime() - began >= PASS_NANOS)) break
                }
            }
        } finally {
            handling = false
            cqes += handled
            if (handled > maxBatch) maxBatch = handled
            if (batchHead == batchCount) {
                batchHead = 0
                batchCount = 0
            } else if (batchHead > 0) compact()
        }
        val took = System.nanoTime() - began
        if (took > maxBatchNanos) maxBatchNanos = took
    }

    fun compact() {
        val left = batchCount - batchHead
        batchData.copyInto(batchData, 0, batchHead, batchCount)
        batchRes.copyInto(batchRes, 0, batchHead, batchCount)
        batchHead = 0
        batchCount = left
    }

    fun add(c: UringCompletion) {
        if (batchCount == batchData.size) {
            batchData = batchData.copyOf(batchCount * 2)
            batchRes = batchRes.copyOf(batchCount * 2)
        }
        batchData[batchCount] = c.userData
        batchRes[batchCount] = c.res
        batchCount++
        inFlight--
        val queued = (batchCount - batchHead).toLong()
        if (queued > maxQueued) maxQueued = queued
    }

    fun absorb() {
        while (true) add(ring.peekCqe().getOrThrow() ?: return)
    }

    /** Stages one SQE; when the ring refuses (SQ plus unreaped CQ at its depth) it submits, gathers, retries once. */
    inline fun stage(op: () -> Result<Unit>) {
        if (op().isFailure) {
            fullRing++
            if (!handling) fullRingOutsideHandler++
            ring.submit().getOrThrow()
            absorb()
            op().getOrThrow()
        }
        inFlight++
    }

    fun handle(userData: Long, res: Int) {
        val op = userData and 0xF
        val slot = ((userData ushr 4) and 0xFFFFFFFFL).toInt()
        when (op) {
            OP_ACCEPT, OP_LISTEN_POLL -> {
                listenerEvent(slot, op, res)
                return
            }
            OP_LISTEN_CLOSE, OP_STRAY_CLOSE -> return
        }
        val c = conns[slot] ?: return
        if (c.gen != (userData ushr 36).toInt()) return
        when (op) {
            OP_POLL_IN -> {
                c.polling = false
                if (res < 0) abort(c) else readable(c)
            }
            OP_PROBE -> {
                c.probing = false
                probes--
                when {
                    c.closeSent -> {}
                    res < 0 || res and (POLLERR or POLLHUP) != 0 -> {
                        abandoned++
                        abort(c)
                    }
                    // Input behind the held first flight: more of it, or the client's EOF. The RECV tells which.
                    res and POLLIN != 0 -> readable(c)
                    else -> handshake(c)
                }
            }
            OP_RECV -> received(c, res)
            OP_SEND -> sent(c, res)
            OP_POLL_OUT -> {
                c.pollingOut = false
                when {
                    c.closeSent -> releaseTx(c)
                    res < 0 -> {
                        releaseTx(c)
                        abort(c)
                    }
                    else -> postSend(c)
                }
            }
            OP_CLOSE -> {
                c.closeDone = true
                closed++
                live--
                if (c.established) established--
                if (anyPaused) resumeAccepts()
            }
        }
        if (c.closeDone && !c.busy) free(c)
    }

    fun listenerEvent(index: Int, op: Long, res: Int) {
        val fd = listeners[index]
        if (op == OP_LISTEN_POLL) {
            if (res >= 0 && !stopping) stage { ring.prepAccept(fd, listenerToken(index, OP_ACCEPT)) }
            return
        }
        when {
            res >= 0 -> if (stopping) {
                stage { ring.prepClose(res, listenerToken(index, OP_STRAY_CLOSE)) }
            } else {
                accept(res)
                // The next ACCEPT, unless admission is full; absorbAccepting submits it and takes what it completes
                // ahead of the batch.
                if (live - established < maxHandshaking) stage { ring.prepAccept(fd, listenerToken(index, OP_ACCEPT)) }
                else {
                    paused[index] = true
                    anyPaused = true
                    acceptPauses++
                }
            }
            stopping || res == -125 || res == -9 -> {}
            res == -11 -> stage { ring.prepPollAdd(fd, POLLIN, listenerToken(index, OP_LISTEN_POLL)) }
            else -> {
                acceptErrors++
                stage { ring.prepPollAdd(fd, POLLIN, listenerToken(index, OP_LISTEN_POLL)) }
            }
        }
    }

    /** Paused listeners accept again once fewer than [maxHandshaking] connections are mid-handshake. */
    fun resumeAccepts() {
        if (stopping || live - established >= maxHandshaking) return
        anyPaused = false
        for (i in listeners.indices) if (paused[i]) {
            paused[i] = false
            stage { ring.prepAccept(listeners[i], listenerToken(i, OP_ACCEPT)) }
        }
    }

    fun accept(fd: Int) {
        accepted++
        noDelay(fd)
        val slot = if (freeTop > 0) freeSlots[--freeTop] else {
            if (slotsUsed == conns.size) {
                conns = conns.copyOf(slotsUsed * 2)
                gens = gens.copyOf(slotsUsed * 2)
                freeSlots = freeSlots.copyOf(slotsUsed * 2)
            }
            slotsUsed++
        }
        val gen = (gens[slot] + 1) and 0x0FFFFFFF
        gens[slot] = gen
        val c = RingConn(slot, gen, fd)
        conns[slot] = c
        occupied++
        live++
        if (live > peakLive) peakLive = live
        val make = sessions
        if (make == null) {
            c.established = true
            established++
        } else {
            val session = make()
            c.tls = session
            current = c
            session.begin(sink)
            current = null
        }
        if (established > peakEstablished) peakEstablished = established
        pollIn(c)
    }

    fun reading(c: RingConn): Boolean = !c.closeSent && (!c.closing || c.awaitTls)

    /**
     * One watch, one RECV or one place in the window queue per connection, never two at once; a held first flight
     * waits for its probe instead.
     */
    fun pollIn(c: RingConn) {
        if (c.recvWindow >= 0 || c.rxQueued) {
            // A graceful close re-arming input while a read is in flight or queued (seen under a small RX pool).
            rxGuarded++
            return
        }
        if (c.polling || c.hello != null || !reading(c)) return
        c.polling = true
        stage { ring.prepPollAdd(c.fd, POLLIN, token(c, OP_POLL_IN)) }
    }

    fun readable(c: RingConn) {
        if (!reading(c) || c.recvWindow >= 0 || c.rxQueued) return
        if (rxTop == 0) {
            c.rxQueued = true
            waitingRx.addLast(c)
        } else recv(c, rxFree[--rxTop])
    }

    fun recv(c: RingConn, window: Int) {
        check(c.recvWindow < 0 && !c.polling) { "connection ${c.slot}: a second receive" }
        c.recvWindow = window
        stage { ring.prepRecv(c.fd, rx.address() + window.toLong() * RX_WINDOW, RX_WINDOW, 0, token(c, OP_RECV)) }
    }

    fun releaseRx(window: Int) {
        while (waitingRx.isNotEmpty()) {
            val next = waitingRx.removeFirst()
            next.rxQueued = false
            if (reading(next) && next.recvWindow < 0) {
                recv(next, window)
                return
            }
        }
        rxFree[rxTop++] = window
    }

    fun received(c: RingConn, res: Int) {
        val window = c.recvWindow
        c.recvWindow = -1
        if (res > 0) MemorySegment.copy(rx, ValueLayout.JAVA_BYTE, window.toLong() * RX_WINDOW, rxHeap, 0, res)
        releaseRx(window)
        when {
            c.closeSent -> {}
            // The probe saw input behind a held first flight: more of the flight, or the client left.
            c.hello != null -> when {
                res > 0 -> {
                    holdHello(c, rxHeap, res)
                    handshake(c)
                }
                res == -11 -> handshake(c)
                else -> {
                    abandoned++
                    abort(c)
                }
            }
            res > 0 -> {
                input(c, rxHeap, res)
                pollIn(c)
            }
            res == -11 -> pollIn(c)
            else -> abort(c)
        }
    }

    fun holdHello(c: RingConn, bytes: ByteArray, n: Int) {
        val prior = c.hello
        if (prior == null) {
            c.hello = bytes.copyOf(n)
            c.helloSize = n
            return
        }
        val into = if (c.helloSize + n > prior.size) prior.copyOf(c.helloSize + n) else prior
        bytes.copyInto(into, c.helloSize, 0, n)
        c.hello = into
        c.helloSize += n
    }

    /** Probes up to [count] waiting handshakes, at most [MAX_PROBES] in flight; each live one starts on its CQE. */
    fun admitHandshakes(count: Int) {
        var left = count
        while (left > 0 && probes < MAX_PROBES) {
            val c = handshakes.removeFirstOrNull() ?: return
            if (c.closeSent || c.hello == null || c.probing) continue
            c.probing = true
            probes++
            left--
            stage { ring.prepPollAdd(c.fd, POLLIN or POLLOUT, token(c, OP_PROBE)) }
        }
    }

    /** The held first flight goes to the session: the handshake runs now. */
    fun handshake(c: RingConn) {
        val hello = c.hello ?: return
        val size = c.helloSize
        c.hello = null
        c.helloSize = 0
        c.helloDone = true
        handshakesStarted++
        input(c, hello, size)
        pollIn(c)
    }

    /** [count] received bytes at the start of [data]: decrypted under TLS, then framed and answered. */
    fun input(c: RingConn, data: ByteArray, count: Int) {
        val session = c.tls
        if (session == null) {
            frame(c, data, count)
            flushOut(c)
            return
        }
        if (!c.helloDone) {
            // The first flight waits for its handshake's turn (admitHandshakes).
            holdHello(c, data, count)
            handshakes.addLast(c)
            return
        }
        plain.size = 0
        current = c
        val open = session.receive(data, 0, count, sink)
        current = null
        if (!c.established && session.established) {
            c.established = true
            established++
            if (established > peakEstablished) peakEstablished = established
            if (anyPaused) resumeAccepts()
        }
        if (!open) {
            if ((session as? JvmTlsRecordSession)?.failure != null) tlsFailures++
            c.closing = true
            c.awaitTls = false
            flushOut(c)
            return
        }
        if (plain.size > 0 && !c.closing) frame(c, plain.bytes, plain.size)
        flushOut(c)
    }

    /** Xio.onRead from its framing on: requests out of [data], answers into [send], held while a commit is open. */
    fun frame(c: RingConn, data: ByteArray, count: Int) {
        val prior = c.cursor
        val src: ByteArray
        val to: Int
        if (prior == null) {
            src = data
            to = count
        } else {
            val grown = if (c.cursorSize + count > prior.size) prior.copyOf(maxOf(prior.size * 2, c.cursorSize + count)) else prior
            data.copyInto(grown, c.cursorSize, 0, count)
            src = grown
            to = c.cursorSize + count
        }
        send.size = 0
        var from = 0
        while (from < to && !c.closing) {
            val end = request.frame(src, from, to)
            if (end == 0) break
            if (end < 0) {
                abort(c)
                return
            }
            feed.respond(src, request, send)
            requests++
            if (request.close) c.closing = true
            from = end
        }
        if (from < to && !c.closing) {
            c.cursor = if (src === data) src.copyOfRange(from, to) else src.copyInto(src, 0, from, to)
            c.cursorSize = to - from
        } else {
            c.cursor = null
            c.cursorSize = 0
        }
        if (send.size == 0) return
        if (store.pending || c.held != null) {
            hold(c, send.bytes, 0, send.size)
            if (!c.deferred) {
                c.deferred = true
                deferred.add(c)
            }
        } else emit(c, send.bytes, 0, send.size)
    }

    fun hold(c: RingConn, bytes: ByteArray, from: Int, to: Int) {
        val n = to - from
        val prior = c.held
        val into = if (prior == null) ByteArray(maxOf(n, 256)) else if (c.heldSize + n > prior.size) prior.copyOf(maxOf(prior.size * 2, c.heldSize + n)) else prior
        bytes.copyInto(into, c.heldSize, from, to)
        c.held = into
        c.heldSize += n
    }

    /** Plaintext for the peer: encrypted under TLS, then queued for SEND. */
    fun emit(c: RingConn, bytes: ByteArray, from: Int, to: Int) {
        val session = c.tls
        if (session == null) {
            enqueue(c, bytes, from, to)
            return
        }
        // At most pendingLimit bytes per send, so a long response is not refused for its length alone.
        val most = session.pendingLimit
        var at = from
        while (at < to) {
            val end = if (to - at > most) at + most else to
            current = c
            val outcome = session.send(bytes, at, end, sink)
            current = null
            if (outcome != TlsSendOutcome.ACCEPTED) {
                // The engine waits for the peer's handshake data with pendingLimit bytes of responses already
                // behind it, or the session closed: this connection cannot carry the response, so it ends, counted.
                if (outcome == TlsSendOutcome.BACKPRESSURE) tlsBackpressure++
                abort(c)
                return
            }
            at = end
        }
    }

    fun enqueue(c: RingConn, bytes: ByteArray, from: Int, to: Int) {
        val n = to - from
        val prior = c.out
        if (prior == null) {
            c.out = bytes.copyOfRange(from, to)
            c.outFrom = 0
            c.outTo = n
            return
        }
        val pending = c.outTo - c.outFrom
        val into = if (pending + n <= prior.size) prior else ByteArray(maxOf(prior.size * 2, pending + n))
        if (c.outFrom > 0 || into !== prior) prior.copyInto(into, 0, c.outFrom, c.outTo)
        bytes.copyInto(into, pending, from, to)
        c.out = into
        c.outFrom = 0
        c.outTo = pending + n
    }

    /**
     * Starts the next SEND when none is in flight. A closing connection whose output has drained and which holds no
     * response for a COMMIT ends gracefully.
     */
    fun flushOut(c: RingConn) {
        if (c.sendWindow >= 0 || c.closeSent) return
        if (c.outTo == c.outFrom) {
            c.out = null
            c.outFrom = 0
            c.outTo = 0
            if (c.closing && c.held == null) closeGracefully(c)
            return
        }
        if (txTop == 0) {
            waitingTx.addLast(c)
            return
        }
        startSend(c, txFree[--txTop])
    }

    /**
     * Under TLS close_notify goes out first, and CLOSE follows once it is sent; plain HTTP closes at once. When the
     * session holds plaintext a handshake must finish first, close_notify waits: the connection keeps reading, sends
     * what ciphertext there is, and returns here once a receive has let the session close.
     */
    fun closeGracefully(c: RingConn) {
        val session = c.tls
        if (session != null && !session.closed) {
            current = c
            session.close(sink)
            current = null
            if (!session.closed) {
                c.awaitTls = true
                if (c.outTo > c.outFrom) flushOut(c) else pollIn(c)
                return
            }
            if (c.outTo > c.outFrom) {
                flushOut(c)
                return
            }
        }
        finish(c)
    }

    fun startSend(c: RingConn, window: Int) {
        val out = c.out!!
        val n = minOf(TX_WINDOW, c.outTo - c.outFrom)
        MemorySegment.copy(out, c.outFrom, tx, ValueLayout.JAVA_BYTE, window.toLong() * TX_WINDOW, n)
        c.outFrom += n
        c.sendWindow = window
        c.sendLen = n
        c.sendDone = 0
        postSend(c)
    }

    fun postSend(c: RingConn) {
        val at = tx.address() + c.sendWindow.toLong() * TX_WINDOW + c.sendDone
        stage { ring.prepSend(c.fd, at, c.sendLen - c.sendDone, 0, token(c, OP_SEND)) }
    }

    fun sent(c: RingConn, res: Int) {
        if (c.closeSent) {
            releaseTx(c)
            return
        }
        when {
            res > 0 -> {
                c.sendDone += res
                if (c.sendDone < c.sendLen) {
                    // A partial SEND: the rest of the window goes next, from where this CQE stopped.
                    postSend(c)
                    return
                }
                releaseTx(c)
                flushOut(c)
            }
            res == -11 -> {
                c.pollingOut = true
                stage { ring.prepPollAdd(c.fd, POLLOUT, token(c, OP_POLL_OUT)) }
            }
            else -> {
                releaseTx(c)
                abort(c)
            }
        }
    }

    fun releaseTx(c: RingConn) {
        val window = c.sendWindow
        if (window < 0) return
        c.sendWindow = -1
        while (waitingTx.isNotEmpty()) {
            val next = waitingTx.removeFirst()
            if (!next.closeSent && next.sendWindow < 0 && next.outTo > next.outFrom) {
                startSend(next, window)
                return
            }
        }
        txFree[txTop++] = window
    }

    /** Ends [c] without its pending output: the peer left, the connection failed, or the stop ran out of time. */
    fun abort(c: RingConn) {
        c.hello = null
        c.closing = true
        c.awaitTls = false
        c.out = null
        c.outFrom = 0
        c.outTo = 0
        c.held = null
        c.heldSize = 0
        finish(c)
    }

    /**
     * CLOSE: it also ends what still waits on the descriptor (the POLL_ADD; a SEND an abort left in the kernel); the
     * slot and windows return once every CQE is in.
     */
    fun finish(c: RingConn) {
        if (c.closeSent) return
        c.closeSent = true
        c.cursor = null
        stage { ring.prepClose(c.fd, token(c, OP_CLOSE)) }
    }

    fun free(c: RingConn) {
        if (conns[c.slot] !== c) return
        conns[c.slot] = null
        freeSlots[freeTop++] = c.slot
        occupied--
    }

    /** COMMIT, then every response that waited for it leaves; a failed COMMIT ends those connections instead. */
    fun settle() {
        windowOpen = false
        val committed = try {
            store.commit()
            true
        } catch (_: Throwable) {
            false
        }
        for (i in deferred.indices) {
            val c = deferred[i]
            c.deferred = false
            val held = c.held ?: continue
            val size = c.heldSize
            c.held = null
            c.heldSize = 0
            if (c.closeSent) continue
            if (!committed) {
                abort(c)
                continue
            }
            emit(c, held, 0, size)
            flushOut(c)
        }
        deferred.clear()
    }
}
