import Vapor

struct PostController: RouteCollection {
    private static let feedSize = 20

    func boot(routes: any RoutesBuilder) throws {
        routes.get("feed", use: feed)

        let posts = routes.grouped("posts")
        posts.get(":id", use: show)

        let authenticated = posts.grouped(BearerTokenAuthenticator())
        authenticated.on(.POST, body: .collect(maxSize: "64kb"), use: create)
        authenticated.post(":id", "like", use: like)
    }

    @Sendable
    func feed(request: Request) async throws -> FeedResponse {
        FeedResponse(posts: try await request.feedRepository.latestPosts(limit: Self.feedSize))
    }

    @Sendable
    func show(request: Request) async throws -> PostResponse {
        guard let post = try await request.feedRepository.post(id: try request.postID()) else {
            throw APIError.postNotFound
        }
        return PostResponse(post: post)
    }

    @Sendable
    func create(request: Request) async throws -> PostResponse {
        let identity = try request.auth.require(Identity.self)
        let input = try CreatePostRequest.decode(from: request.body.data)
        let body = try PostBody(validating: input.body)

        let post = try await request.feedRepository.createPost(
            userID: identity.userID, author: identity.username, body: body.text)
        return PostResponse(status: .created, post: post)
    }

    @Sendable
    func like(request: Request) async throws -> LikeResponse {
        let identity = try request.auth.require(Identity.self)
        let postID = try request.postID()

        switch try await request.feedRepository.like(postID: postID, userID: identity.userID) {
        case .postNotFound: throw APIError.postNotFound
        case .liked: return LikeResponse(alreadyLiked: false, postID: postID)
        case .alreadyLiked: return LikeResponse(alreadyLiked: true, postID: postID)
        }
    }
}

extension Request {
    /// The `:id` path segment.
    fileprivate func postID() throws -> Int64 {
        guard let raw = parameters.get("id"), let id = PositiveID(raw) else {
            throw APIError.invalidPostID
        }
        return id.value
    }
}
