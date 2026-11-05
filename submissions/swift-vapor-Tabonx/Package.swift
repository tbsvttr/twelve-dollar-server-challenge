// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "feed-server",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "App", targets: ["App"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/vapor.git", exact: "4.122.3"),
        .package(url: "https://github.com/vapor/jwt.git", exact: "5.2.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
    ],
    targets: [
        .executableTarget(
            name: "App",
            dependencies: [
                .product(name: "Vapor", package: "vapor"),
                .product(name: "JWT", package: "jwt"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "AppTests",
            dependencies: [
                "App",
                .product(name: "VaporTesting", package: "vapor"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
    ]
)
