import XCTest

@testable import TabulaStorage

final class WorkspaceStateTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("WorkspaceStateTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    func testRoundTrip() throws {
        let store = WorkspaceStateStore(base: base)
        let connection = UUID()
        XCTAssertNil(store.load(connection))
        let state = WorkspaceState(
            database: "analytics",
            schema: "public",
            tabs: [
                .query(title: "Query 2", sql: "SELECT 1;\n-- unsaved", file: URL(fileURLWithPath: "/tmp/report.sql")),
                .table(schema: "public", name: "orders", kind: "table", mode: "Structure"),
                .query(title: "Query 3", sql: "", file: nil),
            ],
            selected: 1,
            history: ["SELECT 2", "SELECT 1"]
        )
        try store.save(state, for: connection)
        XCTAssertEqual(store.load(connection), state)
        XCTAssertNil(store.load(UUID()), "another connection has its own state")
    }

    func testTableFiltersRoundTrip() throws {
        let store = WorkspaceStateStore(base: base)
        let connection = UUID()
        let orders = WorkspaceState.TableKey(database: "shop", schema: "public", name: "orders")
        let rule = WorkspaceState.TableFilter.Rule(
            column: "status",
            op: "=",
            value: "paid",
            conjunction: "AND",
            enabled: false
        )
        let applied = WorkspaceState.TableFilter(
            rules: [rule],
            rawCondition: "",
            usesRawCondition: false,
            appliedCondition: "\"status\" = 'paid'",
            engine: "postgres"
        )
        let draft = WorkspaceState.TableFilter(
            rules: [],
            rawCondition: "total > 100",
            usesRawCondition: true,
            appliedCondition: "",
            engine: nil
        )
        let state = WorkspaceState(
            tabs: [.table(schema: "public", name: "orders", kind: "table", mode: "Data")],
            tableFilters: [
                .init(table: orders, filter: applied),
                .init(table: .init(database: nil, schema: "main", name: "customers"), filter: draft),
            ]
        )
        try store.save(state, for: connection)
        XCTAssertEqual(store.load(connection), state)
    }

    /// A state saved before filters were remembered still loads, with no filters.
    func testStateWithoutFiltersLoads() throws {
        let store = WorkspaceStateStore(base: base)
        let connection = UUID()
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        let saved = """
            {"schema":"public","tabs":[{"query":{"title":"Query 1","sql":"SELECT 1"}}],"selected":0,"history":["SELECT 1"]}
            """
        try Data(saved.utf8).write(to: store.directory.appendingPathComponent("\(connection.uuidString).json"))
        let state = try XCTUnwrap(store.load(connection))
        XCTAssertEqual(state.schema, "public")
        XCTAssertEqual(state.tabs, [.query(title: "Query 1", sql: "SELECT 1", file: nil)])
        XCTAssertEqual(state.history, ["SELECT 1"])
        XCTAssertEqual(state.tableFilters, [])
    }

    /// Filters saved before 0.10.1 don't say which engine they were written for.
    func testFiltersWithoutEngineLoad() throws {
        let saved = """
            {"rules":[],"rawCondition":"id > 1","usesRawCondition":true,"appliedCondition":"id > 1"}
            """
        let filter = try JSONDecoder().decode(WorkspaceState.TableFilter.self, from: Data(saved.utf8))
        XCTAssertNil(filter.engine)
        XCTAssertEqual(filter.appliedCondition, "id > 1")
    }

    /// Rules saved by 0.7.1 have no checkbox and load ticked.
    func testRulesWithoutCheckboxLoadTicked() throws {
        let saved = """
            {"column":"status","op":"=","value":"paid","conjunction":"AND"}
            """
        let rule = try JSONDecoder().decode(WorkspaceState.TableFilter.Rule.self, from: Data(saved.utf8))
        XCTAssertTrue(rule.enabled)
        XCTAssertEqual(rule.column, "status")
    }

    func testDamagedFileIsIgnoredThenReplaced() throws {
        let store = WorkspaceStateStore(base: base)
        let connection = UUID()
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: store.directory.appendingPathComponent("\(connection.uuidString).json"))
        XCTAssertNil(store.load(connection))
        let state = WorkspaceState(schema: "main")
        try store.save(state, for: connection)
        XCTAssertEqual(store.load(connection), state)
    }

    func testRemove() throws {
        let store = WorkspaceStateStore(base: base)
        let kept = UUID()
        let deleted = UUID()
        try store.save(WorkspaceState(schema: "a"), for: kept)
        try store.save(WorkspaceState(schema: "b"), for: deleted)
        store.remove(deleted)
        XCTAssertNil(store.load(deleted))
        XCTAssertNotNil(store.load(kept))
        store.removeAll()
        XCTAssertNil(store.load(kept))
    }
}
