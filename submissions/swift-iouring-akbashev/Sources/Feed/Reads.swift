// The two read queries (and a post's existence, for a like) straight off SQLite's B-trees, as SQLite's own plan
// walks them but without its SQL engine. When the schema isn't the one these reads assume, or a row isn't in the form
// they expect, SQL answers instead.
import BTree
import CSQLite

/// The read queries over four cursors: the posts and users tables (by rowid), posts_created_at_id_idx (newest first)
/// and likes_post_id_idx. The cursors open with the pass's first read and close before its commit.
nonisolated struct Reads: ~Copyable, ~Sendable {
    enum Answer {
        case done
        /// No such post.
        case missing
        /// Not in the form these reads expect (a post without its user, a record that spills): SQL answers.
        case unexpected
        case failed
    }

    /// The schema is the one these reads assume (else SQL answers every read).
    let available: Bool
    private var posts: Cursor
    private var users: Cursor
    private var newest: Cursor
    private var likes: Cursor
    private var isOpen = false

    init(_ db: OpaquePointer, enabled: Bool) throws(StoreError) {
        let roots = enabled && Self.schemaMatches(db)
            ? (Self.root(db, "posts"), Self.root(db, "users"), Self.root(db, "posts_created_at_id_idx"), Self.root(db, "likes_post_id_idx"))
            : (0, 0, 0, 0)
        available = roots.0 != 0 && roots.1 != 0 && roots.2 != 0 && roots.3 != 0
        guard let posts = Cursor(db, root: roots.0), let users = Cursor(db, root: roots.1),
              let newest = Cursor(db, root: roots.2, keyColumns: 2, descending: true),
              let likes = Cursor(db, root: roots.3, keyColumns: 1) else { throw StoreError(description: "btree cursors: out of memory") }
        self.posts = posts
        self.users = users
        self.newest = newest
        self.likes = likes
    }

    /// Before the pass's transaction ends.
    mutating func close() {
        guard isOpen else { return }
        posts.close()
        users.close()
        newest.close()
        likes.close()
        isOpen = false
    }

    private mutating func openIfNeeded() -> Bool {
        if isOpen { return true }
        guard posts.open(), users.open(), newest.open(), likes.open() else {
            posts.close()
            users.close()
            newest.close()
            likes.close()
            return false
        }
        isOpen = true
        return true
    }

    // ---------- the queries ----------

    /// `{"posts":[...]}`: the newest ids off the index, their likes counted in one walk of the likes index, then each
    /// post and its author, written as they are read.
    mutating func feed(into body: inout ByteBuffer) -> Answer {
        guard openIfNeeded() else { return .failed }
        // The feed's ids, newest first: (created_at, id) entries.
        var ids = InlineArray<20, Int64>(repeating: 0)
        var n = 0
        var move = newest.first()
        while move == .entry && n < ids.count {
            guard let id = Self.indexedID(newest.record) else { return .unexpected }
            ids[n] = id
            n += 1
            move = newest.next()
        }
        if move == .failed { return .failed }

        // Their likes in one walk when their ids lie close together (new posts' ids follow one another).
        var counts = InlineArray<513, UInt32>(repeating: 0)
        var lo = Int64.max, hi = Int64.min
        for i in 0..<n {
            lo = min(lo, ids[i])
            hi = max(hi, ids[i])
        }
        let together = n > 0 && hi - lo < Int64(counts.count)
        if together {
            var span = counts.mutableSpan
            switch likes.count(lo, hi, into: &span) {
            case .done: break
            case .unexpected: return .unexpected
            case .failed: return .failed
            }
        }

        body.append("{\"posts\":[")
        for i in 0..<n {
            if i > 0 { body.append(",") }
            let likeCount: UInt32
            if together {
                likeCount = counts[Int(ids[i] - lo)]
            } else {
                var one = InlineArray<1, UInt32>(repeating: 0)
                var span = one.mutableSpan
                switch likes.count(ids[i], ids[i], into: &span) {
                case .done: likeCount = one[0]
                case .unexpected: return .unexpected
                case .failed: return .failed
                }
            }
            switch writePost(ids[i], likes: likeCount, into: &body) {
            case .done: continue
            case .missing: return .unexpected
            case let other: return other
            }
        }
        body.append("]}")
        return .done
    }

    /// `{"post":{...}}`.
    mutating func post(_ id: Int64, into body: inout ByteBuffer) -> Answer {
        guard openIfNeeded() else { return .failed }
        var one = InlineArray<1, UInt32>(repeating: 0)
        var span = one.mutableSpan
        switch likes.count(id, id, into: &span) {
        case .done: break
        case .unexpected: return .unexpected
        case .failed: return .failed
        }
        body.append("{\"post\":")
        let answer = writePost(id, likes: one[0], into: &body)
        if answer == .done { body.append("}") }
        return answer
    }

    /// The post id of a posts_created_at_id_idx entry: (created_at, id).
    private static func indexedID(_ entry: Span<UInt8>) -> Int64? {
        guard let columns: InlineArray<2, Record.Column> = Record.columns(entry) else { return nil }
        return Record.integer(entry, columns[1])
    }

    /// Whether post `id` exists (for a like).
    mutating func postExists(_ id: Int64) -> Answer {
        guard openIfNeeded() else { return .failed }
        switch posts.seek(id) {
        case .entry: return .done
        case .none: return .missing
        case .failed: return .failed
        }
    }

    /// A post object: posts row `id` (id, user_id, body, created_at), then its author's username.
    private mutating func writePost(_ id: Int64, likes likeCount: UInt32, into body: inout ByteBuffer) -> Answer {
        switch posts.seek(id) {
        case .entry: break
        case .none: return .missing
        case .failed: return .failed
        }
        let row = posts.record
        guard let post: InlineArray<4, Record.Column> = Record.columns(row),
              let userID = Record.integer(row, post[1]), post[2].isText, post[3].isText else { return .unexpected }
        body.append("{\"id\":")
        JSON.writeInt(&body, id)
        body.append(",\"body\":")
        JSON.writeString(&body, row.extracting(post[2].range))
        body.append(",\"created_at\":")
        JSON.writeString(&body, row.extracting(post[3].range))

        // The post's columns are written, so the users cursor may move: a post without its user is no row of the join.
        switch users.seek(userID) {
        case .entry: break
        case .none: return .unexpected
        case .failed: return .failed
        }
        let author = users.record
        guard let user: InlineArray<2, Record.Column> = Record.columns(author), user[1].isText else { return .unexpected }
        body.append(",\"author\":")
        JSON.writeString(&body, author.extracting(user[1].range))
        body.append(",\"like_count\":")
        JSON.writeUInt(&body, UInt64(likeCount))
        body.append("}")
        return .done
    }

    // ---------- the schema these reads assume ----------

    /// The columns the decoders rely on, in order, with rowid tables whose `id` is the rowid, the two indexes' keys,
    /// and UTF-8 text.
    private static func schemaMatches(_ db: OpaquePointer) -> Bool {
        let checks: [(String, String)] = [
            ("SELECT name || ' ' || type || ' ' || pk FROM pragma_table_info('posts')",
             "id INTEGER 1,user_id INTEGER 0,body TEXT 0,created_at TEXT 0"),
            ("SELECT name || ' ' || type || ' ' || pk FROM pragma_table_info('users')",
             "id INTEGER 1,username TEXT 0,created_at TEXT 0"),
            ("SELECT count(*) FROM pragma_index_list('posts') WHERE origin = 'pk'", "0"),
            ("SELECT count(*) FROM pragma_index_list('users') WHERE origin = 'pk'", "0"),
            ("SELECT name || ' ' || desc FROM pragma_index_xinfo('posts_created_at_id_idx') WHERE key", "created_at 1,id 1"),
            ("SELECT name || ' ' || desc FROM pragma_index_xinfo('likes_post_id_idx') WHERE key", "post_id 0"),
            ("PRAGMA encoding", "UTF-8"),
        ]
        for (sql, expected) in checks where rows(db, sql) != expected {
            Sys.logLine("btree reads off, SQL answers: \(sql) gave \(rows(db, sql) ?? "an error")")
            return false
        }
        return true
    }

    /// The first column of every row of `sql`, joined with commas.
    private static func rows(_ db: OpaquePointer, _ sql: String) -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
        defer { sqlite3_finalize(stmt) }
        var values: [String] = []
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW {
            values.append(sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? "")
            rc = sqlite3_step(stmt)
        }
        return rc == SQLITE_DONE ? values.joined(separator: ",") : nil
    }

    private static func root(_ db: OpaquePointer, _ name: String) -> UInt32 {
        guard let text = rows(db, "SELECT rootpage FROM sqlite_schema WHERE name = '\(name)'"), let page = UInt32(text) else { return 0 }
        return page
    }
}
