import XCTest

@testable import Tabula
@testable import TabulaConnections
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

    /// SQL INSERT export writes into the table the query read, else into `results` in the window's schema (#264).
    func testInsertExportTargetsTheTableTheQueryRead() async throws {
        let (model, _) = try tab("SELECT x FROM n WHERE x <= 2 ORDER BY x")
        await model.run()
        let script = try model.exportText(.sqlInsert)
        XCTAssertEqual(script, "INSERT INTO \"n\" (\"x\") VALUES ('1');\nINSERT INTO \"n\" (\"x\") VALUES ('2');")
        let (joined, _) = try tab("SELECT a.x, b.x AS y FROM n a JOIN n b ON a.x = b.x WHERE a.x = 1")
        await joined.run()
        XCTAssertTrue(try joined.exportText(.sqlInsert).hasPrefix("INSERT INTO \"results\" "))
        // A renamed or computed column isn't the table's own, so its values don't go back into the table.
        let (renamed, _) = try tab("SELECT x AS y FROM n WHERE x = 1")
        await renamed.run()
        XCTAssertTrue(try renamed.exportText(.sqlInsert).hasPrefix("INSERT INTO \"results\" "))
        for (sql, asNamed) in [
            ("SELECT * FROM n", true), ("SELECT n.x, \"x\" FROM n", true), ("SELECT main.n.* FROM n", true),
            ("SELECT x y FROM n", false), ("SELECT x + 1 FROM n", false), ("SELECT 1 FROM n", false),
            ("SELECT count(x) FROM n", false), ("SELECT DISTINCT x FROM n", false),
        ] {
            XCTAssertEqual(QueryTabModel.selectsColumnsAsNamed(sql, flavor: .sqlite), asNamed, sql)
        }
    }

    func testPostgresInsertExportRunsBackIntoItsTable() async throws {
        guard let port = ProcessInfo.processInfo.environment["TABULA_TEST_PG_PORT"].flatMap(Int.init) else {
            throw XCTSkip("TABULA_TEST_PG_PORT not set")
        }
        let config = ConnectionConfig(kind: .postgres, port: port, user: "tabula", database: "tabula")
        let driver = try await DriverFactory.connect(config, password: "tabula")
        let table = "export_back_" + UUID().uuidString.prefix(8).lowercased()
        try await runThenClean(driver, cleanup: ["DROP TABLE \(table)"]) {
            _ = try await driver.execute("CREATE TABLE \(table) (id int PRIMARY KEY, note text)")
            _ = try await driver.execute("INSERT INTO \(table) VALUES (1, 'it''s'), (2, NULL)")
            let workspace = WorkspaceModel(config: config, password: "tabula")
            let model = QueryTabModel(
                title: "Query 1",
                sql: "SELECT * FROM \(table) ORDER BY id",
                driver: driver,
                workspace: workspace
            )
            await model.run()
            let script = try model.exportText(.sqlInsert)
            XCTAssertTrue(script.hasPrefix("INSERT INTO \"public\".\"\(table)\""), script)
            _ = try await driver.execute("DELETE FROM \(table)")
            for statement in driver.dialect.split(script) {
                _ = try await driver.execute(statement)
            }
            let rows = try await driver.execute("SELECT id, note FROM \(table) ORDER BY id").rows
            XCTAssertEqual(rows, [["1", "it's"], ["2", nil]])
        }
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
