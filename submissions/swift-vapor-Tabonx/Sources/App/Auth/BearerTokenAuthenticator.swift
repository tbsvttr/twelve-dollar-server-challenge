import Foundation
import JWT
import Vapor

/// Requires `Authorization: Bearer <jwt>` and logs the caller in. It runs before the route handler,
/// so a request with a bad id and no token gets 401, not 400.
///
/// Vapor's `BearerAuthenticator` lets unauthenticated requests through for a later guard to reject,
/// and `req.jwt.verify()` throws one error for every failure. The API reports each case separately.
struct BearerTokenAuthenticator: AsyncMiddleware {
    private static let bearerPrefix = "Bearer "
    private static let acceptedAlgorithm = "HS256"
    /// jwt-kit asserts that an HS256 key has at least this many bytes.
    private static let minimumKeyLength = 32

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard let header = request.headers.first(name: .authorization), header.hasPrefix(Self.bearerPrefix) else {
            throw APIError.missingBearerToken
        }
        let token = String(header.dropFirst(Self.bearerPrefix.count))

        // jwt-kit verifies with the collection's only key whatever `alg` the header names, so the
        // header is checked here to accept HS256 and nothing else.
        guard Self.algorithm(of: token) == Self.acceptedAlgorithm else {
            throw APIError.invalidToken
        }
        let payload: TokenPayload
        do {
            payload = try await request.jwt.verify(token, as: TokenPayload.self)
        } catch {
            throw APIError.invalidToken
        }
        guard let identity = payload.identity else {
            throw APIError.invalidTokenPayload
        }

        request.auth.login(identity)
        return try await next.respond(to: request)
    }

    /// HMAC zero-pads keys shorter than the hash block size (RFC 2104 section 2), so padding a short
    /// secret up to 32 bytes produces the same signatures. It only keeps jwt-kit's key-length
    /// assertion from firing for a short secret.
    static func hmacKey(for secret: String) -> HMACKey {
        var bytes = Array(secret.utf8)
        if bytes.count < minimumKeyLength {
            bytes += repeatElement(0, count: minimumKeyLength - bytes.count)
        }
        return HMACKey(from: bytes)
    }

    private struct Header: Decodable {
        let alg: String
    }

    private static func algorithm(of token: String) -> String? {
        guard let encodedHeader = token.split(separator: ".", omittingEmptySubsequences: false).first,
              let data = Data(base64URLEncoded: encodedHeader),
              let header = try? JSONDecoder().decode(Header.self, from: data)
        else { return nil }
        return header.alg
    }
}

extension Data {
    /// Decodes unpadded base64url (RFC 4648 section 5), as used in JWT segments.
    init?(base64URLEncoded string: some StringProtocol) {
        var base64 = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}
