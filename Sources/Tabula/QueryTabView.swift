import AppKit
import SwiftUI
import TabulaCore

struct QueryTabView: View {
    @Bindable var model: QueryTabModel
    let workspace: WorkspaceModel
    @State private var handle = EditorHandle()
    @State private var selection = IndexSet()

    var body: some View {
        VerticalSplit(topMinimum: Layout.Query.editorMinHeight, bottomMinimum: Layout.Query.resultsMinHeight,
                      topIdeal: Layout.Query.editorIdealHeight, autosaveName: "QueryEditor") {
            VStack(spacing: 0) {
                editorBar
                Divider()
                if model.assistant.showPrompt {
                    promptBar
                    Divider()
                }
                SQLEditorView(text: $model.sql, handle: handle, kind: model.driver.kind, suggest: suggest, aiSuggest: aiSuggest,
                              aiSuggestDelay: AIService.shared.settings.provider(for: .inline).runsLocally ? Defaults.AI.localInlineDelay : Defaults.AI.inlineDelay,
                              completionVersion: workspace.completionVersion, undoManager: model.undoManager) { all in run(all: all) }
            }
        } bottom: {
            results
        }
        .onAppear { DispatchQueue.main.async { handle.focus() } }
        .onChange(of: model.runRequest.id) { _, _ in run(all: model.runRequest.all) }
        .onChange(of: model.beautifyRequest) { _, _ in handle.beautify(kind: model.driver.kind) }
        .onChange(of: model.askAIRequest) { _, _ in model.assistant.error = nil; model.assistant.showPrompt = true }
        .onChange(of: model.assistant.submitRequest) { _, _ in askAI() }
        .onChange(of: model.insertRequest?.id) { _, _ in
            if let sql = model.insertRequest?.sql { handle.insertReplacingSelection(sql) }
        }
        .onChange(of: model.results.count) { _, _ in selection = [] }
        .onChange(of: model.selectedResult) { _, _ in selection = [] }
    }

    private var promptBar: AIPromptBar {
        AIPromptBar(assistant: model.assistant, hasSelection: handle.selectedText != nil,
                    language: model.driver.kind.languageName, submit: askAI)
    }

    private var editorBar: some View {
        HStack(spacing: 6) {
            // One Run button, as in other SQL clients; Run All is in its menu (and on ⇧⌘↩).
            Menu {
                Button("Run All Statements") { run(all: true) }
            } label: {
                Label("Run", systemImage: "play.fill")
            } primaryAction: {
                run(all: false)
            }
            .menuStyle(.button)
            .buttonStyle(.borderedProminent)
            .fixedSize()
            .disabled(model.running)
            .help("Run the selected text, or the statement at the cursor when nothing is selected (⌘↩). Run all: ⇧⌘↩")
            Picker("Limit", selection: $model.rowLimit) {
                Text("No Limit").tag(Int?.none)
                Divider()
                ForEach(Defaults.queryRowLimitChoices, id: \.self) { Text("Limit \($0)").tag(Int?.some($0)) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .help(model.driver.kind.isDocument ? "Adds .limit() to find and aggregate commands that don't have one"
                  : "Adds LIMIT to SELECT statements that don't have one")
            Button { handle.beautify(kind: model.driver.kind) } label: {
                Label("Beautify", systemImage: "text.alignleft")
            }
            .help("Format the selection, or the whole editor (⇧⌘I)")
            Button { model.assistant.error = nil; model.assistant.showPrompt.toggle() } label: {
                Label("Ask AI", systemImage: "sparkles")
            }
            .help("Write \(model.driver.kind.isDocument ? "a query" : "SQL") from a description, or change the selection (⌘K)")

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
            Spacer(minLength: 0)
            // A hint, not a control: it disappears when the bar is too narrow for it.
            ViewThatFits(in: .horizontal) {
                Text("⇥ Accept suggestion   ⎋ Suggestions   ⌘/ Comment").font(Layout.Font.icon).foregroundStyle(.tertiary).fixedSize()
                Color.clear.frame(width: 0, height: 0)
            }
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
                    VStack(alignment: .leading, spacing: Layout.barPadding) {
                        Label {
                            Text(error).font(Layout.Font.mono).textSelection(.enabled)
                        } icon: {
                            Image(systemName: "exclamationmark.octagon.fill")
                        }
                        .foregroundStyle(.red)
                        if model.failedStatement != nil, AIService.shared.settings.enabled {
                            HStack(spacing: Layout.barPadding) {
                                Button { fixWithAI() } label: { Label("Fix with AI", systemImage: "sparkles") }
                                    .controlSize(.small)
                                    .disabled(model.assistant.busy)
                                if model.assistant.busy { ProgressView().controlSize(.small) }
                                if model.assistant.busy, !model.assistant.showPrompt, let progress = model.assistant.progress {
                                    AIProgressLine(progress: progress)
                                }
                                // The prompt bar may be closed, so a failed fix reports here.
                                if !model.assistant.showPrompt, let failure = model.assistant.error {
                                    Text(failure).font(Layout.Font.small).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(Layout.barPadding)
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

    private func askAI() {
        let description = model.assistant.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !description.isEmpty else { return }
        // Where the answer goes is decided now, not when it arrives: the user may keep typing meanwhile.
        let target = handle.snapshot()
        let kind = model.driver.kind
        model.assistant.run(for: workspace.config, request: {
            SQLPrompts.generate(description: description, current: target.selectedText,
                                schema: await workspace.loadedAISchema(for: target.text), kind: kind,
                instructions: AIService.shared.settings.instructions(.generate))
        }) { sql in handle.insert(sql, at: target) }
    }

    private func fixWithAI() {
        guard let statement = model.failedStatement, let error = model.error else { return }
        let kind = model.driver.kind
        model.assistant.run(for: workspace.config, request: {
            SQLPrompts.fix(sql: statement, error: error, schema: await workspace.loadedAISchema(for: statement), kind: kind,
                instructions: AIService.shared.settings.instructions(.fix))
        }) { sql in
            handle.replace(statement, with: sql)
            model.clearFailure()
        }
    }

    /// Asks the model to continue the SQL at the caret when the user pauses; nil when AI suggestions are off.
    private var aiSuggest: SQLEditorView.AISuggest? {
        guard AIService.shared.suggestsInline(for: workspace.config) else { return nil }
        let kind = model.driver.kind
        return { [workspace] before, after in
            // Columns only for the tables this statement uses (the rest by name, to keep typing fast); before
            // it names any, every table's columns, so the model doesn't invent some.
            let used = Set(SQLCompletion.tables(in: before + after, kind: kind).map { $0.name.lowercased() })
            let request = SQLPrompts.inline(before: before, after: after, schema: workspace.aiSchema(focus: used.isEmpty ? nil : used), kind: kind,
                instructions: AIService.shared.settings.instructions(.inline))
            guard let reply = try? await AIService.shared.complete(request) else { return nil }
            let continuation = SQLPrompts.cleanContinuation(reply, before: before)
            return continuation.isEmpty ? nil : continuation
        }
    }

    private func suggest(_ text: String, caret: Int) -> (range: NSRange, items: [String]) {
        if model.driver.kind.isDocument {
            return MongoCompletion.suggestions(in: text, caret: caret, collections: workspace.tables.map(\.name),
                                               fields: { workspace.columnNames(of: SQLCompletion.TableName(name: $0)) })
        }
        let context = SQLCompletion.context(in: text, caret: caret, kind: model.driver.kind, schemas: workspace.schemas)
        let items = SQLCompletion.suggestions(for: context, tables: workspace.tables.map(\.name),
                                              columns: { workspace.columnNames(of: $0) }, allColumns: workspace.knownColumnNames,
                                              tablesInSchema: { workspace.tableNames(inSchema: $0) })
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
