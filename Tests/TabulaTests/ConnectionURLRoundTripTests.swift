import XCTest

@testable import TabulaFoundation

/// Copy URL, then pasting it back (or into another tool) gives the same connection and password.
final class ConnectionURLRoundTripTests: XCTestCase {
    private let passwords = ["p@ss:word/with#odd?chars", "100%sure", "spa ce+plus", "ünïcode✓", "back\\slash", "a&b=c"]

    func testPasswordsAndNamesSurvive() throws {
        let configs = [
            ConnectionConfig(
                kind: .postgres,
                host: "db.example.com",
                port: 5433,
                user: "app user",
                database: "shop db"
            ),
            ConnectionConfig(kind: .mysql, host: "10.0.0.5", port: 3307, user: "o'brien", database: "sales"),
            ConnectionConfig(kind: .postgres, host: "::1", port: 5432, user: "me@corp", database: "x"),
            // A link-local address with its zone: written %25en0, which used to stop the app (#234).
            ConnectionConfig(kind: .mysql, host: "fe80::1%en0", port: 3306, user: "u", database: "x"),
            ConnectionConfig(kind: .mongodb, host: "mongo.local", port: 27018, user: "root", database: "app"),
            ConnectionConfig(kind: .redis, host: "cache", port: 6380, user: "default", database: "3"),
        ]
        for config in configs {
            for password in passwords {
                let url = config.url(password: password)
                let parsed = try XCTUnwrap(ConnectionConfig.parse(connectionString: url), url)
                XCTAssertEqual(parsed.password, password, url)
                XCTAssertEqual(parsed.config.kind, config.kind, url)
                XCTAssertEqual(parsed.config.host, config.host, url)
                XCTAssertEqual(parsed.config.port, config.port, url)
                XCTAssertEqual(parsed.config.user, config.user, url)
                XCTAssertEqual(parsed.config.database, config.database, url)
            }
        }
    }

    func testZoneWrittenAsSomeToolsDo() throws {
        let parsed = try XCTUnwrap(ConnectionConfig.parse(connectionString: "postgresql://u@[fe80::1%en0]:5433/d"))
        XCTAssertEqual(parsed.config.host, "fe80::1%en0")
        XCTAssertEqual(parsed.config.port, 5433)
        let config = ConnectionConfig(kind: .postgres, host: "fe80::1%en0", port: 5432, user: "u", database: "d")
        XCTAssertEqual(config.url(), "postgresql://u@[fe80::1%25en0]:5432/d")
    }
}
