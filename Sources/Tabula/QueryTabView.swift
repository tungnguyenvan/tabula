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
                SQLEditorView(text: $model.sql, handle: handle, dialect: model.driver.dialect, suggest: suggest, aiSuggest: aiSuggest,
                              aiSuggestDelay: AIService.shared.settings.provider(for: .inline).runsLocally ? Defaults.AI.localInlineDelay : Defaults.AI.inlineDelay,
                              completionVersion: workspace.completionVersion, undoManager: model.undoManager,
                              onRun: { all in run(all: all) }, onStop: {
                                  guard model.canStop else { return false }
                                  model.stop()
                                  return true
                              })
            }
        } bottom: {
            results
        }
        .onAppear { DispatchQueue.main.async { handle.focus() } }
        .onChange(of: model.runRequest.id) { _, _ in run(all: model.runRequest.all) }
        .onChange(of: model.beautifyRequest) { _, _ in handle.beautify(dialect: model.driver.dialect) }
        .onChange(of: model.askAIRequest) { _, _ in model.assistant.error = nil; model.assistant.showPrompt = true }
        .onChange(of: model.assistant.submitRequest) { _, _ in askAI() }
        .onChange(of: model.insertRequest?.id) { _, _ in
            if let sql = model.insertRequest?.sql { handle.insertReplacingSelection(sql) }
        }
        .onChange(of: model.results.count) { _, _ in selection = [] }
        .onChange(of: model.selectedResult) { _, _ in selection = [] }
        .sheet(isPresented: $model.showResultPreview) {
            if let editor = model.resultEditor {
                SQLPreviewSheet(kind: editor.target.kind, dialect: model.driver.dialect, pending: Result { try editor.pendingStatements() },
                                onCommit: { model.showResultPreview = false; Task { await model.commitResult() } },
                                onCancel: { model.showResultPreview = false })
            }
        }
    }

    private var promptBar: AIPromptBar {
        AIPromptBar(assistant: model.assistant, hasSelection: handle.selectedText != nil,
                    language: model.driver.kind.languageName, submit: askAI)
    }

    private var editorBar: some View {
        HStack(spacing: 6) {
            if model.running {
                Button { model.stop() } label: {
                    Label(model.stopping ? "Stopping…" : "Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.borderedProminent)
                .fixedSize()
                .disabled(!model.canStop)
                .help(model.stopHelp)
            } else {
                // One Run button; Run All is in its menu (and on ⇧⌘↩).
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
                .help("Run the selected text, or the statement at the cursor when nothing is selected (⌘↩). Run all: ⇧⌘↩")
            }
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
            Button { handle.beautify(dialect: model.driver.dialect) } label: {
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
            BarButton(symbol: "folder", help: "Open SQL File… (⌘O)") { workspace.chooseSQLFiles() }
            BarButton(symbol: "square.and.arrow.down", help: model.resultEditor?.hasChanges == true
                      ? "Save SQL File — saves the query text, not pending data changes"
                      : "Save SQL File (⌘S)") { model.save() }

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
            if let status = model.runStatus {
                Label(status, systemImage: "stop.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Layout.barPadding)
                Divider()
            }
            if let result = model.currentResult {
                if result.hasResultSet {
                    let editor = model.resultEditor
                    DataGridView(
                        source: GridSource(
                            columns: result.columns,
                            rowCount: result.rows.count,
                            version: model.version * 1000 + model.selectedResult + (editor?.version ?? 0) * 100_000,
                            cell: { row, column in
                                resultValue(result, editor: editor, row: row, column: column).map(GridCell.value) ?? .null
                            },
                            state: { row, column in editor?.state(row: row, column: column) ?? .normal },
                            isEditable: { row in editor?.target.editableRow(row, in: editor?.rows ?? []) == true && editor?.committing == false && editor?.suspended == false },
                            isColumnEditable: { column in editor?.target.columns.indices.contains(column) == true && editor?.target.columns[column].editable == true },
                            copyText: { rows in
                                rows.map { row in result.columns.indices.map { column in
                                    resultValue(result, editor: editor, row: row, column: column) ?? "NULL"
                                }.joined(separator: "\t") }.joined(separator: "\n")
                            }
                        ),
                        selection: $selection,
                        undoManager: editor?.undoManager,
                        onEdit: editor.map { editor in { row, column, value in editor.setValue(value, row: row, column: column) } }
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
                Text(model.stopping ? "Stopping…" : model.running ? "Running…" : model.runStatus == nil ? "Run a query to see results" : "No results")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            resultBar
        }
        .onChange(of: selection) { _, rows in workspace.setSelection(rows, inTab: model.id) }
        .onAppear { workspace.setSelection(selection, inTab: model.id) }
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
                .disabled(model.committingResults)
            }
            if let result = model.currentResult, result.hasResultSet {
                ExportMenu(suggestedName: "query") { try model.exportText($0) }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
            }
            if let editor = model.resultEditor {
                Label("Editing \(editor.target.table.name)", systemImage: "square.and.pencil")
                    .foregroundStyle(.secondary)
                    .help("Edit cells in this result. Only proven one-table PostgreSQL or MySQL InnoDB results with a complete primary key can be changed.")
                if editor.hasChanges {
                    Button("Discard") { editor.discard() }
                        .help("Discard pending result changes (⌥⌘Z)")
                        .disabled(editor.committing)
                    Button("Preview") { model.showResultPreview = true }
                        .help("Preview the UPDATE statements before committing")
                        .disabled(editor.committing)
                    Button(editor.committing ? "Committing…" : "Commit \(editor.changeCount)") { Task { await model.commitResult() } }
                        .help("Commit pending result changes (⌘S)")
                        .buttonStyle(.borderedProminent)
                        .disabled(editor.committing)
                }
            } else if let note = model.resultEditNotes[model.selectedResult] {
                Label("Read-only", systemImage: "lock")
                    .foregroundStyle(.secondary)
                    .help(note)
            }
            Spacer()
            if let error = model.resultEditor?.error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).lineLimit(1)
                    .help(error)
            }
            if let result = model.currentResult {
                Text(result.summary).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 8)
        .frame(height: 30)
        .barBackground()
    }

    private func resultValue(_ result: QueryResult, editor: QueryResultEditor?, row: Int, column: Int) -> String? {
        if let editor { return editor.value(row: row, column: column) }
        return result.rows[row][column]
    }

    private func run(all: Bool) {
        let text = all ? nil : handle.textToRun(dialect: model.driver.dialect)
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
        let kind = model.driver.kind, dialect = model.driver.dialect
        return { [workspace] before, after in
            // Columns only for the tables this statement uses (the rest by name, to keep typing fast); before
            // it names any, every table's columns, so the model doesn't invent some.
            let used = Set(dialect.referencedTables(in: before + after).map { $0.name.lowercased() })
            let request = SQLPrompts.inline(before: before, after: after, schema: workspace.aiSchema(focus: used.isEmpty ? nil : used), kind: kind,
                instructions: AIService.shared.settings.instructions(.inline))
            guard let reply = try? await AIService.shared.complete(request) else { return nil }
            let continuation = SQLPrompts.cleanContinuation(reply, before: before)
            return continuation.isEmpty ? nil : continuation
        }
    }

    private func suggest(_ text: String, caret: Int) -> (range: NSRange, items: [String]) {
        model.driver.dialect.completions(in: text, caret: caret, catalog: workspace)
    }
}
