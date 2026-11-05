import Vapor

/// The authenticated caller, taken from the token and not looked up.
struct Identity: Authenticatable, Sendable, Equatable {
    let userID: Int64
    let username: String
}
