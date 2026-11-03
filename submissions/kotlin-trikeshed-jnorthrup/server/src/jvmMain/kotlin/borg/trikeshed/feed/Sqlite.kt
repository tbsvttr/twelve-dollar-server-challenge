package borg.trikeshed.feed

import java.lang.foreign.*
import java.lang.foreign.ValueLayout.*
import java.lang.invoke.MethodHandle

/**
 * The FFM downcall handles, one per C signature, made without a function address: the address is the first argument of
 * each call ([Sqlite3] finds it at run time). They are static final fields, so a native image makes them at image build
 * time (--initialize-at-build-time=borg.trikeshed.feed.SqliteCalls) and compiles each call to a direct call: a handle made
 * at run time takes the image's generic path, 3.5 to 5.3 us per call. The JIT folds both shapes alike. Critical: no
 * thread-state transition, heap segments passed in place.
 */
object SqliteCalls {
    @JvmField val linker: Linker = Linker.nativeLinker()
    @JvmField val critical: Linker.Option = Linker.Option.critical(true)

    /** int f(void*) */
    @JvmField val iA: MethodHandle = linker.downcallHandle(FunctionDescriptor.of(JAVA_INT, ADDRESS), critical)
    /** void* f(void*) */
    @JvmField val aA: MethodHandle = linker.downcallHandle(FunctionDescriptor.of(ADDRESS, ADDRESS), critical)
    /** int f(void*, int, long) */
    @JvmField val iAIJ: MethodHandle = linker.downcallHandle(FunctionDescriptor.of(JAVA_INT, ADDRESS, JAVA_INT, JAVA_LONG), critical)
    /** long f(void*, int) */
    @JvmField val jAI: MethodHandle = linker.downcallHandle(FunctionDescriptor.of(JAVA_LONG, ADDRESS, JAVA_INT), critical)
    /** int f(void*, int) */
    @JvmField val iAI: MethodHandle = linker.downcallHandle(FunctionDescriptor.of(JAVA_INT, ADDRESS, JAVA_INT), critical)
    /** void* f(void*, int) */
    @JvmField val aAI: MethodHandle = linker.downcallHandle(FunctionDescriptor.of(ADDRESS, ADDRESS, JAVA_INT), critical)
    /** int f(void*, int, void*, int, void*) */
    @JvmField val iAIAIA: MethodHandle =
        linker.downcallHandle(FunctionDescriptor.of(JAVA_INT, ADDRESS, JAVA_INT, ADDRESS, JAVA_INT, ADDRESS), critical)
    /** int f(void*, void*, int, void*): sqlite3_open_v2 */
    @JvmField val iAAIA: MethodHandle =
        linker.downcallHandle(FunctionDescriptor.of(JAVA_INT, ADDRESS, ADDRESS, JAVA_INT, ADDRESS), critical)
    /** int f(void*, void*, void*, void*, void*): sqlite3_exec */
    @JvmField val iAAAAA: MethodHandle =
        linker.downcallHandle(FunctionDescriptor.of(JAVA_INT, ADDRESS, ADDRESS, ADDRESS, ADDRESS, ADDRESS), critical)
    /** int f(void*, void*, int, int, void*, void*): sqlite3_prepare_v3 */
    @JvmField val iAAIIAA: MethodHandle =
        linker.downcallHandle(FunctionDescriptor.of(JAVA_INT, ADDRESS, ADDRESS, JAVA_INT, JAVA_INT, ADDRESS, ADDRESS), critical)
}

/** libsqlite3's entry points: their addresses, found at run time in the library -Dsqlite.lib names. */
object Sqlite3 {
    val lookup: SymbolLookup = SymbolLookup.libraryLookup(System.getProperty("sqlite.lib", "libsqlite3.so.0"), Arena.global())

    fun find(name: String): MemorySegment = lookup.find(name).orElseThrow { UnsatisfiedLinkError(name) }

    @JvmField val openV2: MemorySegment = find("sqlite3_open_v2")
    @JvmField val exec: MemorySegment = find("sqlite3_exec")
    @JvmField val prepareV3: MemorySegment = find("sqlite3_prepare_v3")
    @JvmField val step: MemorySegment = find("sqlite3_step")
    @JvmField val reset: MemorySegment = find("sqlite3_reset")
    @JvmField val bindInt64: MemorySegment = find("sqlite3_bind_int64")
    @JvmField val bindText: MemorySegment = find("sqlite3_bind_text")
    @JvmField val columnInt64: MemorySegment = find("sqlite3_column_int64")
    @JvmField val columnText: MemorySegment = find("sqlite3_column_text")
    @JvmField val columnBytes: MemorySegment = find("sqlite3_column_bytes")
    @JvmField val changes: MemorySegment = find("sqlite3_changes")
    @JvmField val errmsg: MemorySegment = find("sqlite3_errmsg")
    @JvmField val finalize: MemorySegment = find("sqlite3_finalize")
    @JvmField val closeV2: MemorySegment = find("sqlite3_close_v2")
}

const val SQLITE_ROW: Int = 100
const val SQLITE_DONE: Int = 101
const val SQLITE_OPEN_READWRITE: Int = 0x2
const val SQLITE_OPEN_NOMUTEX: Int = 0x8000
const val SQLITE_PREPARE_PERSISTENT: Int = 0x1

/** SQLITE_TRANSIENT: SQLite copies bound text during the call, so a heap segment may be bound. */
val TRANSIENT: MemorySegment = MemorySegment.ofAddress(-1L)

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

/**
 * One connection, prepared statements reused for the process lifetime, one thread. The server never closes it (the
 * process exit does); [close] is for owners that end sooner, such as tests.
 */
class SqliteStore(path: String) : FeedStore, AutoCloseable {
    val db: MemorySegment
    val feedStmt: MemorySegment
    val postStmt: MemorySegment
    val createStmt: MemorySegment
    val likeStmt: MemorySegment
    val existsStmt: MemorySegment
    val pingStmt: MemorySegment
    val beginStmt: MemorySegment
    val commitStmt: MemorySegment
    val rollbackStmt: MemorySegment
    override var pending: Boolean = false

    init {
        Arena.ofConfined().use { a ->
            val pp = a.allocate(ADDRESS)
            val rc = SqliteCalls.iAAIA.invokeExact(Sqlite3.openV2, a.allocateFrom(path), pp, SQLITE_OPEN_READWRITE or SQLITE_OPEN_NOMUTEX,
                MemorySegment.NULL) as Int
            db = pp.get(ADDRESS, 0)
            check(rc == 0) { "sqlite3_open_v2($path): ${message()}" }
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
    }

    fun message(): String = (SqliteCalls.aA.invokeExact(Sqlite3.errmsg, db) as MemorySegment).reinterpret(4096).getString(0)

    var open = true

    /** Rolls back an open transaction, finalizes the statements and closes the connection; idempotent. */
    override fun close() {
        if (!open) return
        open = false
        if (pending) {
            step(rollbackStmt)
            reset(rollbackStmt)
            pending = false
        }
        for (stmt in arrayOf(feedStmt, postStmt, createStmt, likeStmt, existsStmt, pingStmt, beginStmt, commitStmt, rollbackStmt)) {
            val rc = SqliteCalls.iA.invokeExact(Sqlite3.finalize, stmt) as Int
        }
        val rc = SqliteCalls.iA.invokeExact(Sqlite3.closeV2, db) as Int
        check(rc == 0) { "sqlite3_close_v2: rc $rc" }
    }

    fun exec(sql: String) = Arena.ofConfined().use { a ->
        val rc = SqliteCalls.iAAAAA.invokeExact(Sqlite3.exec, db, a.allocateFrom(sql), MemorySegment.NULL, MemorySegment.NULL, MemorySegment.NULL) as Int
        check(rc == 0) { "$sql: ${message()}" }
    }

    fun prepare(sql: String): MemorySegment = Arena.ofConfined().use { a ->
        val pp = a.allocate(ADDRESS)
        val rc = SqliteCalls.iAAIIAA.invokeExact(Sqlite3.prepareV3, db, a.allocateFrom(sql), -1, SQLITE_PREPARE_PERSISTENT, pp, MemorySegment.NULL) as Int
        check(rc == 0) { "$sql: ${message()}" }
        pp.get(ADDRESS, 0)
    }

    fun step(stmt: MemorySegment): Int = SqliteCalls.iA.invokeExact(Sqlite3.step, stmt) as Int

    fun reset(stmt: MemorySegment) {
        val rc = SqliteCalls.iA.invokeExact(Sqlite3.reset, stmt) as Int
    }

    fun bind(stmt: MemorySegment, index: Int, value: Long) {
        val rc = SqliteCalls.iAIJ.invokeExact(Sqlite3.bindInt64, stmt, index, value) as Int
    }

    fun bind(stmt: MemorySegment, index: Int, text: ByteArray) {
        val rc = SqliteCalls.iAIAIA.invokeExact(Sqlite3.bindText, stmt, index, MemorySegment.ofArray(text), text.size, TRANSIENT) as Int
    }

    fun long(stmt: MemorySegment, col: Int): Long = SqliteCalls.jAI.invokeExact(Sqlite3.columnInt64, stmt, col) as Long

    /** Column text copied into [out] and escaped as a JSON string body. */
    fun text(stmt: MemorySegment, col: Int, out: Out) {
        val p = SqliteCalls.aAI.invokeExact(Sqlite3.columnText, stmt, col) as MemorySegment
        val n = SqliteCalls.iAI.invokeExact(Sqlite3.columnBytes, stmt, col) as Int
        out.room(n)
        MemorySegment.copy(p.reinterpret(n.toLong()), JAVA_BYTE, 0L, out.bytes, out.size, n)
        val at = out.size
        out.size += n
        out.escapeFrom(at)
    }

    fun row(stmt: MemorySegment, out: Out) {
        out.raw(ROW_ID); out.long(long(stmt, 0))
        out.raw(ROW_BODY); text(stmt, 1, out)
        out.raw(ROW_CREATED); text(stmt, 2, out)
        out.raw(ROW_AUTHOR); text(stmt, 3, out)
        out.raw(ROW_LIKES); out.long(long(stmt, 4))
        out.byte('}'.code)
    }

    fun failure(stmt: MemorySegment): Nothing {
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
        bind(createStmt, 1, user)
        bind(createStmt, 2, body.encodeToByteArray())
        if (step(createStmt) != SQLITE_ROW) failure(createStmt)
        out.raw(POST_OPEN)
        out.raw(ROW_ID); out.long(long(createStmt, 0))
        out.raw(ROW_BODY); out.jsonText(body.encodeToByteArray())
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
        if ((SqliteCalls.iA.invokeExact(Sqlite3.changes, db) as Int) == 1) return 1
        bind(existsStmt, 1, post)
        val rc = step(existsStmt)
        reset(existsStmt)
        return if (rc == SQLITE_ROW) 0 else -1
    }
}
