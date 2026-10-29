import XCTest

@testable import TabulaConnections
@testable import TabulaDrivers
@testable import TabulaFoundation

/// Result columns carry where they came from, which editing a query's result relies on: an alias names the real
/// column, and a computed column names none.
final class ResultColumnOriginsTests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment

    func testPostgresOrigins() async throws {
        guard let port = env["TABULA_TEST_PG_PORT"].flatMap(Int.init) else {
            throw XCTSkip("TABULA_TEST_PG_PORT not set")
        }
        let driver = try await DriverFactory.connect(
            ConnectionConfig(kind: .postgres, port: port, user: "tabula", database: "tabula"),
            password: "tabula"
        )
        let table = "origins_" + UUID().uuidString.prefix(8).lowercased()
        _ = try await driver.execute("CREATE TABLE \(table) (a int, b text)")
        let oid = try await driver.execute("SELECT '\(table)'::regclass::oid").rows.first?.first ?? nil
        let result = try await driver.execute("SELECT b AS label, a, a + 1 AS next FROM \(table)")
        XCTAssertEqual(result.columns, ["label", "a", "next"])
        XCTAssertEqual(
            result.origins,
            [
                QueryColumnOrigin(tableOID: UInt32(oid ?? "") ?? 0, attribute: 2),
                QueryColumnOrigin(tableOID: UInt32(oid ?? "") ?? 0, attribute: 1),
                QueryColumnOrigin(tableOID: 0, attribute: 0),
            ]
        )
        _ = try await driver.execute("DROP TABLE \(table)")
        await driver.close()
    }

    func testMySQLOrigins() async throws {
        guard let port = env["TABULA_TEST_MYSQL_PORT"].flatMap(Int.init) else {
            throw XCTSkip("TABULA_TEST_MYSQL_PORT not set")
        }
        let driver = try await DriverFactory.connect(
            ConnectionConfig(kind: .mysql, port: port, user: "tabula", database: "tabula"),
            password: "tabula"
        )
        let table = "origins_" + UUID().uuidString.prefix(8).lowercased()
        // The connection must be closed whatever happens: MySQLNIO asserts on one dropped open.
        do {
            _ = try await driver.execute("CREATE TABLE \(table) (a INT, b VARCHAR(10))")
            let result = try await driver.execute("SELECT b AS label, t.a, a + 1 AS next FROM \(table) AS t")
            // The table is empty: the columns still come back (they used to arrive only with rows).
            XCTAssertEqual(result.columns, ["label", "a", "next"])
            XCTAssertEqual(result.rows.count, 0)
            let origins = try XCTUnwrap(result.mysqlOrigins)
            XCTAssertEqual(origins.map(\.schema), ["tabula", "tabula", ""])
            XCTAssertEqual(origins.map(\.table), ["t", "t", ""], "the alias the query used")
            XCTAssertEqual(origins.map(\.originalTable), [table, table, ""])
            XCTAssertEqual(origins.map(\.originalName), ["b", "a", ""])
            _ = try await driver.execute("DROP TABLE \(table)")
        } catch {
            _ = try? await driver.execute("DROP TABLE IF EXISTS \(table)")
            await driver.close()
            throw error
        }
        await driver.close()
    }
}
