import XCTest

@testable import TabulaConnections
@testable import TabulaDrivers
@testable import TabulaFoundation
@testable import TabulaSQL
@testable import TabulaSQLite

/// The toolbar's row limit, on each server: a SELECT with the limit added still runs and gives the first rows of the
/// full result (#212); one that can't take a LIMIT at its end is left as it was.
final class RowLimitLiveTests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment
    private let limit = 2

    private func check(
        _ driver: any DatabaseDriver,
        table: String,
        limited: [String],
        unchanged: [String] = []
    ) async throws {
        let d = driver.dialect
        try await runThenClean(driver, cleanup: ["DROP TABLE \(table)"]) {
            _ = try await driver.execute("CREATE TABLE \(table) (id INT PRIMARY KEY, top INT, name VARCHAR(20))")
            _ = try await driver.execute(
                "INSERT INTO \(table) VALUES (1, 10, 'a'), (2, 20, 'b'), (3, 30, 'c'), (4, 40, 'd'), (5, 50, 'e')"
            )
            for template in limited + unchanged {
                let query = template.replacingOccurrences(of: "$T", with: table)
                let limited = d.applyingRowLimit(query, limit: limit)
                XCTAssertEqual(limited == query, unchanged.contains(template), "\(driver.kind): \(limited)")
                let full = try await driver.execute(query).rows
                let rows: [[String?]]
                do {
                    rows = try await driver.execute(limited).rows
                } catch {
                    XCTFail("\(driver.kind): \(limited) failed: \(error.localizedDescription)")
                    continue
                }
                XCTAssertEqual(rows, Array(full.prefix(limited == query ? full.count : limit)), limited)
            }
        }
    }

    private var common: [String] {
        [
            "SELECT * FROM $T ORDER BY id",
            // `top` is a plain name here, not SQL Server's SELECT TOP.
            "SELECT top, name FROM $T ORDER BY top DESC",
            "SELECT id FROM $T WHERE id > 1 ORDER BY id -- trailing note",
            "SELECT id FROM $T ORDER BY id /* block */ ;",
            "WITH x AS (SELECT id FROM $T) SELECT id FROM x ORDER BY id",
            "SELECT id FROM $T UNION ALL SELECT id FROM $T ORDER BY 1",
            "SELECT count(*) FROM $T",
            "SELECT name, count(*) FROM $T GROUP BY name ORDER BY name",
        ]
    }

    func testPostgres() async throws {
        guard let port = env["TABULA_TEST_PG_PORT"].flatMap(Int.init) else {
            throw XCTSkip("TABULA_TEST_PG_PORT not set")
        }
        let driver = try await DriverFactory.connect(
            ConnectionConfig(kind: .postgres, port: port, user: "tabula", database: "tabula"),
            password: "tabula"
        )
        try await check(
            driver,
            table: "row_limit_\(UUID().uuidString.prefix(8).lowercased())",
            limited: common + [
                "SELECT DISTINCT ON (name) name, id FROM $T ORDER BY name, id",
                // A column may be named lock (MySQL reserves the word); only LOCK IN SHARE MODE locks.
                "SELECT id AS lock FROM $T ORDER BY id",
                "SELECT id, sum(top) OVER w FROM $T WINDOW w AS (ORDER BY id) ORDER BY id",
            ],
            unchanged: ["SELECT id FROM $T ORDER BY id OFFSET 1", "SELECT id FROM $T ORDER BY id FOR SHARE"]
        )
    }

    func testMySQL() async throws {
        guard let port = env["TABULA_TEST_MYSQL_PORT"].flatMap(Int.init) else {
            throw XCTSkip("TABULA_TEST_MYSQL_PORT not set")
        }
        let driver = try await DriverFactory.connect(
            ConnectionConfig(kind: .mysql, port: port, user: "tabula", database: "tabula"),
            password: "tabula"
        )
        try await check(
            driver,
            table: "row_limit_\(UUID().uuidString.prefix(8).lowercased())",
            limited: common + [
                "SELECT name FROM $T GROUP BY name WITH ROLLUP ORDER BY name",
                "SELECT id FROM $T ORDER BY id # hash note",
            ],
            unchanged: [
                "SELECT id FROM $T ORDER BY id LOCK IN SHARE MODE",
                "SELECT id FROM $T ORDER BY id FOR SHARE",
            ]
        )
    }

    func testSQLite() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("tabula-limit-\(UUID()).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        try await check(
            try SQLiteDriver(path: path),
            table: "row_limit",
            limited: common + [
                "SELECT id, sum(top) OVER w FROM $T WINDOW w AS (ORDER BY id) ORDER BY id",
                "SELECT id AS lock FROM $T ORDER BY id",
            ],
            unchanged: ["SELECT id FROM $T ORDER BY id LIMIT -1 OFFSET 1"]
        )
    }
}
