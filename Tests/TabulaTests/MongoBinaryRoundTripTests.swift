import XCTest

@testable import Tabula
@testable import TabulaConnections
@testable import TabulaDrivers
@testable import TabulaFoundation
@testable import TabulaMongo
@testable import TabulaSQL
@testable import TabulaTransfer

/// MongoDB values the grid and copies must keep exactly: binary of each subtype, UUIDs, decimals, longs, dates
/// and nested documents survive an edit of another field, a duplicated document and an INSERT export.
@MainActor
final class MongoBinaryRoundTripTests: XCTestCase {
    private func connect() async throws -> any DatabaseDriver {
        guard let port = ProcessInfo.processInfo.environment["TABULA_TEST_MONGO_PORT"].flatMap(Int.init) else {
            throw XCTSkip("TABULA_TEST_MONGO_PORT not set")
        }
        return try await DriverFactory.connect(
            ConnectionConfig(kind: .mongodb, port: port, user: "tabula", database: "tabula_binary"),
            password: "tabula"
        )
    }

    private let document = """
        { _id: 1, bin: BinData(0, "3q2+7wA="), md5: BinData(5, "AAECAwQFBgcICQoLDA0ODw=="), \
        uid: UUID("123e4567-e89b-12d3-a456-426614174000"), dec: NumberDecimal("0.1000"), big: NumberLong("9007199254740993"), \
        at: ISODate("1969-07-20T20:17:40.000Z"), nested: { b: BinData(0, ""), list: [BinData(0, "AA=="), null] }, note: "x" }
        """

    func testEditingAnotherFieldAndExportingKeepEveryValue() async throws {
        let driver = try await connect()
        defer { Task { await driver.close() } }
        _ = try await driver.execute("db.items.drop()")
        _ = try await driver.execute("db.items.insertOne(\(document))")
        let table = TableRef(schema: "tabula_binary", name: "items")
        let page = try await driver.fetchPage(TablePageRequest(table: table, limit: 10))
        let before = try XCTUnwrap(page.documents?.first)
        let note = try XCTUnwrap(page.columns.firstIndex(of: "note"))

        // Edit one field: the others go back as they were.
        let statements = try driver.dialect.statements(
            for: TableChanges(
                table: table,
                columns: page.columns,
                rows: page.rows,
                documents: page.documents,
                keyColumns: [try XCTUnwrap(page.columns.firstIndex(of: "_id"))],
                deleted: [],
                edited: [0: [note: .some("y")]],
                inserted: [],
                binaryColumns: page.binaryColumns
            )
        )
        for statement in statements {
            _ = try await driver.execute(statement)
        }
        let edited = try await driver.fetchPage(TablePageRequest(table: table, limit: 10))
        let after = try XCTUnwrap(edited.documents?.first)
        XCTAssertEqual(after, before.replacingOccurrences(of: "note: \"x\"", with: "note: \"y\""))

        // An INSERT export into another collection gives the same document back.
        let script = try ResultExporter.export(
            columns: edited.columns,
            rows: try MongoChanges.rowsForCopy(of: try XCTUnwrap(edited.documents), columns: edited.columns),
            format: .sqlInsert,
            table: TableRef(schema: "tabula_binary", name: "copy"),
            binaryColumns: edited.binaryColumns,
            dialect: driver.dialect
        )
        _ = try await driver.execute("db.copy.drop()")
        for statement in driver.dialect.split(script) {
            _ = try await driver.execute(statement)
        }
        let copied = try await driver.fetchPage(
            TablePageRequest(table: TableRef(schema: "tabula_binary", name: "copy"), limit: 10)
        )
        XCTAssertEqual(copied.documents?.first, after, "the export:\n\(script)")
        _ = try await driver.execute("db.dropDatabase()")
    }

    /// A duplicated document keeps its types, gains no null fields the original lacked, and takes pending edits.
    func testDuplicateRowKeepsTypes() async throws {
        let driver = try await connect()
        _ = try await driver.execute("db.items.drop()")
        _ = try await driver.execute("db.items.insertMany([\(document), { _id: 2, other: \"only here\" }])")
        let model = TableTabModel(
            table: TableRef(schema: "tabula_binary", name: "items"),
            driver: driver,
            connectionTag: .local
        )
        await model.reload()
        let note = try XCTUnwrap(model.resultColumns.firstIndex(of: "note"))
        model.setValue("edited", row: 0, column: note)
        model.duplicateRows(IndexSet([0, 1]))
        await model.commit()
        XCTAssertNil(model.error)
        func withoutID(_ text: String) -> String {
            text.replacingOccurrences(
                of: #"_id: (ObjectId\("[0-9a-f]+"\)|\d+), "#,
                with: "",
                options: .regularExpression
            )
        }
        // The edit was committed to the original too, so the first copy matches it field for field.
        let original = try await driver.execute("db.items.find({ _id: 1 })")
        let copies = try await driver.execute("db.items.find({ _id: { $type: \"objectId\" } }).sort({ other: 1 })")
        let texts = try XCTUnwrap(copies.documents).map(withoutID)
        XCTAssertEqual(texts.count, 2)
        XCTAssertEqual(texts.first, withoutID(try XCTUnwrap(original.documents?.first)))
        XCTAssertTrue(texts.first?.contains("note: \"edited\"") == true)
        XCTAssertEqual(texts.last, "{ other: \"only here\" }", "no null fields for the other columns")
        _ = try await driver.execute("db.dropDatabase()")
        await driver.close()
    }
}
