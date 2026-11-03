package borg.trikeshed.feed

import java.io.IOException
import java.lang.foreign.Arena
import java.lang.foreign.FunctionDescriptor
import java.lang.foreign.Linker
import java.lang.foreign.MemoryLayout
import java.lang.foreign.MemorySegment
import java.lang.foreign.ValueLayout.ADDRESS
import java.lang.foreign.ValueLayout.JAVA_INT
import java.lang.foreign.ValueLayout.JAVA_LONG
import java.lang.foreign.ValueLayout.JAVA_SHORT
import java.lang.invoke.MethodHandle
import java.net.InetSocketAddress
import java.net.StandardSocketOptions
import java.nio.ByteBuffer
import java.nio.channels.SelectionKey
import java.nio.channels.Selector
import java.nio.channels.ServerSocketChannel
import java.nio.channels.SocketChannel
import java.nio.file.Files
import java.nio.file.Path
import java.util.ArrayDeque
import java.util.function.Consumer

actual class Handle(val channel: SocketChannel) {
    var headerKey: SelectionKey? = null
    var bodyKey: SelectionKey? = null
    var writeKey: SelectionKey? = null
}

/** A state selector's bit in the ready set of a wait (its index in the stage poll). */
const val LISTEN_BIT = 1
const val HEADER_BIT = 2
const val BODY_BIT = 4
const val WRITE_BIT = 8

/**
 * HeaderRead visits per outer pass of [Poller.run] (straight from the header select and from its overflow together),
 * and BodyRead keys per visit of the body dispatch loop, each answering requests, before the other states are served.
 * The rest of what one select reported waits, in order, for the next passes, and that selector is selected again only
 * once it is all handled, so no ready key waits behind keys that became ready after it.
 */
const val READ_ROUND = 64

/** Writes one visit of the write dispatch loop makes, one write call each. */
const val WRITE_ROUND = 1024

/**
 * While the header selector's select is the wait: the longest it waits, so the listen selector (and, without the stage
 * poll, an armed body or write selector) is visited this often, after at most that pass's header visits.
 */
const val SLICE_MILLIS = 5L
const val SLICE_NANOS = SLICE_MILLIS * 1_000_000L

/**
 * java.nio readiness with one Selector per transport state class (the table is on [Poller] in Xio.kt). Each Selector
 * is private to one class-owned selector object below and selected only by that object's dispatch loop, all on the
 * one thread in [run]. Interest changes (registration, arming, disarming, cancellation by close) are applied by the JDK
 * only at that selector's next select and do not wake a wait, so a selector with such changes is dirty and is selected
 * before the thread may wait; the listening key starts dirty for the same reason.
 *
 * The wait. While the header selector carries traffic and no body or write key is armed (the ordinary state), the
 * header selector's own select is the wait: one system call, whose consumer visits the ready HeaderReads as a single
 * selector's did (READ_ROUND per pass, the rest queued in order), and the listen selector is selected once
 * [SLICE_MILLIS] have passed, after at most that pass's header visits. While a body or write key is armed, or the
 * header selector is quiet (its last select found nothing), the wait is one poll(2) over the four selectors' own epoll
 * descriptors (each found at startup as the one new anon_inode:[eventpoll] entry in /proc/self/fd across its
 * Selector.open), with the commit deadline as timeout, and then each ready selector's dispatch loop: an idle server
 * sleeps until something is ready. A pass with queued work or a dirty selector does not wait. Without the descriptors
 * (not Linux) the header selector's select always carries the wait, bounded by [SLICE_MILLIS].
 */
actual class Poller actual constructor(host: String, port: Int) {
    val listen: ListenSelector
    val header: HeaderSelector
    val body: BodySelector
    val write: WriteSelector
    /** poll(2) over the four selectors' epoll descriptors; null where they are not known. */
    val stages: StagePoll?
    val rx: ByteBuffer = ByteBuffer.allocateDirect(1 shl 16)
    val tx: ByteBuffer = ByteBuffer.allocateDirect(WRITE_CALL)

    init {
        val proc = Files.isDirectory(PROC_FD)
        val fds = IntArray(4) { -1 }
        var known = if (proc) eventpolls() else emptySet()
        fun opened(i: Int) {
            if (!proc) return
            val now = eventpolls()
            val fresh = now - known
            if (fresh.size == 1) fds[i] = fresh.first()
            known = now
        }
        listen = ListenSelector(host, port)
        opened(0)
        header = HeaderSelector()
        opened(1)
        body = BodySelector()
        opened(2)
        write = WriteSelector()
        opened(3)
        stages = if (fds.all { it >= 0 }) StagePoll(fds) else null
    }

    actual fun run(xio: Xio) {
        header.owner = xio
        while (true) {
            xio.tick()
            header.pass()
            val pending = listen.dirty || header.pending() || body.pending() || write.pending()
            val ready = await(xio, pending)
            listen.dispatch(xio, (ready and LISTEN_BIT) != 0)
            header.dispatch((ready and HEADER_BIT) != 0)
            body.dispatch(xio, (ready and BODY_BIT) != 0)
            write.dispatch(xio, (ready and WRITE_BIT) != 0)
            xio.rest()
        }
    }

    /** The wait described on the class: the bits of the selectors to select now (0 after an interrupted poll). */
    fun await(xio: Xio, pending: Boolean): Int {
        val s = stages
        val armed = body.armed > 0 || write.blocked > 0
        if (s != null && (armed || header.quiet)) return s.poll(if (pending) 0 else xio.waitMillis())
        if (!pending) {
            // Bounded by the listen selector's next visit (none when it is due) and by the commit deadline.
            val left = SLICE_NANOS - (monoNanos() - listen.visited)
            val slice = if (left <= 0) 0L else (left + 999_999L) / 1_000_000L
            val w = xio.waitMillis()
            header.await(if (w < 0) slice else minOf(w, slice))
        }
        var ready = if (monoNanos() - listen.visited >= SLICE_NANOS) LISTEN_BIT else 0
        if (armed) ready = ready or BODY_BIT or WRITE_BIT
        return ready
    }

    actual fun accept(): Handle? = listen.accept()

    actual fun interest(h: HeaderRead, on: Boolean): Boolean = header.arm(h, on)

    actual fun interest(b: BodyRead, on: Boolean): Boolean = body.arm(b, on)

    actual fun interest(w: BufferedWrite, on: Boolean): Boolean = write.arm(w, on)

    actual fun ready(w: BufferedWrite) = write.enqueue(w)

    actual fun read(h: Handle, dst: ByteArray, off: Int, len: Int): Int {
        rx.clear().limit(minOf(len, rx.capacity()))
        val n = try { h.channel.read(rx) } catch (_: IOException) { return -1 }
        if (n > 0) {
            rx.flip()
            rx.get(dst, off, n)
        }
        return n
    }

    actual fun write(h: Handle, src: ByteArray, off: Int, len: Int): Int {
        val n = minOf(len, tx.capacity())
        tx.clear()
        tx.put(src, off, n)
        tx.flip()
        return try { h.channel.write(tx) } catch (_: IOException) { -1 }
    }

    actual fun close(h: Handle) {
        if (h.headerKey != null) header.dirty = true
        val bk = h.bodyKey
        if (bk != null) body.forget(bk)
        val wk = h.writeKey
        if (wk != null) write.forget(wk)
        try { h.channel.close() } catch (_: IOException) {}
    }
}

/** The Listen state's selector: the listening socket's one key, with accept interest always. */
class ListenSelector(host: String, port: Int) {
    val selector: Selector = Selector.open()
    val keys: MutableSet<SelectionKey> = selector.selectedKeys()
    val server: ServerSocketChannel = ServerSocketChannel.open()
    /** Its registration is applied at its first select, which comes before the owner thread may wait. */
    var dirty = true
    /** When it was last selected ([monoNanos]). */
    var visited = 0L

    init {
        server.setOption(StandardSocketOptions.SO_REUSEADDR, true)
        server.bind(InetSocketAddress(host, port), 65535)
        server.configureBlocking(false)
        server.register(selector, SelectionKey.OP_ACCEPT, Listen())
    }

    /** Its dispatch loop: [Xio.onAccept] for the listening key, which takes at most ACCEPT_BUDGET connections per visit. */
    fun dispatch(xio: Xio, ready: Boolean) {
        if (!ready && !dirty) return
        dirty = false
        visited = monoNanos()
        selector.selectNow()
        val it = keys.iterator()
        while (it.hasNext()) {
            val k = it.next()
            it.remove()
            if (k.isValid) xio.onAccept(k.attachment() as Listen)
            xio.tick()
        }
    }

    fun accept(): Handle? {
        while (true) {
            val ch = try { server.accept() } catch (_: IOException) { return null } ?: return null
            try {
                ch.configureBlocking(false)
                ch.setOption(StandardSocketOptions.TCP_NODELAY, true)
                return Handle(ch)
            } catch (_: IOException) {
                try { ch.close() } catch (_: IOException) {}
            }
        }
    }
}

/**
 * The HeaderRead state's selector: every connection's header key, armed with read interest from accept on and disarmed
 * only while its connection is in another state. The consumer of its select visits each reported HeaderRead while the
 * outer pass has visits left (READ_ROUND per pass) and queues the rest, in order, as overflow. The overflow is visited
 * first in the next passes; the selector is not selected while overflow remains, nor twice in one pass, so no
 * HeaderRead is queued twice or visited twice for one select. Interest changes made during a visit (inside the select)
 * leave the selector dirty for its next select.
 */
class HeaderSelector {
    val selector: Selector = Selector.open()
    /** The HeaderReads a select reported after the pass's visits ran out, in the order reported. */
    val overflow = ArrayDeque<HeaderRead>(1024)
    /** The owner thread's [Xio], whose [Xio.onHeader] every visit calls; set by [Poller.run] before the first select. */
    lateinit var owner: Xio
    /** HeaderRead visits left in this outer pass. */
    var budget = 0
    /** This outer pass has selected the header selector. */
    var selected = false
    /** The header selector's one consumer, the only one given to any Selector: a visit while the pass has visits left, else overflow. */
    val visit = Consumer<SelectionKey> { k ->
        val h = k.attachment() as HeaderRead
        if (budget > 0) serve(h) else overflow.addLast(h)
    }
    var dirty = false
    /** Its last select found nothing: the wait goes back to every selector. */
    var quiet = true

    fun pending(): Boolean = dirty || !overflow.isEmpty()

    /** An outer pass begins: READ_ROUND visits for it, from the overflow and from at most one select. */
    fun pass() {
        budget = READ_ROUND
        selected = false
    }

    fun arm(h: HeaderRead, on: Boolean): Boolean {
        dirty = true
        return try {
            val handle = h.conn.handle
            val k = handle.headerKey
            if (k != null) {
                k.interestOps(if (on) SelectionKey.OP_READ else 0)
            } else if (on) {
                handle.headerKey = handle.channel.register(selector, SelectionKey.OP_READ, h)
            }
            true
        } catch (_: Exception) {
            false
        }
    }

    /** Its dispatch loop: the overflow, in order, while the pass has visits left; then, overflow empty and not selected yet this pass, a select when ready or dirty. */
    fun dispatch(ready: Boolean) {
        while (budget > 0) {
            val h = overflow.pollFirst() ?: break
            serve(h)
        }
        if (budget == 0 || selected || !overflow.isEmpty() || (!ready && !dirty)) return
        select(0L)
    }

    /** The wait while it carries traffic: one select of at most [millis] (0: none); its overflow is empty. */
    fun await(millis: Long) = select(millis)

    fun select(millis: Long) {
        selected = true
        dirty = false
        quiet = (if (millis <= 0L) selector.selectNow(visit) else selector.select(visit, millis)) == 0
    }

    /** The one call site of [Xio.onHeader], for direct and queued delivery alike: a visit, then the commit deadline. */
    fun serve(h: HeaderRead) {
        budget--
        owner.onHeader(h)
        owner.tick()
    }
}

/** The BodyRead state's selector: body keys, armed with read interest only while their connection is in BODY. */
class BodySelector {
    val selector: Selector = Selector.open()
    val keys: MutableSet<SelectionKey> = selector.selectedKeys()
    var dirty = false
    /** Body keys armed now. */
    var armed = 0

    fun pending(): Boolean = dirty || keys.isNotEmpty()

    fun arm(b: BodyRead, on: Boolean): Boolean {
        dirty = true
        return try {
            val handle = b.conn.handle
            val k = handle.bodyKey
            if (k != null) {
                k.interestOps(if (on) SelectionKey.OP_READ else 0)
            } else if (on) {
                handle.bodyKey = handle.channel.register(selector, SelectionKey.OP_READ, b)
            }
            if (on) armed++ else armed--
            true
        } catch (_: Exception) {
            false
        }
    }

    /** [k]'s channel is closing: its key is cancelled, and no longer counted as armed. */
    fun forget(k: SelectionKey) {
        dirty = true
        val b = k.attachment() as BodyRead
        if (b.armed) {
            b.armed = false
            armed--
        }
    }

    /** Its dispatch loop: a select once the last one's keys are handled, then [Xio.onBody] for at most READ_ROUND, the commit deadline after each. */
    fun dispatch(xio: Xio, ready: Boolean) {
        if (keys.isEmpty()) {
            if (!ready && !dirty) return
            dirty = false
            selector.selectNow()
            if (keys.isEmpty()) return
        }
        val it = keys.iterator()
        var n = 0
        while (n < READ_ROUND && it.hasNext()) {
            val k = it.next()
            it.remove()
            n++
            if (k.isValid) xio.onBody(k.attachment() as BodyRead)
            xio.tick()
        }
    }
}

/**
 * The BufferedWrite state's selector: its ready queue, which every response joins and which its dispatch loop writes
 * without waiting for readiness, and the write keys of blocked writes, armed with write interest only while a socket is
 * full. A blocked write its selector reports writable joins the same queue (if still blocked and not queued), so one
 * call site writes both.
 */
class WriteSelector {
    val selector: Selector = Selector.open()
    val keys: MutableSet<SelectionKey> = selector.selectedKeys()
    val queue = ArrayDeque<BufferedWrite>(1024)
    var dirty = false
    /** Writes blocked now (write interest armed). */
    var blocked = 0

    fun pending(): Boolean = dirty || !queue.isEmpty()

    fun enqueue(w: BufferedWrite) {
        if (w.queued) return
        w.queued = true
        queue.addLast(w)
    }

    fun arm(w: BufferedWrite, on: Boolean): Boolean {
        dirty = true
        return try {
            val handle = w.conn.handle
            val k = handle.writeKey
            if (k != null) {
                k.interestOps(if (on) SelectionKey.OP_WRITE else 0)
            } else if (on) {
                handle.writeKey = handle.channel.register(selector, SelectionKey.OP_WRITE, w)
            }
            if (on) blocked++ else blocked--
            true
        } catch (_: Exception) {
            false
        }
    }

    /** [k]'s channel is closing: its key is cancelled, and no longer counted as blocked. */
    fun forget(k: SelectionKey) {
        dirty = true
        val w = k.attachment() as BufferedWrite
        if (w.blocked) {
            w.blocked = false
            blocked--
        }
    }

    /** Its dispatch loop: writable blocked writes join the queue, then [Xio.onWrite] for at most WRITE_ROUND of it, the commit deadline after each. */
    fun dispatch(xio: Xio, ready: Boolean) {
        if (ready || dirty) {
            dirty = false
            selector.selectNow()
            val it = keys.iterator()
            while (it.hasNext()) {
                val k = it.next()
                it.remove()
                val w = k.attachment() as BufferedWrite
                if (k.isValid && w.blocked) enqueue(w)
            }
        }
        var n = 0
        while (n < WRITE_ROUND) {
            val w = queue.pollFirst() ?: return
            w.queued = false
            n++
            xio.onWrite(w)
            xio.tick()
        }
    }
}

/**
 * poll(2) over the state selectors' epoll descriptors (Linux only: the native handle and errno capture are made when
 * this class is first used, which is after the descriptors were found).
 */
class StagePoll(fds: IntArray) {
    val set: MemorySegment = Arena.global().allocate(8L * fds.size, 4)
    val count = fds.size.toLong()
    val state: MemorySegment = Arena.global().allocate(CALL_STATE)

    init {
        for (i in fds.indices) {
            set.set(JAVA_INT, 8L * i, fds[i])
            set.set(JAVA_SHORT, 8L * i + 4, POLLIN)
        }
    }

    /**
     * The bits of the ready selectors after waiting at most [timeoutMs] (-1: no limit); 0 when a signal interrupted the
     * wait, so the caller recomputes the timeout from the commit deadline.
     */
    fun poll(timeoutMs: Long): Int {
        val t = if (timeoutMs > Int.MAX_VALUE) Int.MAX_VALUE else timeoutMs.toInt()
        val r = POLL.invokeExact(state, set, count, t) as Int
        if (r < 0) {
            val errno = state.get(JAVA_INT, ERRNO_AT)
            if (errno == EINTR) return 0
            throw IOException("poll(2): errno $errno")
        }
        var ready = 0
        for (i in 0 until count.toInt()) if (set.get(JAVA_SHORT, 8L * i + 6).toInt() != 0) ready = ready or (1 shl i)
        return ready
    }

    companion object {
        const val POLLIN: Short = 1
        const val EINTR = 4
        val CALL_STATE: MemoryLayout = Linker.Option.captureStateLayout()
        val ERRNO_AT: Long = CALL_STATE.byteOffset(MemoryLayout.PathElement.groupElement("errno"))

        /** int poll(struct pollfd *fds, nfds_t nfds, int timeout), nfds_t being unsigned long on Linux; errno captured. */
        val POLL: MethodHandle = Linker.nativeLinker().let { l ->
            l.downcallHandle(l.defaultLookup().find("poll").orElseThrow(), FunctionDescriptor.of(JAVA_INT, ADDRESS, JAVA_LONG, JAVA_INT),
                Linker.Option.captureCallState("errno"))
        }
    }
}

val PROC_FD: Path = Path.of("/proc/self/fd")

/** This process's descriptors that are epoll instances (Linux /proc). */
fun eventpolls(): Set<Int> {
    val out = HashSet<Int>()
    val names = PROC_FD.toFile().list() ?: return out
    for (name in names) {
        val target = try { Files.readSymbolicLink(PROC_FD.resolve(name)).toString() } catch (_: IOException) { continue }
        if (target == "anon_inode:[eventpoll]") out.add(name.toInt())
    }
    return out
}

actual fun epochSeconds(): Long = System.currentTimeMillis() / 1000

actual fun monoNanos(): Long = System.nanoTime()
