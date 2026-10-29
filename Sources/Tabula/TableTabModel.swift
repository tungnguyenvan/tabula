import Foundation
import Observation
import TabulaDrivers
import TabulaFoundation
import TabulaMongo
import TabulaSQL
import TabulaStorage
import TabulaTransfer

/// One table opened in a tab: paged data, pending edits, and structure.
@MainActor @Observable
final class TableTabModel {
    enum Mode: String, CaseIterable, Identifiable {
        case data = "Data"
        case structure = "Structure"
        var id: String { rawValue }
    }

    typealias CellState = GridCellState
    typealias Cell = GridCell

    let id = UUID()
    let table: TableRef
    let driver: any DatabaseDriver
    let connectionTag: ConnectionTag
    var mode: Mode = .data

    private(set) var columns: [ColumnInfo] = []
    private(set) var indexes: [IndexInfo] = []
    private(set) var resultColumns: [String] = []
    private(set) var rows: [[String?]] = []
    /// Columns of the page whose values are bytes; written back as hex literals.
    private(set) var binaryColumns: Set<Int> = []
    /// MongoDB: each row's whole document, so edits keep field types.
    private(set) var documents: DocumentTexts?
    private(set) var totalRows: Int?
    /// Why the total couldn't be counted; the rows still show.
    private(set) var countError: String?
    /// Why the indexes couldn't be read; the columns and rows still show.
    private(set) var indexesError: String?
    private(set) var loading = false
    private(set) var committing = false
    /// Only the newest reload may write its rows; an older one finishing late is dropped.
    private var reloadGeneration = 0
    var error: String?

    var pageSize = Defaults.pageSize
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
    /// MongoDB: a row whose document should open in the editor sheet.
    var documentEditRequest: Int?
    private(set) var appliedFilter = ""

    /// Cell edits, deletions and new rows not committed yet.
    private(set) var changes = PendingRowChanges()
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

    init(table: TableRef, driver: any DatabaseDriver, connectionTag: ConnectionTag) {
        self.table = table
        self.driver = driver
        self.connectionTag = connectionTag
    }

    /// Central gate for every table write, including the toolbar, preview sheet, shortcut and document editor.
    private func confirmProductionWrite() -> Bool {
        connectionTag != .production
            || Confirmation.ask(
                "Save changes on a PRODUCTION connection?",
                detail: "This writes to \(table.schema).\(table.name).",
                action: "Commit"
            )
    }

    // MARK: Loading

    func reload() async {
        reloadGeneration += 1
        let generation = reloadGeneration
        loading = true
        defer {
            if generation == reloadGeneration {
                loading = false
                version += 1
            }
        }
        do {
            if columns.isEmpty {
                let fetched = try await driver.columns(of: table)
                var fetchedIndexes: [IndexInfo] = []
                var indexFailure: String?
                do {
                    fetchedIndexes = try await driver.indexes(of: table)
                } catch {
                    indexFailure = error.localizedDescription
                }
                guard generation == reloadGeneration else { return }
                columns = fetched
                indexes = fetchedIndexes
                indexesError = indexFailure
            }
            let request = TablePageRequest(
                table: table,
                limit: pageSize,
                offset: offset,
                orderBy: orderBy,
                ascending: ascending,
                filter: appliedFilter
            )
            let page = try await driver.fetchPage(request)
            guard generation == reloadGeneration else { return }
            resultColumns = page.columns.isEmpty ? columns.map(\.name) : page.columns
            rows = page.rows
            binaryColumns = page.binaryColumns
            documents = page.documents
            clearPending()
            undoManager.removeAllActions()
            if focusGridOnLoad && !rows.isEmpty {
                focusGridOnLoad = false
                focusRequest = FocusRequest(row: 0, column: 0, edit: false)
            }
            error = nil
            do {
                let count = try await driver.countRows(table, filter: appliedFilter)
                if generation == reloadGeneration {
                    totalRows = count
                    countError = nil
                }
            } catch {
                if generation == reloadGeneration {
                    totalRows = nil
                    countError = error.localizedDescription
                }
            }
        } catch {
            if generation == reloadGeneration {
                self.error = error.localizedDescription
            }
        }
    }

    /// Asks before something drops the pending edits; true when there are none.
    func confirmDiscard(action: String = "Discard") -> Bool {
        guard hasChanges else { return true }
        return Confirmation.ask(
            "Discard \(changeCount) uncommitted change\(changeCount == 1 ? "" : "s") in “\(table.name)”?",
            detail: "Commit them (⌘S) first if you want to keep them.",
            action: action
        )
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
        if showFilterBar && filterRules.isEmpty && !useRawFilter {
            addFilterRule()
        }
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
        if let value, binaryColumns.contains(column), BinaryText.hexDigits(value) != nil, let sql = driver.dialect.sql {
            // Bytes compare with a hex literal; a filter rule compares them with text and would match nothing.
            useRawFilter = true
            filterText = "\(sql.quoteIdentifier(resultColumns[column])) = \(sql.literal(value, binary: true))"
        } else {
            useRawFilter = false
            filterRules = [
                FilterRule(column: resultColumns[column], op: value == nil ? .isNull : .equals, value: value ?? "")
            ]
        }
        showFilterBar = true
        await applyFilter()
    }

    var isFiltered: Bool { !appliedFilter.isEmpty }

    /// The remembered filter the tab opened with, to tell a filter set in this tab from one it only brought back.
    private(set) var restoredFilter: WorkspaceState.TableFilter?

    /// Whether the filter bar differs from what the tab opened with.
    var filterChangedInTab: Bool { rememberedFilter != restoredFilter }

    /// The filter bar as the workspace remembers it for this table, or nil when it holds nothing worth keeping
    /// (not applied, no raw condition, and only rules still waiting for a value).
    var rememberedFilter: WorkspaceState.TableFilter? {
        // A filter this version couldn't read is kept as it was until the bar holds one of its own.
        if let kept = unreadableFilter, filterRules.isEmpty, filterText.isEmpty, !isFiltered {
            return kept
        }
        let hasRuleContent = filterRules.contains { rule in
            !rule.op.needsValue || !rule.value.isEmpty
        }
        let hasRawCondition = !filterText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard isFiltered || hasRuleContent || hasRawCondition else {
            return nil
        }
        let rules = filterRules.map { rule in
            WorkspaceState.TableFilter.Rule(
                column: rule.column,
                op: rule.op.rawValue,
                value: rule.value,
                conjunction: rule.conjunction.rawValue,
                enabled: rule.isEnabled
            )
        }
        return WorkspaceState.TableFilter(
            rules: rules,
            rawCondition: filterText,
            usesRawCondition: useRawFilter,
            appliedCondition: appliedFilter,
            engine: driver.kind.rawValue
        )
    }

    /// A remembered filter this version can't read (a newer version's operator), kept rather than lost.
    private var unreadableFilter: WorkspaceState.TableFilter?

    /// Puts a remembered filter back in the bar, before the first load. The condition that was applied is applied
    /// again, as it ran, and the bar shown, so the rows it hides are not a surprise.
    ///
    /// Not restored: a filter written for another engine (the connection was switched, so the condition would mean
    /// something else), which is forgotten; and one with an operator this version doesn't know (written by a
    /// newer version), which is kept for that version.
    func restoreFilter(_ remembered: WorkspaceState.TableFilter) {
        if let engine = remembered.engine, engine != driver.kind.rawValue {
            return
        }
        var rules: [FilterRule] = []
        for saved in remembered.rules {
            guard let op = FilterRule.Operator(rawValue: saved.op),
                let conjunction = FilterRule.Conjunction(rawValue: saved.conjunction)
            else {
                unreadableFilter = remembered
                return
            }
            let rule = FilterRule(
                column: saved.column,
                op: op,
                value: saved.value,
                conjunction: conjunction,
                isEnabled: saved.enabled
            )
            rules.append(rule)
        }
        restoredFilter = remembered
        filterRules = rules
        filterText = remembered.rawCondition
        useRawFilter = remembered.usesRawCondition
        appliedFilter = remembered.appliedCondition
        if isFiltered {
            showFilterBar = true
        }
    }

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
        guard !rows.isEmpty else {
            return totalRows.map { "\($0) rows" } ?? "No rows"
        }
        let range = "\(offset + 1)–\(offset + rows.count)"
        if let totalRows {
            return "\(range) of \(totalRows)"
        }
        if countError != nil {
            return "\(range) of ?"
        }
        return range
    }

    // MARK: Editing

    private var primaryKeyIndices: [Int] {
        columns.filter(\.isPrimaryKey).compactMap { key in resultColumns.firstIndex(of: key.name) }
    }

    /// Updates and deletes target rows by primary key; without one only inserts are possible.
    var canEditExisting: Bool { table.kind == .table && !primaryKeyIndices.isEmpty }
    var canInsert: Bool { table.kind == .table }

    var displayRowCount: Int { rows.count + changes.insertedRows.count }

    var hasChanges: Bool { !changes.isEmpty }

    var changeCount: Int { changes.count }

    func cell(row: Int, column: Int) -> Cell {
        switch changes.cell(row: row, column: column, existing: rows) {
        case .value(let text):
            return .value(text)
        case .null:
            return .null
        case .columnDefault:
            return .defaultValue
        }
    }

    func state(row: Int, column: Int) -> CellState {
        if row >= rows.count {
            return .inserted
        }
        if changes.isDeleted(row) {
            return .deleted
        }
        if changes.isEdited(row: row, column: column) {
            return .edited
        }
        return .normal
    }

    func isEditable(row: Int) -> Bool {
        // A row the grid doesn't show (stale after a reload) is never written to.
        guard row >= 0, row < displayRowCount else {
            return false
        }
        if row >= rows.count {
            return canInsert
        }
        return canEditExisting && !changes.isDeleted(row)
    }

    /// Records the current changes so the next change can be undone with ⌘Z.
    private func registerUndo(_ name: String) {
        let snapshot = changes
        undoManager.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.restore(snapshot, name: name) }
        }
        undoManager.setActionName(name)
    }

    private func restore(_ snapshot: PendingRowChanges, name: String) {
        registerUndo(name)  // makes the restore itself redoable
        changes = snapshot
        version += 1
    }

    func setValue(_ value: String?, row: Int, column: Int) {
        guard isEditable(row: row) else { return }
        registerUndo("Edit Cell")
        changes.set(value, row: row, column: column, existing: rows)
        version += 1
    }

    /// Appends an empty row and asks the grid to start editing its first cell.
    func addRow() {
        guard canInsert else { return }
        registerUndo("Add Row")
        changes.appendRow()
        version += 1
        focusRequest = FocusRequest(row: displayRowCount - 1, column: firstColumnToFill, edit: true)
    }

    /// Where typing starts in a new row: skip a lone integer primary key, which the database fills in.
    private var firstColumnToFill: Int {
        let keys = columns.filter(\.isPrimaryKey)
        guard keys.count == 1, let key = keys.first,
            ["int", "serial", "objectid"].contains(where: key.dataType.lowercased().contains),
            let index = resultColumns.firstIndex(of: key.name), index == 0, resultColumns.count > 1
        else { return 0 }
        return 1
    }

    /// Copies the selected rows into new rows, leaving primary-key columns to their defaults.
    func duplicateRows(_ indices: IndexSet) {
        guard canInsert, !indices.isEmpty else { return }
        let keyNames = Set(columns.filter(\.isPrimaryKey).map(\.name))
        var copies: [[Int: String?]] = []
        for row in indices.sorted() where row < displayRowCount {
            var copy: [Int: String?] = [:]
            if let documents, row < rows.count {
                // MongoDB: from the stored document, so decimals, dates and longs stay what they are; the row's
                // pending edits go on top.
                do {
                    copy = try MongoChanges.cellsForCopy(of: documents[row], columns: resultColumns)
                } catch {
                    self.error = "Row \(row + 1) couldn't be copied: \(error.localizedDescription)"
                    return
                }
                for (column, value) in changes.edits[row] ?? [:] {
                    copy[column] = .some(value)
                }
            } else {
                for column in resultColumns.indices {
                    switch cell(row: row, column: column) {
                    case .value(let text): copy[column] = .some(text)
                    case .null: copy[column] = .some(nil)
                    case .defaultValue: break
                    }
                }
            }
            for column in resultColumns.indices where keyNames.contains(resultColumns[column]) {
                copy[column] = nil
            }
            copies.append(copy)
        }
        registerUndo("Duplicate Rows")
        for copy in copies {
            changes.appendRow(copy)
        }
        version += 1
        focusRequest = FocusRequest(row: displayRowCount - 1, column: 0, edit: false)
    }

    func deleteRows(_ indices: IndexSet) {
        guard !indices.isEmpty else { return }
        registerUndo(indices.count > 1 ? "Delete Rows" : "Delete Row")
        changes.delete(indices, existingCount: rows.count, existingCanBeDeleted: canEditExisting)
        version += 1
    }

    func restoreRows(_ indices: IndexSet) {
        registerUndo("Restore Rows")
        changes.restore(indices)
        version += 1
    }

    func discardChanges() {
        guard hasChanges else { return }
        registerUndo("Discard Changes")
        clearPending()
        version += 1
    }

    private func clearPending() {
        changes.removeAll()
    }

    /// Statements that apply the pending changes, in the order they will run.
    func pendingStatements() throws -> [String] {
        try driver.dialect.statements(
            for: TableChanges(
                table: table,
                columns: resultColumns,
                rows: rows,
                documents: documents,
                keyColumns: primaryKeyIndices,
                deleted: changes.deletedRows,
                edited: changes.edits,
                inserted: changes.insertedRows,
                binaryColumns: binaryColumns
            )
        )
    }

    /// MongoDB: the row's whole document over indented lines, for the document editor.
    func documentText(row: Int) -> String? {
        guard let documents, documents.indices.contains(row) else { return nil }
        return MongoShell.pretty(documents[row])
    }

    /// MongoDB: replaces the document at `row`, or inserts a new one when `row` is nil. Returns the error, if any.
    func saveDocument(_ text: String, replacing row: Int?) async -> String? {
        guard confirmDiscard(action: "Discard and Save") else {
            return "Commit or discard the changes in the grid first."
        }
        do {
            let statement: String
            if let row {
                guard let documents, documents.indices.contains(row) else {
                    return "Reload the collection and try again."
                }
                statement = try MongoChanges.replace(table, original: documents[row], with: text)
            } else {
                statement = try MongoChanges.insertDocument(table, text: text)
            }
            guard confirmProductionWrite() else {
                return "Save cancelled. Your document has not been changed."
            }
            _ = try await driver.execute(statement)
            await reload()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func commit() async {
        let statements: [String]
        do {
            statements = try pendingStatements()
        } catch {
            self.error = error.localizedDescription
            return
        }
        guard !statements.isEmpty, !committing, confirmProductionWrite() else { return }
        committing = true
        defer { committing = false }
        do {
            try await driver.applyInTransaction(statements)
            await reload()
        } catch {
            guard driver.kind.isDocument else {
                self.error = "Changes were rolled back: \(error.localizedDescription)"
                return
            }
            // MongoDB ran the changes one by one and some may be saved; reload so a second Commit can't repeat them.
            // The message says which ones failed.
            await reload()
            self.error = error.localizedDescription
        }
    }

    // MARK: Export

    func exportText(_ format: ExportFormat) throws -> String {
        // MongoDB INSERTs are written from the documents, so every value keeps its type.
        let exported =
            if format == .sqlInsert, let documents {
                try MongoChanges.rowsForCopy(of: documents, columns: resultColumns)
            } else {
                rows
            }
        return try ResultExporter.export(
            columns: resultColumns,
            rows: exported,
            format: format,
            table: table,
            binaryColumns: binaryColumns,
            dialect: driver.dialect
        )
    }

    func copyText(rows indices: IndexSet) -> String {
        indices.filter { $0 < displayRowCount }
            .map { row in
                (0..<resultColumns.count)
                    .map { column -> String in
                        if case .value(let text) = cell(row: row, column: column) {
                            return text
                        }
                        return cell(row: row, column: column) == .null ? "NULL" : ""
                    }
                    .joined(separator: "\t")
            }
            .joined(separator: "\n")
    }
}
