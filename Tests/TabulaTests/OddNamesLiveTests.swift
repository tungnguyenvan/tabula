import XCTest

@testable import TabulaConnections
@testable import TabulaDrivers
@testable import TabulaFoundation
@testable import TabulaSQL
@testable import TabulaSQLite

/// Tables and columns with names that need quoting, browsed and edited the way a table tab does it: listed, their
/// columns and indexes read (index columns by their names, #222), a page and its count loaded, and rows inserted,
/// edited and deleted.
final class OddNamesLiveTests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment
    private let columnNames = ["id", "it's", "dq\"col", "bt`col", "a.b", "sp ace", "back\\slash", "Tên Hàng"]

    private func check(_ driver: any DatabaseDriver, schema: String, tableName: String) async throws {
        let d = try XCTUnwrap(driver.dialect.sql)
        let table = TableRef(schema: schema, name: tableName)
        let definitions = columnNames.map { d.quoteIdentifier($0) + ($0 == "id" ? " INT PRIMARY KEY" : " VARCHAR(20)") }
        try await runThenClean(driver, cleanup: ["DROP TABLE \(d.qualified(table))"]) {
            _ = try await driver.execute("CREATE TABLE \(d.qualified(table)) (\(definitions.joined(separator: ", ")))")
            _ = try await driver.execute(
                "CREATE INDEX \(d.quoteIdentifier("ix " + tableName.prefix(20))) ON \(d.qualified(table)) (\(d.quoteIdentifier("it's")))"
            )
            let listed = try await driver.tables(in: schema).map(\.name)
            XCTAssertTrue(listed.contains(tableName), "\(listed)")
            let columns = try await driver.columns(of: table)
            XCTAssertEqual(columns.map(\.name), columnNames)
            XCTAssertEqual(columns.filter(\.isPrimaryKey).map(\.name), ["id"])
            if driver.kind == .postgres {
                // An expression index: PostgreSQL writes it with ", " inside.
                _ = try await driver.execute(
                    "CREATE INDEX ON \(d.qualified(table)) (coalesce(\(d.quoteIdentifier("a.b")), \(d.quoteIdentifier("sp ace"))), id)"
                )
            }
            let indexes = try await driver.indexes(of: table)
            XCTAssertTrue(indexes.contains { $0.columns == ["it's"] }, "\(indexes)")
            if driver.kind == .postgres {
                XCTAssertTrue(
                    indexes.contains { $0.columns == [#"COALESCE("a.b", "sp ace")"#, "id"] },
                    "\(indexes.map(\.columns))"
                )
            }

            let values: [String?] = ["1", "x'y", "q\"q", "b`b", "d.d", "s s", "c\\c", "Hà Nội"]
            let insert = d.insert(
                table,
                values: Array(zip(columnNames, values)).map { (column: $0.0, value: $0.1) },
                binaryColumns: []
            )
            _ = try await driver.execute(insert)
            let page = try await driver.execute(d.selectPage(TablePageRequest(table: table, orderBy: "it's")))
            XCTAssertEqual(page.columns, columnNames)
            XCTAssertEqual(page.rows, [values])
            let count = try await driver.countRows(
                table,
                filter: d.condition([FilterRule(column: "Tên Hàng", value: "Hà Nội")])
            )
            XCTAssertEqual(count, 1)

            var edited = values
            edited[1] = "new"
            edited[7] = nil
            let changes = TableChanges(
                table: table,
                columns: columnNames,
                rows: [values],
                documents: nil,
                keyColumns: [0],
                deleted: [],
                edited: [0: [1: "new", 7: nil]],
                inserted: [[0: "2", 6: "z\\z"]],
                binaryColumns: []
            )
            try await driver.applyInTransaction(try d.plannedStatements(for: changes))
            let after = try await driver.execute(d.selectPage(TablePageRequest(table: table, orderBy: "id")))
            XCTAssertEqual(after.rows.first, edited)
            XCTAssertEqual(after.rows.last?[6], "z\\z")

            let delete = TableChanges(
                table: table,
                columns: columnNames,
                rows: after.rows,
                documents: nil,
                keyColumns: [0],
                deleted: [0, 1],
                edited: [:],
                inserted: [],
                binaryColumns: []
            )
            try await driver.applyInTransaction(try d.plannedStatements(for: delete))
            let empty = try await driver.countRows(table, filter: nil)
            XCTAssertEqual(empty, 0)
        }
    }

    private var oddName: String { "odd 'n\" `t.b\\ " + UUID().uuidString.prefix(6).lowercased() }

    func testPostgres() async throws {
        guard let port = env["TABULA_TEST_PG_PORT"].flatMap(Int.init) else {
            throw XCTSkip("TABULA_TEST_PG_PORT not set")
        }
        let driver = try await DriverFactory.connect(
            ConnectionConfig(kind: .postgres, port: port, user: "tabula", database: "tabula"),
            password: "tabula"
        )
        try await check(driver, schema: "public", tableName: oddName)
    }

    func testMySQL() async throws {
        guard let port = env["TABULA_TEST_MYSQL_PORT"].flatMap(Int.init) else {
            throw XCTSkip("TABULA_TEST_MYSQL_PORT not set")
        }
        let driver = try await DriverFactory.connect(
            ConnectionConfig(kind: .mysql, port: port, user: "tabula", database: "tabula"),
            password: "tabula"
        )
        // MySQL table names can't end with a space or hold "/", "\" or "."; it maps them to file names.
        try await check(driver, schema: "tabula", tableName: "odd 'n\" `t " + UUID().uuidString.prefix(6).lowercased())
    }

    func testSQLite() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("tabula-odd-\(UUID()).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        try await check(try SQLiteDriver(path: path), schema: "main", tableName: oddName)
    }
}
