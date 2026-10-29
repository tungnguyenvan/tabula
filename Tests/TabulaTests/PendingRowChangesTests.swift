import XCTest

@testable import TabulaFoundation

final class PendingRowChangesTests: XCTestCase {
    private let rows: [[String?]] = [["1", "Ann", nil], ["2", "Bob", "x"]]

    func testEditsAndSettingTheOriginalBack() {
        var changes = PendingRowChanges()
        XCTAssertTrue(changes.isEmpty)
        changes.set("Anna", row: 0, column: 1, existing: rows)
        XCTAssertEqual(changes.cell(row: 0, column: 1, existing: rows), .value("Anna"))
        XCTAssertTrue(changes.isEdited(row: 0, column: 1))
        changes.set(nil, row: 0, column: 1, existing: rows)
        XCTAssertEqual(changes.cell(row: 0, column: 1, existing: rows), .null, "NULL is a change of its own")
        XCTAssertEqual(changes.count, 1)

        // Back to the original: no change is left for that row.
        changes.set("Ann", row: 0, column: 1, existing: rows)
        XCTAssertTrue(changes.isEmpty)
        XCTAssertEqual(changes.edits, [:])
        XCTAssertEqual(changes.cell(row: 0, column: 2, existing: rows), .null)
    }

    func testNewRowsUseColumnDefaultsUntilSet() {
        var changes = PendingRowChanges()
        changes.appendRow()
        changes.appendRow([1: .some("Cleo")])
        XCTAssertEqual(changes.cell(row: 2, column: 1, existing: rows), .columnDefault)
        XCTAssertEqual(changes.cell(row: 3, column: 1, existing: rows), .value("Cleo"))
        changes.set(nil, row: 2, column: 2, existing: rows)
        XCTAssertEqual(changes.cell(row: 2, column: 2, existing: rows), .null, "a new row's cell set to NULL")
        XCTAssertEqual(changes.count, 2)
    }

    func testDeletingMarksExistingRowsAndRemovesNewOnes() {
        var changes = PendingRowChanges()
        changes.set("Bobby", row: 1, column: 1, existing: rows)
        changes.appendRow()
        changes.appendRow([1: .some("Dan")])
        changes.delete([1, 2], existingCount: rows.count, existingCanBeDeleted: true)
        XCTAssertTrue(changes.isDeleted(1))
        XCTAssertFalse(changes.isEdited(row: 1, column: 1), "a deleted row's edits are dropped")
        XCTAssertEqual(changes.insertedRows, [[1: .some("Dan")]])
        changes.restore([1])
        XCTAssertFalse(changes.isDeleted(1))
        XCTAssertEqual(changes.count, 1)

        // Without a primary key, existing rows can't be deleted; new ones still can.
        var keyless = PendingRowChanges()
        keyless.appendRow()
        keyless.delete([0, 2], existingCount: rows.count, existingCanBeDeleted: false)
        XCTAssertTrue(keyless.isEmpty)
    }

    func testSnapshotsSupportUndo() {
        var changes = PendingRowChanges()
        changes.set("Anna", row: 0, column: 1, existing: rows)
        let snapshot = changes
        changes.appendRow()
        changes.removeAll()
        XCTAssertTrue(changes.isEmpty)
        changes = snapshot
        XCTAssertEqual(changes.cell(row: 0, column: 1, existing: rows), .value("Anna"))
    }
}
