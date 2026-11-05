import Foundation
import Testing
import VaporTesting
@testable import App

@Suite struct EndpointTests {
    @Test func createLikeAndReadBack() async throws {
        try await Fixtures.withApp { client in
            let auth = try await Tokens.bearer()

            let created = try await client.send(.POST, "/posts", authorization: auth, body: #"{"body":"  hello \"world\" / café  "}"#)
            #expect(created.status == .created)
            let createdAt = try #require(created.body.firstMatch(of: /"created_at":"([^"]+)"/)?.1)
            #expect(createdAt.wholeMatch(of: /\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z/) != nil)
            let post = #"{"id":1,"body":"hello \"world\" / café","created_at":"\#(createdAt)","author":"golden_ember_1","#
            #expect(created.body == #"{"post":\#(post)"like_count":0}}"#)

            let firstLike = try await client.send(.POST, "/posts/1/like", authorization: auth)
            #expect(firstLike.status == .created)
            #expect(firstLike.body == #"{"liked":true,"already_liked":false,"post_id":1}"#)

            let repeatLike = try await client.send(.POST, "/posts/1/like", authorization: auth)
            #expect(repeatLike.status == .ok)
            #expect(repeatLike.body == #"{"liked":true,"already_liked":true,"post_id":1}"#)

            let readBack = try await client.send(.GET, "/posts/1")
            #expect(readBack.status == .ok)
            #expect(readBack.body == #"{"post":\#(post)"like_count":1}}"#)

            let feed = try await client.send(.GET, "/feed")
            #expect(feed.status == .ok)
            #expect(feed.body == #"{"posts":[\#(post)"like_count":1}]}"#)
        }
    }

    @Test func health() async throws {
        try await Fixtures.withApp { client in
            let response = try await client.send(.GET, "/health")
            #expect(response.status == .ok)
            #expect(response.body.wholeMatch(of: /\{"status":"ok","db":"ok","uptime_s":\d+\}/) != nil)
        }
    }

    @Test(.enabled(if: Fixtures.seedPath != nil, "set FEED_SEED_DB to the challenge's seed/feed.db"))
    func seedDatabaseMatchesGoldenResponses() async throws {
        let path = try #require(try Fixtures.seedDatabaseCopy())
        try await Fixtures.withApp(databasePath: path) { client in
            let post = try await client.send(.GET, "/posts/1")
            #expect(post.status == .ok)
            #expect(post.body == #"{"post":{"id":1,"body":"Fast tomorrow small bug big droplet. Weird cache really project rarely everything?","created_at":"2025-01-01T00:00:34.152Z","author":"happy_nebula_10241","like_count":11}}"#)

            let feed = try await client.send(.GET, "/feed")
            #expect(feed.status == .ok)
            #expect(feed.body.hasPrefix(#"{"posts":[{"id":500000,"body":"TIL So keepalive"#))
            #expect(feed.body.matches(of: /"like_count":/).count == 20)
        }
    }
}
