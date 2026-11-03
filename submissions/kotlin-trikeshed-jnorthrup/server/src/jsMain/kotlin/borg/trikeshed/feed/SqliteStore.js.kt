package borg.trikeshed.feed

import org.khronos.webgl.Int8Array

/** A JS string's UTF-8 bytes: Node's Buffer, seen in place as a ByteArray (Kotlin/JS ByteArray is Int8Array). */
fun utf8(s: dynamic): ByteArray {
    val b = js("Buffer").from(s, "utf8")
    return Int8Array(b.buffer, b.byteOffset as Int, b.length as Int).unsafeCast<ByteArray>()
}

fun num(v: dynamic): Long = (v as Double).toLong()

const val POST_COLUMNS: String = "SELECT p.id AS id, p.body AS body, p.created_at AS created_at, u.username AS author, " +
    "(SELECT count(*) FROM likes l WHERE l.post_id = p.id) AS likes FROM posts p JOIN users u ON u.id = p.user_id"

val ROW_ID: ByteArray = "{\"id\":".encodeToByteArray()
val ROW_BODY: ByteArray = ",\"body\":\"".encodeToByteArray()
val ROW_CREATED: ByteArray = "\",\"created_at\":\"".encodeToByteArray()
val ROW_AUTHOR: ByteArray = "\",\"author\":\"".encodeToByteArray()
val ROW_LIKES: ByteArray = "\",\"like_count\":".encodeToByteArray()
val FEED_OPEN: ByteArray = "{\"posts\":[".encodeToByteArray()
val FEED_CLOSE: ByteArray = "]}".encodeToByteArray()
val POST_OPEN: ByteArray = "{\"post\":".encodeToByteArray()

/**
 * One node:sqlite connection (Node's own SQLite, unpatched), the KN store's pragmas and statements, one thread. Rows
 * come back as JS objects; each text goes out through [Out.jsonText] from its UTF-8 bytes, so the bytes match KN's.
 */
class SqliteStore(path: String) : FeedStore {
    val db: dynamic
    val feedStmt: dynamic
    val postStmt: dynamic
    val createStmt: dynamic
    val likeStmt: dynamic
    val existsStmt: dynamic
    val pingStmt: dynamic
    override var pending: Boolean = false

    init {
        val ctor = require("node:sqlite").DatabaseSync
        db = js("Reflect").construct(ctor, arrayOf(path))
        // locking_mode before the first WAL access keeps the wal-index in heap memory (no -shm).
        db.exec("PRAGMA locking_mode=EXCLUSIVE")
        db.exec("PRAGMA journal_mode=WAL")
        db.exec("PRAGMA synchronous=NORMAL")
        db.exec("PRAGMA mmap_size=1073741824")
        db.exec("PRAGMA cache_size=-16384")
        db.exec("PRAGMA temp_store=MEMORY")
        feedStmt = db.prepare("$POST_COLUMNS ORDER BY p.created_at DESC, p.id DESC LIMIT 20")
        postStmt = db.prepare("$POST_COLUMNS WHERE p.id = ?1")
        createStmt = db.prepare("INSERT INTO posts (user_id, body) VALUES (?1, ?2) RETURNING id, created_at")
        likeStmt = db.prepare("INSERT INTO likes (user_id, post_id) SELECT ?1, ?2 WHERE EXISTS " +
            "(SELECT 1 FROM posts WHERE id = ?2) ON CONFLICT (user_id, post_id) DO NOTHING")
        existsStmt = db.prepare("SELECT 1 AS one FROM posts WHERE id = ?1")
        pingStmt = db.prepare("SELECT 1 AS one")
    }

    /** One POST_COLUMNS row as the feed's JSON object. */
    fun row(r: dynamic, out: Out) {
        out.raw(ROW_ID); out.long(num(r.id))
        out.raw(ROW_BODY); out.jsonText(utf8(r.body))
        out.raw(ROW_CREATED); out.jsonText(utf8(r.created_at))
        out.raw(ROW_AUTHOR); out.jsonText(utf8(r.author))
        out.raw(ROW_LIKES); out.long(num(r.likes))
        out.byte('}'.code)
    }

    override fun ping(): String? = try {
        pingStmt.get()
        null
    } catch (failure: Throwable) {
        failure.message ?: "unknown error"
    }

    override fun feed(out: Out) {
        val rows = feedStmt.all()
        val n = rows.length as Int
        out.raw(FEED_OPEN)
        for (i in 0 until n) {
            if (i > 0) out.byte(','.code)
            row(rows[i], out)
        }
        out.raw(FEED_CLOSE)
    }

    override fun post(id: Long, out: Out): Boolean {
        val r = postStmt.get(id.toDouble()) ?: return false
        if (r == undefined) return false
        out.raw(POST_OPEN)
        row(r, out)
        out.byte('}'.code)
        return true
    }

    fun begin() {
        if (pending) return
        db.exec("BEGIN IMMEDIATE")
        pending = true
    }

    override fun commit() {
        if (!pending) return
        pending = false
        try {
            db.exec("COMMIT")
        } catch (failure: Throwable) {
            db.exec("ROLLBACK")
            throw failure
        }
    }

    override fun create(user: Long, author: String, body: String, out: Out) {
        begin()
        val r = createStmt.get(user.toDouble(), body)
        out.raw(POST_OPEN)
        out.raw(ROW_ID); out.long(num(r.id))
        out.raw(ROW_BODY); out.jsonText(utf8(body))
        out.raw(ROW_CREATED); out.jsonText(utf8(r.created_at))
        out.raw(ROW_AUTHOR); out.jsonText(utf8(author))
        out.raw(ROW_LIKES); out.byte('0'.code)
        out.byte('}'.code); out.byte('}'.code)
    }

    override fun like(user: Long, post: Long): Int {
        begin()
        val changes = likeStmt.run(user.toDouble(), post.toDouble()).changes
        if (num(changes) == 1L) return 1
        val r = existsStmt.get(post.toDouble())
        return if (r == null || r == undefined) -1 else 0
    }
}
