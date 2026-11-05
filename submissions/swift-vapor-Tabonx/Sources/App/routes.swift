import Vapor

func routes(_ app: Application) throws {
    try app.register(collection: HealthController())
    try app.register(collection: PostController())
}
