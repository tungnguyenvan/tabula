import XCTest

@testable import TabulaAI
@testable import TabulaDrivers
@testable import TabulaFoundation
@testable import TabulaSQL
@testable import TabulaSQLite

/// What completion and the AI know about a schema's names, against a real SQLite file.
@MainActor
final class SchemaNamesTests: XCTestCase {
    private var path = ""
    private var driver: SQLiteDriver!

    override func setUp() async throws {
        path = NSTemporaryDirectory() + "SchemaNamesTests-\(UUID().uuidString).sqlite"
        driver = try SQLiteDriver(path: path)
        _ = try await driver.execute("CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT)")
        _ = try await driver.execute(
            "CREATE TABLE \"Order Lines\" (id INTEGER PRIMARY KEY, customer_id INTEGER REFERENCES customers(id), total REAL)"
        )
    }

    override func tearDown() async throws {
        await driver.close()
        try? FileManager.default.removeItem(atPath: path)
    }

    private func source(_ tables: [TableRef]) -> SchemaNames.Source {
        SchemaNames.Source(driver: driver, kind: .sqlite, tables: tables, schemas: ["main"], selectedSchema: "main")
    }

    private func tables() async throws -> [TableRef] {
        try await driver.tables(in: "main")
    }

    /// Waits for background loads to bump the version past `version`.
    private func waitForVersion(above version: Int, in names: SchemaNames) async throws {
        for _ in 0..<200 where names.version <= version {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThan(names.version, version, "nothing loaded")
    }

    func testColumnsLoadOnFirstAskThenComeFromTheCache() async throws {
        let names = SchemaNames()
        let source = source(try await tables())
        let table = SQLCompletion.TableName(schema: nil, name: "CUSTOMERS")
        XCTAssertNil(names.columnNames(of: table, from: source), "the first ask starts loading")
        try await waitForVersion(above: 0, in: names)
        XCTAssertEqual(names.columnNames(of: table, from: source), ["id", "name"])
        XCTAssertNil(names.columnNames(of: .init(schema: nil, name: "missing"), from: source))
        XCTAssertNil(names.columnNames(of: .init(schema: "nope", name: "customers"), from: source))
    }

    func testTableChangesDropWhatWasKnown() async throws {
        let names = SchemaNames()
        let source = source(try await tables())
        names.prefetchColumns(from: source)
        try await waitForVersion(above: 0, in: names)
        XCTAssertEqual(names.knownColumnNames(inSchema: "main"), ["customer_id", "id", "name", "total"])
        names.tablesChanged()
        XCTAssertEqual(names.knownColumnNames(inSchema: "main"), [])
        XCTAssertEqual(names.knownColumnNames(inSchema: "other"), [])
    }

    func testAISchemaHasColumnsKeysAndQuotedNames() async throws {
        let names = SchemaNames()
        let source = source(try await tables())
        let schema = await names.loadedAISchema(for: "SELECT * FROM customers", from: source)
        let byName = Dictionary(uniqueKeysWithValues: schema.tables.map { ($0.name, $0.columns.map(\.name)) })
        XCTAssertEqual(byName["customers"], ["id", "name"])
        XCTAssertEqual(byName["\"Order Lines\""], ["id", "customer_id", "total"], "names that need quotes are quoted")
        XCTAssertEqual(schema.foreignKeys, ["\"Order Lines\".customer_id -> customers.id"])
        XCTAssertNil(schema.defaultSchema, "SQLite's main database needs no prefix")

        let focused = names.aiSchema(focus: ["customers"], from: source)
        let focusedColumns = Dictionary(uniqueKeysWithValues: focused.tables.map { ($0.name, $0.columns.count) })
        XCTAssertEqual(focusedColumns["customers"], 2)
        XCTAssertEqual(focusedColumns["\"Order Lines\""], 0, "tables out of focus are named without columns")
        XCTAssertEqual(focused.foreignKeys, [])
    }

    func testSelectedSchemaTablesNeedNoLoad() async throws {
        let names = SchemaNames()
        let source = source(try await tables())
        XCTAssertEqual(names.tableNames(inSchema: "MAIN", from: source)?.sorted(), ["Order Lines", "customers"])
        XCTAssertNil(names.tableNames(inSchema: "unknown", from: source))
    }
}
