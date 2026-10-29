// swift-tools-version: 6.0
import PackageDescription

/// Each module owns one concern and depends only on the modules listed for it:
///
///     TabulaFoundation   connection settings, results, shared values; no database code
///     TabulaStorage      saved connections (Keychain) and workspace state
///     TabulaSQL          query languages: lexing, splitting, formatting, completion, dialects
///     TabulaDrivers      the driver protocol and what every driver shares: catalogs, logging, cancellation, SSH
///     Tabula<Engine>     one module per database: Postgres, MySQL, SQLite, Mongo, Redis
///     TabulaConnections  opens the driver for a connection's database (the only module that knows every engine)
///     TabulaTransfer     dump, restore and export
///     TabulaAI           providers, chat history and the assistant's tools
///     TabulaUpdates      the release feed
let package = Package(
    name: "Tabula",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Tabula", targets: ["Tabula"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0"),
        .package(url: "https://github.com/vapor/mysql-nio.git", from: "1.7.0"),
        .package(url: "https://github.com/swift-server/RediStack.git", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0"),
        .package(url: "https://github.com/orlandos-nl/MongoKitten.git", from: "7.16.3"),
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
            dependencies: ["TabulaDrivers", .product(name: "PostgresNIO", package: "postgres-nio")]
        ),
        .target(
            name: "TabulaMySQL",
            dependencies: ["TabulaDrivers", .product(name: "MySQLNIO", package: "mysql-nio")]
        ),
        .target(
            name: "TabulaSQLite",
            dependencies: ["TabulaDrivers"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "TabulaMongo",
            dependencies: ["TabulaDrivers", .product(name: "MongoKitten", package: "MongoKitten")]
        ),
        .target(
            name: "TabulaRedis",
            dependencies: ["TabulaDrivers", .product(name: "RediStack", package: "RediStack")]
        ),
        .target(
            name: "TabulaConnections",
            dependencies: ["TabulaDrivers", "TabulaPostgres", "TabulaMySQL", "TabulaSQLite", "TabulaMongo"]
        ),
        .target(name: "TabulaTransfer", dependencies: ["TabulaDrivers"]),
        .target(name: "TabulaUpdates", dependencies: ["TabulaFoundation"]),
        .target(name: "TabulaAI", dependencies: ["TabulaDrivers", "TabulaUpdates", "llama"]),
        // llama.cpp, which runs local models inside the app. Fetched by scripts/fetch-llama.sh.
        .binaryTarget(name: "llama", path: "Vendor/llama.xcframework"),
        .executableTarget(
            name: "Tabula",
            dependencies: [
                "TabulaFoundation", "TabulaStorage", "TabulaSQL", "TabulaDrivers", "TabulaPostgres", "TabulaMySQL",
                "TabulaSQLite", "TabulaMongo", "TabulaRedis", "TabulaConnections", "TabulaTransfer", "TabulaAI",
                "TabulaUpdates",
            ]
        ),
        // Times the drivers against the test containers: swift run -c release TabulaBench
        .executableTarget(name: "TabulaBench", dependencies: ["TabulaConnections", "TabulaMongo", "TabulaRedis"]),
        .testTarget(
            name: "TabulaCoreTests",
            dependencies: [
                "TabulaFoundation", "TabulaStorage", "TabulaSQL", "TabulaDrivers", "TabulaPostgres", "TabulaMySQL",
                "TabulaSQLite", "TabulaMongo", "TabulaRedis", "TabulaConnections", "TabulaTransfer", "TabulaAI",
                "TabulaUpdates",
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
