import XCTest

@testable import Tabula
@testable import TabulaConnections
@testable import TabulaDrivers
@testable import TabulaFoundation
@testable import TabulaSQL
@testable import TabulaSQLite

/// Bytes show as `\x` hex on every database and go back as bytes (#171).
@MainActor
final class BinaryValuesTests: XCTestCase {
    func testLiteralsForBinaryColumns() {
        XCTAssertEqual(BinaryText.text([0xDE, 0xAD, 0x00]), "\\xdead00")
        XCTAssertEqual(BinaryText.text([]), "\\x")
        XCTAssertEqual(BinaryText.hexDigits("\\xdead00"), "dead00")
        XCTAssertNil(BinaryText.hexDigits("\\xabc"), "an odd number of digits isn't bytes")
        XCTAssertNil(BinaryText.hexDigits("hello"))

        let mysql = SQLDialect(flavor: .mysql)
        XCTAssertEqual(mysql.literal("\\xdead00", binary: true), "X'DEAD00'")
        XCTAssertEqual(mysql.literal("\\x", binary: true), "X''")
        XCTAssertEqual(mysql.literal("typed text", binary: true), "'typed text'", "text typed into a binary column")
        XCTAssertEqual(mysql.literal("\\xdead00", binary: false), "'\\\\xdead00'", "text that only looks like bytes")
        XCTAssertEqual(SQLDialect(flavor: .sqlite).literal("\\xff", binary: true), "X'FF'")
        XCTAssertEqual(SQLDialect(flavor: .postgres).literal("\\xff", binary: true), "'\\xff'", "bytea reads this")
        XCTAssertEqual(mysql.literal(nil, binary: true), "NULL")
    }

    func testDuplicatingARowKeepsItsBytes() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("tabula-bin-\(UUID()).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let setup = try SQLiteDriver(path: path)
        _ = try await setup.executeScript(
            "CREATE TABLE files (id INTEGER PRIMARY KEY, data BLOB); INSERT INTO files (data) VALUES (x'00FF10');"
        )
        await setup.close()
        let model = TableTabModel(
            table: TableRef(schema: "main", name: "files"),
            driver: try SQLiteDriver(path: path),
            connectionTag: .local
        )
        await model.reload()
        XCTAssertEqual(model.rows.first?[1], "\\x00ff10")
        model.duplicateRows(IndexSet(integer: 0))
        await model.commit()
        XCTAssertNil(model.error)
        let check = try SQLiteDriver(path: path)
        let rows = try await check.execute("SELECT hex(data), typeof(data) FROM files ORDER BY id").rows
        XCTAssertEqual(rows, [["00FF10", "blob"], ["00FF10", "blob"]])
        await check.close()
    }

    func testFilteringByABinaryValueFindsIt() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("tabula-binf-\(UUID()).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let setup = try SQLiteDriver(path: path)
        _ = try await setup.executeScript(
            "CREATE TABLE files (id INTEGER PRIMARY KEY, data BLOB); INSERT INTO files (data) VALUES (x'00FF10'), (x'AA');"
        )
        await setup.close()
        let model = TableTabModel(
            table: TableRef(schema: "main", name: "files"),
            driver: try SQLiteDriver(path: path),
            connectionTag: .local
        )
        await model.reload()
        await model.filter(equalTo: "\\x00ff10", column: 1)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.rows.map { $0[0] }, ["1"])
        XCTAssertEqual(model.filterText, "\"data\" = X'00FF10'")
        await model.filter(equalTo: "1", column: 0)
        XCTAssertEqual(model.rows.map { $0[0] }, ["1"], "other columns still use a filter rule")
        XCTAssertFalse(model.useRawFilter)
    }

    func testMySQLShowsBytesAsHex() async throws {
        guard let port = ProcessInfo.processInfo.environment["TABULA_TEST_MYSQL_PORT"].flatMap(Int.init) else {
            throw XCTSkip("TABULA_TEST_MYSQL_PORT not set")
        }
        let driver = try await DriverFactory.connect(
            ConnectionConfig(kind: .mysql, port: port, user: "tabula", database: "tabula"),
            password: "tabula"
        )
        do {
            let result = try await driver.execute(
                "SELECT X'DEADBEEF00' AS b, b'10100101' AS bits, CAST('é' AS BINARY) AS bin, 'é' AS t, 7 AS n, CAST('{}' AS JSON) AS j"
            )
            XCTAssertEqual(result.rows, [["\\xdeadbeef00", "\\xa5", "\\xc3a9", "é", "7", "{}"]])
            XCTAssertEqual(
                result.binaryColumns,
                [0, 1, 2],
                "numbers and JSON report the binary set too, but aren't bytes"
            )
        } catch {
            await driver.close()
            throw error
        }
        await driver.close()
    }
}
