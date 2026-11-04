package borg.trikeshed.feed

import borg.trikeshed.parse.confix.KnownSchema
import borg.trikeshed.parse.confix.KnownShape

/**
 * The SQLite side of the API. Writes join the store's open transaction (group commit): the reactor commits
 * once per pass and only then sends the responses of that pass.
 */
interface FeedStore {
    /** null when `SELECT 1` succeeds, else the error message. */
    fun ping(): String?

    /** `{"posts":[...]}` of the 20 newest posts. */
    fun feed(out: Out)

    /** `{"post":{...}}` of post [id]; false when it does not exist. */
    fun post(id: Long, out: Out): Boolean

    /** Inserts the post and writes `{"post":{...}}` with like_count 0. */
    fun create(user: Long, author: String, body: String, out: Out)

    /** 1 when the like is new, 0 when it existed, -1 when the post does not exist. */
    fun like(user: Long, post: Long): Int

    /** Whether a write transaction is open; [commit] ends it. */
    val pending: Boolean
    fun commit()

    /** The end of a wake: read state held for the wake's reads (a read transaction) is let go. */
    fun rest() {}

    /** Whether the next write batch may begin now; false holds it (reads go on) while the store's WAL gate is shut. */
    fun ready(): Boolean = true
}

/** Status line + fixed headers, up to the Content-Length value. */
fun head(status: String): ByteArray =
    "HTTP/1.1 $status\r\nContent-Type: application/json\r\nContent-Length: ".encodeToByteArray()

val S200: ByteArray = head("200 OK")
val S201: ByteArray = head("201 Created")
val S400: ByteArray = head("400 Bad Request")
val S401: ByteArray = head("401 Unauthorized")
val S404: ByteArray = head("404 Not Found")
val S500: ByteArray = head("500 Internal Server Error")
val S503: ByteArray = head("503 Service Unavailable")
val CRLF2: ByteArray = "\r\n\r\n".encodeToByteArray()
val CLOSE_HEAD: ByteArray = "\r\nConnection: close\r\n\r\n".encodeToByteArray()
val KEEP_HEAD: ByteArray = "\r\nConnection: keep-alive\r\n\r\n".encodeToByteArray()

fun errorBody(message: String): ByteArray = "{\"error\":\"$message\"}".encodeToByteArray()

val NOT_FOUND: ByteArray = errorBody("not found")
val INVALID_ID: ByteArray = errorBody("invalid post id")
val POST_NOT_FOUND: ByteArray = errorBody("post not found")
val MISSING_BEARER: ByteArray = errorBody("missing bearer token")
val INVALID_TOKEN: ByteArray = errorBody("invalid or expired token")
val INVALID_PAYLOAD: ByteArray = errorBody("invalid token payload")
val MALFORMED: ByteArray = errorBody("malformed JSON body")
val BODY_REQUIRED: ByteArray = errorBody("body is required")
val BODY_TOO_LONG: ByteArray = errorBody("body must be at most 500 characters")
val INTERNAL: ByteArray = errorBody("internal server error")

val HEALTH_OK: ByteArray = "{\"status\":\"ok\",\"db\":\"ok\",\"uptime_s\":".encodeToByteArray()
val HEALTH_DOWN: ByteArray = "{\"status\":\"degraded\",\"db\":\"unreachable\",\"error\":\"".encodeToByteArray()
val LIKED: ByteArray = "{\"liked\":true,\"already_liked\":false,\"post_id\":".encodeToByteArray()
val RELIKED: ByteArray = "{\"liked\":true,\"already_liked\":true,\"post_id\":".encodeToByteArray()

val PATH_HEALTH: ByteArray = "/health".encodeToByteArray()
val PATH_FEED: ByteArray = "/feed".encodeToByteArray()
val PATH_POSTS: ByteArray = "/posts".encodeToByteArray()
val PATH_LIKE: ByteArray = "/like".encodeToByteArray()
val BODY_KEYS: Array<String> = arrayOf("body")

/** The POST /posts body's one member, as a known-schema plan. */
val BODY_SCHEMA: KnownSchema = KnownSchema(*BODY_KEYS)

/** [WriteQueue.kind]: POST /posts/:id/like. */
const val LIKE = 1

/** [WriteQueue.kind]: POST /posts. */
const val CREATE = 2

/** [Feed.route]'s answer for a write it queued: no response yet; [Feed.answer] writes it after the batch runs. */
val QUEUED: ByteArray = ByteArray(0)

/**
 * Write requests that passed every check (bearer verified, id or body valid) and are not executed yet, in arrival
 * order, with the connection each response goes to. The batch runs them in one transaction, then COMMIT, then the
 * responses go out: no read ever runs while a write is uncommitted, so no read waits for the batch.
 */
class WriteQueue {
    var count = 0
    var kind = IntArray(256)
    var user = LongArray(256)
    var post = LongArray(256)
    var author = arrayOfNulls<String>(256)
    var text = arrayOfNulls<String>(256)
    var close = BooleanArray(256)
    var keepAlive = BooleanArray(256)
    var conns = arrayOfNulls<Conn>(256)

    fun add(k: Int, u: Long, p: Long, a: String?, t: String?) {
        if (count == kind.size) {
            val n = count * 2
            kind = kind.copyOf(n); user = user.copyOf(n); post = post.copyOf(n)
            author = author.copyOf(n); text = text.copyOf(n)
            close = close.copyOf(n); keepAlive = keepAlive.copyOf(n); conns = conns.copyOf(n)
        }
        kind[count] = k
        user[count] = u
        post[count] = p
        author[count] = a
        text[count] = t
        count++
    }

    /** Entry [i] is answered: its references go, so the strings and the connection are not kept alive by the queue. */
    fun clear(i: Int) {
        author[i] = null
        text[i] = null
        conns[i] = null
    }
}

/** Routes one framed request and appends its whole HTTP response to [send]. */
class Feed(val store: FeedStore, val bearer: Bearer, val startedSeconds: Long) {
    val body = Out()
    val bodyReader = BODY_SCHEMA.reader()

    /** Where valid writes wait for the batch; null runs each write at once in the store's open transaction. */
    var queue: WriteQueue? = null

    fun respond(src: ByteArray, r: Request, send: Out) {
        body.size = 0
        val status = try {
            route(src, r)
        } catch (failure: Throwable) {
            body.size = 0
            body.raw(INTERNAL)
            S500
        }
        if (status === QUEUED) {
            val q = queue!!
            q.close[q.count - 1] = r.close
            q.keepAlive[q.count - 1] = r.keepAlive
            return
        }
        frame(status, r.close, r.keepAlive, send)
    }

    /** Status line, headers and [body] into [send]. */
    fun frame(status: ByteArray, close: Boolean, keepAlive: Boolean, send: Out) {
        send.raw(status)
        send.long(body.size.toLong())
        send.raw(if (close) CLOSE_HEAD else if (keepAlive) KEEP_HEAD else CRLF2)
        send.raw(body.bytes, 0, body.size)
    }

    /** Runs queued write [i] in the store's open transaction and writes its whole response into [send]. */
    fun answer(q: WriteQueue, i: Int, send: Out) {
        body.size = 0
        val status = try {
            if (q.kind[i] == LIKE) liked(q.user[i], q.post[i]) else {
                store.create(q.user[i], q.author[i]!!, q.text[i]!!, body)
                S201
            }
        } catch (failure: Throwable) {
            body.size = 0
            body.raw(INTERNAL)
            S500
        }
        frame(status, q.close[i], q.keepAlive[i], send)
    }

    fun route(src: ByteArray, r: Request): ByteArray {
        val p = r.pathFrom
        val n = r.pathTo - p
        if (r.method == Method.GET) {
            if (n == 5 && src.startsWith(p, PATH_FEED)) { store.feed(body); return S200 }
            if (n == 7 && src.startsWith(p, PATH_HEALTH)) return health()
            if (n > 7 && src.startsWith(p, PATH_POSTS) && src[p + 6] == '/'.code.toByte()) {
                val id = pathId(src, p + 7, r.pathTo)
                if (id == 0L) return body(INVALID_ID, S400)
                return if (store.post(id, body)) S200 else body(POST_NOT_FOUND, S404)
            }
            return body(NOT_FOUND, S404)
        }
        if (r.method == Method.POST) {
            if (n == 6 && src.startsWith(p, PATH_POSTS)) return create(src, r)
            if (n > 12 && src.startsWith(p, PATH_POSTS) && src[p + 6] == '/'.code.toByte() &&
                src.startsWith(r.pathTo - 5, PATH_LIKE)) return like(src, r, p + 7, r.pathTo - 5)
        }
        return body(NOT_FOUND, S404)
    }

    fun body(bytes: ByteArray, status: ByteArray): ByteArray {
        body.raw(bytes)
        return status
    }

    fun health(): ByteArray {
        val failure = store.ping()
        if (failure == null) {
            body.raw(HEALTH_OK)
            body.long(epochSeconds() - startedSeconds)
            body.byte('}'.code)
            return S200
        }
        body.raw(HEALTH_DOWN)
        body.jsonText(failure.encodeToByteArray())
        body.raw("\"}".encodeToByteArray())
        return S503
    }

    /** null when the bearer is valid, else the 401 status with its body written. */
    fun authorize(src: ByteArray, r: Request): ByteArray? = when (bearer.verify(src, r.authFrom, r.authTo, epochSeconds())) {
        BearerState.VALID -> null
        BearerState.MISSING -> body(MISSING_BEARER, S401)
        BearerState.INVALID -> body(INVALID_TOKEN, S401)
        BearerState.PAYLOAD -> body(INVALID_PAYLOAD, S401)
    }

    fun create(src: ByteArray, r: Request): ByteArray {
        authorize(src, r)?.let { return it }
        if (bodyReader.scan(src, r.bodyFrom, r.bodyTo) == KnownShape.MALFORMED) return body(MALFORMED, S400)
        val text = bodyReader.text(0)?.ecmaTrim()
        if (text.isNullOrEmpty()) return body(BODY_REQUIRED, S400)
        if (text.codePointLength() > 500) return body(BODY_TOO_LONG, S400)
        val q = queue
        if (q != null) {
            q.add(CREATE, bearer.user, 0, bearer.name, text)
            return QUEUED
        }
        store.create(bearer.user, bearer.name, text, body)
        return S201
    }

    fun like(src: ByteArray, r: Request, from: Int, to: Int): ByteArray {
        authorize(src, r)?.let { return it }
        val id = pathId(src, from, to)
        if (id == 0L) return body(INVALID_ID, S400)
        val q = queue
        if (q != null) {
            q.add(LIKE, bearer.user, id, null, null)
            return QUEUED
        }
        return liked(bearer.user, id)
    }

    /** The like runs in the store's open transaction; its status, with the body written. */
    fun liked(user: Long, id: Long): ByteArray {
        return when (store.like(user, id)) {
            1 -> { body.raw(LIKED); body.long(id); body.byte('}'.code); S201 }
            0 -> { body.raw(RELIKED); body.long(id); body.byte('}'.code); S200 }
            else -> body(POST_NOT_FOUND, S404)
        }
    }
}

/**
 * The `:id` path segment: a positive decimal integer, or 0 when it is anything else. Values past
 * SQLite's INTEGER range are positive integers that name no post: they map to Long.MAX_VALUE.
 */
fun pathId(src: ByteArray, from: Int, to: Int): Long {
    if (from >= to) return 0
    var v = 0L
    for (i in from until to) {
        val d = src[i] - '0'.code.toByte()
        if (d !in 0..9) return 0
        v = if (v > (Long.MAX_VALUE - d) / 10) Long.MAX_VALUE else v * 10 + d
    }
    return v
}
