import Vapor

struct PostResponse: JSONResponse {
    var status: HTTPStatus = .ok
    let post: Post

    func encode(to json: inout JSONWriter) {
        json.object { $0.field("post", post) }
    }
}

struct FeedResponse: JSONResponse {
    let posts: [Post]

    func encode(to json: inout JSONWriter) {
        json.object { $0.field("posts", posts) }
    }
}

struct LikeResponse: JSONResponse {
    let alreadyLiked: Bool
    let postID: Int64

    var status: HTTPStatus { alreadyLiked ? .ok : .created }

    func encode(to json: inout JSONWriter) {
        json.object { object in
            object.field("liked", true)
            object.field("already_liked", alreadyLiked)
            object.field("post_id", postID)
        }
    }
}

/// `{"status":"ok","db":"ok","uptime_s":N}` when the database answers, otherwise
/// `{"status":"degraded","db":"unreachable","error":"..."}` with status 503.
enum HealthResponse: JSONResponse {
    case healthy(uptimeSeconds: Int64)
    case degraded(error: String)

    var status: HTTPStatus {
        switch self {
        case .healthy: .ok
        case .degraded: .serviceUnavailable
        }
    }

    func encode(to json: inout JSONWriter) {
        json.object { object in
            switch self {
            case .healthy(let uptimeSeconds):
                object.field("status", "ok")
                object.field("db", "ok")
                object.field("uptime_s", uptimeSeconds)
            case .degraded(let error):
                object.field("status", "degraded")
                object.field("db", "unreachable")
                object.field("error", error)
            }
        }
    }
}

/// `{"error":"<message>"}`
struct ErrorResponse: JSONResponse {
    let status: HTTPStatus
    let message: String

    func encode(to json: inout JSONWriter) {
        json.object { $0.field("error", message) }
    }
}
