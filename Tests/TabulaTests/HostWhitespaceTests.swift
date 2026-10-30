import XCTest

@testable import TabulaConnections
@testable import TabulaDrivers
@testable import TabulaFoundation

/// Spaces and line breaks around a host, as a paste often brings, are no part of it (#260).
final class HostWhitespaceTests: XCTestCase {
    func testTheHostIsTrimmed() {
        XCTAssertEqual(ConnectionConfig(kind: .postgres, host: " db.example.com\n").resolvedHost, "db.example.com")
        XCTAssertEqual(ConnectionConfig(kind: .postgres, host: "   ").resolvedHost, Defaults.host, "blank is local")
        // A user name may hold spaces; it stays as typed.
        XCTAssertEqual(ConnectionConfig(kind: .postgres, user: " app user ").user, " app user ")
    }

    func testConnectsDespiteSpacesAroundTheHost() async throws {
        guard let port = ProcessInfo.processInfo.environment["TABULA_TEST_PG_PORT"].flatMap(Int.init) else {
            throw XCTSkip("TABULA_TEST_PG_PORT not set")
        }
        var config = ConnectionConfig(
            kind: .postgres,
            host: "localhost \n",
            port: port,
            user: "tabula",
            database: "tabula"
        )
        config.connectTimeout = 5
        let driver = try await DriverFactory.connect(config, password: "tabula")
        let version = try await driver.serverVersion()
        XCTAssertFalse(version.isEmpty)
        await driver.close()
    }
}
