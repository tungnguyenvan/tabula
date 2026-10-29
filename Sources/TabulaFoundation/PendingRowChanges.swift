import Foundation

/// Changes to a page of table rows that aren't saved yet: edited cells of the rows the database returned, those rows
/// marked for deletion, and new rows. A value, so undo can keep snapshots of it.
///
/// Rows are numbered as the grid shows them: first the `existing` rows from the database, then the new ones.
public struct PendingRowChanges: Equatable, Sendable {
    /// Existing row → column → new value (inner nil = SQL NULL).
    public private(set) var edits: [Int: [Int: String?]] = [:]
    public private(set) var deletedRows: Set<Int> = []
    /// New rows hold only the cells the user set; unset cells use the column default.
    public private(set) var insertedRows: [[Int: String?]] = []

    public init() {}

    public var isEmpty: Bool {
        edits.isEmpty && deletedRows.isEmpty && insertedRows.isEmpty
    }

    /// Cells edited, rows deleted and rows added.
    public var count: Int {
        let editedCells = edits.values.reduce(0) { total, row in total + row.count }
        return editedCells + deletedRows.count + insertedRows.count
    }

    /// What a cell shows.
    public enum Cell: Equatable, Sendable {
        case value(String)
        case null
        /// A new row's cell the user didn't set: the database fills in the column default.
        case columnDefault
    }

    public func cell(row: Int, column: Int, existing rows: [[String?]]) -> Cell {
        if row >= rows.count {
            guard let set = insertedRows[row - rows.count][column] else {
                return .columnDefault
            }
            return Self.cell(set)
        }
        if let edited = edits[row]?[column] {
            return Self.cell(edited)
        }
        return Self.cell(rows[row][column])
    }

    private static func cell(_ value: String?) -> Cell {
        guard let value else {
            return .null
        }
        return .value(value)
    }

    public func isDeleted(_ row: Int) -> Bool {
        deletedRows.contains(row)
    }

    public func isEdited(row: Int, column: Int) -> Bool {
        edits[row]?[column] != nil
    }

    /// Sets a cell. For an existing row, setting its original value back removes the edit.
    public mutating func set(_ value: String?, row: Int, column: Int, existing rows: [[String?]]) {
        if row >= rows.count {
            insertedRows[row - rows.count][column] = .some(value)
            return
        }
        guard rows[row][column] != value else {
            edits[row]?[column] = nil
            if edits[row]?.isEmpty == true {
                edits[row] = nil
            }
            return
        }
        edits[row, default: [:]][column] = .some(value)
    }

    /// Adds a new row with `cells` set (none: every column takes its default).
    public mutating func appendRow(_ cells: [Int: String?] = [:]) {
        insertedRows.append(cells)
    }

    /// Marks existing rows for deletion, dropping their edits, when `existingCanBeDeleted`; new rows are removed.
    public mutating func delete(_ rows: IndexSet, existingCount: Int, existingCanBeDeleted: Bool) {
        var removedInserted: [Int] = []
        for row in rows {
            if row >= existingCount {
                removedInserted.append(row - existingCount)
            } else if existingCanBeDeleted {
                deletedRows.insert(row)
                edits[row] = nil
            }
        }
        for index in removedInserted.sorted(by: >) where index < insertedRows.count {
            insertedRows.remove(at: index)
        }
    }

    /// Unmarks rows for deletion.
    public mutating func restore(_ rows: IndexSet) {
        for row in rows {
            deletedRows.remove(row)
        }
    }

    public mutating func removeAll() {
        self = PendingRowChanges()
    }
}
