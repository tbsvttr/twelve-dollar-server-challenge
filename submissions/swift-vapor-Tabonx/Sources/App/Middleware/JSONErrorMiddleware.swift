import Vapor

/// Turns every error into `{"error":"..."}`. It runs first, so it also sees the router's 404.
/// Unexpected errors are logged and reach the client as a plain 500, without their details.
struct JSONErrorMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        do {
            return try await next.respond(to: request)
        } catch let error as APIError {
            return ErrorResponse(status: error.status, message: error.reason).makeResponse()
        } catch let error as any AbortError where error.status == .notFound {
            return ErrorResponse(status: .notFound, message: APIError.notFound.reason).makeResponse()
        } catch let error as any AbortError {
            return ErrorResponse(status: error.status, message: error.status.reasonPhrase.lowercased()).makeResponse()
        } catch {
            request.logger.error("Unhandled error on \(request.url.path): \(String(reflecting: error))")
            return ErrorResponse(status: .internalServerError, message: "internal server error").makeResponse()
        }
    }
}
