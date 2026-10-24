import AppKit
import SwiftUI
import TabulaCore

struct QueryTabView: View {
    @Bindable var model: QueryTabModel
    let workspace: WorkspaceModel
    @State private var handle = EditorHandle()
    @State private var selection = IndexSet()

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                editorBar
                Divider()
                SQLEditorView(text: $model.sql, handle: handle, suggest: suggest,
                              undoManager: model.undoManager) { all in run(all: all) }
            }
            .frame(minHeight: 120, idealHeight: 260)

            results
                .frame(minHeight: 140)
        }
        .onAppear { DispatchQueue.main.async { handle.focus() } }
        .onChange(of: model.runRequest.id) { _, _ in run(all: model.runRequest.all) }
        .onChange(of: model.beautifyRequest) { _, _ in handle.beautify(kind: model.driver.kind) }
        .onChange(of: model.results.count) { _, _ in selection = [] }
        .onChange(of: model.selectedResult) { _, _ in selection = [] }
    }

    private var editorBar: some View {
        HStack(spacing: 6) {
            Button { run(all: false) } label: {
                Label("Run Current", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.running)
            .help("Run the selected text only, or the statement at the cursor when nothing is selected (⌘↩)")
            Button { run(all: true) } label: {
                Label("Run All", systemImage: "forward.fill")
            }
            .disabled(model.running)
            .help("Run every statement in the editor (⇧⌘↩)")
            Picker("Limit", selection: $model.rowLimit) {
                Text("No Limit").tag(Int?.none)
                Divider()
                ForEach(Defaults.queryRowLimitChoices, id: \.self) { Text("Limit \($0)").tag(Int?.some($0)) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .help("Adds LIMIT to SELECT statements that don't have one")
            Button { handle.beautify(kind: model.driver.kind) } label: {
                Label("Beautify", systemImage: "text.alignleft")
            }
            .help("Format the selection, or the whole editor (⇧⌘I)")

            Menu {
                if workspace.history.isEmpty { Text("No queries yet") }
                ForEach(Array(workspace.history.prefix(30).enumerated()), id: \.offset) { _, sql in
                    Button(String(sql.replacingOccurrences(of: "\n", with: " ").prefix(80))) { model.sql = sql }
                }
            } label: {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Query history")
            BarButton(symbol: "folder", help: "Open .sql file") { openSQL() }
            BarButton(symbol: "square.and.arrow.down", help: "Save as .sql file") { saveSQL() }

            if model.running { ProgressView().controlSize(.mini) }
            Spacer()
            Text("⇥ Accept suggestion   ⎋ Suggestions   ⌘/ Comment").font(Layout.Font.icon).foregroundStyle(.tertiary)
        }
        .controlSize(.small)
        .padding(.horizontal, 8)
        .frame(height: 30)
        .barBackground()
    }

    @ViewBuilder
    private var results: some View {
        VStack(spacing: 0) {
            if let error = model.error {
                ScrollView {
                    Label {
                        Text(error).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    } icon: {
                        Image(systemName: "exclamationmark.octagon.fill")
                    }
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
                .frame(maxHeight: model.results.isEmpty ? .infinity : 90)
                Divider()
            }
            if let result = model.currentResult {
                if result.hasResultSet {
                    DataGridView(
                        source: GridSource(
                            columns: result.columns,
                            rowCount: result.rows.count,
                            version: model.version * 1000 + model.selectedResult,
                            cell: { row, column in result.rows[row][column].map(GridCell.value) ?? .null },
                            copyText: { rows in
                                rows.map { result.rows[$0].map { $0 ?? "NULL" }.joined(separator: "\t") }.joined(separator: "\n")
                            }
                        ),
                        selection: $selection
                    )
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: "checkmark.circle").font(.system(size: 22, weight: .light)).foregroundStyle(.green)
                        Text(result.affectedRows.map { "\($0) row\($0 == 1 ? "" : "s") affected" } ?? "Statement executed")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else if model.error == nil {
                Text(model.running ? "Running…" : "Run a query to see results")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            resultBar
        }
        .onChange(of: selection) { _, rows in workspace.inspectedRows = rows }
    }

    private var resultBar: some View {
        HStack(spacing: 8) {
            if model.results.count > 1 {
                Picker("Result", selection: $model.selectedResult) {
                    ForEach(Array(model.results.enumerated()), id: \.offset) { index, result in
                        Text("\(index + 1). \(String(result.statement.replacingOccurrences(of: "\n", with: " ").prefix(40)))").tag(index)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            if let result = model.currentResult, result.hasResultSet {
                ExportMenu(suggestedName: "query") { model.exportText($0) }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
            }
            Spacer()
            if let result = model.currentResult {
                Text(result.summary).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 8)
        .frame(height: 30)
        .barBackground()
    }

    private func run(all: Bool) {
        let text = all ? nil : handle.textToRun(kind: model.driver.kind)
        if !all && text == nil { return }
        Task { await model.run(text) }
    }

    private func suggest(_ text: String, caret: Int) -> (range: NSRange, items: [String]) {
        let context = SQLCompletion.context(in: text, caret: caret, kind: model.driver.kind)
        let items = SQLCompletion.suggestions(for: context, tables: workspace.tables.map(\.name)) { workspace.columnNames(of: $0) }
        return (context.partialRange, items)
    }

    private func saveSQL() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(model.title).sql"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? model.sql.write(to: url, atomically: true, encoding: .utf8)
    }

    private func openSQL() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        model.sql = text
        model.title = url.deletingPathExtension().lastPathComponent
    }
}
