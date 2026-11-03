package borg.trikeshed.loadgen

/** Request kinds, in load.js order. */
const val FEED = 0
const val POST = 1
const val LIKE = 2
const val CREATE = 3
val KINDS = arrayOf("GET /feed", "GET /posts/:id", "POST /posts/:id/like", "POST /posts")

/**
 * Sample scopes, by when a request's first byte left (when it never left: when it was issued): the whole run; the
 * canonical hold, k6's fixed stage [start + ramp, start + ramp + hold); the established hold, the same length starting
 * when client and server both first counted every user's TLS session established.
 */
const val RUN = 0
const val CANONICAL = 1
const val ESTABLISHED = 2
val SCOPES = arrayOf("run", "canonicalHold", "establishedHold")

/**
 * Latency in microseconds, log-linear: 64 buckets per power of two. A quantile is reported as the upper bound of the
 * bucket holding it, so it overstates the exact value by at most one bucket width (under 1.6%).
 */
class Histogram {
    val counts = LongArray(64 * 40)
    var total = 0L
    var max = 0L

    fun record(micros: Long) {
        val v = maxOf(1L, micros)
        counts[minOf(index(v), counts.size - 1)]++
        total++
        if (v > max) max = v
    }

    fun index(v: Long): Int {
        val exponent = 63 - v.countLeadingZeroBits()
        return if (exponent < 6) v.toInt() else (exponent - 5) * 64 + ((v shr (exponent - 6)) and 63).toInt()
    }

    /** The smallest value bucket [index] holds. */
    fun lower(index: Int): Long = if (index < 64) index.toLong() else {
        val exponent = index / 64 + 5
        (1L shl exponent) + ((index % 64).toLong() shl (exponent - 6))
    }

    fun upper(index: Int): Long = if (index + 1 < counts.size) lower(index + 1) - 1 else Long.MAX_VALUE

    fun percentile(p: Double): Long {
        if (total == 0L) return 0
        val rank = kotlin.math.ceil(p / 100.0 * total).toLong().coerceAtLeast(1)
        var seen = 0L
        for (i in counts.indices) {
            seen += counts[i]
            if (seen >= rank) return minOf(max, upper(i))
        }
        return max
    }

    fun add(other: Histogram) {
        for (i in counts.indices) counts[i] += other.counts[i]
        total += other.total
        if (other.max > max) max = other.max
    }
}

/** One scope's requests of one kind. Every finished request, failed ones included, is in [latency]. */
class KindStats {
    val latency = Histogram()
    /** The expected status (k6 checks' statuses). */
    var ok = 0L
    /** Another status, a timeout or a transport failure: k6's http_req_failed. */
    var failed = 0L
    /** Expected status but the body did not match. */
    var checksFailed = 0L
    /** Finished after its scope ended. */
    var drained = 0L
    /** Still outstanding at the drain deadline: in [latency] with the time they had waited by then (a lower bound). */
    var unfinished = 0L

    fun add(o: KindStats) {
        latency.add(o.latency)
        ok += o.ok
        failed += o.failed
        checksFailed += o.checksFailed
        drained += o.drained
        unfinished += o.unfinished
    }
}

/** Hold events kept with their stamps (all are counted). */
const val HOLD_EVENT_LIMIT = 1000

/** Why a request failed or a connection ended. */
object Reason {
    /** The request's deadline passed before connect and TLS finished. */
    const val SETUP_TIMEOUT = 0
    /** The deadline passed with the request sent over an established connection. */
    const val REQUEST_TIMEOUT = 1
    /** A SOCKET, BIND or CONNECT CQE error. */
    const val CONNECT = 2
    /** A SEND CQE error, or 0 bytes sent. */
    const val SEND = 3
    /** RECV returned 0: the server closed the connection. */
    const val EOF = 4
    /** A RECV or POLL CQE error. */
    const val RECV = 5
    /** The TLS session failed (an alert, a bad record). */
    const val TLS = 6
    /** The TLS session closed (the server's close_notify). */
    const val TLS_CLOSED = 7
    /** The TLS session refused the request (see TlsSendOutcome). */
    const val TLS_REFUSED = 8
    /** A response with an unexpected HTTP status. */
    const val STATUS = 9
    val NAMES = arrayOf("setupTimeout", "requestTimeout", "connectError", "sendError", "peerEof", "recvError", "tlsFailure",
        "tlsClosed", "tlsRefused", "httpStatus")
}
