import AppKit
import SwiftUI
import XCTest

@testable import Tabula

/// The grid's coordinator on a table view with no window, set up as `makeNSView` does. Copy goes to a pasteboard
/// of the test's own, never the system one.
@MainActor
final class DataGridTests: XCTestCase {
    private let rows: [[GridCell]] = [
        [.value("1"), .value("Ann"), .null],
        [.value("2"), .value("Bình"), .value("{\"b\":1,\"a\":[2]}")],
        [.value("3"), .defaultValue, .value("x")],
    ]
    private var tableView: GridTableView!
    private var coordinator: DataGridView.Coordinator!
    private var pasteboard: NSPasteboard!
    private var deleted: [IndexSet] = []
    private var edits: [(row: Int, column: Int, value: String?)] = []

    override func setUp() {
        pasteboard = NSPasteboard.withUniqueName()
        let rows = rows
        let source = GridSource(
            columns: ["id", "name", "data"],
            rowCount: rows.count,
            version: 1,
            cell: { rows[$0][$1] },
            isEditable: { $0 != 2 },
            isColumnEditable: { $0 != 0 },
            copyText: { indices in
                indices.map { row in
                    rows[row]
                        .map { cell -> String in
                            if case .value(let text) = cell { return text }
                            return cell == .null ? "NULL" : ""
                        }
                        .joined(separator: "\t")
                }
                .joined(separator: "\n")
            }
        )
        let grid = DataGridView(
            source: source,
            selection: .constant([]),
            onEdit: { [weak self] row, column, value in self?.edits.append((row, column, value)) },
            onDelete: { [weak self] in self?.deleted.append($0) }
        )
        tableView = GridTableView()
        coordinator = DataGridView.Coordinator(grid)
        coordinator.pasteboard = pasteboard
        tableView.coordinator = coordinator
        tableView.dataSource = coordinator
        tableView.delegate = coordinator
        coordinator.tableView = tableView
        coordinator.apply(grid)
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        deleted = []
        edits = []
    }

    func testColumnsMapToDataEvenWhenReordered() {
        XCTAssertEqual(tableView.numberOfColumns, 4, "the row-number gutter, then the data")
        XCTAssertNil(coordinator.dataColumn(0))
        XCTAssertEqual(coordinator.dataColumn(1), 0)
        XCTAssertEqual(coordinator.tableColumn(forData: 2), 3)
        tableView.moveColumn(3, toColumn: 1)
        XCTAssertEqual(coordinator.dataColumn(1), 2, "a dragged column keeps its data")
        XCTAssertEqual(coordinator.tableColumn(forData: 2), 1)
        XCTAssertNil(coordinator.dataColumn(9))
    }

    func testTabMovesAcrossCellsAndWrapsRows() {
        coordinator.focus(row: 0, tableColumn: 3, edit: false)
        coordinator.advance(by: 1, edit: false)
        XCTAssertEqual(tableView.selectedRow, 1)
        XCTAssertEqual(coordinator.focusedColumn, 1, "past the last column, the next row's first")
        coordinator.advance(by: -1, edit: false)
        XCTAssertEqual(tableView.selectedRow, 0)
        XCTAssertEqual(coordinator.focusedColumn, 3)
        coordinator.focus(row: 2, tableColumn: 3, edit: false)
        coordinator.advance(by: 1, edit: false)
        XCTAssertEqual(tableView.selectedRow, 2, "the last cell stays put")
        XCTAssertEqual(coordinator.focusedColumn, 3)
    }

    func testCopyingRowsAndACell() {
        tableView.selectRowIndexes([0, 2], byExtendingSelection: false)
        coordinator.copySelection(withHeader: true)
        XCTAssertEqual(pasteboard.string(forType: .string), "id\tname\tdata\n1\tAnn\tNULL\n3\t\tx")
        coordinator.focus(row: 0, tableColumn: 3, edit: false)
        coordinator.copyFocusedCell()
        XCTAssertEqual(pasteboard.string(forType: .string), "NULL")
    }

    func testDeleteAndSetNullFollowWhatCanBeEdited() {
        tableView.selectRowIndexes([0, 1], byExtendingSelection: false)
        coordinator.deleteSelection()
        XCTAssertEqual(deleted, [IndexSet([0, 1])])

        coordinator.focus(row: 1, tableColumn: 2, edit: false)
        coordinator.setFocusedCellNull()
        XCTAssertEqual(edits.map(\.row), [1])
        XCTAssertEqual(edits.first?.column, 1)
        XCTAssertNil(edits.first?.value ?? nil)
        // The id column and the third row can't be edited.
        coordinator.focus(row: 1, tableColumn: 1, edit: false)
        coordinator.setFocusedCellNull()
        coordinator.focus(row: 2, tableColumn: 2, edit: false)
        coordinator.setFocusedCellNull()
        XCTAssertEqual(edits.count, 1)
    }

    private func press(_ keyCode: UInt16, _ characters: String = "", flags: NSEvent.ModifierFlags = []) throws {
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: characters,
                charactersIgnoringModifiers: characters,
                isARepeat: false,
                keyCode: keyCode
            )
        )
        tableView.keyDown(with: event)
    }

    func testKeysMoveFocusDeleteAndClearCells() throws {
        coordinator.focus(row: 1, tableColumn: 2, edit: false)
        try press(124)  // →
        XCTAssertEqual(coordinator.focusedColumn, 3)
        try press(124)
        XCTAssertEqual(coordinator.focusedColumn, 3, "→ stops at the last column")
        try press(123, flags: .command)  // ⌘←
        XCTAssertEqual(coordinator.focusedColumn, 1)
        try press(125, flags: .command)  // ⌘↓
        XCTAssertEqual(tableView.selectedRow, 2)
        try press(126, flags: .command)  // ⌘↑
        XCTAssertEqual(tableView.selectedRow, 0)
        try press(48)  // Tab
        XCTAssertEqual(coordinator.focusedColumn, 2)

        try press(51, flags: .option)  // ⌥⌫: NULL in the focused cell
        XCTAssertEqual(edits.count, 1)
        XCTAssertEqual(edits.first?.row, 0)
        XCTAssertEqual(edits.first?.column, 1)
        try press(51)  // ⌫: the selected rows
        XCTAssertEqual(deleted, [IndexSet(integer: 0)])
        try press(53)  // Escape
        XCTAssertEqual(tableView.selectedRowIndexes, [])
    }

    func testQuickLookPrettyPrintsJSONOnly() {
        XCTAssertEqual(
            DataGridView.Coordinator.prettyJSON("{\"b\":1,\"a\":[2]}"),
            "{\n  \"a\" : [\n    2\n  ],\n  \"b\" : 1\n}"
        )
        XCTAssertNil(DataGridView.Coordinator.prettyJSON("not json"))
        XCTAssertNil(DataGridView.Coordinator.prettyJSON("{broken"))
        XCTAssertNil(DataGridView.Coordinator.prettyJSON("42"), "only objects and arrays")
    }
}
