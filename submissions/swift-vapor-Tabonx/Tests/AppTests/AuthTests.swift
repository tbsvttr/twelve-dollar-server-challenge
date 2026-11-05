import Foundation
import Testing
import VaporTesting
@testable import App

@Suite struct AuthTests {
    @Test(arguments: [nil, "Basic abc", "bearer abc", "Bearer"])
    func missingBearerToken(authorization: String?) async throws {
        try await Fixtures.withApp { client in
            let response = try await client.send(.POST, "/posts", authorization: authorization, body: #"{"body":"x"}"#)
            #expect(response.status == .unauthorized)
            #expect(response.body == errorBody("missing bearer token"))
        }
    }

    @Test func rejectsInvalidTokens() async throws {
        let now = Int(Date().timeIntervalSince1970)
        let valid = try await Tokens.sign(.valid())
        let parts = valid.split(separator: ".")
        let noneHeader = Data(#"{"alg":"none","typ":"JWT"}"#.utf8).base64EncodedString()
            .replacingOccurrences(of: "=", with: "")

        let tokens = [
            "abc",
            "\(parts[0]).\(parts[1]).c2lnbmF0dXJlLWlzLW5vdC12YWxpZA",
            "\(noneHeader).\(parts[1]).",
            try await Tokens.sign(.valid(), secret: "another-secret-that-is-32-bytes-long"),
            // Signed with the right HS256 key but labelled HS512: only HS256 is accepted.
            try await Tokens.sign(.valid(), header: ["alg": "HS512"]),
            try await Tokens.sign(Claims(values: ["sub": .string("1"), "username": .string("a"), "exp": .int(now - 60)])),
            try await Tokens.sign(Claims(values: ["sub": .string("1"), "username": .string("a")])),
        ]

        try await Fixtures.withApp { client in
            for token in tokens {
                let response = try await client.send(.POST, "/posts", authorization: "Bearer \(token)", body: #"{"body":"x"}"#)
                #expect(response.status == .unauthorized, "token: \(token)")
                #expect(response.body == errorBody("invalid or expired token"), "token: \(token)")
            }
        }
    }

    @Test func rejectsInvalidPayloads() async throws {
        let exp = Claims.Value.int(Int(Date().timeIntervalSince1970) + 3600)
        let payloads: [Claims] = [
            .valid(sub: "abc"),
            .valid(sub: "0"),
            .valid(sub: "-1"),
            .valid(sub: "+1"),
            .valid(sub: "1.5"),
            Claims(values: ["sub": .int(1), "username": .string("a"), "exp": exp]),
            Claims(values: ["sub": .string("1"), "exp": exp]),
            Claims(values: ["sub": .string("1"), "username": .int(7), "exp": exp]),
        ]

        try await Fixtures.withApp { client in
            for payload in payloads {
                let response = try await client.send(
                    .POST, "/posts", authorization: try await Tokens.bearer(payload), body: #"{"body":"x"}"#)
                #expect(response.status == .unauthorized, "payload: \(payload.values)")
                #expect(response.body == errorBody("invalid token payload"), "payload: \(payload.values)")
            }
        }
    }

    @Test func acceptsTokenSignedWithShortChallengeSecret() async throws {
        // Signed with openssl using the 23-byte challenge secret; expires in 2100.
        let token = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxIiwidXNlcm5hbWUiOiJnb2xkZW5fZW1iZXJfMSIsImlhdCI6MTc2MTM1MDQwMCwiZXhwIjo0MTAyNDQ0ODAwfQ.TBD84OEtOHAvWQ0zjBq_mP5NESCVfFXYtNXjpYXwPfA"
        try await Fixtures.withApp(secret: "twelve-dollar-challenge") { client in
            let response = try await client.send(.POST, "/posts", authorization: "Bearer \(token)", body: #"{"body":"hello"}"#)
            #expect(response.status == .created)
        }
    }

    @Test func checksAuthBeforePostID() async throws {
        try await Fixtures.withApp { client in
            let anonymous = try await client.send(.POST, "/posts/abc/like")
            #expect(anonymous.status == .unauthorized)
            #expect(anonymous.body == errorBody("missing bearer token"))

            let authenticated = try await client.send(.POST, "/posts/abc/like", authorization: try await Tokens.bearer())
            #expect(authenticated.status == .badRequest)
            #expect(authenticated.body == errorBody("invalid post id"))
        }
    }
}
