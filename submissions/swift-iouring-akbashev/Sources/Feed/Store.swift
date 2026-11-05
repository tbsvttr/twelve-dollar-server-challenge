// SQLite, in-process: the loop's connection, its statements prepared once, and one transaction per pass of the loop
// (group commit, rule 6): every request of the pass runs inside it, and no response leaves before its COMMIT. Reads
// walk SQLite's B-trees directly (Reads.swift), with these statements as their fallback; writes are SQL. Rows are
// written as JSON straight from SQLite's memory. The checkpointer has a connection of its own.
import CSQLite

/// What a request asks the database.
nonisolated enum Query {
    case health
    case feed
    case post(id: Int64)
    /// `body` trimmed and checked; `author` is the token's username, which the response echoes.
    case createPost(userID: Int64, body: [UInt8], author: [UInt8])
    case like(userID: Int64, postID: Int64)
}

nonisolated struct StoreError: Error, CustomStringConvertible {
    let description: String
}

nonisolated struct Store: ~Copyable, ~Sendable {
    private let db: OpaquePointer
    private let feed: OpaquePointer
    private let post: OpaquePointer
    private let postExists: OpaquePointer
    private let insertPost: OpaquePointer
    private let insertLike: OpaquePointer
    private let health: OpaquePointer
    private let begin: OpaquePointer
    private let commit: OpaquePointer
    private let rollback: OpaquePointer
    /// The read queries off the B-trees.
    private var reads: Reads
    /// The WAL's size in frames after the last commit (the WAL hook writes it).
    private let walFrames: UnsafeMutablePointer<Int32>
    private let started: UInt64

    private(set) var inTransaction = false
    /// A statement failed in a way that ended the transaction: the rest of the pass is answered with 500s.
    private(set) var passFailed = false

    /// Checkpoints run past this many WAL frames (automatic checkpoints are off).
    static let checkpointFrames: Int32 = 1024

    private static let postColumns = """
        SELECT p.id, p.body, p.created_at, u.username, (SELECT count(*) FROM likes l WHERE l.post_id = p.id)
          FROM posts p JOIN users u ON u.id = p.user_id
        """

    init(path: String, started: UInt64, directReads: Bool) throws(StoreError) {
        let db = try SQLite.open(path, cacheKiB: 256 * 1024)
        let statements: [OpaquePointer]
        do {
            statements = try Self.prepareAll(db)
        } catch {
            sqlite3_close_v2(db)
            throw error
        }
        do {
            reads = try Reads(db, enabled: directReads)
        } catch {
            for stmt in statements { sqlite3_finalize(stmt) }
            sqlite3_close_v2(db)
            throw error
        }
        self.db = db
        self.started = started
        (feed, post, postExists, insertPost, insertLike) = (statements[0], statements[1], statements[2], statements[3], statements[4])
        (health, begin, commit, rollback) = (statements[5], statements[6], statements[7], statements[8])
        walFrames = .allocate(capacity: 1)
        walFrames.initialize(to: 0)
        sqlite3_wal_hook(db, { context, _, _, frames in
            context!.assumingMemoryBound(to: Int32.self).pointee = frames
            return SQLITE_OK
        }, walFrames)
    }

    /// The statements, prepared once (in the order the properties take them).
    private static func prepareAll(_ db: OpaquePointer) throws(StoreError) -> [OpaquePointer] {
        var statements: [OpaquePointer] = []
        for sql in [
            postColumns + " ORDER BY p.created_at DESC, p.id DESC LIMIT 20",
            postColumns + " WHERE p.id = ?1",
            "SELECT 1 FROM posts WHERE id = ?1",
            "INSERT INTO posts (user_id, body) VALUES (?1, ?2) RETURNING id, created_at",
            "INSERT INTO likes (user_id, post_id) VALUES (?1, ?2) ON CONFLICT (user_id, post_id) DO NOTHING",
            "SELECT 1", "BEGIN", "COMMIT", "ROLLBACK",
        ] {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v3(db, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &stmt, nil) == SQLITE_OK, let stmt else {
                let message = String(cString: sqlite3_errmsg(db))
                for s in statements { sqlite3_finalize(s) }
                throw StoreError(description: "prepare \(sql): \(message)")
            }
            statements.append(stmt)
        }
        return statements
    }

    deinit {
        for stmt in [feed, post, postExists, insertPost, insertLike, health, begin, commit, rollback] { sqlite3_finalize(stmt) }
        sqlite3_close_v2(db)
        walFrames.deallocate()
    }

    // ---------- the pass's transaction ----------

    /// Commits the pass's transaction, if one is open; false if it didn't commit (every response of the pass is then
    /// a 500, rule 6).
    mutating func finishPass() -> Bool {
        defer { passFailed = false }
        reads.close()
        guard inTransaction else { return !passFailed }
        inTransaction = false
        let rc = sqlite3_step(commit)
        sqlite3_reset(commit)
        if rc == SQLITE_DONE && !passFailed { return true }
        if sqlite3_get_autocommit(db) == 0 {
            sqlite3_step(rollback)
            sqlite3_reset(rollback)
        }
        return false
    }

    var checkpointDue: Bool { walFrames.pointee >= Self.checkpointFrames }

    /// The reads walk the B-trees (the schema is the one they assume).
    var directReads: Bool { reads.available }

    /// The checkpointer copied the WAL: the next commit reports what's in it again.
    func checkpointFinished() {
        walFrames.pointee = 0
    }

    /// Copies the WAL back into the database file on this connection, in the loop (`CHECKPOINT_THREAD=0`; the
    /// checkpointer does it otherwise).
    mutating func checkpoint() {
        sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_PASSIVE, nil, nil)
        walFrames.pointee = 0
    }

    private mutating func beginIfNeeded() -> Bool {
        if inTransaction { return true }
        let rc = sqlite3_step(begin)
        sqlite3_reset(begin)
        guard rc == SQLITE_DONE else { return false }
        inTransaction = true
        return true
    }

    /// After a statement failed: whether SQLite ended the transaction itself (SQLITE_FULL, I/O errors), which fails the
    /// whole pass.
    private mutating func noteFailure() {
        if inTransaction && sqlite3_get_autocommit(db) != 0 {
            inTransaction = false
            passFailed = true
        }
    }

    // ---------- answers ----------

    /// Runs `query` inside the pass's transaction and appends the response body to `body` (the connection's send
    /// buffer, written in place); returns the status.
    mutating func answer(_ query: Query, into body: inout ByteBuffer) -> UInt16 {
        let mark = body.count
        guard !passFailed, beginIfNeeded() else {
            passFailed = true
            return error(&body, mark, 500, "internal server error")
        }
        switch query {
        case .health:
            let rc = sqlite3_step(health)
            sqlite3_reset(health)
            guard rc == SQLITE_ROW else {
                body.append("{\"status\":\"degraded\",\"db\":\"unreachable\",\"error\":")
                JSON.writeString(&body, String(cString: sqlite3_errmsg(db)).utf8Span.span)
                body.append("}")
                return 503
            }
            body.append("{\"status\":\"ok\",\"db\":\"ok\",\"uptime_s\":")
            JSON.writeUInt(&body, (Sys.monotonicNanos() - started) / 1_000_000_000)
            body.append("}")
            return 200

        case .feed:
            if reads.available {
                switch reads.feed(into: &body) {
                case .done: return 200
                case .failed: return failed(&body, mark)
                case .missing, .unexpected: body.truncate(mark)
                }
            }
            defer { sqlite3_reset(feed) }
            body.append("{\"posts\":[")
            var rows = 0
            var rc = sqlite3_step(feed)
            while rc == SQLITE_ROW {
                if rows > 0 { body.append(",") }
                writePost(feed, into: &body)
                rows += 1
                rc = sqlite3_step(feed)
            }
            guard rc == SQLITE_DONE else { return failed(&body, mark) }
            body.append("]}")
            return 200

        case .post(let id):
            if reads.available {
                switch reads.post(id, into: &body) {
                case .done: return 200
                case .missing: return error(&body, mark, 404, "post not found")
                case .failed: return failed(&body, mark)
                case .unexpected: body.truncate(mark)
                }
            }
            defer { sqlite3_reset(post) }
            sqlite3_bind_int64(post, 1, id)
            let rc = sqlite3_step(post)
            if rc == SQLITE_DONE { return error(&body, mark, 404, "post not found") }
            guard rc == SQLITE_ROW else { return failed(&body, mark) }
            body.append("{\"post\":")
            writePost(post, into: &body)
            body.append("}")
            return 200

        case .createPost(let userID, let text, let author):
            defer {
                sqlite3_reset(insertPost)
                sqlite3_clear_bindings(insertPost)
            }
            sqlite3_bind_int64(insertPost, 1, userID)
            let bound = text.withUnsafeBytes { raw in
                sqlite3_bind_text(insertPost, 2, raw.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(raw.count), nil)
            }
            guard bound == SQLITE_OK, sqlite3_step(insertPost) == SQLITE_ROW else { return failed(&body, mark) }
            body.append("{\"post\":{\"id\":")
            JSON.writeInt(&body, sqlite3_column_int64(insertPost, 0))
            body.append(",\"body\":")
            JSON.writeString(&body, text)
            body.append(",\"created_at\":")
            Self.writeText(insertPost, 1, into: &body)
            body.append(",\"author\":")
            JSON.writeString(&body, author)
            body.append(",\"like_count\":0}}")
            guard sqlite3_step(insertPost) == SQLITE_DONE else { return failed(&body, mark) }
            return 201

        case .like(let userID, let postID):
            switch reads.available ? reads.postExists(postID) : .unexpected {
            case .done: break
            case .missing: return error(&body, mark, 404, "post not found")
            case .failed: return failed(&body, mark)
            case .unexpected:
                sqlite3_bind_int64(postExists, 1, postID)
                let exists = sqlite3_step(postExists)
                sqlite3_reset(postExists)
                if exists == SQLITE_DONE { return error(&body, mark, 404, "post not found") }
                guard exists == SQLITE_ROW else { return failed(&body, mark) }
            }
            sqlite3_bind_int64(insertLike, 1, userID)
            sqlite3_bind_int64(insertLike, 2, postID)
            let rc = sqlite3_step(insertLike)
            sqlite3_reset(insertLike)
            guard rc == SQLITE_DONE else { return failed(&body, mark) }
            let inserted = sqlite3_changes(db) == 1
            body.append(inserted ? "{\"liked\":true,\"already_liked\":false,\"post_id\":" : "{\"liked\":true,\"already_liked\":true,\"post_id\":")
            JSON.writeInt(&body, postID)
            body.append("}")
            return inserted ? 201 : 200
        }
    }

    /// A post object from a row of `postColumns`: id, body, created_at (stored in the wire format), username,
    /// like_count.
    @inline(__always) private func writePost(_ stmt: OpaquePointer, into body: inout ByteBuffer) {
        body.append("{\"id\":")
        JSON.writeInt(&body, sqlite3_column_int64(stmt, 0))
        body.append(",\"body\":")
        Self.writeText(stmt, 1, into: &body)
        body.append(",\"created_at\":")
        Self.writeText(stmt, 2, into: &body)
        body.append(",\"author\":")
        Self.writeText(stmt, 3, into: &body)
        body.append(",\"like_count\":")
        JSON.writeInt(&body, sqlite3_column_int64(stmt, 4))
        body.append("}")
    }

    /// A text column as a JSON string, straight from SQLite's copy of it.
    @inline(__always) private static func writeText(_ stmt: OpaquePointer, _ column: Int32, into body: inout ByteBuffer) {
        let count = Int(sqlite3_column_bytes(stmt, column))
        let base = sqlite3_column_text(stmt, column)
        JSON.writeString(&body, Span(_unsafeElements: UnsafeBufferPointer(start: base, count: base == nil ? 0 : count)))
    }

    private mutating func failed(_ body: inout ByteBuffer, _ mark: Int) -> UInt16 {
        Sys.logLine("sqlite: \(String(cString: sqlite3_errmsg(db)))")
        noteFailure()
        return error(&body, mark, 500, "internal server error")
    }

    /// An error body in place of whatever this answer wrote after `mark`.
    private func error(_ body: inout ByteBuffer, _ mark: Int, _ status: UInt16, _ message: StaticString) -> UInt16 {
        body.truncate(mark)
        JSON.writeError(&body, message)
        return status
    }
}

/// Opening a connection, for the loop and for the checkpointer alike.
nonisolated enum SQLite {
    /// A connection through the `unix-excl` VFS: the process holds the file's lock for its life (no other process may
    /// open it), and the WAL index lives in this process's memory, shared by its connections (no `-shm` file). WAL
    /// with synchronous=NORMAL (rule 6); checkpoints run by the server, not by SQLite after a commit; SQLite's own
    /// page cache of `cacheKiB`, no mmap.
    static func open(_ path: String, cacheKiB: Int) throws(StoreError) -> OpaquePointer {
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE, "unix-excl")
        guard rc == SQLITE_OK, let db = handle else {
            if let handle { sqlite3_close_v2(handle) }
            throw StoreError(description: "sqlite3_open_v2 \(path): \(String(cString: sqlite3_errstr(rc)))")
        }
        for pragma in [
            "PRAGMA journal_mode=WAL", "PRAGMA synchronous=NORMAL", "PRAGMA wal_autocheckpoint=0",
            "PRAGMA cache_size=-\(cacheKiB)", "PRAGMA mmap_size=0", "PRAGMA temp_store=MEMORY",
        ] {
            guard sqlite3_exec(db, pragma, nil, nil, nil) == SQLITE_OK else {
                let message = String(cString: sqlite3_errmsg(db))
                sqlite3_close_v2(db)
                throw StoreError(description: "\(pragma): \(message)")
            }
        }
        return db
    }
}
