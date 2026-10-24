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
    ],
    targets: [
        .target(
            name: "TabulaCore",
            dependencies: [
                .product(name: "PostgresNIO", package: "postgres-nio"),
                .product(name: "MySQLNIO", package: "mysql-nio"),
            ],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(name: "Tabula", dependencies: ["TabulaCore"]),
        .testTarget(name: "TabulaCoreTests", dependencies: ["TabulaCore"]),
    ],
    swiftLanguageModes: [.v5]
)
