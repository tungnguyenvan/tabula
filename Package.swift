// swift-tools-version: 6.0
import PackageDescription

/// Each module owns one concern and lists every module and product it imports:
///
///     TabulaFoundation   connection settings, results, shared values; no database code
///     TabulaStorage      saved connections (Keychain) and workspace state
///     TabulaSQL          query languages: lexing, splitting, formatting, completion, dialects
///     TabulaDrivers      the driver protocol and what every driver shares: catalogs, logging, cancellation, SSH
///     Tabula<Engine>     one module per database: Postgres, MySQL, SQLite, Mongo, Redis
///     TabulaConnections  opens the DatabaseDriver for a connection (every engine except Redis, which has its own
///                        workspace and driver API)
///     TabulaTransfer     dump, restore and export
///     TabulaAI           providers, chat history and the assistant's tools
///     TabulaUpdates      the release feed
let package = Package(
    name: "Tabula",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Tabula", targets: ["Tabula"])
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0"),
        .package(url: "https://github.com/vapor/mysql-nio.git", from: "1.7.0"),
        .package(url: "https://github.com/swift-server/RediStack.git", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
        .package(url: "https://github.com/orlandos-nl/MongoKitten.git", from: "7.16.3"),
        .package(url: "https://github.com/orlandos-nl/BSON.git", from: "8.0.0"),
    ],
    targets: [
        .target(name: "TabulaFoundation"),
        .target(name: "TabulaStorage", dependencies: ["TabulaFoundation"]),
        .target(name: "TabulaSQL", dependencies: ["TabulaFoundation"]),
        .target(
            name: "TabulaDrivers",
            dependencies: [
                "TabulaFoundation",
                "TabulaSQL",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
            ]
        ),
        .target(
            name: "TabulaPostgres",
            dependencies: [
                "TabulaFoundation",
                "TabulaSQL",
                "TabulaDrivers",
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .target(
            name: "TabulaMySQL",
            dependencies: [
                "TabulaFoundation",
                "TabulaSQL",
                "TabulaDrivers",
                .product(name: "MySQLNIO", package: "mysql-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .target(
            name: "TabulaSQLite",
            dependencies: ["TabulaFoundation", "TabulaSQL", "TabulaDrivers"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "TabulaMongo",
            dependencies: [
                "TabulaFoundation",
                "TabulaSQL",
                "TabulaDrivers",
                .product(name: "MongoKitten", package: "MongoKitten"),
                .product(name: "MongoClient", package: "MongoKitten"),
                .product(name: "BSON", package: "BSON"),
                .product(name: "NIOCore", package: "swift-nio"),
            ]
        ),
        .target(
            name: "TabulaRedis",
            dependencies: [
                "TabulaFoundation",
                "TabulaDrivers",
                .product(name: "RediStack", package: "RediStack"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .target(
            name: "TabulaConnections",
            dependencies: [
                "TabulaFoundation",
                "TabulaDrivers",
                "TabulaPostgres",
                "TabulaMySQL",
                "TabulaSQLite",
                "TabulaMongo",
            ]
        ),
        .target(name: "TabulaTransfer", dependencies: ["TabulaFoundation", "TabulaSQL", "TabulaDrivers"]),
        .target(name: "TabulaUpdates", dependencies: ["TabulaFoundation"]),
        .target(name: "TabulaAI", dependencies: ["TabulaFoundation", "TabulaSQL", "TabulaDrivers", "llama"]),
        // llama.cpp, which runs local models inside the app. Fetched by scripts/fetch-llama.sh.
        .binaryTarget(name: "llama", path: "Vendor/llama.xcframework"),
        .executableTarget(
            name: "Tabula",
            dependencies: [
                "TabulaFoundation",
                "TabulaStorage",
                "TabulaSQL",
                "TabulaDrivers",
                "TabulaMongo",
                "TabulaRedis",
                "TabulaConnections",
                "TabulaTransfer",
                "TabulaAI",
                "TabulaUpdates",
            ]
        ),
        // Times the drivers against the test containers: swift run -c release TabulaBench
        .executableTarget(
            name: "TabulaBench",
            dependencies: [
                "TabulaFoundation",
                "TabulaSQL",
                "TabulaDrivers",
                "TabulaConnections",
                "TabulaMongo",
                "TabulaRedis",
            ]
        ),
        .testTarget(
            name: "TabulaTests",
            dependencies: [
                "TabulaFoundation",
                "TabulaStorage",
                "TabulaSQL",
                "TabulaDrivers",
                "TabulaPostgres",
                "TabulaMySQL",
                "TabulaSQLite",
                "TabulaMongo",
                "TabulaRedis",
                "TabulaConnections",
                "TabulaTransfer",
                "TabulaAI",
                "TabulaUpdates",
                .product(name: "BSON", package: "BSON"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
