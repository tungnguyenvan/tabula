import Foundation
import Observation
import TabulaDrivers

/// Pending cell updates for one query result. Original rows and keys remain unchanged until a successful commit;
/// switching between script results keeps each one's edits and undo history.
@MainActor @Observable
final class QueryResultEditor {
    let target: QueryEditTarget
    private(set) var rows: [[String?]]
    private(set) var edits: [Int: [Int: String?]] = [:]
    private(set) var version = 0
    var committing = false
    var suspended = false
    var error: String?
    let undoManager = UndoManager()

    init(target: QueryEditTarget, rows: [[String?]]) {
        self.target = target
        self.rows = rows
    }

    var hasChanges: Bool { !edits.isEmpty }
    var changeCount: Int { edits.values.reduce(0) { $0 + $1.count } }

    func isEditable(row: Int, column: Int) -> Bool {
        !committing && !suspended && target.columns.indices.contains(column) && target.columns[column].editable
            && target.editableRow(row, in: rows)
    }

    func value(row: Int, column: Int) -> String? {
        if let edited = edits[row]?[column] {
            return edited
        }
        return rows[row][column]
    }

    func state(row: Int, column: Int) -> GridCellState { edits[row]?.keys.contains(column) == true ? .edited : .normal }

    func setValue(_ value: String?, row: Int, column: Int) {
        guard isEditable(row: row, column: column), self.value(row: row, column: column) != value else { return }
        registerUndo()
        if rows[row][column] == value {
            edits[row]?[column] = nil
            if edits[row]?.isEmpty == true {
                edits[row] = nil
            }
        } else {
            edits[row, default: [:]][column] = .some(value)
        }
        error = nil
        version += 1
    }

    private func registerUndo() {
        let before = edits
        undoManager.registerUndo(withTarget: self) { editor in
            guard !editor.committing else { return }
            editor.registerUndo()
            editor.edits = before
            editor.version += 1
        }
        undoManager.setActionName("Edit Result Cell")
    }

    func discard() {
        guard !committing, !suspended else { return }
        edits = [:]
        error = nil
        undoManager.removeAllActions()
        version += 1
    }

    var changes: [QueryRowEdit] {
        edits.keys.sorted().map { QueryRowEdit(row: $0, original: rows[$0], values: edits[$0] ?? [:]) }
    }

    func pendingStatements() throws -> [String] { try changes.map { try target.statement(for: $0) } }

    func applied(_ returned: [Int: [String?]]) {
        for (index, row) in returned where rows.indices.contains(index) {
            rows[index] = row
        }
        edits = [:]
        error = nil
        undoManager.removeAllActions()
        version += 1
    }
}
