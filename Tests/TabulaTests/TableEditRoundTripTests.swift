import XCTest

@testable import TabulaConnections
@testable import TabulaDrivers
@testable import TabulaFoundation
@testable import TabulaSQL
@testable import TabulaSQLite

/// A table tab shows each value as text and writes edited text back. Writing a cell's shown text back unchanged
/// must save the same value, for every type: one commit per column, each re-read.
final class TableEditRoundTripTests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment

    private func check(
        _ driver: any DatabaseDriver,
        schema: String,
        columns: [(type: String, value: String)]
    ) async throws {
        let d = try XCTUnwrap(driver.dialect.sql)
        let table = TableRef(schema: schema, name: "edit_back_" + UUID().uuidString.prefix(8).lowercased())
        let definitions = columns.enumerated().map { "c\($0.offset) \($0.element.type)" }.joined(separator: ", ")
        try await runThenClean(driver, cleanup: ["DROP TABLE \(d.qualified(table))"]) {
            _ = try await driver.execute("CREATE TABLE \(d.qualified(table)) (id INT PRIMARY KEY, \(definitions))")
            let values = columns.map(\.value).joined(separator: ", ")
            _ = try await driver.execute("INSERT INTO \(d.qualified(table)) VALUES (1, \(values))")
            let page = try await driver.execute(d.selectPage(TablePageRequest(table: table)))
            let row = try XCTUnwrap(page.rows.first)
            for index in 1..<page.columns.count {
                let label = "\(driver.kind) \(columns[index - 1].type)"
                let changes = TableChanges(
                    table: table,
                    columns: page.columns,
                    rows: [row],
                    documents: nil,
                    keyColumns: [0],
                    deleted: [],
                    edited: [0: [index: row[index]]],
                    inserted: [],
                    binaryColumns: page.binaryColumns
                )
                do {
                    try await driver.applyInTransaction(try d.plannedStatements(for: changes))
                } catch {
                    XCTFail("\(label): writing back \(row[index] ?? "NULL") failed: \(error.localizedDescription)")
                    continue
                }
                let after = try await driver.execute(d.selectPage(TablePageRequest(table: table)))
                XCTAssertEqual(after.rows.first?[index], row[index], label)
            }
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
        // Times with a zone are shown in the session's zone and must still save the same instant.
        _ = try await driver.execute("SET TIME ZONE 'Asia/Ho_Chi_Minh'")
        try await check(
            driver,
            schema: "public",
            columns: [
                ("float8", "0.1"), ("float4", "1.1"), ("float8", "'NaN'"), ("float8", "1e300"), ("numeric", "1e-20"),
                ("money", "-12.34"), ("timestamptz", "'2024-01-02 03:04:05.678+00'"),
                ("timestamp", "'0044-03-15 10:00 BC'"), ("timestamptz", "'0010-06-01 00:00+00 BC'"),
                ("date", "'infinity'"), ("time", "'24:00'"), ("timetz", "'12:30+05:30'"),
                ("interval", "'-1 day +02:00:00.5'"), ("interval", "'1 year 2 mons'"),
                ("jsonb", #"'{"b": [1, 2.50], "a": "é"}'"#), ("json", #"'{"b": 1,  "a": 2}'"#),
                ("bytea", #"'\xdead00'"#), ("int[]", "'[0:1]={7,8}'"),
                ("text[]", #"ARRAY['a,b', NULL, '', 'q"x', 'b\s']"#), ("inet", "'10.0.0.1/8'"),
                ("cidr", "'10.0.0.0/8'"),
                ("macaddr8", "'08:00:2b:01:02:03:04:05'"), ("bit(4)", "B'1010'"), ("varbit", "B'101'"),
                ("int4range", "'[1,5)'"), ("tstzrange", "'[2024-01-01 00:00+00,2024-02-01 00:00+00)'"),
                ("point", "point(1.5, -2)"), ("box", "'((0,0),(1,1))'"), ("tsvector", "'a:1 b:2'"),
                ("tsquery", "'a & !b'"), ("uuid", "'00000000-0000-0000-0000-000000000001'"), ("boolean", "true"),
                ("char(5)", "'ab'"), ("xml", "'<a/>'"), ("oid", "42"), ("pg_lsn", "'1/0'"),
                ("int4multirange", "'{[1,2), [5,6)}'"),
                ("timestamptz[]", "ARRAY['2024-01-02 03:04:05+00'::timestamptz]"),
                ("jsonb[]", #"ARRAY['{"k": 1}'::jsonb]"#), ("numeric(10,2)", "1.5"), ("bigint", "-9223372036854775808"),
            ]
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
            schema: "tabula",
            columns: [
                ("DOUBLE", "0.1"), ("FLOAT", "1.1"), ("DECIMAL(30,10)", "1e-10"),
                ("DATETIME(6)", "'2024-01-02 03:04:05.000006'"), ("TIMESTAMP(3)", "'2024-01-02 03:04:05.678'"),
                ("TIME(2)", "'-838:59:59.00'"), ("YEAR", "2024"), ("DATE", "'1000-01-01'"),
                ("JSON", #"'{"b": [1, 2.50], "a": "é"}'"#), ("BIT(8)", "b'10100101'"), ("BIT(1)", "b'1'"),
                ("ENUM('a','b c')", "'b c'"), ("SET('x','y')", "'x,y'"), ("BLOB", "X'00FF'"), ("BINARY(4)", "X'61'"),
                ("VARCHAR(10)", "'tail  '"), ("CHAR(5)", "'ab'"), ("TINYINT(1)", "1"),
                ("BIGINT UNSIGNED", "18446744073709551615"), ("TEXT", #"'a\\b'"#),
                // Spatial values are bytes (SRID and WKB), shown as hex (#230).
                ("GEOMETRY", "ST_GeomFromText('POINT(1 2)')"), ("POINT", "ST_GeomFromText('POINT(-1.5 0)', 4326)"),
            ]
        )
    }

    func testSQLite() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("tabula-edit-\(UUID()).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        try await check(
            try SQLiteDriver(path: path),
            schema: "main",
            columns: [
                ("REAL", "0.1"), ("REAL", "1e300"), ("NUMERIC", "'1.50'"), ("INTEGER", "9223372036854775807"),
                ("TEXT", "'x'"), ("BLOB", "x'00ff'"), ("", "'untyped'"), ("DATETIME", "'2024-01-02 03:04:05'"),
                ("BOOLEAN", "1"), ("INTEGER", "1.5"),
            ]
        )
    }
}
