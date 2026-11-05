/// Settings read from the environment. A missing or invalid value stops the server at startup.
struct ServerConfiguration: Sendable {
    var databasePath: String
    var jwtSecret: String
    var host = "0.0.0.0"
    var port = 80

    init(databasePath: String, jwtSecret: String) {
        self.databasePath = databasePath
        self.jwtSecret = jwtSecret
    }

    init(environment: [String: String]) throws {
        guard let databasePath = environment["SQLITE_PATH"], !databasePath.isEmpty else {
            throw ConfigurationError.missing("SQLITE_PATH")
        }
        guard let jwtSecret = environment["JWT_SECRET"], !jwtSecret.isEmpty else {
            throw ConfigurationError.missing("JWT_SECRET")
        }
        self.init(databasePath: databasePath, jwtSecret: jwtSecret)

        if let host = environment["HOST"] { self.host = host }
        if let rawPort = environment["PORT"] {
            guard let port = Int(rawPort), (1...65535).contains(port) else {
                throw ConfigurationError.invalid("PORT", rawPort)
            }
            self.port = port
        }
    }
}

enum ConfigurationError: Error, CustomStringConvertible {
    case missing(String)
    case invalid(String, String)

    var description: String {
        switch self {
        case .missing(let name): "environment variable \(name) is required"
        case .invalid(let name, let value): "environment variable \(name) has an invalid value: \(value)"
        }
    }
}
