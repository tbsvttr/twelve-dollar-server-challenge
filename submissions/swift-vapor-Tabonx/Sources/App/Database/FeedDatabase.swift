import Foundation
import GRDB
import Vapor

enum FeedDatabase {
    /// Opens the database as a WAL pool: concurrent readers and one serialized writer.
    static func openPool(at path: String) throws -> DatabasePool {
        // SQLite would create an empty file, and every query would then fail with "no such table".
        guard FileManager.default.fileExists(atPath: path) else {
            throw DatabaseError(resultCode: .SQLITE_CANTOPEN, message: "database file not found: \(path)")
        }
        var configuration = Configuration()
        // A commit survives a crash of the process. Only a power cut can lose the last commits.
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        configuration.busyMode = .timeout(5)
        // GRDB defaults to .userInitiated. On Linux, libdispatch then tries to raise the thread's
        // priority, which an unprivileged service can't do, and logs a failure for every worker.
        configuration.qos = .default
        // SQLite does its work on these threads, so more readers than CPUs only adds waiting.
        configuration.maximumReaderCount = max(2, ProcessInfo.processInfo.activeProcessorCount)
        // The spec takes the user id from the token and doesn't look it up.
        configuration.foreignKeysEnabled = false
        return try DatabasePool(path: path, configuration: configuration)
    }
}

/// Folds the WAL back into the database file and closes the pool on shutdown, so the file on disk
/// is complete once the process exits.
struct DatabaseLifecycle: LifecycleHandler {
    let pool: DatabasePool

    func shutdownAsync(_ application: Application) async {
        do {
            try await pool.barrierWriteWithoutTransaction { try $0.checkpoint(.truncate) }
            try pool.close()
        } catch {
            application.logger.error("Closing the database failed: \(String(reflecting: error))")
        }
    }
}
