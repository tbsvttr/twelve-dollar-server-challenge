package borg.trikeshed.feed

import cnames.structs.sqlite3
import cnames.structs.sqlite3_stmt
import feedc.*
import kotlinx.cinterop.*

const val SQLITE_ROW: Int = 100
const val SQLITE_DONE: Int = 101

/** The longest column text one row may hold: room for six escaped bytes per byte stays inside an Int. */
const val TEXT_MAX: Int = 1 shl 24

/** The room a feed row is offered before the call: a usual row fits, a row with a long body asks again for exactly what it needs. */
const val ROW_ROOM: Int = 4096

/** The room a B-tree plan is offered first: a usual feed fits; a larger one asks once for its exact size. */
const val PLAN_ROOM: Int = 32768

const val POST_SELECT: String = "SELECT p.id, p.body, p.created_at, u.username, " +
    "(SELECT count(*) FROM likes l WHERE l.post_id = p.id) FROM posts p JOIN users u ON u.id = p.user_id"

val ROW_ID: ByteArray = "{\"id\":".encodeToByteArray()
val ROW_BODY: ByteArray = ",\"body\":\"".encodeToByteArray()
val ROW_CREATED: ByteArray = "\",\"created_at\":\"".encodeToByteArray()
val ROW_AUTHOR: ByteArray = "\",\"author\":\"".encodeToByteArray()
val ROW_LIKES: ByteArray = "\",\"like_count\":".encodeToByteArray()
val FEED_OPEN: ByteArray = "{\"posts\":[".encodeToByteArray()
val FEED_CLOSE: ByteArray = "]}".encodeToByteArray()
val POST_OPEN: ByteArray = "{\"post\":".encodeToByteArray()

/** One connection through cinterop, the JVM SqliteStore's pragmas and statements, one thread. */
@OptIn(ExperimentalForeignApi::class)
class SqliteStore(path: String) : FeedStore {
    val db: CPointer<sqlite3>
    val feedStmt: CPointer<sqlite3_stmt>
    val postStmt: CPointer<sqlite3_stmt>
    val createStmt: CPointer<sqlite3_stmt>
    val likeStmt: CPointer<sqlite3_stmt>
    val existsStmt: CPointer<sqlite3_stmt>
    val pingStmt: CPointer<sqlite3_stmt>
    val beginStmt: CPointer<sqlite3_stmt>
    val commitStmt: CPointer<sqlite3_stmt>
    val rollbackStmt: CPointer<sqlite3_stmt>
    override var pending: Boolean = false

    /** The B-tree read plans (feedbt.c) found the schema they read; false sends every read to SQL. */
    val plans: Boolean

    init {
        db = memScoped {
            val pp = alloc<CPointerVar<sqlite3>>()
            val rc = sqlite3_open_v2(path, pp.ptr, SQLITE_OPEN_READWRITE or SQLITE_OPEN_NOMUTEX, null)
            val d = pp.value ?: error("sqlite3_open_v2($path): rc $rc")
            check(rc == 0) { "sqlite3_open_v2($path): ${sqlite3_errmsg(d)?.toKString()}" }
            d
        }
        // locking_mode before the first WAL access keeps the wal-index in heap memory (no -shm).
        exec("PRAGMA locking_mode=EXCLUSIVE")
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")
        exec("PRAGMA mmap_size=1073741824")
        exec("PRAGMA cache_size=-16384")
        exec("PRAGMA temp_store=MEMORY")
        feedStmt = prepare("$POST_SELECT ORDER BY p.created_at DESC, p.id DESC LIMIT 20")
        postStmt = prepare("$POST_SELECT WHERE p.id = ?1")
        createStmt = prepare("INSERT INTO posts (user_id, body) VALUES (?1, ?2) RETURNING id, created_at")
        likeStmt = prepare("INSERT INTO likes (user_id, post_id) SELECT ?1, ?2 WHERE EXISTS " +
            "(SELECT 1 FROM posts WHERE id = ?2) ON CONFLICT (user_id, post_id) DO NOTHING")
        existsStmt = prepare("SELECT 1 FROM posts WHERE id = ?1")
        pingStmt = prepare("SELECT 1")
        beginStmt = prepare("BEGIN IMMEDIATE")
        commitStmt = prepare("COMMIT")
        rollbackStmt = prepare("ROLLBACK")
        plans = feedbt_init(db) == 1
    }

    fun message(): String = sqlite3_errmsg(db)?.toKString() ?: "unknown error"

    fun exec(sql: String) {
        val rc = sqlite3_exec(db, sql, null, null, null)
        check(rc == 0) { "$sql: ${message()}" }
    }

    fun prepare(sql: String): CPointer<sqlite3_stmt> = memScoped {
        val pp = alloc<CPointerVar<sqlite3_stmt>>()
        val rc = sqlite3_prepare_v3(db, sql, -1, SQLITE_PREPARE_PERSISTENT.convert(), pp.ptr, null)
        check(rc == 0) { "$sql: ${message()}" }
        pp.value!!
    }

    /** Every SQL statement steps here: the wake's held read transaction (feedbt.c) ends first. */
    fun step(stmt: CPointer<sqlite3_stmt>): Int {
        if (plans) feedbt_release()
        return sqlite3_step(stmt)
    }

    override fun rest() { if (plans) feedbt_release() }

    fun reset(stmt: CPointer<sqlite3_stmt>) { sqlite3_reset(stmt) }

    fun bind(stmt: CPointer<sqlite3_stmt>, index: Int, value: Long) { sqlite3_bind_int64(stmt, index, value) }

    fun bind(stmt: CPointer<sqlite3_stmt>, index: Int, text: ByteArray) {
        if (text.isEmpty()) feed_bind_text(stmt, index, "", 0) else feed_bind_text(stmt, index, text.refTo(0), text.size)
    }

    fun long(stmt: CPointer<sqlite3_stmt>, col: Int): Long = sqlite3_column_int64(stmt, col)

    /** Column text copied into [out] as a JSON string body, in one C pass (feed_json_text in feedc.def). */
    fun text(stmt: CPointer<sqlite3_stmt>, col: Int, out: Out) {
        val p = sqlite3_column_text(stmt, col)
        val n = sqlite3_column_bytes(stmt, col)
        if (p == null || n == 0) return
        check(n <= TEXT_MAX) { "column text of $n bytes" }
        out.room(n * 6)
        out.size += feed_json_text(p, n, out.bytes.refTo(out.size))
    }

    /** One POST_SELECT row as the feed's JSON object, written by feed_row_json in one crossing; a short buffer asks again with the room it needs. */
    fun row(stmt: CPointer<sqlite3_stmt>, out: Out) {
        out.room(ROW_ROOM)
        var n = feed_row_json(stmt, out.bytes.refTo(out.size), out.bytes.size - out.size)
        if (n < 0) {
            out.room(-n)
            n = feed_row_json(stmt, out.bytes.refTo(out.size), out.bytes.size - out.size)
        }
        out.size += n
    }

    fun failure(stmt: CPointer<sqlite3_stmt>): Nothing {
        val m = message()
        reset(stmt)
        error(m)
    }

    override fun ping(): String? {
        val rc = step(pingStmt)
        if (rc == SQLITE_ROW) { reset(pingStmt); return null }
        val m = message()
        reset(pingStmt)
        return m
    }

    override fun feed(out: Out) {
        if (plans) {
            out.room(PLAN_ROOM)
            var n = feedbt_feed(out.bytes.refTo(out.size), out.bytes.size - out.size)
            if (n < -1) {
                out.room(-n)
                n = feedbt_feed(out.bytes.refTo(out.size), out.bytes.size - out.size)
            }
            if (n >= 0) { out.size += n; return }
        }
        out.raw(FEED_OPEN)
        var rc = step(feedStmt)
        var first = true
        while (rc == SQLITE_ROW) {
            if (!first) out.byte(','.code)
            first = false
            row(feedStmt, out)
            rc = step(feedStmt)
        }
        if (rc != SQLITE_DONE) failure(feedStmt)
        reset(feedStmt)
        out.raw(FEED_CLOSE)
    }

    override fun post(id: Long, out: Out): Boolean {
        if (plans) {
            out.room(PLAN_ROOM)
            var n = feedbt_post(id, out.bytes.refTo(out.size), out.bytes.size - out.size)
            if (n < -1) {
                out.room(-n)
                n = feedbt_post(id, out.bytes.refTo(out.size), out.bytes.size - out.size)
            }
            if (n == 0) return false
            if (n > 0) { out.size += n; return true }
        }
        bind(postStmt, 1, id)
        val rc = step(postStmt)
        if (rc == SQLITE_DONE) { reset(postStmt); return false }
        if (rc != SQLITE_ROW) failure(postStmt)
        out.raw(POST_OPEN)
        row(postStmt, out)
        out.byte('}'.code)
        reset(postStmt)
        return true
    }

    fun begin() {
        if (pending) return
        if (step(beginStmt) != SQLITE_DONE) failure(beginStmt)
        reset(beginStmt)
        pending = true
    }

    override fun commit() {
        if (!pending) return
        pending = false
        val rc = step(commitStmt)
        reset(commitStmt)
        if (rc != SQLITE_DONE) {
            step(rollbackStmt)
            reset(rollbackStmt)
            error("COMMIT: ${message()}")
        }
    }

    override fun create(user: Long, author: String, body: String, out: Out) {
        begin()
        val bodyBytes = body.encodeToByteArray()
        bind(createStmt, 1, user)
        bind(createStmt, 2, bodyBytes)
        if (step(createStmt) != SQLITE_ROW) failure(createStmt)
        out.raw(POST_OPEN)
        out.raw(ROW_ID); out.long(long(createStmt, 0))
        out.raw(ROW_BODY); out.jsonText(bodyBytes)
        out.raw(ROW_CREATED); text(createStmt, 1, out)
        out.raw(ROW_AUTHOR); out.jsonText(author.encodeToByteArray())
        out.raw(ROW_LIKES); out.byte('0'.code)
        out.byte('}'.code); out.byte('}'.code)
        reset(createStmt)
    }

    override fun like(user: Long, post: Long): Int {
        begin()
        bind(likeStmt, 1, user)
        bind(likeStmt, 2, post)
        if (step(likeStmt) != SQLITE_DONE) failure(likeStmt)
        reset(likeStmt)
        if (sqlite3_changes(db) == 1) return 1
        bind(existsStmt, 1, post)
        val rc = step(existsStmt)
        reset(existsStmt)
        return if (rc == SQLITE_ROW) 0 else -1
    }
}
