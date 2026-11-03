package borg.trikeshed.feed

import feedc.*
import kotlinx.cinterop.*

/** Rings, as feedc.def's FEED_RINGS. */
const val RINGS = 8

/** feedc.def's user_data ops. */
const val OP_ACCEPT = 1
const val OP_RECV = 2
const val OP_SEND = 3
const val OP_CLOSE = 5

const val CQE_F_MORE = 2
const val ENOBUFS = 105

/** Completions one reap moves, and the bytes their receives may carry. */
const val REAP = 4096
const val REAP_BYTES = 8 shl 20

/**
 * A connection's io_uring direct descriptor ([ring], [slot]) of generation [gen], with the bytes received and not yet
 * read, and the response bytes waiting behind the SEND in flight. [input] is the poller's reap buffer while this
 * wake's bytes are read in place there; whatever is left at the end of the wake moves to an array of its own.
 */
actual class Handle(val ring: Int, val slot: Int, val gen: Int) {
    var input = NO_BYTES
    var from = 0
    var to = 0
    var eof = false
    var recvOn = false
    var closed = false
    var sending = false
    var queued = ByteArray(0)
    var queuedSize = 0
    var header: HeaderRead? = null
    var body: BodyRead? = null
    var flagged = false
}

/**
 * The same four state classes as the JVM selectors, fed by completions: a receive appends to its [Handle] and puts it
 * in the data queue, whose dispatch loop calls [Xio.onHeader] or [Xio.onBody] by the connection's stage; the write
 * queue's loop calls [Xio.onWrite]; accepted slots wait in the accept queue for [Xio.onAccept]. A write is one SEND,
 * so the socket never reports full and write interest is never needed.
 */
@OptIn(ExperimentalForeignApi::class)
actual class Poller actual constructor(host: String, port: Int) {
    val listen = Listen()
    val nslots: Int
    val slots: Array<Array<Handle?>>
    var gen = 0
    val accepted = ArrayDeque<Handle>()
    val data = ArrayList<Handle>()
    val writes = ArrayDeque<BufferedWrite>()
    val ud = LongArray(REAP)
    val res = IntArray(REAP)
    val flags = IntArray(REAP)
    val off = IntArray(REAP)
    val bytes = ByteArray(REAP_BYTES)
    val at = IntArray(1)
    /** Handles whose [Handle.input] is [bytes]. */
    val borrowed = ArrayList<Handle>()

    init {
        val lfd = feed_listen(host, port)
        check(lfd >= 0) { "listen $host:$port: errno ${-lfd}" }
        nslots = feed_setup(lfd)
        check(nslots > 0) { "io_uring setup: errno ${-nslots}" }
        slots = Array(RINGS) { arrayOfNulls<Handle>(nslots) }
        feed_policy()
    }

    actual fun run(xio: Xio) {
        while (true) {
            val idle = accepted.isEmpty() && data.isEmpty() && writes.isEmpty()
            val w = xio.waitMillis()
            feed_enter(if (!idle) 0 else if (w < 0) 1000 else w.toInt())
            at[0] = 0
            for (r in 0 until RINGS) reap(r)
            dispatch(xio)
            xio.rest()
            unborrow()
            xio.tick()
            feed_policy()
        }
    }

    fun reap(r: Int) {
        while (true) {
            val n = feed_reap(r, ud.refTo(0), res.refTo(0), flags.refTo(0), off.refTo(0), REAP, bytes.refTo(0), REAP_BYTES, at.refTo(0))
            for (i in 0 until n) completion(r, ud[i], res[i], flags[i], off[i])
            if (at[0] > REAP_BYTES / 2) { unborrow(); at[0] = 0 }
            if (n < REAP) return
        }
    }

    /** Bytes still unread in [bytes] move to arrays of their owners, before [bytes] is written again. */
    fun unborrow() {
        for (h in borrowed) {
            if (h.input !== bytes) continue
            val live = h.to - h.from
            h.input = if (live == 0 || h.closed) NO_BYTES else bytes.copyOfRange(h.from, h.to)
            h.from = 0
            h.to = if (h.input === NO_BYTES) 0 else live
        }
        borrowed.clear()
    }

    fun completion(r: Int, u: Long, rs: Int, fl: Int, from: Int) {
        val op = (u ushr 60).toInt()
        val slot = ((u ushr 32) and 0xffffffL).toInt()
        val aux = u.toInt()
        when (op) {
            OP_ACCEPT -> if (rs >= 0 && rs < nslots) {
                val h = Handle(r, rs, ++gen)
                slots[r][rs] = h
                accepted.addLast(h)
            }
            OP_RECV -> {
                val h = slots[r][slot] ?: return
                if (h.gen != aux) return
                if (rs > 0) append(h, from, rs) else if (rs != -ENOBUFS) h.eof = true
                if (fl and CQE_F_MORE == 0) {
                    h.recvOn = false
                    if (!h.eof && !h.closed) { feed_recv(r, slot, h.gen); h.recvOn = true }
                }
                flag(h)
            }
            OP_SEND -> {
                val h = slots[r][slot] ?: return
                if (h.gen != aux) return
                h.sending = false
                if (rs < 0) {
                    h.eof = true
                    h.queuedSize = 0
                    if (h.closed) feed_close(r, slot, h.gen) else flag(h)
                    return
                }
                if (h.queuedSize > 0) {
                    val n = h.queuedSize
                    h.queuedSize = 0
                    send(h, h.queued, 0, n)
                } else if (h.closed) feed_close(r, slot, h.gen)
            }
            OP_CLOSE -> if (slots[r][slot]?.gen == aux) slots[r][slot] = null
        }
    }

    /** The receive's bytes at [from] in [bytes]: read in place when nothing else waits, else appended to its own array. */
    fun append(h: Handle, from: Int, n: Int) {
        if (h.from == h.to) {
            if (h.input !== bytes) borrowed.add(h)
            h.input = bytes
            h.from = from
            h.to = from + n
            return
        }
        if (h.input === bytes && h.to == from) { h.to += n; return }
        val live = h.to - h.from
        if (h.input === bytes || h.to + n > h.input.size) {
            val next = ByteArray(maxOf(live + n, if (h.input === bytes) 0 else h.input.size * 2))
            h.input.copyInto(next, 0, h.from, h.to)
            h.input = next
            h.from = 0
            h.to = live
        }
        bytes.copyInto(h.input, h.to, from, from + n)
        h.to += n
    }

    fun flag(h: Handle) {
        if (h.flagged || h.closed) return
        h.flagged = true
        data.add(h)
    }

    /** The accept, data and write queues' dispatch loops, until none has work; the commit deadline after each visit. */
    fun dispatch(xio: Xio) {
        while (accepted.isNotEmpty()) { xio.onAccept(listen); xio.tick() }
        do {
            var i = 0
            while (i < data.size) {
                val h = data[i++]
                h.flagged = false
                visit(h, xio)
            }
            data.clear()
            while (writes.isNotEmpty()) {
                val w = writes.removeFirst()
                w.queued = false
                xio.onWrite(w)
                xio.tick()
            }
        } while (data.isNotEmpty())
    }

    fun visit(h: Handle, xio: Xio) {
        if (h.closed) return
        val hr = h.header ?: return
        val c = hr.conn
        val before = h.from
        when (c.stage) {
            HEADER -> if (hr.armed) xio.onHeader(hr) else return
            BODY -> { val b = h.body ?: return; if (b.armed) xio.onBody(b) else return }
            else -> return
        }
        xio.tick()
        if (!h.closed && (c.stage == HEADER || c.stage == BODY) && h.to > h.from && h.from != before) flag(h)
    }

    actual fun accept(): Handle? = accepted.removeFirstOrNull()

    actual fun interest(h: HeaderRead, on: Boolean): Boolean {
        val hd = h.conn.handle
        hd.header = h
        if (on) {
            if (!hd.recvOn && !hd.eof && !hd.closed) { feed_recv(hd.ring, hd.slot, hd.gen); hd.recvOn = true }
            if (hd.to > hd.from || hd.eof) flag(hd)
        }
        return true
    }

    actual fun interest(b: BodyRead, on: Boolean): Boolean {
        val hd = b.conn.handle
        hd.body = b
        if (on && (hd.to > hd.from || hd.eof)) flag(hd)
        return true
    }

    actual fun interest(w: BufferedWrite, on: Boolean): Boolean = true

    actual fun ready(w: BufferedWrite) {
        if (w.queued) return
        w.queued = true
        writes.addLast(w)
    }

    actual fun read(h: Handle, dst: ByteArray, off: Int, len: Int): Int {
        val n = minOf(len, h.to - h.from)
        if (n <= 0) return if (h.eof) -1 else 0
        h.input.copyInto(dst, off, h.from, h.from + n)
        h.from += n
        return n
    }

    actual fun write(h: Handle, src: ByteArray, off: Int, len: Int): Int {
        if (h.closed || h.eof) return -1
        val n = minOf(len, WRITE_CALL)
        if (n == 0) return 0
        if (h.sending) {
            if (h.queuedSize + n > h.queued.size) h.queued = h.queued.copyOf(maxOf(h.queued.size * 2, h.queuedSize + n))
            src.copyInto(h.queued, h.queuedSize, off, off + n)
            h.queuedSize += n
        } else if (!send(h, src, off, n)) return -1
        return n
    }

    fun send(h: Handle, src: ByteArray, off: Int, n: Int): Boolean {
        if (feed_send(h.ring, h.slot, src.refTo(off), n, h.gen) != 0) return false
        h.sending = true
        return true
    }

    actual fun close(h: Handle) {
        if (h.closed) return
        h.closed = true
        h.from = h.to
        if (!h.sending) feed_close(h.ring, h.slot, h.gen)
    }
}

actual fun epochSeconds(): Long = feed_epoch_s()

actual fun monoNanos(): Long = feed_mono_ns()
