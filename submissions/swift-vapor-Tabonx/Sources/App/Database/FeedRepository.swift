import GRDB

/// Every SQL statement the API runs. Each method is one short read or one write transaction.
struct FeedRepository: Sendable {
    let database: any DatabaseWriter

    private static let selectPost = """
        SELECT p.id, p.body, p.created_at, u.username,
               (SELECT count(*) FROM likes l WHERE l.post_id = p.id) AS like_count
          FROM posts p JOIN users u ON u.id = p.user_id
        """

    func ping() async throws {
        _ = try await database.read { db in
            try Int.fetchOne(db.cachedStatement(sql: "SELECT 1"))
        }
    }

    func latestPosts(limit: Int) async throws -> [Post] {
        try await database.read { db in
            let statement = try db.cachedStatement(sql: Self.selectPost + " ORDER BY p.created_at DESC, p.id DESC LIMIT ?")
            return try Post.fetchAll(statement, arguments: [limit])
        }
    }

    func post(id: Int64) async throws -> Post? {
        try await database.read { db in
            let statement = try db.cachedStatement(sql: Self.selectPost + " WHERE p.id = ?")
            return try Post.fetchOne(statement, arguments: [id])
        }
    }

    /// Inserts a post and returns it once the transaction has committed.
    func createPost(userID: Int64, author: String, body: String) async throws -> Post {
        let (id, createdAt) = try await database.write { db -> (Int64, String) in
            let statement = try db.cachedStatement(
                sql: "INSERT INTO posts (user_id, body) VALUES (?, ?) RETURNING id, created_at")
            guard let row = try Row.fetchOne(statement, arguments: [userID, body]) else {
                throw DatabaseError(message: "INSERT ... RETURNING returned no row")
            }
            return (row[0], row[1])
        }
        return Post(id: id, body: body, createdAt: createdAt, author: author, likeCount: 0)
    }

    enum LikeOutcome: Sendable {
        case liked
        case alreadyLiked
        case postNotFound
    }

    /// Records one like per (user, post). The existence check and the insert share a transaction.
    func like(postID: Int64, userID: Int64) async throws -> LikeOutcome {
        try await database.write { db in
            let exists = try Bool.fetchOne(
                db.cachedStatement(sql: "SELECT EXISTS (SELECT 1 FROM posts WHERE id = ?)"),
                arguments: [postID]) ?? false
            guard exists else { return .postNotFound }

            try db.cachedStatement(
                sql: "INSERT INTO likes (user_id, post_id) VALUES (?, ?) ON CONFLICT (user_id, post_id) DO NOTHING"
            ).execute(arguments: [userID, postID])
            return db.changesCount > 0 ? .liked : .alreadyLiked
        }
    }
}
