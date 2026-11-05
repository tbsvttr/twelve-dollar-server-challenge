import JWT
import Vapor

/// Wires the database, the JWT key, the middleware and the routes into `app`.
func configure(_ app: Application, _ configuration: ServerConfiguration) async throws {
    app.http.server.configuration.hostname = configuration.host
    app.http.server.configuration.port = configuration.port
    // Connections arrive in bursts when clients reconnect. The default of 256 refuses some of them.
    app.http.server.configuration.backlog = 4096

    let pool = try FeedDatabase.openPool(at: configuration.databasePath)
    app.feedRepository = FeedRepository(database: pool)
    app.lifecycle.use(DatabaseLifecycle(pool: pool))

    await app.jwt.keys.add(hmac: BearerTokenAuthenticator.hmacKey(for: configuration.jwtSecret), digestAlgorithm: .sha256)

    // Replaces Vapor's default stack, which reports errors as {"error":true,"reason":"..."}.
    // It also drops per-request logging at info level, which costs more than the request at load.
    app.middleware = .init()
    app.middleware.use(RouteLoggingMiddleware(logLevel: .debug))
    app.middleware.use(JSONErrorMiddleware())

    try routes(app)
}
