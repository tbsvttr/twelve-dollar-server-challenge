package borg.trikeshed.feed

import org.khronos.webgl.Int8Array
import org.khronos.webgl.Uint8Array

external fun require(module: String): dynamic

/**
 * A Node.js socket of generation [gen], with the bytes received and not yet read: [input] is the last chunk Node handed
 * over (a view of its Buffer) while nothing else waits, else an array of its own.
 */
actual class Handle(val socket: dynamic, val gen: Int) {
    var input = NO_BYTES
    var from = 0
    var to = 0
    var eof = false
    var closed = false
    var header: HeaderRead? = null
    var body: BodyRead? = null
    var flagged = false
}

/**
 * The nearest open window on Node, kept as the baseline that the unified CCEK channel layer is measured against
 * (STUDIES.md S15, S16): Node's own sockets, not TrikeShed's elements, whose node versions are stubs today. The same four
 * state classes as the other pollers, fed by Node's socket events: a chunk appends to its [Handle] and
 * flags it, and one pass per event-loop turn (setImmediate) runs the accept, data and write queues' dispatch loops, then
 * [Xio.rest] and [Xio.tick]; a timer brings the pass back when the commit window ends. A write is one socket.write of a
 * copy, which libuv takes whole, so the socket never reports full and write interest is never needed. libuv polls the
 * sockets with epoll: this build has no io_uring.
 */
actual class Poller actual constructor(val host: String, val port: Int) {
    val listen = Listen()
    val accepted = ArrayDeque<Handle>()
    val data = ArrayList<Handle>()
    val writes = ArrayDeque<BufferedWrite>()
    var gen = 0
    var passQueued = false
    var timer: dynamic = null
    lateinit var xio: Xio

    actual fun run(xio: Xio) {
        this.xio = xio
        val net = require("node:net")
        val server = net.createServer { s: dynamic ->
            s.setNoDelay(true)
            val h = Handle(s, ++gen)
            s.on("data") { chunk: dynamic -> append(h, chunk); flag(h); wake() }
            s.on("end") { -> h.eof = true; flag(h); wake() }
            s.on("error") { _: dynamic -> h.eof = true; flag(h); wake() }
            accepted.addLast(h)
            wake()
        }
        val options: dynamic = js("({})")
        options.host = host
        options.port = port
        options.backlog = 65535
        server.listen(options)
    }

    fun wake() {
        if (passQueued) return
        passQueued = true
        js("setImmediate")({ -> pass() })
    }

    fun pass() {
        passQueued = false
        // COMMIT in tick queues the parked responses: dispatch again until no queue has work.
        do {
            dispatch(xio)
            xio.rest()
            xio.tick()
        } while (writes.isNotEmpty() || data.isNotEmpty() || accepted.isNotEmpty())
        val w = xio.waitMillis()
        if (w >= 0 && timer == null) {
            timer = js("setTimeout")({ -> timer = null; pass() }, w.toInt())
        }
    }

    /** The chunk in place when nothing else waits, else appended to the handle's own array. */
    fun append(h: Handle, chunk: dynamic) {
        val n = chunk.length as Int
        val view = Int8Array(chunk.buffer, chunk.byteOffset as Int, n).unsafeCast<ByteArray>()
        if (h.from == h.to) {
            h.input = view
            h.from = 0
            h.to = n
            return
        }
        val live = h.to - h.from
        val next = ByteArray(live + n)
        h.input.copyInto(next, 0, h.from, h.to)
        view.copyInto(next, live, 0, n)
        h.input = next
        h.from = 0
        h.to = live + n
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
        if (on && (hd.to > hd.from || hd.eof)) flag(hd)
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
        val copy = src.copyOfRange(off, off + n).unsafeCast<Int8Array>()
        h.socket.write(Uint8Array(copy.buffer, copy.byteOffset, n))
        return n
    }

    actual fun close(h: Handle) {
        if (h.closed) return
        h.closed = true
        h.from = h.to
        h.socket.end()
    }
}

actual fun epochSeconds(): Long = (js("Date.now()") as Double / 1000.0).toLong()

actual fun monoNanos(): Long = (js("performance.now()") as Double * 1_000_000.0).toLong()
