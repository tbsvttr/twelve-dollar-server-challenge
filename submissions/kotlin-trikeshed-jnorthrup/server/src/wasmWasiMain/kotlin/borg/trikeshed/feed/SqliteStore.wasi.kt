@file:OptIn(ExperimentalWasmInterop::class)

package borg.trikeshed.feed

import borg.trikeshed.userspace.wasi.Wasi
import kotlin.wasm.ExperimentalWasmInterop
import kotlin.wasm.WasmImport

// The SQLite module (sqlite.wasm: the stock amalgamation plus src/wasmWasiMain/c/sqlbridge.c), preloaded by
// wasmtime as "sqlite". Pointers are i32 addresses in that module's memory, not this one's.
@WasmImport("sqlite", "ts_alloc") external fun tsAlloc(n: Int): Int
@WasmImport("sqlite", "ts_free") external fun tsFree(p: Int)
@WasmImport("sqlite", "ts_load64") external fun tsLoad64(p: Int): Long
@WasmImport("sqlite", "ts_store64") external fun tsStore64(p: Int, v: Long)
@WasmImport("sqlite", "ts_load8") external fun tsLoad8(p: Int): Int
@WasmImport("sqlite", "ts_store8") external fun tsStore8(p: Int, v: Int)
@WasmImport("sqlite", "ts_preopen") external fun tsPreopen(fd: Int, prefix: Int): Int
@WasmImport("sqlite", "sqlite3_open_v2") external fun sqlite3OpenV2(path: Int, db: Int, flags: Int, vfs: Int): Int
@WasmImport("sqlite", "sqlite3_prepare_v2") external fun sqlite3PrepareV2(db: Int, sql: Int, n: Int, stmt: Int, tail: Int): Int
@WasmImport("sqlite", "sqlite3_step") external fun sqlite3Step(stmt: Int): Int
@WasmImport("sqlite", "sqlite3_reset") external fun sqlite3Reset(stmt: Int): Int
@WasmImport("sqlite", "sqlite3_bind_int64") external fun sqlite3BindInt64(stmt: Int, i: Int, v: Long): Int
@WasmImport("sqlite", "sqlite3_bind_text") external fun sqlite3BindText(stmt: Int, i: Int, p: Int, n: Int, destructor: Int): Int
@WasmImport("sqlite", "sqlite3_column_int64") external fun sqlite3ColumnInt64(stmt: Int, i: Int): Long
@WasmImport("sqlite", "sqlite3_column_text") external fun sqlite3ColumnText(stmt: Int, i: Int): Int
@WasmImport("sqlite", "sqlite3_column_bytes") external fun sqlite3ColumnBytes(stmt: Int, i: Int): Int
@WasmImport("sqlite", "sqlite3_changes") external fun sqlite3Changes(db: Int): Int
@WasmImport("sqlite", "sqlite3_errmsg") external fun sqlite3Errmsg(db: Int): Int

const val SQLITE_OK = 0
const val SQLITE_ROW = 100
const val SQLITE_DONE = 101
/** SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE */
const val SQLITE_OPEN = 0x2 or 0x4
/** SQLITE_TRANSIENT, ((sqlite3_destructor_type)-1): SQLite copies the bound text. */
const val SQLITE_TRANSIENT = -1

const val POST_COLUMNS: String = "SELECT p.id, p.body, p.created_at, u.username, " +
    "(SELECT count(*) FROM likes l WHERE l.post_id = p.id) FROM posts p JOIN users u ON u.id = p.user_id"

val ROW_ID: ByteArray = "{\"id\":".encodeToByteArray()
val ROW_BODY: ByteArray = ",\"body\":\"".encodeToByteArray()
val ROW_CREATED: ByteArray = "\",\"created_at\":\"".encodeToByteArray()
val ROW_AUTHOR: ByteArray = "\",\"author\":\"".encodeToByteArray()
val ROW_LIKES: ByteArray = "\",\"like_count\":".encodeToByteArray()
val FEED_OPEN: ByteArray = "{\"posts\":[".encodeToByteArray()
val FEED_CLOSE: ByteArray = "]}".encodeToByteArray()
val POST_OPEN: ByteArray = "{\"post\":".encodeToByteArray()

/** [n] bytes from [src] at [from] into the SQLite module's memory at [p]: eight per call, then one per call. */
fun poke(p: Int, src: ByteArray, from: Int, n: Int) {
    var i = 0
    while (i + 8 <= n) {
        var v = 0L
        var k = 7
        while (k >= 0) { v = (v shl 8) or (src[from + i + k].toLong() and 0xff); k-- }
        tsStore64(p + i, v)
        i += 8
    }
    while (i < n) { tsStore8(p + i, src[from + i].toInt()); i++ }
}

/** [n] bytes of the SQLite module's memory at [p] into [dst] at [to]. */
fun peek(p: Int, dst: ByteArray, to: Int, n: Int) {
    var i = 0
    while (i + 8 <= n) {
        var v = tsLoad64(p + i)
        var k = 0
        while (k < 8) { dst[to + i + k] = v.toByte(); v = v shr 8; k++ }
        i += 8
    }
    while (i < n) { dst[to + i] = tsLoad8(p + i).toByte(); i++ }
}

/**
 * One SQLite connection through the preloaded sqlite.wasm module, with the KN store's pragmas and statements, one
 * thread. Values cross the module boundary through [poke] and [peek]; each text column goes out through the same
 * JSON escape as [Out.jsonText], so the bytes match KN's.
 */
class SqliteStore(path: String) : FeedStore {
    val db: Int
    /** Scratch space in the SQLite module: SQL and bound text in, out-pointers back. */
    var scratch = tsAlloc(4096)
    var scratchSize = 4096
    /** Column bytes copied out of the SQLite module before they are escaped into the response. */
    var column = ByteArray(4096)
    val feedStmt: Int
    val postStmt: Int
    val createStmt: Int
    val likeStmt: Int
    val existsStmt: Int
    val pingStmt: Int
    val beginStmt: Int
    val commitStmt: Int
    val rollbackStmt: Int
    override var pending: Boolean = false

    init {
        for ((fd, dir) in Wasi.preopens) check(tsPreopen(fd, text(dir.encodeToByteArray(), 0)) == 0) { "preopen $dir" }
        val name = path.encodeToByteArray()
        val p = text(name, 8)
        val rc = sqlite3OpenV2(p + 8, p, SQLITE_OPEN, 0)
        db = tsLoad64(p).toInt()
        check(rc == SQLITE_OK) { "open $path failed: $rc ${if (db != 0) error() else "no handle"}" }
        // locking_mode before the first WAL access keeps the wal-index in heap memory (WASI has no shared memory).
        exec("PRAGMA locking_mode=EXCLUSIVE")
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA synchronous=NORMAL")
        exec("PRAGMA cache_size=-16384")
        exec("PRAGMA temp_store=MEMORY")
        feedStmt = prepare("$POST_COLUMNS ORDER BY p.created_at DESC, p.id DESC LIMIT 20")
        postStmt = prepare("$POST_COLUMNS WHERE p.id = ?1")
        createStmt = prepare("INSERT INTO posts (user_id, body) VALUES (?1, ?2) RETURNING id, created_at")
        likeStmt = prepare("INSERT INTO likes (user_id, post_id) SELECT ?1, ?2 WHERE EXISTS " +
            "(SELECT 1 FROM posts WHERE id = ?2) ON CONFLICT (user_id, post_id) DO NOTHING")
        existsStmt = prepare("SELECT 1 FROM posts WHERE id = ?1")
        pingStmt = prepare("SELECT 1")
        beginStmt = prepare("BEGIN IMMEDIATE")
        commitStmt = prepare("COMMIT")
        rollbackStmt = prepare("ROLLBACK")
    }

    /** [bytes] and a NUL in the scratch space at [at], grown when needed: the scratch pointer. */
    fun text(bytes: ByteArray, at: Int): Int {
        val need = at + bytes.size + 1
        if (need > scratchSize) {
            tsFree(scratch)
            scratchSize = maxOf(need, scratchSize * 2)
            scratch = tsAlloc(scratchSize)
        }
        poke(scratch + at, bytes, 0, bytes.size)
        tsStore8(scratch + at + bytes.size, 0)
        return scratch
    }

    fun error(): String {
        val p = sqlite3Errmsg(db)
        var n = 0
        while (tsLoad8(p + n) != 0) n++
        val b = ByteArray(n)
        peek(p, b, 0, n)
        return b.decodeToString()
    }

    fun prepare(sql: String): Int {
        val bytes = sql.encodeToByteArray()
        val p = text(bytes, 8)
        check(sqlite3PrepareV2(db, p + 8, bytes.size, p, 0) == SQLITE_OK) { "prepare: ${error()}" }
        return tsLoad64(p).toInt()
    }

    fun exec(sql: String) {
        val s = prepare(sql)
        var rc = sqlite3Step(s)
        while (rc == SQLITE_ROW) rc = sqlite3Step(s)
        sqlite3Reset(s)
        check(rc == SQLITE_DONE) { "$sql: ${error()}" }
    }

    /** One step that must finish the statement; the statement is reset either way. */
    fun done(s: Int) {
        var rc = sqlite3Step(s)
        while (rc == SQLITE_ROW) rc = sqlite3Step(s)
        sqlite3Reset(s)
        check(rc == SQLITE_DONE) { error() }
    }

    /** Column [i] of the current row as a JSON string body. */
    fun textColumn(s: Int, i: Int, out: Out) {
        val p = sqlite3ColumnText(s, i)
        val n = sqlite3ColumnBytes(s, i)
        if (n > column.size) column = ByteArray(maxOf(n, column.size * 2))
        if (n > 0) peek(p, column, 0, n)
        val at = out.size
        out.raw(column, 0, n)
        out.escapeFrom(at)
    }

    /** The current POST_COLUMNS row as the feed's JSON object. */
    fun row(s: Int, out: Out) {
        out.raw(ROW_ID); out.long(sqlite3ColumnInt64(s, 0))
        out.raw(ROW_BODY); textColumn(s, 1, out)
        out.raw(ROW_CREATED); textColumn(s, 2, out)
        out.raw(ROW_AUTHOR); textColumn(s, 3, out)
        out.raw(ROW_LIKES); out.long(sqlite3ColumnInt64(s, 4))
        out.byte('}'.code)
    }

    override fun ping(): String? {
        val rc = sqlite3Step(pingStmt)
        sqlite3Reset(pingStmt)
        return if (rc == SQLITE_ROW) null else error()
    }

    override fun feed(out: Out) {
        out.raw(FEED_OPEN)
        var first = true
        var rc = sqlite3Step(feedStmt)
        while (rc == SQLITE_ROW) {
            if (!first) out.byte(','.code)
            first = false
            row(feedStmt, out)
            rc = sqlite3Step(feedStmt)
        }
        sqlite3Reset(feedStmt)
        check(rc == SQLITE_DONE) { error() }
        out.raw(FEED_CLOSE)
    }

    override fun post(id: Long, out: Out): Boolean {
        sqlite3BindInt64(postStmt, 1, id)
        val rc = sqlite3Step(postStmt)
        if (rc != SQLITE_ROW) {
            sqlite3Reset(postStmt)
            check(rc == SQLITE_DONE) { error() }
            return false
        }
        out.raw(POST_OPEN)
        row(postStmt, out)
        out.byte('}'.code)
        sqlite3Reset(postStmt)
        return true
    }

    fun begin() {
        if (pending) return
        done(beginStmt)
        pending = true
    }

    override fun commit() {
        if (!pending) return
        pending = false
        try {
            done(commitStmt)
        } catch (failure: Throwable) {
            done(rollbackStmt)
            throw failure
        }
    }

    override fun create(user: Long, author: String, body: String, out: Out) {
        begin()
        val bytes = body.encodeToByteArray()
        val p = text(bytes, 0)
        sqlite3BindInt64(createStmt, 1, user)
        check(sqlite3BindText(createStmt, 2, p, bytes.size, SQLITE_TRANSIENT) == SQLITE_OK) { error() }
        check(sqlite3Step(createStmt) == SQLITE_ROW) { sqlite3Reset(createStmt); error() }
        out.raw(POST_OPEN)
        out.raw(ROW_ID); out.long(sqlite3ColumnInt64(createStmt, 0))
        out.raw(ROW_BODY); out.jsonText(bytes)
        out.raw(ROW_CREATED); textColumn(createStmt, 1, out)
        out.raw(ROW_AUTHOR); out.jsonText(author.encodeToByteArray())
        out.raw(ROW_LIKES); out.byte('0'.code)
        out.byte('}'.code); out.byte('}'.code)
        done(createStmt)
    }

    override fun like(user: Long, post: Long): Int {
        begin()
        sqlite3BindInt64(likeStmt, 1, user)
        sqlite3BindInt64(likeStmt, 2, post)
        done(likeStmt)
        if (sqlite3Changes(db) == 1) return 1
        sqlite3BindInt64(existsStmt, 1, post)
        val rc = sqlite3Step(existsStmt)
        sqlite3Reset(existsStmt)
        return if (rc == SQLITE_ROW) 0 else -1
    }
}
