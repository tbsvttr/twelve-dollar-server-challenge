import Vapor

/// Every error the API reports. Each case maps to one status and one message from the spec.
enum APIError: AbortError, Equatable {
    case notFound
    case invalidPostID
    case postNotFound
    case missingBearerToken
    case invalidToken
    case invalidTokenPayload
    case malformedJSON
    case bodyRequired
    case bodyTooLong

    var status: HTTPResponseStatus {
        switch self {
        case .notFound, .postNotFound: .notFound
        case .invalidPostID, .malformedJSON, .bodyRequired, .bodyTooLong: .badRequest
        case .missingBearerToken, .invalidToken, .invalidTokenPayload: .unauthorized
        }
    }

    var reason: String {
        switch self {
        case .notFound: "not found"
        case .invalidPostID: "invalid post id"
        case .postNotFound: "post not found"
        case .missingBearerToken: "missing bearer token"
        case .invalidToken: "invalid or expired token"
        case .invalidTokenPayload: "invalid token payload"
        case .malformedJSON: "malformed JSON body"
        case .bodyRequired: "body is required"
        case .bodyTooLong: "body must be at most \(PostBody.maximumLength) characters"
        }
    }
}
