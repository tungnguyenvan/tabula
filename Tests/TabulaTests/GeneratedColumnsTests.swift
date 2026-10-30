import XCTest

@testable import Tabula
@testable import TabulaConnections
@testable import TabulaDrivers
@testable import TabulaFoundation
@testable import TabulaSQL
@testable import TabulaSQLite

/// Columns the server computes are listed, marked, and left out when a row is duplicated, which the server
/// would refuse otherwise (#250).
@MainActor
final class GeneratedColumnsTests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment

    private func duplicate(
        _ driver: any DatabaseDriver,
        table: TableRef,
        create: String,
        generated: Set<String>,
        compare: String
    ) async throws {
        let d = try XCTUnwrap(driver.dialect.sql)
        try await runThenClean(driver, cleanup: ["DROP TABLE \(d.qualified(table))"]) {
            _ = try await driver.execute(create.replacingOccurrences(of: "$T", with: d.qualified(table)))
            _ = try await driver.execute("INSERT INTO \(d.qualified(table)) (id, n) VALUES (1, 5)")
            let columns = try await driver.columns(of: table)
            XCTAssertEqual(Set(columns.filter(\.isGenerated).map(\.name)), generated, "\(driver.kind)")
            XCTAssertTrue(columns.contains { $0.name == "twice" }, "\(driver.kind): generated columns are listed")

            let model = TableTabModel(table: table, driver: driver, connectionTag: .local)
            await model.reload()
            XCTAssertNil(model.error)
            model.duplicateRows(IndexSet(integer: 0))
            // The copy gets its own key; this table's key has no default.
            if let id = model.resultColumns.firstIndex(of: "id") {
                model.setValue("2", row: 1, column: id)
            }
            await model.commit()
            XCTAssertNil(model.error, "\(driver.kind)")
            let rows = try await driver.execute(compare.replacingOccurrences(of: "$T", with: d.qualified(table))).rows
            XCTAssertEqual(rows, [["1", "5", "10"], ["2", "5", "10"]], "\(driver.kind)")
        }
    }

    func testPostgres() async throws {
        guard let port = env["TABULA_TEST_PG_PORT"].flatMap(Int.init) else {
            throw XCTSkip("TABULA_TEST_PG_PORT not set")
        }
        let driver = try await DriverFactory.connect(
            ConnectionConfig(kind: .postgres, port: port, user: "tabula", database: "tabula"),
            password: "tabula"
        )
        try await duplicate(
            driver,
            table: TableRef(schema: "public", name: "generated_" + UUID().uuidString.prefix(8).lowercased()),
            create:
                "CREATE TABLE $T (id int PRIMARY KEY, n int, twice int GENERATED ALWAYS AS (n * 2) STORED, seq bigint GENERATED ALWAYS AS IDENTITY)",
            generated: ["twice", "seq"],
            compare: "SELECT id, n, twice FROM $T ORDER BY id"
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
        try await duplicate(
            driver,
            table: TableRef(schema: "tabula", name: "generated_" + UUID().uuidString.prefix(8).lowercased()),
            create:
                "CREATE TABLE $T (id INT PRIMARY KEY, n INT, twice INT AS (n * 2) STORED, v INT AS (n + 1) VIRTUAL, at DATETIME DEFAULT (NOW()))",
            generated: ["twice", "v"],
            compare: "SELECT id, n, twice FROM $T ORDER BY id"
        )
    }

    func testSQLite() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("tabula-gen-\(UUID()).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        try await duplicate(
            try SQLiteDriver(path: path),
            table: TableRef(schema: "main", name: "generated"),
            create:
                "CREATE TABLE $T (id INTEGER PRIMARY KEY, n INT, twice INT GENERATED ALWAYS AS (n * 2) STORED, v INT AS (n + 1))",
            generated: ["twice", "v"],
            compare: "SELECT id, n, twice FROM $T ORDER BY id"
        )
    }
}
