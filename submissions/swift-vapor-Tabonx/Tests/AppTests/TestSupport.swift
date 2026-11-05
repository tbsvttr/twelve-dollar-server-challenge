import Foundation
import GRDB
import JWT
import NIOCore
import VaporTesting
@testable import App

/// A running test application, with one method per kind of request the tests send.
struct TestClient: Sendable {
    let app: Application

    @discardableResult
    func send(
        _ method: HTTPMethod,
        _ uri: String,
        authorization: String? = nil,
        body: String? = nil
    ) async throws -> (status: HTTPStatus, body: String) {
        var headers = HTTPHeaders()
        if let authorization { headers.replaceOrAdd(name: .authorization, value: authorization) }
        if body != nil { headers.replaceOrAdd(name: .contentType, value: "application/json") }
        let payload = body.map { ByteBuffer(string: $0) } ?? ByteBuffer()
        let box = ResultBox()
        try await app.testing().test(method, uri, headers: headers, body: payload) { response in
            await box.set(response.status, response.body.string)
        }
        return await box.value
    }

    private actor ResultBox {
        var value: (status: HTTPStatus, body: String) = (.internalServerError, "")
        func set(_ status: HTTPStatus, _ body: String) { value = (status, body) }
    }
}

enum Fixtures {
    static let secret = "a-test-secret-of-at-least-32-bytes"
    static let username = "golden_ember_1"

    /// A temporary database with the challenge schema and one user (id 1).
    static func emptyDatabase() throws -> String {
        let path = try temporaryDirectory().appendingPathComponent("feed.db").path
        let queue = try DatabaseQueue(path: path)
        try queue.write { db in
            try db.execute(sql: schema)
            try db.execute(sql: "INSERT INTO users (id, username) VALUES (1, ?)", arguments: [username])
        }
        try queue.close()
        return path
    }

    /// A temporary copy of the seed database named by `FEED_SEED_DB`, or nil when it is not set.
    static func seedDatabaseCopy() throws -> String? {
        guard let seed = seedPath else { return nil }
        let path = try temporaryDirectory().appendingPathComponent("feed.db").path
        try FileManager.default.copyItem(atPath: seed, toPath: path)
        return path
    }

    static var seedPath: String? {
        ProcessInfo.processInfo.environment["FEED_SEED_DB"].flatMap { $0.isEmpty ? nil : $0 }
    }

    static func withApp(
        databasePath: String? = nil,
        secret: String = Fixtures.secret,
        _ body: @Sendable (TestClient) async throws -> Void
    ) async throws {
        let path = try databasePath ?? emptyDatabase()
        let app = try await Application.make(.testing)
        do {
            try await configure(app, ServerConfiguration(databasePath: path, jwtSecret: secret))
            try await body(TestClient(app: app))
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("feed-server-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // Same as the challenge's schema.sql.
    private static let schema = """
        CREATE TABLE users (
          id          INTEGER PRIMARY KEY,
          username    TEXT NOT NULL UNIQUE,
          created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
        );
        CREATE TABLE posts (
          id          INTEGER PRIMARY KEY,
          user_id     INTEGER NOT NULL REFERENCES users(id),
          body        TEXT NOT NULL CHECK (length(body) BETWEEN 1 AND 500),
          created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
        );
        CREATE TABLE likes (
          user_id     INTEGER NOT NULL REFERENCES users(id),
          post_id     INTEGER NOT NULL REFERENCES posts(id),
          created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
          PRIMARY KEY (user_id, post_id)
        );
        CREATE INDEX posts_created_at_id_idx ON posts (created_at DESC, id DESC);
        CREATE INDEX posts_user_id_idx       ON posts (user_id);
        CREATE INDEX likes_post_id_idx       ON likes (post_id);
        """
}

/// Arbitrary JWT claims, so tests can sign payloads the server must reject.
struct Claims: JWTPayload {
    enum Value: Encodable, Sendable {
        case string(String)
        case int(Int)

        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let value): try container.encode(value)
            case .int(let value): try container.encode(value)
            }
        }
    }

    var values: [String: Value]

    static func valid(sub: String = "1", username: String = Fixtures.username) -> Claims {
        let now = Int(Date().timeIntervalSince1970)
        return Claims(values: ["sub": .string(sub), "username": .string(username), "iat": .int(now), "exp": .int(now + 3600)])
    }

    init(values: [String: Value]) {
        self.values = values
    }

    init(from _: any Decoder) throws {
        throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Claims are only signed in tests"))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: AnyKey.self)
        for (key, value) in values {
            try container.encode(value, forKey: AnyKey(stringValue: key))
        }
    }

    func verify(using _: some JWTAlgorithm) async throws {}

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue _: Int) { nil }
    }
}

enum Tokens {
    static func sign(_ claims: Claims, secret: String = Fixtures.secret, header: JWTHeader = .init()) async throws -> String {
        let keys = JWTKeyCollection()
        await keys.add(hmac: HMACKey(from: Array(secret.utf8)), digestAlgorithm: .sha256)
        return try await keys.sign(claims, header: header)
    }

    static func bearer(_ claims: Claims = .valid()) async throws -> String {
        "Bearer " + (try await sign(claims))
    }
}

func errorBody(_ message: String) -> String {
    #"{"error":"\#(message)"}"#
}
