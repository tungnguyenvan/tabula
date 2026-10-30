import AppKit
import SwiftUI
import TabulaFoundation
import TabulaMongo
import TabulaSQL
import TabulaTransfer

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
                        copyRows: { model.copyRows($0) },
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
                    onDelete: {
                        model.deleteRows($0)
                        selection = []
                    },
                    onRestore: { model.restoreRows($0) },
                    onFilterByValue: { row, column in
                        let value: String? =
                            if case .value(let text) = model.cell(row: row, column: column) {
                                text
                            } else {
                                nil
                            }
                        Task { await model.filter(equalTo: value, column: column) }
                    },
                    onDuplicate: model.canInsert ? { model.duplicateRows($0) } : nil,
                    onAddRow: model.canInsert ? { model.addRow() } : nil,
                    onPaste: model.canInsert || model.canEditExisting
                        ? { text, row, column in model.paste(text, row: row, column: column) } : nil
                )
                .overlay { if model.loading && model.rows.isEmpty { ProgressView().controlSize(.small) } }
            case .structure:
                StructureView(model: model)
            }
            Divider()
            bottomBar
        }
        .onChange(of: selection) { _, rows in workspace.setSelection(rows, inTab: model.id) }
        // A rebuilt view starts with no selection; the inspector and ⌘D must not keep using the old rows.
        .onAppear { workspace.setSelection(selection, inTab: model.id) }
        .onChange(of: model.showPreviewRequest) { _, _ in if model.hasChanges { showingPreview = true } }
        .onChange(of: model.documentEditRequest) { _, row in
            if let row, let text = model.documentText(row: row) {
                editingDocument = .init(row: row, text: text)
            }
            model.documentEditRequest = nil
        }
        .sheet(item: $editingDocument) { target in
            DocumentEditorSheet(target: target, collection: model.table.name) { text in
                await model.saveDocument(text, replacing: target.row)
            }
        }
        .sheet(isPresented: $showingPreview) {
            SQLPreviewSheet(
                kind: model.driver.kind,
                dialect: model.driver.dialect,
                pending: Result { try model.pendingStatements() }
            ) {
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
                    BarButton(symbol: "plus", help: "Add \(noun) (or double-click below the \(noun)s)") {
                        model.addRow()
                    }
                    .disabled(!model.canInsert)
                    BarButton(symbol: "minus", help: "Delete selected \(noun)s (⌫)") {
                        model.deleteRows(selection)
                        selection = []
                    }
                    .disabled(
                        selection.isEmpty || !(model.canEditExisting || selection.contains { $0 >= model.rows.count })
                    )
                    if model.driver.kind.isDocument {
                        BarButton(symbol: "curlybraces", help: "Edit the selected document as JSON") {
                            editSelectedDocument()
                        }
                        .disabled(
                            selection.count != 1 || !model.canEditExisting || (selection.first ?? 0) >= model.rows.count
                        )
                        BarButton(symbol: "doc.badge.plus", help: "Insert a document written as JSON") {
                            editingDocument = .init(row: nil, text: "{\n  \n}")
                        }
                        .disabled(!model.canInsert)
                    }
                }
                BarButton(
                    symbol: model.isFiltered
                        ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle",
                    help: "Filter (⌘F)",
                    active: model.showFilterBar || model.isFiltered
                ) {
                    model.toggleFilterBar()
                }
                ExportMenu(suggestedName: model.table.name) { try model.exportText($0) }
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
                if model.loading {
                    ProgressView().controlSize(.mini)
                }
                Text(model.pageDescription)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .help(model.countError.map { "Couldn't count the rows: \($0)" } ?? "")
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
                BarButton(symbol: "arrow.clockwise", help: "Reload structure") {
                    Task { await model.reloadStructure() }
                }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 8)
        .frame(height: 30)
        .barBackground()
    }
}
