import XCTest

@testable import TabulaConnections
@testable import TabulaDrivers
@testable import TabulaFoundation
@testable import TabulaSQL
@testable import TabulaSQLite
@testable import TabulaTransfer

/// An SQL INSERT export, run into an empty copy of its table, gives the same rows back. Hard values go through:
/// quotes, backslashes, line breaks, NULL next to an empty string, JSON, numbers, times, and bytes (#171): bytea,
/// MySQL's BLOB, VARBINARY and BIT, and SQLite blobs, including one that reads as text and one in a text column.
final class SQLExportRoundTripTests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment

    private func roundTrip(
        _ driver: any DatabaseDriver,
        schema: String,
        create: (String) -> String,
        seed: (String) -> String,
        compare: String
    ) async throws {
        let suffix = UUID().uuidString.prefix(8).lowercased()
        let source = TableRef(schema: schema, name: "export_src_\(suffix)")
        let copy = TableRef(schema: schema, name: "export_copy_\(suffix)")
        let d = driver.dialect
        try await runThenClean(
            driver,
            cleanup: ["DROP TABLE \(d.qualified(source))", "DROP TABLE \(d.qualified(copy))"]
        ) {
            _ = try await driver.execute(create(d.qualified(source)))
            _ = try await driver.execute(create(d.qualified(copy)))
            _ = try await driver.execute(seed(d.qualified(source)))
            let page = try await driver.execute("SELECT * FROM \(d.qualified(source)) ORDER BY id")
            let script = try ResultExporter.export(
                columns: page.columns,
                rows: page.rows,
                format: .sqlInsert,
                table: copy,
                binaryColumns: page.binaryColumns,
                dialect: d
            )
            for statement in d.split(script) {
                _ = try await driver.execute(statement)
            }
            let original = try await driver.execute(compare.replacingOccurrences(of: "$T", with: d.qualified(source)))
            let copied = try await driver.execute(compare.replacingOccurrences(of: "$T", with: d.qualified(copy)))
            XCTAssertEqual(copied.rows, original.rows, "the export didn't give the same rows back:\n\(script)")
            XCTAssertEqual(original.rows.count, 3)
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
        try await roundTrip(
            driver,
            schema: "public",
            create: {
                "CREATE TABLE \($0) (id int PRIMARY KEY, t text, j jsonb, b bytea, n numeric, f float8, ts timestamptz, d date, a int[], flag boolean, iv interval)"
            },
            seed: {
                """
                INSERT INTO \($0) VALUES
                  (1, 'it''s \\ a "test"' || chr(10) || 'line two', '{"k": "v''s", "n": [1, 2.5]}', '\\xdeadbeef00', 12.3400, 1.5, '2024-01-02 03:04:05.678+07', '0044-03-15 BC', '{1,NULL,3}', true, '-1 day +02:00'),
                  (2, '', NULL, '\\x', 0, 'NaN', '-infinity', 'infinity', '{}', false, '0'),
                  (3, NULL, '[]', NULL, -1e-20, -0.0, NULL, NULL, NULL, NULL, NULL)
                """
            },
            compare:
                "SELECT id, t, j::text, encode(b, 'hex'), n::text, f::text, ts::text, d::text, a::text, flag::text, iv::text FROM $T ORDER BY id"
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
        try await roundTrip(
            driver,
            schema: "tabula",
            create: {
                "CREATE TABLE \($0) (id INT PRIMARY KEY, t TEXT, j JSON, b BLOB, vb VARBINARY(8), bits BIT(8), n DECIMAL(20,6), f DOUBLE, ts DATETIME(3), flag TINYINT(1))"
            },
            seed: {
                """
                INSERT INTO \($0) VALUES
                  (1, CONCAT('it''s \\\\ a "test"', CHAR(10), 'line two'), '{"k": "v\\'s", "n": [1, 2.5]}', X'DEADBEEF00', X'41', b'10100101', 12.34, 1.5, '2024-01-02 03:04:05.678', 1),
                  (2, '', NULL, X'', X'', b'0', 0, -0.0, '1000-01-01 00:00:00', 0),
                  (3, NULL, '[]', NULL, NULL, NULL, -0.000001, 1e300, NULL, NULL)
                """
            },
            compare:
                "SELECT id, t, CAST(j AS CHAR), HEX(b), HEX(vb), HEX(bits), CAST(n AS CHAR), CAST(f AS CHAR), CAST(ts AS CHAR), flag FROM $T ORDER BY id"
        )
    }

    func testSQLite() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("tabula-export-\(UUID()).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        try await roundTrip(
            try SQLiteDriver(path: path),
            schema: "main",
            create: { "CREATE TABLE \($0) (id INTEGER PRIMARY KEY, t TEXT, b BLOB, r REAL, i INTEGER)" },
            seed: {
                "INSERT INTO \($0) VALUES (1, 'it''s \\ a \"test\"' || char(10) || 'two', x'DEADBEEF00', 1.5, 9007199254740993), (2, '', x'', -0.0, 0), (3, x'414243', 'text in a blob column', NULL, NULL)"
            },
            compare: "SELECT id, t, typeof(t), hex(b), typeof(b), r, i FROM $T ORDER BY id"
        )
    }
}
