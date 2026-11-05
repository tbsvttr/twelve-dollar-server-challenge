import Vapor

/// A response body written with `JSONWriter`.
///
/// `Content` would be the usual choice, but it encodes with `JSONEncoder`, which keeps keys in a
/// dictionary. It has no option for declaration order, and the API's key order is part of its contract.
protocol JSONResponse: AsyncResponseEncodable, JSONEncodable, Sendable {
    var status: HTTPStatus { get }
}

extension JSONResponse {
    var status: HTTPStatus { .ok }

    func encodeResponse(for _: Request) async throws -> Response {
        makeResponse()
    }

    func makeResponse() -> Response {
        Response(
            status: status,
            headers: ["content-type": "application/json; charset=utf-8"],
            body: .init(buffer: ByteBuffer(bytes: JSONWriter.encode(self)))
        )
    }
}
