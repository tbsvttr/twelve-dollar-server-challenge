package borg.trikeshed.feed

/** A connected socket of the platform: on the JVM a java.nio SocketChannel and its key in each state selector. */
expect class Handle

/**
 * The platform's readiness: one selector per concrete transport state class, each private to that class's selector
 * object and selected only by its own typed dispatch loop, all owned by the one thread in [run]:
 *
 *   state class      selector  armed interest                               queued work               dispatch calls
 *   [Listen]         listen    accept, always                               -                         [Xio.onAccept]
 *   [HeaderRead]     header    read, from accept on; off while disarmed     a select's overflow       [Xio.onHeader]
 *   [BodyRead]       body      read, only while the connection is in BODY   -                         [Xio.onBody]
 *   [BufferedWrite]  write     write, only while a write is blocked         every response            [Xio.onWrite]
 *
 * Kernel interest follows the transport state lazily, so an ordinary request and its response change none. Every
 * response joins the write selector's ready queue ([ready]); its dispatch loop writes it with one nonblocking write and
 * arms write interest only when the socket is full. A header key stays armed across requests: [Conn.stage] says which
 * state may consume input, and a header key reported while the connection is in another state is disarmed without
 * reading, then armed again when the connection returns to [HEADER]. COMMIT is a deadline, not readiness: [run] waits
 * at most until [Xio.waitMillis] and calls [Xio.tick] after every handled key and write.
 */
expect class Poller(host: String, port: Int) {
    /** The owner thread's loop; it does not return. */
    fun run(xio: Xio)

    /** The next pending connection, or null when none is waiting. */
    fun accept(): Handle?

    /** The header selector: [h]'s read interest on (its key registered the first time) or off. False when refused. */
    fun interest(h: HeaderRead, on: Boolean): Boolean

    /** The body selector: [b]'s read interest on or off. False when the platform refused. */
    fun interest(b: BodyRead, on: Boolean): Boolean

    /** The write selector: [w]'s write interest on (its socket is full) or off. False when the platform refused. */
    fun interest(w: BufferedWrite, on: Boolean): Boolean

    /** The write selector: [w] joins its ready queue, unless it is queued already. */
    fun ready(w: BufferedWrite)

    /** Reads at most [len] bytes into [dst] at [off]: the count, 0 when none are ready, -1 at end of stream or error. */
    fun read(h: Handle, dst: ByteArray, off: Int, len: Int): Int

    /**
     * Writes at most min([len], [WRITE_CALL]) bytes from [src] at [off] in one call: the count, less than that when the
     * socket is full (0 included), -1 on error.
     */
    fun write(h: Handle, src: ByteArray, off: Int, len: Int): Int

    /** Closes the socket; its keys in every state selector are cancelled with it. */
    fun close(h: Handle)
}

/** Seconds since the epoch. */
expect fun epochSeconds(): Long

/** A monotonic clock in nanoseconds. */
expect fun monoNanos(): Long

/**
 * How long the write transaction stays open for more writes before its COMMIT, counted from the start of the request
 * that began it. At 64,000 users on a 1-CPU container (2 min holds) server CPU per request was 67.1-69.6 us with one
 * COMMIT per selector pass, 59.7-62.1 us with a 32 ms window, 56.2-59.0 us with 64 ms and 56.3-56.4 us with 128 ms
 * (README, Group commit).
 */
const val COMMIT_WINDOW_NANOS = 64_000_000L

/** The longest a due write batch waits for [FeedStore.ready] (the WAL gate) before it runs anyway. */
const val GATE_HOLD_NANOS = 500_000_000L

/** Connections the listen state accepts per visit; the listening socket stays ready for the next visit. */
const val ACCEPT_BUDGET = 64

/**
 * Bytes one read takes. It bounds the requests one header visit answers (a pipeline's rest stays in the socket,
 * which stays ready), so the commit deadline waits at most for that much work.
 */
const val READ_BUDGET = 1 shl 14

/** Bytes one write call offers at most; a longer response takes more write visits. */
const val WRITE_CALL = 1 shl 18

/** An output chunk: the responses of many connections, copied in front to back. */
const val CHUNK = 1 shl 20

/** [Conn.stage]: its responses wait for COMMIT; no state consumes its input (also after close). */
const val PARKED = 0

/** [Conn.stage] and [Conn.reading]: [HeaderRead] consumes its input. */
const val HEADER = 1

/** [Conn.stage] and [Conn.reading]: [BodyRead] consumes its input. */
const val BODY = 2

/** [Conn.stage]: its output belongs to the write selector, queued or blocked on a full socket. */
const val WRITE = 3

val NO_BYTES: ByteArray = ByteArray(0)

/** The listening socket's readiness state: the one key in the listen selector. */
class Listen

/**
 * One connection: the socket, and which transport state it is in. Each state's data is its own class below, and an
 * instance of a state class is registered with that state's selector only. What a state may do ([stage]) is kept apart
 * from what its selector watches ([HeaderRead.armed], [BodyRead.armed], [BufferedWrite.blocked]) and from queued work
 * ([BufferedWrite.queued]).
 */
class Conn(val handle: Handle) {
    var open = true
    /** Close once the output already produced is written (Connection: close, HTTP/1.0). */
    var closing = false
    /** A write of this connection waits in [Xio.queue]; nothing after it is read until its response is out. */
    var awaiting = false
    /** The read state the connection returns to once its output is out: [HEADER], or [BODY] while a body is incomplete. */
    var reading = HEADER
    /** The state that may act on the connection now: [HEADER], [BODY], [PARKED] or [WRITE]. */
    var stage = HEADER
    val header = HeaderRead(this)
    var body: BodyRead? = null
    val write = BufferedWrite(this)
}

/** Awaiting a request head; [held] keeps the bytes of a partial head across reads. Only the header selector holds it. */
class HeaderRead(val conn: Conn) {
    var held: ByteArray? = null
    var heldSize = 0
    /** [held] may hold whole requests that arrived behind a queued write: framed again once that write is answered. */
    var replay = false
    /** Read interest is on in the header selector. */
    var armed = false
}

/**
 * A request whose head is parsed and whose body is incomplete: [bytes] holds the head and the body so far, [size] of
 * [need]; [request] was parsed once and its offsets index [bytes]. Only the body selector holds it.
 */
class BodyRead(val conn: Conn) {
    val request = Request()
    var bytes = NO_BYTES
    var size = 0
    var need = 0
    /** Read interest is on in the body selector. */
    var armed = false
}

/**
 * Response bytes not written yet: [from] until [to] of [bytes], which belong to [chunk] while it is shared and to this
 * connection alone once [chunk] is null. Only the write selector holds it.
 */
class BufferedWrite(val conn: Conn) {
    var chunk: Chunk? = null
    var bytes = NO_BYTES
    var from = 0
    var to = 0
    /** In the write selector's ready queue. */
    var queued = false
    /** Its socket was full: write interest is on until the rest is written. */
    var blocked = false
}

/** Response bytes of many connections, front to back; [refs] counts the [BufferedWrite]s still pointing into it. */
class Chunk {
    val bytes = ByteArray(CHUNK)
    var size = 0
    var refs = 0
}

/**
 * Where responses wait to be written, copied once out of the reused [Xio.send] buffer: [current] takes the next one.
 * A full chunk others still point into is left to them and a free chunk (or a new one) becomes current; a chunk no
 * write points into any more is reused, so the steady state allocates no array per response.
 */
class Output {
    var current = Chunk()
    val free = ArrayList<Chunk>()

    fun put(w: BufferedWrite, src: ByteArray, from: Int, to: Int) {
        val n = to - from
        if (n > CHUNK) {
            w.chunk = null
            w.bytes = src.copyOfRange(from, to)
            w.from = 0
            w.to = n
            return
        }
        var c = current
        if (c.size + n > CHUNK) {
            if (c.refs == 0) c.size = 0 else {
                c = if (free.isEmpty()) Chunk() else free.removeAt(free.size - 1)
                current = c
            }
        }
        src.copyInto(c.bytes, c.size, from, to)
        w.chunk = c
        w.bytes = c.bytes
        w.from = c.size
        w.to = c.size + n
        c.size += n
        c.refs++
    }

    /** [w] no longer points into its chunk. */
    fun release(w: BufferedWrite) {
        val c = w.chunk ?: return
        w.chunk = null
        if (--c.refs == 0 && c !== current) {
            c.size = 0
            free.add(c)
        }
    }
}

/**
 * RelaxFactory's one.xio.HttpMethod.init/innerloop, monomorphized per transport state: [Poller] keeps one selector
 * per state class, and each selector's own dispatch loop calls one of [onAccept], [onHeader], [onBody] and [onWrite]
 * with that one class. One thread owns everything, SQLite included. Reads run at once on committed data and answer in
 * the same visit. A write is checked when it arrives and queued unexecuted ([queue]); its connection reads nothing
 * more until the write is answered. [tick] runs the batch once the first queued write is [commitWindowNanos] old:
 * BEGIN, every queued write, COMMIT, then their responses; no read ever sees a write that is not committed.
 */
class Xio(val poller: Poller, val feed: Feed, val store: FeedStore, val commitWindowNanos: Long = COMMIT_WINDOW_NANOS) {
    val rx = ByteArray(READ_BUDGET)
    val request = Request()
    val send = Out()
    val output = Output()
    val queue = WriteQueue().also { feed.queue = it }
    /** Whether writes wait in [queue], and when their batch runs ([monoNanos]). */
    var windowOpen = false
    var deadline = 0L

    fun init() = poller.run(this)

    /** The end of a wake (the poller's dispatch pass is done): read state held for the wake's reads is let go. */
    fun rest() = store.rest()

    /** COMMIT once the first queued write is [commitWindowNanos] old and the store is [FeedStore.ready], or [GATE_HOLD_NANOS] later regardless. */
    fun tick() {
        if (!windowOpen) return
        val late = monoNanos() - deadline
        if (late >= 0 && (store.ready() || late > GATE_HOLD_NANOS)) settle()
    }

    /** How long the owner thread may wait for readiness: until the batch is due, or -1 when no write waits; 1 ms while a due batch is held. */
    fun waitMillis(): Long {
        if (!windowOpen) return -1
        val left = deadline - monoNanos()
        return if (left <= 0) 1 else (left + 999_999L) / 1_000_000L
    }

    /** Listen state: at most [ACCEPT_BUDGET] new connections, each into [HeaderRead] with its key armed. */
    fun onAccept(l: Listen) {
        var n = 0
        while (n < ACCEPT_BUDGET) {
            val c = Conn(poller.accept() ?: return)
            arm(c.header, c)
            n++
        }
    }

    /**
     * HeaderRead state: one read, then every complete request answered; a partial head stays, a partial body moves on.
     * Reported ready while the connection is in another state, it consumes nothing and disarms its key.
     */
    fun onHeader(h: HeaderRead) {
        val c = h.conn
        if (!c.open) return
        if (c.stage != HEADER) {
            if (h.armed) disarm(h, c)
            return
        }
        try {
            val n = poller.read(c.handle, rx, 0, rx.size)
            if (n < 0) { close(c); return }
            if (n == 0) return
            send.size = 0
            val held = h.held
            if (held == null) frame(c, rx, 0, n) else {
                val to = h.heldSize + n
                val src = if (to > held.size) held.copyOf(maxOf(held.size * 2, to)) else held
                rx.copyInto(src, h.heldSize, 0, n)
                h.held = null
                h.heldSize = 0
                frame(c, src, 0, to)
            }
            emit(c)
        } catch (_: Throwable) {
            close(c)
        }
    }

    /**
     * BodyRead state: one read of the body's missing bytes, straight into [BodyRead.bytes]; complete, its key is
     * disarmed and the request answered. Reported ready while the connection is not in BODY, it only disarms.
     */
    fun onBody(b: BodyRead) {
        val c = b.conn
        if (!c.open) return
        if (c.stage != BODY) {
            if (b.armed) disarm(b, c)
            return
        }
        try {
            val n = poller.read(c.handle, b.bytes, b.size, minOf(b.need - b.size, READ_BUDGET))
            if (n < 0) { close(c); return }
            if (n == 0) return
            b.size += n
            if (b.size < b.need) return
            if (b.armed) disarm(b, c)
            if (!c.open) return
            c.reading = HEADER
            send.size = 0
            respond(c, b.bytes, b.request)
            b.bytes = NO_BYTES
            emit(c)
        } catch (_: Throwable) {
            close(c)
        }
    }

    /**
     * BufferedWrite state, only while the connection is in WRITE: one nonblocking write. All out: the connection reads
     * again, or closes. The socket full (fewer
     * bytes taken than offered): the rest becomes the connection's own and write interest waits for room; it is not
     * queued again. A whole [WRITE_CALL] taken with more left: queued again for the next visit.
     */
    fun onWrite(w: BufferedWrite) {
        val c = w.conn
        if (!c.open || c.stage != WRITE) return
        try {
            val len = w.to - w.from
            val n = poller.write(c.handle, w.bytes, w.from, len)
            if (n < 0) { close(c); return }
            w.from += n
            if (w.from < w.to) {
                if (n == minOf(len, WRITE_CALL)) {
                    poller.ready(w)
                    return
                }
                if (w.chunk != null) {
                    val rest = w.bytes.copyOfRange(w.from, w.to)
                    output.release(w)
                    w.bytes = rest
                    w.from = 0
                    w.to = rest.size
                }
                if (!w.blocked) {
                    if (poller.interest(w, true)) w.blocked = true else close(c)
                }
                return
            }
            output.release(w)
            w.bytes = NO_BYTES
            w.from = 0
            w.to = 0
            if (w.blocked) {
                if (!poller.interest(w, false)) { close(c); return }
                w.blocked = false
            }
            if (c.closing) close(c) else toRead(c)
        } catch (_: Throwable) {
            close(c)
        }
    }

    /**
     * The batch: every queued write runs in one transaction, in arrival order, each response written behind whatever
     * its connection produced before it; then COMMIT, and only then do the responses join the write selector's queue.
     * A failed COMMIT closes those connections: none of their writes is acknowledged.
     */
    fun settle() {
        windowOpen = false
        val q = queue
        val n = q.count
        for (i in 0 until n) {
            val c = q.conns[i]!!
            send.size = 0
            val w = c.write
            if (c.open && w.to > w.from) {
                send.raw(w.bytes, w.from, w.to)
                output.release(w)
            }
            feed.answer(q, i, send)
            if (c.open) output.put(w, send.bytes, 0, send.size)
        }
        val committed = try { store.commit(); true } catch (_: Throwable) { false }
        for (i in 0 until n) {
            val c = q.conns[i]!!
            q.clear(i)
            c.awaiting = false
            if (!c.open) continue
            if (committed) {
                c.stage = WRITE
                poller.ready(c.write)
            } else close(c)
        }
        q.count = 0
    }

    /** Closes once: the output's chunk is released here, and queue entries left behind are skipped by [Conn.open]. */
    fun close(c: Conn) {
        if (!c.open) return
        c.open = false
        c.stage = PARKED
        val w = c.write
        output.release(w)
        w.bytes = NO_BYTES
        poller.close(c.handle)
    }

    /**
     * Answers every complete request in src[start, to) into [send]; a partial head stays in [HeaderRead], a partial
     * body moves to [BodyRead]. A queued write stops it: the bytes behind the write wait in [HeaderRead.held] for
     * [toRead] to frame them again, so responses leave in request order.
     */
    fun frame(c: Conn, src: ByteArray, start: Int, to: Int) {
        val r = request
        var from = start
        while (from < to && !c.closing && !c.awaiting) {
            val at = r.frameHead(src, from, to)
            if (at < 0) { close(c); return }
            if (at == 0) break
            if (r.bodyTo > to) { toBody(c, src, from, to); return }
            respond(c, src, r)
            from = r.bodyTo
        }
        if (from < to && !c.closing) {
            val h = c.header
            h.held = if (src === rx) src.copyOfRange(from, to) else src.copyInto(src, 0, from, to)
            h.heldSize = to - from
            if (c.awaiting) h.replay = true
        }
    }

    /** The head in src[from, to) is parsed (its sizes bounded) and its body incomplete: the bytes and the parse move to [BodyRead]. */
    fun toBody(c: Conn, src: ByteArray, from: Int, to: Int) {
        val b = c.body ?: BodyRead(c).also { c.body = it }
        b.need = request.bodyTo - from
        b.bytes = ByteArray(b.need)
        src.copyInto(b.bytes, 0, from, to)
        b.size = to - from
        b.request.copyFrom(request, from)
        c.reading = BODY
    }

    /** One request: a read's response into [send] at once; a valid write joins [queue], and the batch is due [commitWindowNanos] after the first. */
    fun respond(c: Conn, src: ByteArray, r: Request) {
        val q = queue
        val before = q.count
        feed.respond(src, r, send)
        if (r.close) c.closing = true
        if (q.count != before) {
            q.conns[before] = c
            c.awaiting = true
            if (!windowOpen) {
                windowOpen = true
                deadline = monoNanos() + commitWindowNanos
            }
        }
    }

    /**
     * What this read produced goes out: handed straight to the poller (one copy, into the send arena), and only a rest
     * the socket did not take is kept in [BufferedWrite] for the write selector's queue. With a write queued, the
     * responses before it wait in [BufferedWrite] and the batch appends the write's response. Nothing produced: the
     * connection stays in, or enters, its read state.
     */
    fun emit(c: Conn) {
        if (!c.open) return
        val w = c.write
        if (c.awaiting) {
            if (send.size > 0) output.put(w, send.bytes, 0, send.size)
            c.stage = PARKED
            return
        }
        if (send.size == 0) { toRead(c); return }
        val n = poller.write(c.handle, send.bytes, 0, send.size)
        if (n < 0) { close(c); return }
        if (n == send.size) {
            if (c.closing) close(c) else toRead(c)
            return
        }
        output.put(w, send.bytes, n, send.size)
        c.stage = WRITE
        poller.ready(w)
    }

    /**
     * Its output is out (or it produced none): the connection returns to its read state. [HEADER] arms the header key
     * if it was disarmed, and frames the requests that waited behind a write; [BODY] takes read interest from the
     * header key and gives it to the body key.
     */
    fun toRead(c: Conn) {
        val h = c.header
        if (c.reading == HEADER) {
            c.stage = HEADER
            if (!h.armed) arm(h, c)
            if (h.replay && c.open) {
                h.replay = false
                val held = h.held!!
                val n = h.heldSize
                h.held = null
                h.heldSize = 0
                send.size = 0
                frame(c, held, 0, n)
                emit(c)
            }
            return
        }
        c.stage = BODY
        if (h.armed) disarm(h, c)
        val b = c.body!!
        if (c.open && !b.armed) arm(b, c)
    }

    /** The flags change only when the selector took the change, so they always say what it watches. */
    fun arm(h: HeaderRead, c: Conn) {
        if (poller.interest(h, true)) h.armed = true else close(c)
    }

    fun disarm(h: HeaderRead, c: Conn) {
        if (poller.interest(h, false)) h.armed = false else close(c)
    }

    fun arm(b: BodyRead, c: Conn) {
        if (poller.interest(b, true)) b.armed = true else close(c)
    }

    fun disarm(b: BodyRead, c: Conn) {
        if (poller.interest(b, false)) b.armed = false else close(c)
    }
}
