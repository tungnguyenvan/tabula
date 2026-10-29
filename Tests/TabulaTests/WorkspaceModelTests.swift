import XCTest

@testable import Tabula
@testable import TabulaDrivers
@testable import TabulaFoundation
@testable import TabulaSQL
@testable import TabulaSQLite
@testable import TabulaStorage

/// The workspace window's model against a real SQLite file, with its stores in `TestDataDirectory`.
@MainActor
final class WorkspaceModelTests: XCTestCase {
    private var path = ""
    private var workspaces: [WorkspaceModel] = []

    override class func setUp() {
        super.setUp()
        TestDataDirectory.prepare()
    }

    override func setUp() async throws {
        try TestDataDirectory.check()
        path =
            FileManager.default.temporaryDirectory.appendingPathComponent("tabula-ws-\(UUID().uuidString).sqlite")
            .path
        let setup = try SQLiteDriver(path: path)
        _ = try await setup.executeScript(
            """
            CREATE TABLE alpha (id INTEGER PRIMARY KEY, v TEXT);
            CREATE TABLE beta (id INTEGER PRIMARY KEY, v TEXT);
            CREATE TABLE gamma (id INTEGER PRIMARY KEY, v TEXT);
            INSERT INTO alpha (v) VALUES ('a'), ('b');
            """
        )
        await setup.close()
    }

    override func tearDown() async throws {
        for workspace in workspaces {
            await workspace.disconnect()
            try? FileManager.default.removeItem(
                at: WorkspaceModel.stateStore.directory.appendingPathComponent("\(workspace.connectionID).json")
            )
        }
        workspaces = []
        try? FileManager.default.removeItem(atPath: path)
    }

    private func connect(_ config: ConnectionConfig) async throws -> WorkspaceModel {
        let workspace = WorkspaceModel(config: config, password: nil)
        workspaces.append(workspace)
        await workspace.connect()
        XCTAssertEqual(workspace.status, .connected)
        return workspace
    }

    private func table(_ name: String) -> TableRef { TableRef(schema: "main", name: name) }

    private func titles(_ workspace: WorkspaceModel) -> [String] {
        workspace.tabs.map { tab in
            switch tab {
            case .table(let model): model.table.name
            case .query(let model): model.title
            default: "other"
            }
        }
    }

    func testConnectingListsTablesAndOpensAQueryTab() async throws {
        let workspace = try await connect(ConnectionConfig(kind: .sqlite, filePath: path))
        XCTAssertEqual(workspace.tableNames, ["alpha", "beta", "gamma"])
        XCTAssertEqual(titles(workspace), ["Query 1"])
        workspace.tableSearch = "ET"
        XCTAssertEqual(workspace.filteredTables.map(\.name), ["beta"])
    }

    func testPreviewTabsAreReplacedUntilPinned() async throws {
        let workspace = try await connect(ConnectionConfig(kind: .sqlite, filePath: path))
        workspace.open(table("alpha"), preview: true)
        workspace.open(table("beta"), preview: true)
        XCTAssertEqual(titles(workspace), ["Query 1", "beta"], "a preview replaces the last preview")
        let beta = try XCTUnwrap(workspace.selectedTabID)
        XCTAssertTrue(workspace.isPreview(beta))
        workspace.pin(beta)
        workspace.open(table("gamma"), preview: true)
        XCTAssertEqual(titles(workspace), ["Query 1", "beta", "gamma"])
        // Opening a table that is already open switches to it.
        workspace.open(table("beta"))
        XCTAssertEqual(workspace.selectedTabID, beta)
        XCTAssertEqual(workspace.tabs.count, 3)
    }

    func testClosingReopeningAndTabShortcuts() async throws {
        let workspace = try await connect(ConnectionConfig(kind: .sqlite, filePath: path))
        workspace.open(table("alpha"))
        workspace.newQueryTab(sql: "SELECT 2")
        XCTAssertEqual(titles(workspace), ["Query 1", "alpha", "Query 2"])

        workspace.selectTab(number: 1)
        XCTAssertEqual(workspace.selectedTabID, workspace.tabs[0].id)
        workspace.selectTab(number: 9)
        XCTAssertEqual(workspace.selectedTabID, workspace.tabs[2].id, "⌘9 is the last tab")
        workspace.selectAdjacentTab(1)
        XCTAssertEqual(workspace.selectedTabID, workspace.tabs[0].id, "next wraps around")

        workspace.close(workspace.tabs[2].id)
        workspace.close(workspace.tabs[1].id)
        // The empty Query 1 isn't kept for reopening.
        workspace.close(workspace.tabs[0].id)
        XCTAssertTrue(workspace.tabs.isEmpty)
        XCTAssertNil(workspace.selectedTabID)
        workspace.reopenClosedTab()
        workspace.reopenClosedTab()
        XCTAssertEqual(titles(workspace), ["alpha", "Query 2"])
        XCTAssertFalse(workspace.canReopenTab)
    }

    func testHistoryKeepsTheLatestOnce() async throws {
        let workspace = try await connect(ConnectionConfig(kind: .sqlite, filePath: path))
        workspace.recordHistory("SELECT 1")
        workspace.recordHistory("SELECT 2")
        workspace.recordHistory("SELECT 1")
        XCTAssertEqual(workspace.history, ["SELECT 1", "SELECT 2"])
        for index in 0..<(Defaults.historyLimit + 5) {
            workspace.recordHistory("SELECT \(index + 10)")
        }
        XCTAssertEqual(workspace.history.count, Defaults.historyLimit)
    }

    func testUnsavedTableEditsAreReported() async throws {
        let workspace = try await connect(ConnectionConfig(kind: .sqlite, filePath: path))
        workspace.open(table("alpha"))
        let model = try XCTUnwrap(workspace.selectedTableTab)
        // open() loads the rows in a task of its own; an edit staged before that finishes would be reloaded away.
        for _ in 0..<200 where model.rows.isEmpty || model.loading {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(model.rows.count, 2)
        XCTAssertFalse(workspace.hasUnsavedChanges)
        model.setValue("changed", row: 0, column: 1)
        XCTAssertTrue(workspace.hasUnsavedChanges)
        XCTAssertTrue(workspace.hasUnsavedChanges(model.id))
    }

    /// What one window had open comes back in the next one for the same connection.
    func testStateIsSavedAndRestored() async throws {
        let config = ConnectionConfig(kind: .sqlite, filePath: path)
        let first = try await connect(config)
        first.open(table("beta"))
        let beta = try XCTUnwrap(first.selectedTableTab)
        beta.filterRules = [FilterRule(column: "v", op: .equals, value: "x")]
        await beta.applyFilter()
        first.newQueryTab(sql: "SELECT * FROM alpha")
        first.recordHistory("SELECT * FROM alpha")
        first.selectTab(number: 2)
        first.rememberOpenTableFilters()
        first.saveState()
        await first.disconnect()

        let second = try await connect(config)
        XCTAssertEqual(titles(second), ["Query 1", "beta", "Query 2"])
        XCTAssertEqual(second.history, ["SELECT * FROM alpha"])
        guard case .table(let restored) = try XCTUnwrap(second.selectedTab) else {
            return XCTFail("the table tab was selected")
        }
        XCTAssertEqual(restored.table.name, "beta")
        XCTAssertEqual(restored.filterRules.first?.value, "x")
        second.newQueryTab()
        XCTAssertEqual(titles(second).last, "Query 3", "numbering goes on after the restored tabs")
    }
}
