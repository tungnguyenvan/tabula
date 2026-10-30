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

    /// A repeated name gets a suffix no other column has, so every value keeps its own key (#232).
    func testJSONKeysStayUniqueAgainstRealNames() throws {
        XCTAssertEqual(ResultExporter.uniqueNames(["id", "id", "id_2"]), ["id", "id_3", "id_2"])
        XCTAssertEqual(ResultExporter.uniqueNames(["a", "a", "a", "a_2"]), ["a", "a_3", "a_4", "a_2"])
        XCTAssertEqual(ResultExporter.uniqueNames(["x", "y"]), ["x", "y"])
        let json = try ResultExporter.export(
            columns: ["id", "id", "id_2"],
            rows: [["1", "2", "3"]],
            format: .json,
            binaryColumns: [],
            dialect: SQLDialect(flavor: .postgres)
        )
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: String]])
        XCTAssertEqual(parsed, [["id": "1", "id_3": "2", "id_2": "3"]])
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
        XCTAssertEqual(try store.load().connections, [config])
        XCTAssertNil(try store.load().setAside)
        XCTAssertEqual(config.port, 3306)
    }

    /// A connection this version can't read (damaged, or of a kind a newer Tabula added) must not cost the others,
    /// and the next save must not erase it: the file is copied aside first.
    func testUnreadableConnectionsAreKeptAside() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ConnectionStore(directory: directory)
        let readable = ConnectionConfig(name: "Kept", kind: .postgres, user: "app", database: "shop")
        try store.save([readable])
        var entries = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [[String: Any]]
        )
        var future = entries[0]
        future["id"] = UUID().uuidString
        future["kind"] = "oracle"
        entries.append(future)
        let original = try JSONSerialization.data(withJSONObject: entries)
        try original.write(to: store.fileURL)

        let loaded = try store.load()
        XCTAssertEqual(loaded.connections, [readable], "the readable connection still opens")
        let aside = try XCTUnwrap(loaded.setAside)
        XCTAssertEqual(try Data(contentsOf: aside), original, "the file as it was")
        XCTAssertEqual(
            try store.load().setAside?.resolvingSymlinksInPath(),
            aside.resolvingSymlinksInPath(),
            "a second launch reuses the copy"
        )
        // Saving now writes what was read; the unreadable entry survives in the copy.
        try store.save(loaded.connections)
        XCTAssertTrue(FileManager.default.fileExists(atPath: aside.path))

        // A file that isn't JSON at all is set aside too, and reads as no connections.
        try Data("{ damaged".utf8).write(to: store.fileURL)
        let damaged = try store.load()
        XCTAssertEqual(damaged.connections, [])
        XCTAssertNotNil(damaged.setAside)
    }
}
