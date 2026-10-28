import XCTest
@testable import TabulaCore

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
        let state = WorkspaceState(database: "analytics", schema: "public", tabs: [
            .query(title: "Query 2", sql: "SELECT 1;\n-- unsaved", file: URL(fileURLWithPath: "/tmp/report.sql")),
            .table(schema: "public", name: "orders", kind: "table", mode: "Structure"),
            .query(title: "Query 3", sql: "", file: nil),
        ], selected: 1, history: ["SELECT 2", "SELECT 1"])
        try store.save(state, for: connection)
        XCTAssertEqual(store.load(connection), state)
        XCTAssertNil(store.load(UUID()), "another connection has its own state")
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
        let kept = UUID(), deleted = UUID()
        try store.save(WorkspaceState(schema: "a"), for: kept)
        try store.save(WorkspaceState(schema: "b"), for: deleted)
        store.remove(deleted)
        XCTAssertNil(store.load(deleted))
        XCTAssertNotNil(store.load(kept))
        store.removeAll()
        XCTAssertNil(store.load(kept))
    }
}
