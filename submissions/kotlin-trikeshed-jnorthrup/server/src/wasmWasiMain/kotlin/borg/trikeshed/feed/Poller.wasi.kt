package borg.trikeshed.feed

import borg.trikeshed.userspace.wasi.Wasi

/** A socket wasmtime handed over (sock_accept), and which of its states want readiness. */
actual class Handle(val fd: Int) {
    var header: HeaderRead? = null
    var body: BodyRead? = null
    var write: BufferedWrite? = null
    var headerOn = false
    var bodyOn = false
    var writeOn = false
    var closed = false
}

/**
 * The poller on WASI preview 1 (wasmtime 46 with -S preview2=n -S tcplisten=HOST:PORT): the host owns the listening
 * socket and hands it over as a descriptor, so [host] and [port] only name it. One poll_oneoff per wake over the
 * listener and every armed state, one subscription per state class as the JVM's selectors have one key each (header
 * read, body read, blocked write); the commit window is the poll's clock deadline. Every response joins the write
 * queue ([ready]) and is written in the same pass; write interest is armed only while a socket is full. wasmtime polls
 * the sockets with its own reactor: this build has no io_uring.
 */
actual class Poller actual constructor(val host: String, val port: Int) {
    val listen = Listen()
    val listener: Int = Wasi.listeners.firstOrNull() ?: error("no listening socket: run wasmtime with -S tcplisten")
    val live = ArrayList<Handle>()
    val writes = ArrayDeque<BufferedWrite>()
    var fds = IntArray(256)
    var outward = BooleanArray(256)
    var owners = arrayOfNulls<Handle>(256)
    /** Per subscription: 0 listener, 1 header, 2 body, 3 write. */
    var kinds = IntArray(256)
    var ready = IntArray(256)

    fun subscribe(n: Int, fd: Int, write: Boolean, owner: Handle?, kind: Int): Int {
        if (n == fds.size) {
            val size = n * 2
            fds = fds.copyOf(size); outward = outward.copyOf(size); owners = owners.copyOf(size)
            kinds = kinds.copyOf(size); ready = ready.copyOf(size)
        }
        fds[n] = fd; outward[n] = write; owners[n] = owner; kinds[n] = kind
        return n + 1
    }

    actual fun run(xio: Xio) {
        while (true) {
            var n = subscribe(0, listener, false, null, 0)
            var i = 0
            while (i < live.size) {
                val h = live[i++]
                if (h.headerOn) n = subscribe(n, h.fd, false, h, 1)
                if (h.bodyOn) n = subscribe(n, h.fd, false, h, 2)
                if (h.writeOn) n = subscribe(n, h.fd, true, h, 3)
            }
            val w = xio.waitMillis()
            val got = Wasi.poll(fds, outward, n, if (w < 0) -1 else w * 1_000_000L, ready)
            check(got >= 0) { "poll_oneoff failed: ${-got}" }
            var k = 0
            while (k < got) {
                val s = ready[k++]
                val h = owners[s]
                when (kinds[s]) {
                    0 -> xio.onAccept(listen)
                    1 -> if (h != null && !h.closed) h.header?.let { xio.onHeader(it) }
                    2 -> if (h != null && !h.closed) h.body?.let { xio.onBody(it) }
                    3 -> if (h != null && !h.closed) h.write?.let { xio.onWrite(it) }
                }
                xio.tick()
                drain(xio)
            }
            // COMMIT in tick queues the parked responses: write them in this pass.
            do {
                xio.rest()
                xio.tick()
                drain(xio)
            } while (writes.isNotEmpty())
            var j = 0
            while (j < live.size) {
                if (!live[j].closed) { j++; continue }
                val last = live.removeAt(live.size - 1)
                if (j < live.size) live[j] = last
            }
        }
    }

    /** The write queue's dispatch loop: every queued response gets one write call. */
    fun drain(xio: Xio) {
        while (writes.isNotEmpty()) {
            val w = writes.removeFirst()
            w.queued = false
            xio.onWrite(w)
            xio.tick()
        }
    }

    actual fun accept(): Handle? {
        val fd = Wasi.accept(listener)
        if (fd < 0) return null
        return Handle(fd).also { live.add(it) }
    }

    actual fun interest(h: HeaderRead, on: Boolean): Boolean {
        val hd = h.conn.handle
        hd.header = h
        hd.headerOn = on
        return true
    }

    actual fun interest(b: BodyRead, on: Boolean): Boolean {
        val hd = b.conn.handle
        hd.body = b
        hd.bodyOn = on
        return true
    }

    actual fun interest(w: BufferedWrite, on: Boolean): Boolean {
        val hd = w.conn.handle
        hd.write = w
        hd.writeOn = on
        return true
    }

    actual fun ready(w: BufferedWrite) {
        if (w.queued) return
        w.queued = true
        writes.addLast(w)
    }

    actual fun read(h: Handle, dst: ByteArray, off: Int, len: Int): Int {
        if (h.closed) return -1
        val n = Wasi.recv(h.fd, dst, off, len)
        return when {
            n > 0 -> n
            n == 0 -> -1
            n == -11 -> 0
            else -> -1
        }
    }

    actual fun write(h: Handle, src: ByteArray, off: Int, len: Int): Int {
        if (h.closed) return -1
        val n = Wasi.send(h.fd, src, off, minOf(len, WRITE_CALL))
        return when {
            n >= 0 -> n
            n == -11 -> 0
            else -> -1
        }
    }

    actual fun close(h: Handle) {
        if (h.closed) return
        h.closed = true
        h.headerOn = false; h.bodyOn = false; h.writeOn = false
        Wasi.shutdown(h.fd)
        Wasi.close(h.fd)
    }
}

actual fun epochSeconds(): Long = Wasi.realtimeNanos() / 1_000_000_000L

actual fun monoNanos(): Long = Wasi.monotonicNanos()
