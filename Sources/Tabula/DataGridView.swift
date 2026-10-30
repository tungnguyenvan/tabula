import AppKit
import SwiftUI

enum GridCell: Equatable {
    case value(String)
    case null, defaultValue
}

enum GridCellState {
    case normal, edited, deleted, inserted
}

/// Rows as tab-separated text, as Excel puts them on the pasteboard and spreadsheets read them back: a field with a
/// tab or a line break, or starting with a quote, goes in quotes with its quotes doubled.
enum TabSeparated {
    static func text(_ rows: [[String]]) -> String {
        rows.map { $0.map(field).joined(separator: "\t") }.joined(separator: "\n")
    }

    static func field(_ value: String) -> String {
        guard value.contains(where: { $0 == "\t" || $0.isNewline }) || value.hasPrefix("\"") else {
            return value
        }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

/// Everything the grid needs to draw; closures read straight from the owning model.
struct GridSource {
    var columns: [String]
    var rowCount: Int
    /// Changes whenever the underlying data changes, so the grid reloads.
    var version: Int
    var cell: (_ row: Int, _ column: Int) -> GridCell
    var state: (_ row: Int, _ column: Int) -> GridCellState = { _, _ in .normal }
    var isEditable: (_ row: Int) -> Bool = { _ in false }
    /// Columns that can never be edited (e.g. computed ones) return false.
    var isColumnEditable: (_ column: Int) -> Bool = { _ in true }
    /// The selected rows' cells as text, for Copy; the grid writes them as a spreadsheet reads them.
    var copyRows: (IndexSet) -> [[String]]
    /// Added to the row index for the row-number gutter (the page offset).
    var rowNumberOffset = 0
    /// Rows at or after this index are new and numbered "+".
    var insertedFrom = Int.max
}

/// A spreadsheet-style grid on NSTableView: rows are selected, and one cell in the
/// current row has keyboard focus (arrows, Tab, Return to edit, typing to replace).
struct DataGridView: NSViewRepresentable {
    var source: GridSource
    var sortColumn: String?
    var ascending = true
    @Binding var selection: IndexSet
    var undoManager: UndoManager?
    /// Moves focus to a cell (and optionally edits it), e.g. after "Add Row".
    var focusRequest: TableTabModel.FocusRequest?
    var onEdit: ((_ row: Int, _ column: Int, _ value: String?) -> Void)?
    var onSort: ((_ column: String, _ ascending: Bool) -> Void)?
    var onDelete: ((IndexSet) -> Void)?
    var onRestore: ((IndexSet) -> Void)?
    var onFilterByValue: ((_ row: Int, _ column: Int) -> Void)?
    var onDuplicate: ((IndexSet) -> Void)?
    /// Double-clicking the empty space below the last row adds a row, like the bar's + button.
    var onAddRow: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = GridTableView()
        tableView.coordinator = context.coordinator
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.gridStyleMask = [.solidVerticalGridLineMask]
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.rowHeight = 21
        tableView.style = .plain
        tableView.target = context.coordinator
        tableView.action = #selector(Coordinator.clicked(_:))
        tableView.doubleAction = #selector(Coordinator.doubleClicked(_:))

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        context.coordinator.tableView = tableView
        context.coordinator.apply(self)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.apply(self)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
        var parent: DataGridView
        weak var tableView: GridTableView?
        private var columns: [String] = []
        private var version = -1
        private var applyingSort = false
        private var reloadAfterEditing = false
        private var handledFocusRequest: UUID?
        /// Table-view column index of the focused cell; 0 is the row-number gutter, so data starts at 1.
        private(set) var focusedColumn = 1
        /// Where Copy writes: the system pasteboard, except in tests.
        var pasteboard = NSPasteboard.general
        private var focusedRow = -1
        private var popover: NSPopover?
        /// The binding value seen last; a different value means SwiftUI changed the selection itself.
        private var lastParentSelection = IndexSet()
        private var sizedWithRows = false

        init(_ parent: DataGridView) { self.parent = parent }

        func apply(_ parent: DataGridView) {
            self.parent = parent
            guard let tableView else { return }
            // Rebuild when columns change, and once more when the first rows arrive so widths fit the data.
            if parent.source.columns != columns || (!sizedWithRows && parent.source.rowCount > 0) {
                columns = parent.source.columns
                sizedWithRows = parent.source.rowCount > 0
                rebuildColumns(tableView)
                focusedColumn = min(max(focusedColumn, 1), max(1, tableView.numberOfColumns - 1))
                version = -1
            }
            if parent.source.version != version {
                version = parent.source.version
                if tableView.currentEditor() == nil {
                    tableView.reloadData()
                } else {
                    reloadAfterEditing = true
                }
            }
            let descriptors = parent.sortColumn.map { [NSSortDescriptor(key: $0, ascending: parent.ascending)] } ?? []
            if tableView.sortDescriptors != descriptors {
                applyingSort = true
                tableView.sortDescriptors = descriptors
                applyingSort = false
            }
            // Only push SwiftUI's selection when it changed on its own; otherwise a stale binding value
            // (updated asynchronously) would undo a selection the user just made with the keyboard.
            if parent.selection != lastParentSelection {
                lastParentSelection = parent.selection
                if tableView.selectedRowIndexes != parent.selection,
                    parent.selection.allSatisfy({ $0 < parent.source.rowCount })
                {
                    tableView.selectRowIndexes(parent.selection, byExtendingSelection: false)
                    if let first = parent.selection.first {
                        tableView.scrollRowToVisible(first)
                    }
                }
            }
            // A hidden tab's grid takes its focus request when the tab is shown, not from the tab in front.
            if let request = parent.focusRequest, request.id != handledFocusRequest,
                request.row < parent.source.rowCount,
                !tableView.isHiddenOrHasHiddenAncestor
            {
                handledFocusRequest = request.id
                DispatchQueue.main.async { [weak self] in
                    self?
                        .focus(
                            row: request.row,
                            tableColumn: (self?.tableColumn(forData: request.column) ?? 1),
                            edit: request.edit
                        )
                }
            }
        }

        private static let gutterID = NSUserInterfaceItemIdentifier("#")

        /// The data column for a table-view column index, or nil for the row-number gutter.
        func dataColumn(_ tableColumn: Int) -> Int? {
            guard let tableView, tableView.tableColumns.indices.contains(tableColumn) else { return nil }
            return Int(tableView.tableColumns[tableColumn].identifier.rawValue)
        }

        /// The table-view column showing a data column (columns can be reordered by dragging).
        func tableColumn(forData column: Int) -> Int? {
            guard let tableView else { return nil }
            let index = tableView.column(withIdentifier: NSUserInterfaceItemIdentifier("\(column)"))
            return index >= 0 ? index : nil
        }

        private func rebuildColumns(_ tableView: NSTableView) {
            tableView.tableColumns.forEach(tableView.removeTableColumn)
            // Take the new row count before adding columns: each added column makes the table fill in its cells
            // for the rows it shows, and with the old count those could be rows the new result doesn't have.
            tableView.reloadData()
            let font = GridCellView.font
            let gutter = NSTableColumn(identifier: Self.gutterID)
            gutter.title = ""
            let digits = String(max(parent.source.rowCount + parent.source.rowNumberOffset, 99)).count
            gutter.width = CGFloat(digits) * 7 + 14
            gutter.minWidth = gutter.width
            gutter.resizingMask = []
            tableView.addTableColumn(gutter)
            for (index, name) in columns.enumerated() {
                let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("\(index)"))
                column.title = name
                column.headerToolTip = name
                column.sortDescriptorPrototype =
                    parent.onSort == nil ? nil : NSSortDescriptor(key: name, ascending: true)
                column.minWidth = 40
                column.headerCell.font = .systemFont(ofSize: 11, weight: .medium)
                var widest =
                    (name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium)])
                    .width + 28
                // Sample up to ~200 rows spread over the whole result, not just the top.
                let count = parent.source.rowCount
                for row in stride(from: 0, to: count, by: max(1, count / 200)) {
                    if case .value(let text) = parent.source.cell(row, index) {
                        widest = max(
                            widest,
                            (String(text.prefix(80)) as NSString).size(withAttributes: [.font: font]).width + 16
                        )
                    }
                }
                column.width = min(max(widest, 64), index == columns.count - 1 ? 640 : 380)
                tableView.addTableColumn(column)
            }
        }

        // MARK: Data source

        func numberOfRows(in tableView: NSTableView) -> Int { parent.source.rowCount }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn else { return nil }
            if tableColumn.identifier == Self.gutterID {
                let view =
                    (tableView.makeView(withIdentifier: Self.gutterID, owner: nil) as? GutterCellView)
                    ?? {
                        let view = GutterCellView()
                        view.identifier = Self.gutterID
                        return view
                    }()
                let source = parent.source
                view.textField?.stringValue = row >= source.insertedFrom ? "+" : "\(row + 1 + source.rowNumberOffset)"
                return view
            }
            guard let column = Int(tableColumn.identifier.rawValue) else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("cell")
            let view =
                (tableView.makeView(withIdentifier: identifier, owner: nil) as? GridCellView)
                ?? {
                    let view = GridCellView()
                    view.identifier = identifier
                    view.textField?.delegate = self
                    return view
                }()
            // The table can ask for a cell before it has caught up with a new result (while editing, say).
            guard row < parent.source.rowCount, column < parent.source.columns.count else {
                return view
            }
            view.configure(parent.source.cell(row, column), state: parent.source.state(row, column))
            view.isFocusedCell =
                row == tableView.selectedRow
                && tableView.column(withIdentifier: tableColumn.identifier) == focusedColumn
            return view
        }

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard !applyingSort, let descriptor = tableView.sortDescriptors.first, let key = descriptor.key else {
                return
            }
            parent.onSort?(key, descriptor.ascending)
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard let tableView else { return }
            refreshFocus()
            let selected = tableView.selectedRowIndexes
            DispatchQueue.main.async { [weak self] in
                guard let self, self.parent.selection != selected else { return }
                self.lastParentSelection = selected
                self.parent.selection = selected
            }
        }

        // MARK: Focus

        /// Moves the focus ring by updating existing cell views (no reload, so an active cell editor survives).
        private func refreshFocus() {
            guard let tableView else { return }
            let rows = Set([focusedRow, tableView.selectedRow]).filter { $0 >= 0 && $0 < tableView.numberOfRows }
            focusedRow = tableView.selectedRow
            for row in rows {
                for column in 1..<max(1, tableView.numberOfColumns) {
                    (tableView.view(atColumn: column, row: row, makeIfNecessary: false) as? GridCellView)?
                        .isFocusedCell =
                        row == focusedRow && column == focusedColumn
                }
            }
        }

        func moveFocus(toColumn column: Int) {
            guard let tableView, tableView.numberOfColumns > 1 else { return }
            if tableView.selectedRow < 0 && tableView.numberOfRows > 0 {
                tableView.selectRowIndexes([0], byExtendingSelection: false)
            }
            focusedColumn = min(max(column, 1), tableView.numberOfColumns - 1)
            tableView.scrollColumnToVisible(focusedColumn)
            focusedRow = -1
            refreshFocus()
        }

        func focus(row: Int, tableColumn: Int, edit: Bool) {
            guard let tableView, !tableView.isHiddenOrHasHiddenAncestor, row >= 0, row < tableView.numberOfRows else {
                return
            }
            tableView.selectRowIndexes([row], byExtendingSelection: false)
            tableView.scrollRowToVisible(row)
            tableView.window?.makeFirstResponder(tableView)
            moveFocus(toColumn: tableColumn)
            if edit {
                beginEditing(row: row, column: focusedColumn)
            }
        }

        /// Moves to the next/previous cell, wrapping across rows like a spreadsheet.
        func advance(by step: Int, edit: Bool) {
            guard let tableView, tableView.selectedRow >= 0 else { return }
            var row = tableView.selectedRow
            var column = focusedColumn + step
            let last = tableView.numberOfColumns - 1
            if column > last {
                column = 1
                row += 1
            }
            if column < 1 {
                column = last
                row -= 1
            }
            guard row >= 0 && row < tableView.numberOfRows else { return }
            focus(row: row, tableColumn: column, edit: edit && parent.source.isEditable(row))
        }

        @objc func clicked(_ sender: Any?) {
            guard let tableView, tableView.clickedColumn >= 1 else { return }
            focusedColumn = tableView.clickedColumn
            focusedRow = -1
            refreshFocus()
        }

        // MARK: Editing

        @objc func doubleClicked(_ sender: Any?) {
            // The row-number gutter (column 0) isn't a cell, as with single clicks.
            guard let tableView, tableView.clickedRow >= 0, tableView.clickedColumn >= 1 else { return }
            focusedColumn = tableView.clickedColumn
            if parent.onEdit != nil && parent.source.isEditable(tableView.clickedRow),
                dataColumn(focusedColumn).map(parent.source.isColumnEditable) == true
            {
                beginEditing(row: tableView.clickedRow, column: focusedColumn)
            } else {
                showQuickLook()
            }
        }

        var canEditFocusedCell: Bool {
            guard let tableView, parent.onEdit != nil, tableView.selectedRow >= 0 else { return false }
            guard let column = dataColumn(focusedColumn) else { return false }
            return parent.source.isEditable(tableView.selectedRow) && parent.source.isColumnEditable(column)
        }

        /// Starts editing; `replacingWith` begins with typed text instead of the current value.
        func beginEditing(row: Int, column: Int, replacingWith initial: String? = nil) {
            guard let tableView, parent.onEdit != nil, row >= 0, let dataColumn = dataColumn(column),
                parent.source.isEditable(row),
                parent.source.isColumnEditable(dataColumn),
                let view = tableView.view(atColumn: column, row: row, makeIfNecessary: true) as? GridCellView,
                let field = view.textField
            else { return }
            if let initial {
                field.stringValue = initial
            } else if case .value(let text) = parent.source.cell(row, dataColumn) {
                field.stringValue = text
            } else {
                field.stringValue = ""
            }
            view.beginEditingAppearance()
            field.isEditable = true
            tableView.window?.makeFirstResponder(field)
            if initial == nil {
                field.currentEditor()?.selectAll(nil)
            } else if let editor = field.currentEditor() {
                editor.selectedRange = NSRange(location: (field.stringValue as NSString).length, length: 0)
            }
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField, let tableView else { return }
            field.isEditable = false
            let row = tableView.row(for: field)
            let column = tableView.column(for: field)
            let movement = notification.userInfo?["NSTextMovement"] as? Int
            defer {
                if reloadAfterEditing {
                    reloadAfterEditing = false
                    tableView.reloadData()
                } else if row >= 0 && column >= 0 {
                    tableView.reloadData(forRowIndexes: [row], columnIndexes: [column])
                }
            }
            guard row >= 0, let dataColumn = dataColumn(column), movement != NSTextMovement.cancel.rawValue else {
                return
            }
            let newValue = field.stringValue
            switch parent.source.cell(row, dataColumn) {
            case .value(let old) where old == newValue: return
            case .null, .defaultValue: if newValue.isEmpty { return }
            default: break
            }
            parent.onEdit?(row, dataColumn, newValue)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard let field = control as? NSTextField, let tableView else { return false }
            switch selector {
            case #selector(NSResponder.cancelOperation(_:)):
                // Escape: leave the cell unchanged.
                field.abortEditing()
                field.isEditable = false
                let row = tableView.row(for: field)
                let column = tableView.column(for: field)
                if row >= 0 && column >= 0 {
                    tableView.reloadData(forRowIndexes: [row], columnIndexes: [column])
                }
                tableView.window?.makeFirstResponder(tableView)
                return true
            case #selector(NSResponder.insertNewline(_:)):
                // Return: save and move down, like a spreadsheet.
                let row = tableView.row(for: field)
                tableView.window?.makeFirstResponder(tableView)
                if row + 1 < tableView.numberOfRows {
                    tableView.selectRowIndexes([row + 1], byExtendingSelection: false)
                    tableView.scrollRowToVisible(row + 1)
                }
                return true
            case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
                // Tab / ⇧Tab: save and edit the next / previous cell.
                let step = selector == #selector(NSResponder.insertTab(_:)) ? 1 : -1
                tableView.window?.makeFirstResponder(tableView)
                DispatchQueue.main.async { [weak self] in self?.advance(by: step, edit: true) }
                return true
            case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                // ⌥Return: a literal newline inside the value.
                textView.insertText("\n", replacementRange: textView.selectedRange())
                return true
            default:
                return false
            }
        }

        // MARK: Commands

        func copySelection(withHeader: Bool = false) {
            guard let tableView else { return }
            let rows = tableView.selectedRowIndexes
            guard !rows.isEmpty else { return }
            var lines = parent.source.copyRows(rows)
            if withHeader {
                lines.insert(parent.source.columns, at: 0)
            }
            Clipboard.copy(TabSeparated.text(lines), to: pasteboard)
        }

        func copyFocusedCell() {
            guard let tableView, tableView.selectedRow >= 0, let column = dataColumn(focusedColumn) else { return }
            let text: String =
                switch parent.source.cell(tableView.selectedRow, column) {
                case .value(let value): value
                case .null: "NULL"
                case .defaultValue: ""
                }
            Clipboard.copy(text, to: pasteboard)
        }

        func deleteSelection() {
            guard let tableView, let onDelete = parent.onDelete else { return }
            let rows = tableView.selectedRowIndexes
            if !rows.isEmpty {
                onDelete(rows)
            }
        }

        func setFocusedCellNull() {
            guard canEditFocusedCell, let tableView, let column = dataColumn(focusedColumn) else { return }
            parent.onEdit?(tableView.selectedRow, column, nil)
        }

        /// Space: show the full value of the focused cell (JSON pretty-printed) in a popover.
        func showQuickLook() {
            if let popover, popover.isShown {
                popover.close()
                return
            }
            guard let tableView, tableView.selectedRow >= 0, let column = dataColumn(focusedColumn) else { return }
            let row = tableView.selectedRow
            let text: String
            switch parent.source.cell(row, column) {
            case .value(let value): text = Self.prettyJSON(value) ?? value
            case .null: text = "NULL"
            case .defaultValue: text = "DEFAULT"
            }
            let controller = ValuePopoverController(title: parent.source.columns[column], text: text)
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = controller
            popover.show(
                relativeTo: tableView.frameOfCell(atColumn: focusedColumn, row: row),
                of: tableView,
                preferredEdge: .maxY
            )
            self.popover = popover
        }

        static func prettyJSON(_ text: String) -> String? {
            guard let first = text.trimmingCharacters(in: .whitespaces).first, first == "{" || first == "[",
                let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)),
                let data = try? JSONSerialization.data(
                    withJSONObject: object,
                    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                )
            else {
                return nil
            }
            return String(data: data, encoding: .utf8)
        }

        func menu(row: Int, column: Int) -> NSMenu? {
            guard let tableView, row >= 0 else { return nil }
            if !tableView.selectedRowIndexes.contains(row) {
                tableView.selectRowIndexes([row], byExtendingSelection: false)
            }
            if column >= 1 {
                focusedColumn = column
                refreshFocus()
            }
            let rows = tableView.selectedRowIndexes
            let menu = NSMenu()
            let dataColumn = dataColumn(column)

            if dataColumn != nil {
                menu.addItem(ClosureMenuItem("Quick Look", key: " ") { [weak self] in self?.showQuickLook() })
                menu.addItem(
                    ClosureMenuItem("Copy Cell Value", key: "c", modifiers: [.command, .option]) { [weak self] in
                        self?.copyFocusedCell()
                    }
                )
            }
            menu.addItem(
                ClosureMenuItem(rows.count > 1 ? "Copy \(rows.count) Rows" : "Copy Row", key: "c") { [weak self] in
                    self?.copySelection()
                }
            )
            menu.addItem(
                ClosureMenuItem("Copy with Column Names", key: "c", modifiers: [.command, .option, .shift]) {
                    [weak self] in
                    self?.copySelection(withHeader: true)
                }
            )
            if let onFilter = parent.onFilterByValue, let dataColumn, row < parent.source.insertedFrom {
                menu.addItem(.separator())
                menu.addItem(ClosureMenuItem("Filter by This Value") { onFilter(row, dataColumn) })
            }
            if let onEdit = parent.onEdit, let dataColumn, parent.source.isEditable(row),
                parent.source.isColumnEditable(dataColumn)
            {
                menu.addItem(.separator())
                menu.addItem(
                    ClosureMenuItem("Edit Cell", key: "\r", modifiers: []) { [weak self] in
                        self?.beginEditing(row: row, column: column)
                    }
                )
                menu.addItem(
                    ClosureMenuItem("Set NULL", key: "\u{8}", modifiers: [.option]) { onEdit(row, dataColumn, nil) }
                )
                menu.addItem(ClosureMenuItem("Set Empty String") { onEdit(row, dataColumn, "") })
            }
            if let onDuplicate = parent.onDuplicate {
                menu.addItem(.separator())
                menu.addItem(
                    ClosureMenuItem(rows.count > 1 ? "Duplicate \(rows.count) Rows" : "Duplicate Row", key: "d") {
                        onDuplicate(rows)
                    }
                )
            }
            if let onDelete = parent.onDelete {
                if parent.onDuplicate == nil {
                    menu.addItem(.separator())
                }
                let deleted = rows.filter { parent.source.state($0, 0) == .deleted }
                if !deleted.isEmpty, let onRestore = parent.onRestore {
                    menu.addItem(
                        ClosureMenuItem("Restore Row\(deleted.count > 1 ? "s" : "")") { onRestore(IndexSet(deleted)) }
                    )
                }
                menu.addItem(
                    ClosureMenuItem(
                        rows.count > 1 ? "Delete \(rows.count) Rows" : "Delete Row",
                        key: "\u{8}",
                        modifiers: [.command]
                    ) {
                        onDelete(rows)
                    }
                )
            }
            return menu
        }
    }
}
