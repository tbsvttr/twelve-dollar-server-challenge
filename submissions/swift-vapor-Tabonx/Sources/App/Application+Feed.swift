import Vapor

extension Application {
    private struct FeedRepositoryKey: StorageKey {
        typealias Value = FeedRepository
    }

    /// The repository every controller uses. `configure` sets it once at startup.
    var feedRepository: FeedRepository {
        get {
            guard let repository = storage[FeedRepositoryKey.self] else {
                fatalError("configure(_:_:) sets feedRepository before the server starts")
            }
            return repository
        }
        set { storage[FeedRepositoryKey.self] = newValue }
    }
}

extension Request {
    var feedRepository: FeedRepository { application.feedRepository }
}
