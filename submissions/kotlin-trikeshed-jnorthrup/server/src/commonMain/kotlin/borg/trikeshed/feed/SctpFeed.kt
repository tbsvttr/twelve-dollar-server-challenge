package borg.trikeshed.feed

import borg.trikeshed.htx.PPID_HTX11
import borg.trikeshed.sctp.Ppid
import borg.trikeshed.sctp.SctpState
import borg.trikeshed.sctp.SctpTcb
import borg.trikeshed.sctp.SctpUdpPort
import borg.trikeshed.sctp.SctpUpper

/**
 * The feed over SCTP associations (TRANSPORT=sctp), beside [Xio]'s TCP states: every association of the port shares
 * one UDP socket, so the kernel holds one descriptor however many users are connected. An SCTP message carries one
 * request (or a pipeline of them) as HTTP/1.1 text; [Request.frame] and [Feed.respond] are the TCP path's own, and the
 * responses leave as one message on the same association. Writes join the same COMMIT window as [Xio]: a response
 * produced while a write transaction is open waits in the parked list until its COMMIT, so a 201 follows its commit.
 * A message that is not a whole HTTP/1.x request aborts its association. The client owns association lifetime: a
 * request's Connection: close is answered as on TCP, and the association stays until the client shuts it down.
 */
class SctpFeed(val feed: Feed, val store: FeedStore, val commitWindowNanos: Long = COMMIT_WINDOW_NANOS) : SctpUpper {
    lateinit var port: SctpUdpPort
    val request = Request()
    val send = Out()
    var parkedTcb = arrayOfNulls<SctpTcb>(1024)
    var parkedBytes = arrayOfNulls<ByteArray>(1024)
    var parkedCount = 0
    var windowOpen = false
    var deadline = 0L

    override fun associated(tcb: SctpTcb) {}

    override fun closed(tcb: SctpTcb) {}

    override fun message(tcb: SctpTcb, ppid: Ppid, bytes: ByteArray, offset: Int, length: Int) {
        send.size = 0
        var from = offset
        val to = offset + length
        while (from < to) {
            val at = request.frame(bytes, from, to)
            if (at <= 0) { port.table.abort(tcb); return }
            val start = if (windowOpen) 0L else port.now()
            feed.respond(bytes, request, send)
            if (!windowOpen && store.pending) {
                windowOpen = true
                deadline = start + commitWindowNanos
            }
            from = at
        }
        if (store.pending) park(tcb, send.bytes.copyOf(send.size))
        else port.table.send(tcb, PPID_HTX11, send.bytes, 0, send.size)
    }

    fun park(tcb: SctpTcb, response: ByteArray) {
        if (parkedCount == parkedTcb.size) {
            parkedTcb = parkedTcb.copyOf(parkedCount * 2)
            parkedBytes = parkedBytes.copyOf(parkedCount * 2)
        }
        parkedTcb[parkedCount] = tcb
        parkedBytes[parkedCount++] = response
    }

    /** COMMIT once the window has passed; then the parked responses leave, or their associations abort if it failed. */
    fun tick(now: Long) {
        store.rest()
        if (!windowOpen || now - deadline < 0) return
        windowOpen = false
        val committed = try { store.commit(); true } catch (_: Throwable) { false }
        for (i in 0 until parkedCount) {
            val t = parkedTcb[i]!!
            val b = parkedBytes[i]!!
            parkedTcb[i] = null
            parkedBytes[i] = null
            if (t.state == SctpState.CLOSED) continue
            if (committed) port.table.send(t, PPID_HTX11, b, 0, b.size) else port.table.abort(t)
        }
        parkedCount = 0
        port.flush()
    }

    /** The owner loop: wakes for datagrams, the associations' timers or the COMMIT deadline. It does not return. */
    suspend fun serve() {
        while (true) {
            val commitAt = if (windowOpen) deadline else Long.MAX_VALUE
            port.waitWake(minOf(port.table.nextDeadline(), commitAt))
            port.pump()
            tick(port.now())
        }
    }
}
