import XCTest

@testable import Tabula
@testable import TabulaDrivers
@testable import TabulaFoundation
@testable import TabulaSQL
@testable import TabulaSQLite
@testable import TabulaStorage

/// The table tab against a real SQLite file: paging, sorting, filters and staged edits up to the commit.
@MainActor
final class TableTabModelTests: XCTestCase {
    private var path = ""

    override func setUp() async throws {
        path =
            FileManager.default.temporaryDirectory.appendingPathComponent("tabula-tab-\(UUID().uuidString).sqlite")
            .path
        let setup = try SQLiteDriver(path: path)
        _ = try await setup.executeScript(
            """
            CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT NOT NULL, city TEXT DEFAULT 'Huế');
            CREATE VIEW people_view AS SELECT * FROM people;
            """
        )
        for index in 1...25 {
            _ = try await setup.execute(
                "INSERT INTO people (name, city) VALUES ('P\(index)', \(index % 2 == 0 ? "'Hà Nội'" : "NULL"))"
            )
        }
        await setup.close()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: path)
    }

    private func open(_ name: String = "people", kind: TableKind = .table) async throws -> TableTabModel {
        let driver = try SQLiteDriver(path: path)
        let model = TableTabModel(
            table: TableRef(schema: "main", name: name, kind: kind),
            driver: driver,
            connectionTag: .local
        )
        model.pageSize = 10
        await model.reload()
        XCTAssertNil(model.error)
        return model
    }

    func testPagesAndSorting() async throws {
        let model = try await open()
        XCTAssertEqual(model.rows.count, 10)
        XCTAssertEqual(model.totalRows, 25)
        XCTAssertFalse(model.canGoBack)
        XCTAssertTrue(model.canGoForward)
        await model.nextPage()
        await model.nextPage()
        XCTAssertEqual(model.rows.count, 5)
        XCTAssertFalse(model.canGoForward)
        await model.previousPage()
        XCTAssertEqual(model.rows.first?.first, "11")

        await model.sort(by: "id", ascending: false)
        XCTAssertEqual(model.rows.first?.first, "25", "sorting goes back to the first page")
    }

    func testFilterRulesAndRawCondition() async throws {
        let model = try await open()
        model.filterRules = [FilterRule(column: "city", op: .isNull, value: "")]
        await model.applyFilter()
        XCTAssertTrue(model.isFiltered)
        XCTAssertEqual(model.totalRows, 13)

        model.useRawFilter = true
        model.filterText = "name = 'P2'"
        await model.applyFilter()
        XCTAssertEqual(model.rows.map { $0[1] }, ["P2"])

        await model.clearFilter()
        XCTAssertFalse(model.isFiltered)
        XCTAssertEqual(model.totalRows, 25)
    }

    func testRememberedFilterRestoresInAnotherTab() async throws {
        let first = try await open()
        first.filterRules = [FilterRule(column: "name", op: .equals, value: "P7")]
        await first.applyFilter()
        let remembered = try XCTUnwrap(first.rememberedFilter)

        let second = try await open()
        second.restoreFilter(remembered)
        await second.reload()
        XCTAssertEqual(second.rows.map { $0[1] }, ["P7"])
        XCTAssertFalse(second.filterChangedInTab)
    }

    func testEditsUndoAndCommit() async throws {
        let model = try await open()
        XCTAssertTrue(model.canEditExisting)
        // In the app each change is its own event, and AppKit groups undo by event; here there is no run loop.
        model.undoManager.groupsByEvent = false
        func step(_ change: () -> Void) {
            model.undoManager.beginUndoGrouping()
            change()
            model.undoManager.endUndoGrouping()
        }
        step { model.setValue("Ann", row: 0, column: 1) }
        step { model.setValue(nil, row: 1, column: 2) }
        step { model.addRow() }
        let added = model.rows.count
        step { model.setValue("New", row: added, column: 1) }
        step { model.deleteRows(IndexSet(integer: 2)) }
        XCTAssertEqual(model.changeCount, 4)
        XCTAssertEqual(model.displayRowCount, 11)

        model.undoManager.undo()
        XCTAssertEqual(model.changeCount, 3, "undo takes back the delete")
        XCTAssertFalse(model.changes.isDeleted(2))

        let statements = try model.pendingStatements()
        XCTAssertEqual(statements.count, 3)

        await model.commit()
        XCTAssertNil(model.error)
        XCTAssertFalse(model.hasChanges)
        XCTAssertEqual(model.totalRows, 26)

        let check = try SQLiteDriver(path: path)
        let rows: [[String?]] =
            try await check.execute("SELECT name, city FROM people WHERE id IN (1, 2, 26) ORDER BY id").rows
        XCTAssertEqual(rows, [["Ann", nil], ["P2", nil], ["New", "Huế"]], "the new row takes the column default")
        await check.close()
    }

    func testViewsAndTablesWithoutKeysAreReadOnly() async throws {
        let view = try await open("people_view", kind: .view)
        XCTAssertFalse(view.canEditExisting)
        XCTAssertFalse(view.canInsert)
        XCTAssertFalse(view.isEditable(row: 0))
    }

    func testDiscardingChanges() async throws {
        let model = try await open()
        model.setValue("Changed", row: 3, column: 1)
        XCTAssertTrue(model.hasChanges)
        model.discardChanges()
        XCTAssertFalse(model.hasChanges)
        XCTAssertEqual(model.cell(row: 3, column: 1), .value("P4"))
    }
}
