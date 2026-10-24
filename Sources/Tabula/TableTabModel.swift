import Foundation
import Observation
import TabulaCore

/// One table opened in a tab: paged data, pending edits, and structure.
@MainActor @Observable
final class TableTabModel {
    enum Mode: String, CaseIterable, Identifiable {
        case data = "Data", structure = "Structure"
        var id: String { rawValue }
    }

    typealias CellState = GridCellState
    typealias Cell = GridCell

    let id = UUID()
    let table: TableRef
    let driver: any DatabaseDriver
    var mode: Mode = .data

    private(set) var columns: [ColumnInfo] = []
    private(set) var indexes: [IndexInfo] = []
    private(set) var resultColumns: [String] = []
    private(set) var rows: [[String?]] = []
    private(set) var totalRows: Int?
    private(set) var loading = false
    private(set) var committing = false
    /// Only the newest reload may write its rows; an older one finishing late is dropped.
    private var reloadGeneration = 0
    var error: String?

    var pageSize = 300
    private(set) var offset = 0
    private(set) var orderBy: String?
    private(set) var ascending = true
    /// Raw SQL condition, used when `useRawFilter` is on.
    var filterText = ""
    var filterRules: [FilterRule] = []
    var useRawFilter = false
    var showFilterBar = false
    /// Incremented to move focus into the filter bar (⌘F while it is already open).
    var filterFocusRequest = 0
    /// Incremented by the menu to open the SQL preview sheet (⇧⌘S).
    var showPreviewRequest = 0
    private(set) var appliedFilter = ""

    /// row index → column index → new value (inner nil = SQL NULL).
    private(set) var edits: [Int: [Int: String?]] = [:]
    private(set) var deletedRows: Set<Int> = []
    /// Inserted rows hold only the cells the user set; unset cells use the column default.
    private(set) var insertedRows: [[Int: String?]] = []
    /// Bumped on every change so the grid knows to redraw.
    private(set) var version = 0

    /// Per-tab undo history for pending (uncommitted) changes; the grid hands it to the responder chain.
    let undoManager = UndoManager()

    /// A cell the grid should move to (and optionally start editing) on its next update.
    struct FocusRequest: Equatable {
        var row: Int
        var column: Int
        var edit: Bool
        var id = UUID()
    }
    var focusRequest: FocusRequest?
    /// Put keyboard focus in the grid once rows load (opened on purpose, not while browsing the sidebar).
    var focusGridOnLoad = false

    init(table: TableRef, driver: any DatabaseDriver) {
        self.table = table
        self.driver = driver
    }

    // MARK: Loading

    func reload() async {
        reloadGeneration += 1
        let generation = reloadGeneration
        loading = true
        defer { if generation == reloadGeneration { loading = false; version += 1 } }
        do {
            if columns.isEmpty {
                let fetched = try await driver.columns(of: table)
                let fetchedIndexes = (try? await driver.indexes(of: table)) ?? []
                guard generation == reloadGeneration else { return }
                columns = fetched
                indexes = fetchedIndexes
            }
            let request = TablePageRequest(table: table, limit: pageSize, offset: offset, orderBy: orderBy,
                                           ascending: ascending, filter: appliedFilter)
            let page = try await driver.fetchPage(request)
            guard generation == reloadGeneration else { return }
            resultColumns = page.columns.isEmpty ? columns.map(\.name) : page.columns
            rows = page.rows
            clearPending()
            undoManager.removeAllActions()
            if focusGridOnLoad && !rows.isEmpty {
                focusGridOnLoad = false
                focusRequest = FocusRequest(row: 0, column: 0, edit: false)
            }
            error = nil
            let count = try? await driver.countRows(table, filter: appliedFilter)
            if generation == reloadGeneration { totalRows = count }
        } catch {
            if generation == reloadGeneration { self.error = error.localizedDescription }
        }
    }

    /// Asks before something drops the pending edits; true when there are none.
    func confirmDiscard(action: String = "Discard") -> Bool {
        guard hasChanges else { return true }
        return Confirmation.ask("Discard \(changeCount) uncommitted change\(changeCount == 1 ? "" : "s") in “\(table.name)”?",
                                detail: "Commit them (⌘S) first if you want to keep them.", action: action)
    }

    func reloadStructure() async {
        columns = []
        await reload()
    }

    func applyFilter() async {
        guard confirmDiscard() else { return }
        appliedFilter = useRawFilter ? filterText : driver.dialect.condition(filterRules)
        offset = 0
        await reload()
    }

    func clearFilter() async {
        guard confirmDiscard() else { return }
        clearPending()
        filterText = ""
        filterRules = []
        await applyFilter()
    }

    func addFilterRule() {
        let column = resultColumns.first ?? columns.first?.name ?? ""
        filterRules.append(FilterRule(column: column))
        showFilterBar = true
    }

    /// Shows the filter bar, seeding a rule so there is something to edit.
    func toggleFilterBar() {
        showFilterBar.toggle()
        if showFilterBar && filterRules.isEmpty && !useRawFilter { addFilterRule() }
    }

    /// ⌘F: open the filter bar, or jump into it if it is already open.
    func focusFilter() {
        mode = .data
        if showFilterBar {
            filterFocusRequest += 1
        } else {
            toggleFilterBar()
        }
    }

    /// Restricts to rows equal to this cell (context-menu "Filter by value").
    func filter(equalTo value: String?, column: Int) async {
        guard resultColumns.indices.contains(column), confirmDiscard() else { return }
        clearPending()
        useRawFilter = false
        filterRules = [FilterRule(column: resultColumns[column], op: value == nil ? .isNull : .equals, value: value ?? "")]
        showFilterBar = true
        await applyFilter()
    }

    var isFiltered: Bool { !appliedFilter.isEmpty }

    func columnInfo(_ name: String) -> ColumnInfo? { columns.first { $0.name == name } }

    func sort(by column: String, ascending: Bool) async {
        guard confirmDiscard() else { return }
        orderBy = column
        self.ascending = ascending
        offset = 0
        await reload()
    }

    var canGoBack: Bool { offset > 0 }
    var canGoForward: Bool { rows.count == pageSize && (totalRows.map { offset + pageSize < $0 } ?? true) }

    func nextPage() async {
        guard canGoForward, confirmDiscard() else { return }
        offset += pageSize
        await reload()
    }

    func previousPage() async {
        guard confirmDiscard() else { return }
        offset = max(0, offset - pageSize)
        await reload()
    }

    var pageDescription: String {
        guard !rows.isEmpty else { return totalRows.map { "\($0) rows" } ?? "No rows" }
        let range = "\(offset + 1)–\(offset + rows.count)"
        return totalRows.map { "\(range) of \($0)" } ?? range
    }

    // MARK: Editing

    private var primaryKeyIndices: [Int] {
        columns.filter(\.isPrimaryKey).compactMap { key in resultColumns.firstIndex(of: key.name) }
    }

    /// Updates and deletes target rows by primary key; without one only inserts are possible.
    var canEditExisting: Bool { table.kind == .table && !primaryKeyIndices.isEmpty }
    var canInsert: Bool { table.kind == .table }

    var displayRowCount: Int { rows.count + insertedRows.count }

    var hasChanges: Bool { !edits.isEmpty || !deletedRows.isEmpty || !insertedRows.isEmpty }

    var changeCount: Int { edits.values.reduce(0) { $0 + $1.count } + deletedRows.count + insertedRows.count }

    func cell(row: Int, column: Int) -> Cell {
        if row >= rows.count {
            let inserted = insertedRows[row - rows.count]
            guard let set = inserted[column] else { return .defaultValue }
            return set.map(Cell.value) ?? .null
        }
        if let edit = edits[row]?[column] { return edit.map(Cell.value) ?? .null }
        return rows[row][column].map(Cell.value) ?? .null
    }

    func state(row: Int, column: Int) -> CellState {
        if row >= rows.count { return .inserted }
        if deletedRows.contains(row) { return .deleted }
        return edits[row]?[column] != nil ? .edited : .normal
    }

    func isEditable(row: Int) -> Bool {
        row >= rows.count ? canInsert : (canEditExisting && !deletedRows.contains(row))
    }

    private struct Pending {
        var edits: [Int: [Int: String?]]
        var deletedRows: Set<Int>
        var insertedRows: [[Int: String?]]
    }

    private var pending: Pending {
        get { Pending(edits: edits, deletedRows: deletedRows, insertedRows: insertedRows) }
        set { edits = newValue.edits; deletedRows = newValue.deletedRows; insertedRows = newValue.insertedRows; version += 1 }
    }

    /// Records the current pending state so the next change can be undone with ⌘Z.
    private func registerUndo(_ name: String) {
        let snapshot = pending
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.restore(snapshot, name: name) }
        }
        undoManager.setActionName(name)
    }

    private func restore(_ snapshot: Pending, name: String) {
        registerUndo(name) // makes the restore itself redoable
        pending = snapshot
    }

    func setValue(_ value: String?, row: Int, column: Int) {
        guard isEditable(row: row) else { return }
        registerUndo("Edit Cell")
        if row >= rows.count {
            insertedRows[row - rows.count][column] = .some(value)
        } else if rows[row][column] == value {
            edits[row]?[column] = nil
            if edits[row]?.isEmpty == true { edits[row] = nil }
        } else {
            edits[row, default: [:]][column] = .some(value)
        }
        version += 1
    }

    /// Appends an empty row and asks the grid to start editing its first cell.
    func addRow() {
        guard canInsert else { return }
        registerUndo("Add Row")
        insertedRows.append([:])
        version += 1
        focusRequest = FocusRequest(row: displayRowCount - 1, column: firstColumnToFill, edit: true)
    }

    /// Where typing starts in a new row: skip a lone integer primary key, which the database fills in.
    private var firstColumnToFill: Int {
        let keys = columns.filter(\.isPrimaryKey)
        guard keys.count == 1, let key = keys.first,
              ["int", "serial"].contains(where: key.dataType.lowercased().contains),
              let index = resultColumns.firstIndex(of: key.name), index == 0, resultColumns.count > 1 else { return 0 }
        return 1
    }

    /// Copies the selected rows into new rows, leaving primary-key columns to their defaults.
    func duplicateRows(_ indices: IndexSet) {
        guard canInsert, !indices.isEmpty else { return }
        registerUndo("Duplicate Rows")
        let keyNames = Set(columns.filter(\.isPrimaryKey).map(\.name))
        for row in indices.sorted() where row < displayRowCount {
            var copy: [Int: String?] = [:]
            for column in resultColumns.indices where !keyNames.contains(resultColumns[column]) {
                switch cell(row: row, column: column) {
                case .value(let text): copy[column] = .some(text)
                case .null: copy[column] = .some(nil)
                case .defaultValue: break
                }
            }
            insertedRows.append(copy)
        }
        version += 1
        focusRequest = FocusRequest(row: displayRowCount - 1, column: 0, edit: false)
    }

    func deleteRows(_ indices: IndexSet) {
        guard !indices.isEmpty else { return }
        registerUndo(indices.count > 1 ? "Delete Rows" : "Delete Row")
        var removedInserted: [Int] = []
        for row in indices {
            if row >= rows.count {
                removedInserted.append(row - rows.count)
            } else if canEditExisting {
                deletedRows.insert(row)
                edits[row] = nil
            }
        }
        for index in removedInserted.sorted(by: >) where index < insertedRows.count {
            insertedRows.remove(at: index)
        }
        version += 1
    }

    func restoreRows(_ indices: IndexSet) {
        registerUndo("Restore Rows")
        for row in indices { deletedRows.remove(row) }
        version += 1
    }

    func discardChanges() {
        guard hasChanges else { return }
        registerUndo("Discard Changes")
        clearPending()
        version += 1
    }

    private func clearPending() {
        edits = [:]
        deletedRows = []
        insertedRows = []
    }

    private func key(for row: Int) -> [(column: String, value: String?)] {
        primaryKeyIndices.map { (resultColumns[$0], rows[row][$0]) }
    }

    /// SQL statements that apply the pending changes, in the order they will run.
    func pendingStatements() -> [String] {
        let d = driver.dialect
        var statements: [String] = []
        for row in deletedRows.sorted() {
            statements.append(d.delete(table, key: key(for: row)))
        }
        for row in edits.keys.sorted() where !deletedRows.contains(row) {
            let values = (edits[row] ?? [:]).sorted { $0.key < $1.key }.map { (resultColumns[$0.key], $0.value) }
            statements.append(d.update(table, set: values, key: key(for: row)))
        }
        for inserted in insertedRows {
            let values = inserted.sorted { $0.key < $1.key }.map { (resultColumns[$0.key], $0.value) }
            statements.append(d.insert(table, values: values))
        }
        return statements
    }

    func commit() async {
        let statements = pendingStatements()
        guard !statements.isEmpty, !committing else { return }
        committing = true
        defer { committing = false }
        do {
            try await driver.applyInTransaction(statements)
            await reload()
        } catch {
            self.error = "Changes were rolled back: \(error.localizedDescription)"
        }
    }

    // MARK: Export

    func exportText(_ format: ExportFormat) -> String {
        ResultExporter.export(columns: resultColumns, rows: rows, format: format, table: table, dialect: driver.dialect)
    }

    func copyText(rows indices: IndexSet) -> String {
        indices.filter { $0 < displayRowCount }.map { row in
            (0..<resultColumns.count).map { column -> String in
                if case .value(let text) = cell(row: row, column: column) { return text }
                return cell(row: row, column: column) == .null ? "NULL" : ""
            }.joined(separator: "\t")
        }.joined(separator: "\n")
    }
}
