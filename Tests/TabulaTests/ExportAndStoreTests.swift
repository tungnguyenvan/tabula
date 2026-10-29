import XCTest

@testable import TabulaFoundation
@testable import TabulaSQL
@testable import TabulaStorage
@testable import TabulaTransfer

final class ExportAndStoreTests: XCTestCase {
    func testCSVEscaping() throws {
        let csv = try ResultExporter.export(
            columns: ["a", "b"],
            rows: [["x,y", nil], ["say \"hi\"", "line\nbreak"]],
            format: .csv,
            binaryColumns: [],
            dialect: SQLDialect(flavor: .postgres)
        )
        XCTAssertEqual(csv, "a,b\n\"x,y\",\n\"say \"\"hi\"\"\",\"line\nbreak\"\n")
    }

    func testJSONKeepsNulls() throws {
        let json = try ResultExporter.export(
            columns: ["a", "b"],
            rows: [["1", nil]],
            format: .json,
            binaryColumns: [],
            dialect: SQLDialect(flavor: .postgres)
        )
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        XCTAssertTrue(parsed[0]["b"] is NSNull)
    }

    func testSQLInsertExport() throws {
        let sql = try ResultExporter.export(
            columns: ["id"],
            rows: [["1"]],
            format: .sqlInsert,
            table: TableRef(schema: "db", name: "t"),
            binaryColumns: [],
            dialect: SQLDialect(flavor: .mysql)
        )
        XCTAssertEqual(sql, "INSERT INTO `db`.`t` (`id`) VALUES ('1');")
    }

    func testConnectionRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConnectionStore(directory: directory)
        let config = ConnectionConfig(name: "Local", kind: .mysql, user: "root", database: "app", tag: .local)
        try store.save([config])
        XCTAssertEqual(try store.load(), [config])
        XCTAssertEqual(config.port, 3306)
    }
}
