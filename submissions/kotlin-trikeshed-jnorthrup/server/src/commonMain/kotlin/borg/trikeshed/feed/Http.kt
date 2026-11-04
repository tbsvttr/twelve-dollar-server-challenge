package borg.trikeshed.feed

/** Request methods this API routes; anything else is [OTHER]. */
enum class Method { GET, POST, OTHER }

/**
 * One HTTP/1.1 request framed in a receive window: request line, the three headers of interest
 * (Content-Length, Authorization, Connection), and the body. Other headers are skipped unread.
 */
class Request {
    var method = Method.OTHER
    var pathFrom = 0
    var pathTo = 0
    var authFrom = -1
    var authTo = -1
    var bodyFrom = 0
    var bodyTo = 0
    var close = false
    /** HTTP/1.0 request asking for keep-alive: the response must say `Connection: keep-alive`. */
    var keepAlive = false

    /**
     * Frames the request starting at [from]: the index after it when complete, 0 when more bytes are
     * needed, -1 when the bytes are not an HTTP/1.x request.
     */
    fun frame(src: ByteArray, from: Int, to: Int): Int {
        val at = frameHead(src, from, to)
        return if (at <= 0) at else if (bodyTo <= to) bodyTo else 0
    }

    /**
     * Parses the request head starting at [from] in one pass: [bodyFrom] when the head is complete, with [bodyTo] where
     * the body ends (possibly past [to]), 0 when more head bytes are needed, -1 when the bytes are not an HTTP/1.x
     * request. Each line is found once (its CR); a header line is first matched against the name predicted at its
     * position ([plan]: the order HTTP clients send them), which gives its colon without a search. A line off the
     * prediction is classified the general way, so any order and any case parse the same.
     */
    fun frameHead(src: ByteArray, from: Int, to: Int): Int {
        val lineEnd = src.indexOf(CR, from, minOf(to, from + MAX_HEAD))
        if (lineEnd < 0 || lineEnd + 1 >= to) return more(from, to)
        if (src[lineEnd + 1] != LF) return -1
        val sp1 = when {
            src[from] == 'G'.code.toByte() && src.startsWith(from, GET_SP) -> from + 3
            src[from] == 'P'.code.toByte() && src.startsWith(from, POST_SP) -> from + 4
            else -> src.indexOf(' '.code.toByte(), from, lineEnd)
        }
        if (sp1 < 0) return -1
        method = when {
            sp1 - from == 3 && src.startsWith(from, GET) -> Method.GET
            sp1 - from == 4 && src.startsWith(from, POST) -> Method.POST
            else -> Method.OTHER
        }
        val sp2 = src.indexOf(' '.code.toByte(), sp1 + 1, lineEnd)
        if (sp2 < 0) return -1
        pathFrom = sp1 + 1
        val q = src.indexOf('?'.code.toByte(), pathFrom, sp2)
        pathTo = if (q < 0) sp2 else q
        authFrom = -1
        authTo = -1
        val http10 = lineEnd - sp2 == 9 && src[sp2 + 8] == '0'.code.toByte() && src[sp2 + 7] == '.'.code.toByte()
        close = http10
        keepAlive = false
        val plan = if (method == Method.POST) POST_PLAN else GET_PLAN
        var k = 0
        var length = 0L
        var line = lineEnd + 2
        while (true) {
            if (line + 1 >= to) return more(from, to)
            if (src[line] == CR) {
                if (src[line + 1] != LF) return -1
                break
            }
            val eol = src.indexOf(CR, line, minOf(to, from + MAX_HEAD))
            if (eol < 0 || eol + 1 >= to) return more(from, to)
            if (src[eol + 1] != LF) return -1
            var colon: Int
            var kind: Int
            if (k < plan.size && src.startsWith(line, plan[k])) {
                colon = line + plan[k].size - 1
                kind = PLAN_KIND[plan[k].size]
                k++
            } else {
                colon = src.indexOf(':'.code.toByte(), line, eol)
                kind = when (colon - line) {
                    14 -> if (src.equalsIgnoreCase(line, CONTENT_LENGTH)) KIND_LENGTH else KIND_SKIP
                    13 -> if (src.equalsIgnoreCase(line, AUTHORIZATION)) KIND_AUTH else KIND_SKIP
                    10 -> if (src.equalsIgnoreCase(line, CONNECTION)) KIND_CONNECTION else KIND_SKIP
                    else -> KIND_SKIP
                }
            }
            if (kind != KIND_SKIP) {
                var v = colon + 1
                while (v < eol && (src[v] == ' '.code.toByte() || src[v] == '\t'.code.toByte())) v++
                var ve = eol
                while (ve > v && (src[ve - 1] == ' '.code.toByte() || src[ve - 1] == '\t'.code.toByte())) ve--
                when (kind) {
                    KIND_LENGTH -> {
                        length = 0
                        for (i in v until ve) {
                            val d = src[i] - '0'.code.toByte()
                            if (d !in 0..9 || length > MAX_BODY) return -1
                            length = length * 10 + d
                        }
                    }
                    KIND_AUTH -> { authFrom = v; authTo = ve }
                    KIND_CONNECTION -> {
                        if (ve - v == 5 && src.equalsIgnoreCase(v, CLOSE)) {
                            close = true
                        } else if (ve - v == 10 && src.equalsIgnoreCase(v, KEEP_ALIVE)) {
                            close = false
                            keepAlive = http10
                        }
                    }
                }
            }
            line = eol + 2
        }
        if (line + 2 - from > MAX_HEAD) return -1
        if (length > MAX_BODY) return -1
        bodyFrom = line + 2
        bodyTo = bodyFrom + length.toInt()
        return bodyFrom
    }

    /** The head is incomplete in src[from, to): 0 to wait for more bytes, or -1 once it can no longer fit [MAX_HEAD]. */
    fun more(from: Int, to: Int): Int = if (to - from > MAX_HEAD) -1 else 0

    /** Becomes [o] as read from bytes that start [base] later: every offset moves down by [base]. */
    fun copyFrom(o: Request, base: Int) {
        method = o.method
        pathFrom = o.pathFrom - base
        pathTo = o.pathTo - base
        authFrom = if (o.authFrom < 0) -1 else o.authFrom - base
        authTo = if (o.authTo < 0) -1 else o.authTo - base
        bodyFrom = o.bodyFrom - base
        bodyTo = o.bodyTo - base
        close = o.close
        keepAlive = o.keepAlive
    }
}

const val MAX_HEAD: Int = 16384
const val MAX_BODY: Long = 1L shl 20

const val CR: Byte = 13
const val LF: Byte = 10

/** A header line's meaning to the parser: skipped, Content-Length, Authorization or Connection. */
const val KIND_SKIP = 0
const val KIND_LENGTH = 1
const val KIND_AUTH = 2
const val KIND_CONNECTION = 3

val GET: ByteArray = "GET".encodeToByteArray()
val POST: ByteArray = "POST".encodeToByteArray()
val GET_SP: ByteArray = "GET ".encodeToByteArray()
val POST_SP: ByteArray = "POST ".encodeToByteArray()
val CONTENT_LENGTH: ByteArray = "content-length".encodeToByteArray()
val AUTHORIZATION: ByteArray = "authorization".encodeToByteArray()
val CONNECTION: ByteArray = "connection".encodeToByteArray()
val CLOSE: ByteArray = "close".encodeToByteArray()
val KEEP_ALIVE: ByteArray = "keep-alive".encodeToByteArray()

/**
 * The header names predicted line by line after the request line, colon included, in the order HTTP clients send
 * them (k6 v2.3.0, bench/load.js: Host, User-Agent; a POST adds Content-Length, Authorization, Content-Type). A
 * name matches with its exact bytes; a line off the plan is classified the general way, and the same prediction
 * waits for the next line.
 */
val GET_PLAN: Array<ByteArray> = arrayOf("Host:".encodeToByteArray(), "User-Agent:".encodeToByteArray())
val POST_PLAN: Array<ByteArray> = arrayOf(
    "Host:".encodeToByteArray(), "User-Agent:".encodeToByteArray(), "Content-Length:".encodeToByteArray(),
    "Authorization:".encodeToByteArray(), "Content-Type:".encodeToByteArray(),
)

/** The kind of a predicted name, indexed by its size: the five names (5, 11, 15, 14 and 13 bytes) differ in size. */
val PLAN_KIND: IntArray = IntArray(16).also { it[15] = KIND_LENGTH; it[14] = KIND_AUTH }

/** Index of the CR of the CRLFCRLF that ends the header block, or -1. */
fun headerEnd(src: ByteArray, from: Int, to: Int): Int {
    var i = from
    while (i + 3 < to) {
        if (src[i + 3] == '\n'.code.toByte()) {
            if (src[i] == '\r'.code.toByte() && src[i + 1] == '\n'.code.toByte() && src[i + 2] == '\r'.code.toByte()) return i
            i++
        } else i += if (src[i + 3] == '\r'.code.toByte()) 1 else 4
    }
    return -1
}

/** ASCII case-insensitive match of [lower] (already lower case) at [at]. */
fun ByteArray.equalsIgnoreCase(at: Int, lower: ByteArray): Boolean {
    if (at + lower.size > size) return false
    for (i in lower.indices) {
        val c = this[at + i].toInt()
        val l = if (c in 'A'.code..'Z'.code) c + 32 else c
        if (l != lower[i].toInt()) return false
    }
    return true
}
