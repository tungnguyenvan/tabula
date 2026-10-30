import XCTest

@testable import TabulaConnections
@testable import TabulaDrivers
@testable import TabulaFoundation
@testable import TabulaSQL
@testable import TabulaSQLite

/// The filter bar's operators on each engine, with values that are LIKE wildcards or escapes: % and _ match
/// themselves, a backslash, a quote and MySQL's escape "!" are plain characters, and text matching ignores case.
/// MySQL runs it twice, the second time with NO_BACKSLASH_ESCAPES (#220).
final class FilterOperatorsLiveTests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment
    private let values = ["50%", "500", "a_b", "aXb", "back\\slash", "back", "it's", "Mixed", "HÀ NỘI", "wow!_"]

    private func check(_ driver: any DatabaseDriver, schema: String) async throws {
        let d = try XCTUnwrap(driver.dialect.sql)
        let table = TableRef(schema: schema, name: "filters_" + UUID().uuidString.prefix(8).lowercased())
        _ = try await driver.execute("CREATE TABLE \(d.qualified(table)) (id INT PRIMARY KEY, v VARCHAR(40))")
        try await runThenClean(driver, cleanup: ["DROP TABLE \(d.qualified(table))"]) {
            for (index, value) in (values + [nil]).enumerated() {
                _ = try await driver.execute(
                    d.insert(table, values: [("id", String(index)), ("v", value)], binaryColumns: [])
                )
            }
            let stored = try await driver.execute("SELECT v FROM \(d.qualified(table)) ORDER BY id").rows.map { $0[0] }
            XCTAssertEqual(stored, values + [nil], "the values are stored as written")
            func matches(_ op: FilterRule.Operator, _ value: String) async throws -> [String?] {
                let condition = d.condition([FilterRule(column: "v", op: op, value: value)])
                return try await driver.execute("SELECT v FROM \(d.qualified(table)) WHERE \(condition) ORDER BY id")
                    .rows.map { $0[0] }
            }
            let contains = try await matches(.contains, "%")
            XCTAssertEqual(contains, ["50%"], "% is a character, not a wildcard")
            let starts = try await matches(.startsWith, "a_")
            XCTAssertEqual(starts, ["a_b"], "_ is a character, not one-of-anything")
            let slash = try await matches(.contains, "\\")
            XCTAssertEqual(slash, ["back\\slash"])
            let equal = try await matches(.equals, "back\\slash")
            XCTAssertEqual(equal, ["back\\slash"])
            let bang = try await matches(.endsWith, "!_")
            XCTAssertEqual(bang, ["wow!_"])
            let quote = try await matches(.contains, "'s")
            XCTAssertEqual(quote, ["it's"])
            let ends = try await matches(.endsWith, "B")
            XCTAssertEqual(ends, ["a_b", "aXb"], "text matching ignores case")
            let mixed = try await matches(.contains, "mix")
            XCTAssertEqual(mixed, ["Mixed"])
            let list = try await matches(.inList, "500, 50%")
            XCTAssertEqual(list, ["50%", "500"])
            let vietnamese = try await matches(.contains, "hà nội")
            XCTAssertEqual(vietnamese, ["HÀ NỘI"], "case is ignored beyond ASCII too")
            // "b" has no accented forms, so MySQL's accent-insensitive collations agree with the others.
            let notContains = try await matches(.notContains, "b")
            XCTAssertEqual(
                notContains,
                ["50%", "500", "it's", "Mixed", "HÀ NỘI", "wow!_"],
                "NULL is neither, as in SQL"
            )
        }
    }

    func testPostgres() async throws {
        guard let port = env["TABULA_TEST_PG_PORT"].flatMap(Int.init) else {
            throw XCTSkip("TABULA_TEST_PG_PORT not set")
        }
        try await check(
            try await DriverFactory.connect(
                ConnectionConfig(kind: .postgres, port: port, user: "tabula", database: "tabula"),
                password: "tabula"
            ),
            schema: "public"
        )
    }

    func testMySQL() async throws {
        guard let port = env["TABULA_TEST_MYSQL_PORT"].flatMap(Int.init) else {
            throw XCTSkip("TABULA_TEST_MYSQL_PORT not set")
        }
        try await check(
            try await DriverFactory.connect(
                ConnectionConfig(kind: .mysql, port: port, user: "tabula", database: "tabula"),
                password: "tabula"
            ),
            schema: "tabula"
        )
    }

    func testMySQLWithoutBackslashEscapes() async throws {
        guard let port = env["TABULA_TEST_MYSQL_PORT"].flatMap(Int.init) else {
            throw XCTSkip("TABULA_TEST_MYSQL_PORT not set")
        }
        let driver = try await DriverFactory.connect(
            ConnectionConfig(kind: .mysql, port: port, user: "tabula", database: "tabula"),
            password: "tabula"
        )
        _ = try await driver.execute(
            "SET SESSION sql_mode = CONCAT_WS(',', @@SESSION.sql_mode, 'NO_BACKSLASH_ESCAPES')"
        )
        try await check(driver, schema: "tabula")
    }

    func testSQLite() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("tabula-filters-\(UUID()).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        try await check(try SQLiteDriver(path: path), schema: "main")
    }
}
