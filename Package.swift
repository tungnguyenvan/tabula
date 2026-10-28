// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tabula",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Tabula", targets: ["Tabula"]),
        .library(name: "TabulaCore", targets: ["TabulaCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0"),
        .package(url: "https://github.com/vapor/mysql-nio.git", from: "1.7.0"),
        .package(url: "https://github.com/swift-server/RediStack.git", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0"),
        .package(url: "https://github.com/orlandos-nl/MongoKitten.git", from: "7.16.3"),
    ],
    targets: [
        .target(
            name: "TabulaCore",
            dependencies: [
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "MySQLNIO", package: "mysql-nio"),
                .product(name: "RediStack", package: "RediStack"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "MongoKitten", package: "MongoKitten"),
                "llama",
            ],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        // llama.cpp, which runs local models inside the app. Fetched by scripts/fetch-llama.sh.
        .binaryTarget(name: "llama", path: "Vendor/llama.xcframework"),
        .executableTarget(name: "Tabula", dependencies: ["TabulaCore"]),
        // Times the drivers against the test containers: swift run -c release TabulaBench
        .executableTarget(name: "TabulaBench", dependencies: ["TabulaCore"]),
        .testTarget(name: "TabulaCoreTests", dependencies: ["TabulaCore"]),
    ],
    swiftLanguageModes: [.v5]
)
