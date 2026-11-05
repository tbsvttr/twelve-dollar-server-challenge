import GRDB

/// A post as the API returns it.
struct Post: Sendable, Equatable {
    let id: Int64
    let body: String
    /// Stored in the wire format (`2025-12-31T23:59:19.409Z`), so it passes through untouched.
    let createdAt: String
    let author: String
    let likeCount: Int
}

extension Post: FetchableRecord {
    /// Reads columns by position, in the order of `FeedRepository.selectPost`.
    init(row: Row) {
        id = row[0]
        body = row[1]
        createdAt = row[2]
        author = row[3]
        likeCount = row[4]
    }
}

extension Post: JSONEncodable {
    func encode(to json: inout JSONWriter) {
        json.object { object in
            object.field("id", id)
            object.field("body", body)
            object.field("created_at", createdAt)
            object.field("author", author)
            object.field("like_count", likeCount)
        }
    }
}
