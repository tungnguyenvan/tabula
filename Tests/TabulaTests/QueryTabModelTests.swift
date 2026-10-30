import XCTest

@testable import Tabula
@testable import TabulaDrivers
@testable import TabulaFoundation
@testable import TabulaSQLite

/// The query tab against a real SQLite file: scripts, errors, the row limit and Stop.
@MainActor
final class QueryTabModelTests: XCTestCase {
    private var path = ""
    private var driver: SQLiteDriver?

    /// The workspace reads its stores from TABULA_DATA_DIR, so nothing of the user's is read or written.
    override class func setUp() {
        super.setUp()
        TestDataDirectory.prepare()
    }

    override func setUp() async throws {
        try TestDataDirectory.check()
        path =
            FileManager.default.temporaryDirectory.appendingPathComponent("tabula-query-\(UUID().uuidString).sqlite")
            .path
        let driver = try SQLiteDriver(path: path)
        _ = try await driver.executeScript(
            """
            CREATE TABLE n (x INTEGER);
            WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 25) INSERT INTO n SELECT x FROM c;
            """
        )
        self.driver = driver
    }

    override func tearDown() async throws {
        await driver?.close()
        try? FileManager.default.removeItem(atPath: path)
    }

    private func tab(_ sql: String) throws -> (QueryTabModel, WorkspaceModel) {
        let workspace = WorkspaceModel(config: ConnectionConfig(kind: .sqlite, filePath: path), password: nil)
        let model = QueryTabModel(title: "Query 1", sql: sql, driver: try XCTUnwrap(driver), workspace: workspace)
        return (model, workspace)
    }

    func testScriptShowsTheLastResultSet() async throws {
        let (model, workspace) = try tab("SELECT 1; UPDATE n SET x = x WHERE x = 1; SELECT count(*) FROM n")
        await model.run()
        XCTAssertNil(model.error)
        XCTAssertEqual(model.results.count, 3)
        XCTAssertEqual(model.selectedResult, 2)
        XCTAssertEqual(model.currentResult?.rows, [["25"]])
        XCTAssertEqual(workspace.history.first, "SELECT 1; UPDATE n SET x = x WHERE x = 1; SELECT count(*) FROM n")
    }

    func testFailedStatementIsNamedAndTheRestIsNotRun() async throws {
        let (model, _) = try tab("SELECT 1; SELECT * FROM missing; DELETE FROM n")
        await model.run()
        XCTAssertEqual(model.results.count, 1)
        XCTAssertEqual(model.failedStatement, "SELECT * FROM missing")
        XCTAssertTrue(
            model.error?.hasPrefix("Statement 2 of 3 failed:\nno such table: missing") == true,
            "\(model.error ?? "")"
        )
        let left = try await XCTUnwrap(driver).execute("SELECT count(*) FROM n")
        XCTAssertEqual(left.rows, [["25"]])
    }

    func testRowLimitAndRunningASelection() async throws {
        let (model, _) = try tab("SELECT x FROM n ORDER BY x")
        model.rowLimit = 5
        await model.run()
        XCTAssertEqual(model.currentResult?.rows.count, 5)
        model.rowLimit = nil
        await model.run("SELECT x FROM n WHERE x > 20")
        XCTAssertEqual(model.currentResult?.rows.count, 5)
        XCTAssertEqual(model.sql, "SELECT x FROM n ORDER BY x", "running a selection leaves the editor as it was")
    }

    /// A SQLite query's result can be edited in the tab and committed through the workspace's writer connection.
    func testEditingASQLiteResult() async throws {
        _ = try await XCTUnwrap(driver).execute("CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT)")
        _ = try await XCTUnwrap(driver).execute("INSERT INTO people (name) VALUES ('Ann'), ('Bình')")
        // The tab holds its workspace weakly; the commit goes through it.
        let (model, workspace) = try tab("SELECT id, name FROM people ORDER BY id")
        await model.run()
        let editor = try XCTUnwrap(model.resultEditor, "the result is editable")
        XCTAssertTrue(editor.isEditable(row: 1, column: 1))
        XCTAssertFalse(editor.isEditable(row: 1, column: 0), "the key stays read-only")
        editor.setValue("Bình An", row: 1, column: 1)
        XCTAssertTrue(model.hasResultChanges)
        await model.commitResult()
        XCTAssertFalse(model.hasResultChanges)
        XCTAssertNil(editor.error)
        let names = try await XCTUnwrap(driver).execute("SELECT name FROM people ORDER BY id").rows
        XCTAssertEqual(names, [["Ann"], ["Bình An"]])
        XCTAssertEqual(model.currentResult?.rows.last, ["2", "Bình An"], "the result shows the saved row")
        withExtendedLifetime(workspace) {}
    }

    func testStopInterruptsAndSkipsTheRest() async throws {
        let (model, _) = try tab(
            "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c) SELECT count(*) FROM c; DELETE FROM n"
        )
        let run = Task { await model.run() }
        for _ in 0..<100 where !model.canStop {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(model.canStop)
        try await Task.sleep(for: .milliseconds(100))
        model.stop()
        await run.value
        XCTAssertFalse(model.running)
        XCTAssertNil(model.error)
        let status = try XCTUnwrap(model.runStatus)
        XCTAssertTrue(status.hasPrefix("Query cancelled. 0 of 2 statements completed; the rest were not run."), status)
        XCTAssertTrue(status.contains("SQLite has rolled the transaction back"), status)
        let left = try await XCTUnwrap(driver).execute("SELECT count(*) FROM n")
        XCTAssertEqual(left.rows, [["25"]], "the DELETE after the stopped statement didn't run")
    }
}
