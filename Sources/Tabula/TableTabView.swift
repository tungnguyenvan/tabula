import AppKit
import SwiftUI
import TabulaCore

struct TableTabView: View {
    @Bindable var model: TableTabModel
    let workspace: WorkspaceModel
    @State private var selection = IndexSet()
    @State private var showingPreview = false
    /// MongoDB: the document open in the editor sheet (row nil = a new document).
    @State private var editingDocument: DocumentEditorSheet.Target?

    var body: some View {
        VStack(spacing: 0) {
            if model.mode == .data && model.showFilterBar {
                FilterBarView(model: model)
                Divider()
            }
            if let error = model.error {
                ErrorBanner(message: error) { model.error = nil }
            }
            switch model.mode {
            case .data:
                DataGridView(
                    source: GridSource(
                        columns: model.resultColumns,
                        rowCount: model.displayRowCount,
                        version: model.version,
                        cell: { model.cell(row: $0, column: $1) },
                        state: { model.state(row: $0, column: $1) },
                        isEditable: { model.isEditable(row: $0) },
                        copyText: { model.copyText(rows: $0) },
                        rowNumberOffset: model.offset,
                        insertedFrom: model.rows.count
                    ),
                    sortColumn: model.orderBy,
                    ascending: model.ascending,
                    selection: $selection,
                    undoManager: model.undoManager,
                    focusRequest: model.focusRequest,
                    onEdit: { row, column, value in model.setValue(value, row: row, column: column) },
                    onSort: { column, ascending in Task { await model.sort(by: column, ascending: ascending) } },
                    onDelete: { model.deleteRows($0); selection = [] },
                    onRestore: { model.restoreRows($0) },
                    onFilterByValue: { row, column in
                        let value: String? = if case .value(let text) = model.cell(row: row, column: column) { text } else { nil }
                        Task { await model.filter(equalTo: value, column: column) }
                    },
                    onDuplicate: model.canInsert ? { model.duplicateRows($0) } : nil
                )
                .overlay { if model.loading && model.rows.isEmpty { ProgressView().controlSize(.small) } }
            case .structure:
                StructureView(model: model)
            }
            Divider()
            bottomBar
        }
        .onChange(of: selection) { _, rows in workspace.inspectedRows = rows }
        .onChange(of: model.showPreviewRequest) { _, _ in if model.hasChanges { showingPreview = true } }
        .onChange(of: model.documentEditRequest) { _, row in
            if let row, let text = model.documentText(row: row) { editingDocument = .init(row: row, text: text) }
            model.documentEditRequest = nil
        }
        .onAppear { workspace.inspectedRows = selection }
        .sheet(item: $editingDocument) { target in
            DocumentEditorSheet(target: target, collection: model.table.name) { text in
                await model.saveDocument(text, replacing: target.row)
            }
        }
        .sheet(isPresented: $showingPreview) {
            SQLPreviewSheet(kind: model.driver.kind, pending: Result { try model.pendingStatements() }) {
                showingPreview = false
                Task { await model.commit() }
            } onCancel: {
                showingPreview = false
            }
        }
    }

    private func editSelectedDocument() {
        guard let row = selection.first, selection.count == 1, let text = model.documentText(row: row) else { return }
        editingDocument = .init(row: row, text: text)
    }

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Picker("Mode", selection: $model.mode) {
                ForEach(TableTabModel.Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            if model.mode == .data {
                HStack(spacing: 2) {
                    let noun = model.driver.kind.rowNoun
                    BarButton(symbol: "plus", help: "Add \(noun)") { model.addRow() }
                        .disabled(!model.canInsert)
                    BarButton(symbol: "minus", help: "Delete selected \(noun)s (⌫)") { model.deleteRows(selection); selection = [] }
                        .disabled(selection.isEmpty || !(model.canEditExisting || selection.contains { $0 >= model.rows.count }))
                    if model.driver.kind.isDocument {
                        BarButton(symbol: "curlybraces", help: "Edit the selected document as JSON") {
                            editSelectedDocument()
                        }
                        .disabled(selection.count != 1 || !model.canEditExisting || (selection.first ?? 0) >= model.rows.count)
                        BarButton(symbol: "doc.badge.plus", help: "Insert a document written as JSON") {
                            editingDocument = .init(row: nil, text: "{\n  \n}")
                        }
                        .disabled(!model.canInsert)
                    }
                }
                BarButton(symbol: model.isFiltered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle",
                          help: "Filter (⌘F)", active: model.showFilterBar || model.isFiltered) {
                    model.toggleFilterBar()
                }
                ExportMenu(suggestedName: model.table.name) { model.exportText($0) }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
            }

            Spacer(minLength: 8)

            if model.hasChanges {
                HStack(spacing: 6) {
                    Text("\(model.changeCount) change\(model.changeCount == 1 ? "" : "s")")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.orange)
                    Button("Preview") { showingPreview = true }
                        .help("Preview \(model.driver.kind.statementsNoun) (⇧⌘S)")
                    Button("Discard") { model.discardChanges() }
                    Button("Commit") { Task { await model.commit() } }
                        .disabled(model.committing)
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .help("Commit changes (⌘S)")
                }
                .controlSize(.small)
                Spacer(minLength: 8)
            } else if model.table.kind == .view {
                Text("Read-only view").font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer(minLength: 8)
            } else if !model.canEditExisting && !model.columns.isEmpty {
                Text("No primary key — rows are read-only").font(.system(size: 11)).foregroundStyle(.tertiary)
                Spacer(minLength: 8)
            }

            if model.mode == .data {
                if model.loading { ProgressView().controlSize(.mini) }
                Text(model.pageDescription)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                Menu {
                    ForEach(Defaults.pageSizeChoices, id: \.self) { size in
                        Button("\(size) rows per page") {
                            guard model.confirmDiscard() else { return }
                            model.pageSize = size
                            Task { await model.reload() }
                        }
                    }
                } label: {
                    Text("\(model.pageSize)/page").font(.system(size: 11))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                HStack(spacing: 2) {
                    BarButton(symbol: "chevron.left", help: "Previous page") { Task { await model.previousPage() } }
                        .disabled(!model.canGoBack || model.hasChanges)
                    BarButton(symbol: "chevron.right", help: "Next page") { Task { await model.nextPage() } }
                        .disabled(!model.canGoForward || model.hasChanges)
                }
            } else {
                BarButton(symbol: "arrow.clockwise", help: "Reload structure") { Task { await model.reloadStructure() } }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 8)
        .frame(height: 30)
        .barBackground()
    }
}

/// Small borderless icon button used in the bottom bars.
struct BarButton: View {
    let symbol: String
    let help: String
    var active = false
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .frame(width: 24, height: 20)
                .foregroundStyle(active ? AnyShapeStyle(Color.accentColor) : (isEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

/// Column / operator / value rows, or a raw SQL condition.
struct FilterBarView: View {
    @Bindable var model: TableTabModel
    @FocusState private var focusedRule: UUID?
    @FocusState private var rawFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.useRawFilter {
                HStack(spacing: 6) {
                    Text(filterKeyword).font(Layout.Font.smallBold.monospaced()).foregroundStyle(.secondary)
                    TextField(isDocument ? "{ age: { $gt: 30 }, status: \"active\" }" : "id > 10 AND status = 'active'", text: $model.filterText)
                        .focused($rawFocused)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .onSubmit { Task { await model.applyFilter() } }
                    controls
                }
            } else {
                ForEach($model.filterRules) { $rule in
                    HStack(spacing: 6) {
                        if rule.id == model.filterRules.first?.id {
                            Text(filterKeyword).font(Layout.Font.smallBold.monospaced()).foregroundStyle(.secondary)
                                .frame(width: Layout.Filter.conjunctionWidth, alignment: .leading)
                        } else {
                            Picker("Join", selection: $rule.conjunction) {
                                ForEach(FilterRule.Conjunction.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .labelsHidden()
                            .frame(width: Layout.Filter.conjunctionWidth)
                            .help("AND binds tighter than OR: a AND b OR c means (a AND b) OR c")
                        }
                        Picker("Column", selection: $rule.column) {
                            ForEach(model.resultColumns, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: Layout.Filter.columnWidth)
                        Picker("Operator", selection: $rule.op) {
                            ForEach(FilterRule.Operator.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: Layout.Filter.operatorWidth)
                        TextField(rule.op == .inList ? "a, b, c" : "Value", text: $rule.value)
                            .focused($focusedRule, equals: rule.id)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .disabled(!rule.op.needsValue)
                            .onSubmit { Task { await model.applyFilter() } }
                        BarButton(symbol: "minus.circle", help: "Remove condition") {
                            model.filterRules.removeAll { $0.id == rule.id }
                        }
                        BarButton(symbol: "plus.circle", help: "Add condition") { model.addFilterRule() }
                        if rule.id == model.filterRules.first?.id { controls }
                    }
                }
                if model.filterRules.isEmpty {
                    HStack {
                        Button("Add Condition") { model.addFilterRule() }
                        Spacer()
                        controls
                    }
                }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear(perform: focusValue)
        .onChange(of: model.filterFocusRequest) { _, _ in focusValue() }
        .onExitCommand { model.showFilterBar = false } // Esc closes the bar; the applied filter stays.
    }

    private var isDocument: Bool { model.driver.kind.isDocument }
    private var filterKeyword: String { isDocument ? "FIND" : "WHERE" }

    private func focusValue() {
        DispatchQueue.main.async {
            if model.useRawFilter { rawFocused = true } else { focusedRule = model.filterRules.last?.id }
        }
    }

    private var controls: some View {
        HStack(spacing: 6) {
            Toggle(isDocument ? "{ }" : "SQL", isOn: $model.useRawFilter)
                .toggleStyle(.button)
                .help(isDocument ? "Write the query document by hand" : "Write the WHERE condition by hand")
            Button("Apply") { Task { await model.applyFilter() } }
                .keyboardShortcut(.defaultAction)
            if model.isFiltered {
                Button("Clear") { Task { await model.clearFilter() } }
            }
        }
    }
}

struct StructureView: View {
    let model: TableTabModel

    var body: some View {
        VSplitView {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.driver.kind.isDocument ? "Fields (from the first \(Defaults.Mongo.sampleSize) documents)" : "Columns")
                    .font(.headline).padding([.horizontal, .top], 10)
                if model.driver.kind.isDocument { fieldsTable } else { columnsTable }
            }
            .frame(minHeight: 160)
            VStack(alignment: .leading, spacing: 4) {
                Text("Indexes").font(.headline).padding([.horizontal, .top], 10)
                Table(model.indexes) {
                    TableColumn("Name") { Text($0.name).font(.body.monospaced()) }
                    TableColumn(model.driver.kind.isDocument ? "Fields" : "Columns") { Text($0.columns.joined(separator: ", ")).font(.body.monospaced()) }
                    TableColumn("Kind") { index in
                        Text(index.isPrimary ? "PRIMARY" : index.isUnique ? "UNIQUE" : "INDEX")
                    }
                    .width(80)
                    TableColumn("Definition") { Text($0.definition ?? "").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled) }
                }
            }
            .frame(minHeight: 120)
        }
    }

    private var columnsTable: some View {
        Table(model.columns) {
            TableColumn("Name") { column in
                HStack(spacing: 4) {
                    if column.isPrimaryKey { Image(systemName: "key.fill").foregroundStyle(.yellow).font(.caption) }
                    Text(column.name).font(.body.monospaced())
                }
            }
            TableColumn("Type") { Text($0.dataType).font(.body.monospaced()) }
            TableColumn("Nullable") { Text($0.isNullable ? "YES" : "NO").foregroundStyle($0.isNullable ? .secondary : .primary) }
                .width(70)
            TableColumn("Default") { Text($0.defaultValue ?? "—").font(.body.monospaced()).foregroundStyle(.secondary) }
            TableColumn("Comment") { Text($0.comment ?? "").foregroundStyle(.secondary) }
        }
    }

    /// MongoDB fields have no defaults or comments; the types are what the sample showed.
    private var fieldsTable: some View {
        Table(model.columns) {
            TableColumn("Name") { column in
                HStack(spacing: 4) {
                    if column.isPrimaryKey { Image(systemName: "key.fill").foregroundStyle(.yellow).font(.caption) }
                    Text(column.name).font(.body.monospaced())
                }
            }
            TableColumn("Types seen") { Text($0.dataType).font(.body.monospaced()) }
            TableColumn("Missing in some") { Text($0.isNullable ? "YES" : "NO").foregroundStyle($0.isNullable ? .secondary : .primary) }
        }
    }
}

/// MongoDB: one document written out in full, to edit nested fields or insert a new document.
struct DocumentEditorSheet: View {
    struct Target: Identifiable {
        let id = UUID()
        /// The row being replaced; nil inserts a new document.
        var row: Int?
        var text: String
    }

    let target: Target
    let collection: String
    /// Saves and returns the error, or nil when it worked.
    let save: (String) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?
    @State private var saving = false
    @State private var handle = EditorHandle()
    @State private var undoManager = UndoManager()

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.barPadding) {
            Text(target.row == nil ? "Insert into \(collection)" : "Edit document in \(collection)").font(.headline)
            Text("Shell syntax: ObjectId(\"…\"), ISODate(\"…\"), NumberLong(…) and NumberDecimal(\"…\") keep their types. "
                 + (target.row == nil ? "Leave out _id to have one generated." : "The document is replaced as a whole, matched by its _id."))
                .font(.caption).foregroundStyle(.secondary)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout).lineLimit(4)
            }
            SQLEditorView(text: $text, handle: handle, kind: .mongodb,
                          suggest: { _, caret in (NSRange(location: caret, length: 0), []) },
                          undoManager: undoManager) { _ in Task { await submit() } }
                .border(Color(nsColor: .separatorColor))
            HStack {
                Button("Format") { handle.beautify(kind: .mongodb); text = MongoShell.pretty(text) }
                    .help("Lay the document out over indented lines")
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(target.row == nil ? "Insert" : "Save") { Task { await submit() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Layout.Sheet.padding)
        .frame(width: Layout.Sheet.documentWidth, height: Layout.Sheet.documentHeight)
        .onAppear { text = target.text }
    }

    private func submit() async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        if let message = await save(text) { error = message } else { dismiss() }
    }
}

struct SQLPreviewSheet: View {
    let kind: DatabaseKind
    let pending: Result<[String], any Error>
    let onCommit: () -> Void
    let onCancel: () -> Void

    private var statements: [String] { (try? pending.get()) ?? [] }
    private var script: String { statements.map { $0 + ";" }.joined(separator: "\n") }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pending changes").font(.headline)
            Text(kind.isDocument
                 ? "These commands run one after another. If one fails, the ones before it stay saved."
                 : "These statements run in a single transaction. If any fails, all are rolled back.")
                .font(.caption).foregroundStyle(.secondary)
            if case .failure(let error) = pending {
                Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            ScrollView {
                Text(script).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Button("Copy \(kind.statementsNoun)") {
                    Clipboard.copy(script)
                }
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button("Commit", action: onCommit).keyboardShortcut(.defaultAction).disabled(statements.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 640, height: 420)
    }
}

struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(.red)
            Text(message).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.borderless)
        }
        .padding(8)
        .background(Color.red.opacity(0.1))
    }
}

struct ExportMenu: View {
    let suggestedName: String
    let text: (ExportFormat) -> String

    var body: some View {
        Menu {
            Section("Save to file") {
                ForEach(ExportFormat.allCases) { format in
                    Button("\(format.displayName)…") { save(format) }
                }
            }
            Section("Copy to clipboard") {
                ForEach(ExportFormat.allCases) { format in
                    Button("Copy as \(format.displayName)") {
                        Clipboard.copy(text(format))
                    }
                }
            }
        } label: {
            Image(systemName: "square.and.arrow.up").font(.system(size: 12))
        }
        .fixedSize()
        .help("Export the rows shown")
    }

    private func save(_ format: ExportFormat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(suggestedName).\(format.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? text(format).write(to: url, atomically: true, encoding: .utf8)
    }
}
