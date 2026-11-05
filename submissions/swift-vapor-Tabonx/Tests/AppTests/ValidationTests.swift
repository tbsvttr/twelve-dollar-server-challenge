import Testing
import VaporTesting
@testable import App

@Suite struct ValidationTests {
    @Test(arguments: ["0", "-1", "abc", "1.5", "+1", "1e3", "99999999999999999999"])
    func rejectsInvalidPostIDs(id: String) async throws {
        try await Fixtures.withApp { client in
            let response = try await client.send(.GET, "/posts/\(id)")
            #expect(response.status == .badRequest)
            #expect(response.body == errorBody("invalid post id"))
        }
    }

    @Test func unknownPathAndMissingPost() async throws {
        try await Fixtures.withApp { client in
            let unknown = try await client.send(.GET, "/nope")
            #expect(unknown.status == .notFound)
            #expect(unknown.body == errorBody("not found"))

            let missing = try await client.send(.GET, "/posts/999999999")
            #expect(missing.status == .notFound)
            #expect(missing.body == errorBody("post not found"))

            let missingLike = try await client.send(.POST, "/posts/999999999/like", authorization: try await Tokens.bearer())
            #expect(missingLike.status == .notFound)
            #expect(missingLike.body == errorBody("post not found"))
        }
    }

    @Test(arguments: [
        (#"{"body":""}"#, "body is required"),
        (#"{"body":"   \n\t "}"#, "body is required"),
        (#"{"body":123}"#, "body is required"),
        (#"{"body":null}"#, "body is required"),
        (#"{}"#, "body is required"),
        (#"[]"#, "body is required"),
        (#"{bad json"#, "malformed JSON body"),
        (#""#, "malformed JSON body"),
        (#"{"body":"\#(String(repeating: "a", count: 501))"}"#, "body must be at most 500 characters"),
    ])
    func rejectsInvalidBodies(body: String, message: String) async throws {
        try await Fixtures.withApp { client in
            let response = try await client.send(.POST, "/posts", authorization: try await Tokens.bearer(), body: body)
            #expect(response.status == .badRequest)
            #expect(response.body == errorBody(message))
        }
    }

    @Test func escapesStrings() {
        var json = JSONWriter()
        json.string("plain \"q\" \\ \n\r\t\u{1} caf\u{E9}")
        #expect(String(decoding: json.bytes, as: UTF8.self) == #""plain \"q\" \\ \n\r\t\u0001 caf\#u{E9}""#)
    }

    @Test func trimsAndCountsUnicodeScalars() throws {
        #expect(try PostBody(validating: "  hello \n").text == "hello")
        #expect(try PostBody(validating: String(repeating: "\u{E9}", count: 500)).text.unicodeScalars.count == 500)

        // 300 characters but 600 Unicode scalars: SQLite's length() would reject it, so validation does too.
        let combining = String(repeating: "e\u{301}", count: 300)
        #expect(combining.count == 300)
        #expect(throws: APIError.bodyTooLong) { try PostBody(validating: combining) }

        // JavaScript's trim() removes U+FEFF and keeps U+0085.
        #expect(try PostBody(validating: "\u{FEFF}hi\u{FEFF}").text == "hi")
        #expect(try PostBody(validating: "\u{85}hi").text == "\u{85}hi")
    }
}
