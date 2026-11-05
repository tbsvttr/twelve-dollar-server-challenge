import Vapor

struct HealthController: RouteCollection {
    private let startedAt = ContinuousClock.now

    func boot(routes: any RoutesBuilder) throws {
        routes.get("health", use: health)
    }

    @Sendable
    func health(request: Request) async -> HealthResponse {
        do {
            try await request.feedRepository.ping()
            return .healthy(uptimeSeconds: (ContinuousClock.now - startedAt).components.seconds)
        } catch {
            request.logger.error("Health check failed: \(String(reflecting: error))")
            return .degraded(error: String(describing: error))
        }
    }
}
