// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "feed",
    // Linux only (io_uring, eventfd). Two C targets: io_uring through its system calls (no liburing), and SQLite's
    // amalgamation, which build.sh fetches (pinned, sha256-checked), compiled inside btree.c so that BTree can read
    // SQLite's B-trees directly.
    targets: [
        .target(
            name: "CIORing",
            path: "Sources/CIORing",
            cSettings: [.unsafeFlags(["-O2"])]
        ),
        .target(
            name: "CSQLite",
            path: "Sources/CSQLite",
            exclude: ["sqlite3.c"],
            cSettings: [
                // Two connections, each used by one thread (the loop's, the checkpointer's): multi-thread mode. No
                // memory statistics, no features the server doesn't use.
                .define("SQLITE_THREADSAFE", to: "2"),
                .define("SQLITE_DEFAULT_MEMSTATUS", to: "0"),
                .define("SQLITE_DEFAULT_WAL_SYNCHRONOUS", to: "1"),
                .define("SQLITE_DQS", to: "0"),
                .define("SQLITE_LIKE_DOESNT_MATCH_BLOBS"),
                .define("SQLITE_MAX_EXPR_DEPTH", to: "0"),
                .define("SQLITE_OMIT_DEPRECATED"),
                .define("SQLITE_OMIT_LOAD_EXTENSION"),
                .define("SQLITE_OMIT_PROGRESS_CALLBACK"),
                .define("SQLITE_OMIT_SHARED_CACHE"),
                .define("SQLITE_USE_ALLOCA"),
                .unsafeFlags(["-O3", "-Wno-everything"]),
            ]
        ),
        // Cursors over SQLite's B-trees and the record format, for the read queries.
        .target(
            name: "BTree",
            dependencies: ["CSQLite"],
            path: "Sources/BTree",
            swiftSettings: [
                .enableExperimentalFeature("Lifetimes"),
                .unsafeFlags(["-Ounchecked", "-enforce-exclusivity=unchecked"], .when(configuration: .release)),
            ]
        ),
        // The Linux calls Glibc's module leaves out, declared in Swift with `@_extern(c)`.
        .target(
            name: "Syscalls",
            path: "Sources/Syscalls",
            swiftSettings: [.enableExperimentalFeature("Extern")]
        ),
        .executableTarget(
            name: "Feed",
            dependencies: ["CIORing", "CSQLite", "BTree", "Syscalls"],
            path: "Sources/Feed",
            swiftSettings: [
                // The server is one thread: its state is the main actor's. The value types that hold no shared state
                // (bytes, JSON, HTTP, buffers, the store and the ring a reactor owns) are declared nonisolated, so code
                // in them carries no main-actor checks.
                .defaultIsolation(MainActor.self),
                .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
                .enableUpcomingFeature("InferIsolatedConformances"),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("MemberImportVisibility"),
                // `@_lifetime` on the ~Escapable views (an HTTP request, the JSON parser) and on the Spans the
                // noncopyable buffers lend out.
                .enableExperimentalFeature("Lifetimes"),
                .unsafeFlags(["-Ounchecked", "-enforce-exclusivity=unchecked"], .when(configuration: .release)),
            ]
        ),
    ]
)
