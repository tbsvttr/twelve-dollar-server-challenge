import JWT

/// The JWT claims this API reads.
///
/// Decoding only requires `exp`, so a payload with a bad `sub` or `username` still decodes after the
/// signature check. `identity` then reports it, which tells "invalid token payload" apart from
/// "invalid or expired token".
struct TokenPayload: JWTPayload {
    let expiration: ExpirationClaim
    let subject: String?
    let username: String?

    enum CodingKeys: String, CodingKey {
        case expiration = "exp"
        case subject = "sub"
        case username
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        expiration = try container.decode(ExpirationClaim.self, forKey: .expiration)
        subject = try? container.decode(String.self, forKey: .subject)
        username = try? container.decode(String.self, forKey: .username)
    }

    func verify(using _: some JWTAlgorithm) async throws {
        try expiration.verifyNotExpired()
    }

    /// The caller, or nil when `sub` isn't a positive integer string or `username` isn't a string.
    var identity: Identity? {
        guard let subject, let username, let userID = PositiveID(subject)?.value else { return nil }
        return Identity(userID: userID, username: username)
    }
}
