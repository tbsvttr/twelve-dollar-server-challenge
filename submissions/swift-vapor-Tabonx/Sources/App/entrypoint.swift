import Foundation
import Logging
import Vapor

@main
enum Entrypoint {
    static func main() async throws {
        var environment = try Environment.detect()
        try LoggingSystem.bootstrap(from: &environment)

        let app = try await Application.make(environment)
        do {
            let configuration = try ServerConfiguration(environment: ProcessInfo.processInfo.environment)
            try await configure(app, configuration)
            try await app.execute()
        } catch {
            app.logger.critical("Server stopped: \(String(reflecting: error))")
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}
