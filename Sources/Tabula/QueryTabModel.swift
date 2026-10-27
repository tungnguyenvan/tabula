import AppKit
import Observation
import TabulaCore

@MainActor @Observable
final class QueryTabModel {
    let id = UUID()
    var title: String
    var sql: String
    let driver: any DatabaseDriver
    private weak var workspace: WorkspaceModel?

    private(set) var results: [QueryResult] = []
    var selectedResult = 0
    private(set) var resultEditors: [Int: QueryResultEditor] = [:]
    var showResultPreview = false
    var resultEditor: QueryResultEditor? { resultEditors[selectedResult] }
    var hasResultChanges: Bool { resultEditors.values.contains(where: \.hasChanges) }
    var committingResults: Bool { resultEditors.values.contains(where: \.committing) }

    private(set) var error: String?
    private(set) var running = false
    private(set) var version = 0
    let undoManager = UndoManager()
    /// Added as LIMIT to SELECTs that have none; nil runs statements as written.
    var rowLimit: Int? = Defaults.queryRowLimit
    /// Incremented by the menu bar to run from the editor (selection or current statement / everything).
    var runRequest: (all: Bool, id: Int) = (false, 0)
    /// Incremented by the menu bar to beautify the editor (⇧⌘I).
    var beautifyRequest = 0
    /// Incremented by the menu bar to open the Ask AI bar (⌘K).
    var askAIRequest = 0
    /// SQL from the chat panel to insert at the caret (the id makes each request distinct).
    var insertRequest: (sql: String, id: UUID)?
    /// The statement that failed in the last run, for Fix with AI.
    private(set) var failedStatement: String?
    /// The .sql file the tab was opened from or last saved to.
    private(set) var fileURL: URL?
    /// The text as last read from or written to `fileURL`.
    private var savedSQL = ""
    /// Edited since it was last read or saved. Tabs without a file aren't tracked, as in a scratch editor.
    var isEdited: Bool { fileURL != nil && sql != savedSQL }

    /// Ties the tab to a file holding `text`, naming the tab after it.
    func attach(_ url: URL, savedText text: String) {
        fileURL = url.standardizedFileURL
        savedSQL = text
        title = url.lastPathComponent
    }

    /// This tab on another connection (after switching database), still tied to its file.
    func moved(to driver: any DatabaseDriver, workspace: WorkspaceModel) -> QueryTabModel {
        let copy = QueryTabModel(title: title, sql: sql, driver: driver, workspace: workspace)
        copy.fileURL = fileURL
        copy.savedSQL = savedSQL
        return copy
    }

    /// After Fix with AI replaced the failed statement, its error no longer applies.
    func clearFailure() {
        error = nil
        failedStatement = nil
    }
    let assistant = QueryAssistant()

    init(title: String, sql: String, driver: any DatabaseDriver, workspace: WorkspaceModel) {
        self.title = title
        self.sql = sql
        self.driver = driver
        self.workspace = workspace
    }

    var currentResult: QueryResult? {
        results.indices.contains(selectedResult) ? results[selectedResult] : nil
    }

    /// Runs `text` (the editor selection, or the whole editor when nil) statement by statement.
    func run(_ text: String? = nil) async {
        let script = (text?.isEmpty == false ? text! : sql).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !script.isEmpty, !running, workspace?.openingDatabase == nil, !committingResults, confirmDiscardResults() else { return }
        running = true
        error = nil
        failedStatement = nil
        results = []
        resultEditors = [:]
        defer { running = false; version += 1 }

        workspace?.recordHistory(script)
        let statements = SQLSplitter.split(script, kind: driver.kind)
        for (index, statement) in statements.enumerated() {
            // The tab was closed mid-script: don't keep running statements nobody will see.
            if Task.isCancelled { break }
            do {
                let limited = rowLimit.map { driver.dialect.applyingRowLimit(statement, limit: $0) } ?? statement
                let result = try await driver.execute(limited)
                results.append(result)
                // Metadata/catalog checks may reject a result, but must not turn a successful query into an error.
                if let target = try? await driver.queryEditTarget(for: result) {
                    resultEditors[results.count - 1] = QueryResultEditor(target: target, rows: result.rows)
                }
            } catch {
                failedStatement = statement
                let prefix = statements.count > 1 ? "Statement \(index + 1) of \(statements.count) failed:\n" : ""
                self.error = prefix + error.localizedDescription
                break
            }
        }
        // Show the last result set, which is what the user usually wants after a script.
        selectedResult = results.lastIndex(where: \.hasResultSet) ?? max(0, results.count - 1)
        // Schema may have changed (CREATE/DROP/ALTER).
        if results.contains(where: { !$0.hasResultSet }) { await workspace?.loadTables() }
    }

    func suspendResultEditing() {
        for editor in resultEditors.values { editor.suspended = true }
    }

    func confirmDiscardResults() -> Bool {
        guard !committingResults else { return false }
        return !hasResultChanges || Confirmation.ask("Discard uncommitted query result changes?",
            detail: "Commit the result changes first if you want to keep them. Saving the SQL file does not save data changes.",
            action: "Discard Changes")
    }

    func commitResult() async {
        guard let editor = resultEditor, !editor.suspended, editor.hasChanges, !running, !committingResults, let workspace, workspace.openingDatabase == nil else { return }
        if workspace.config.tag == .production, !Confirmation.ask("Commit result changes on a PRODUCTION connection?",
            detail: "This updates rows in \(editor.target.table.schema).\(editor.target.table.name).", action: "Commit") { return }
        editor.committing = true
        defer { editor.committing = false }
        do {
            // An isolated session avoids implicitly committing/rolling back an SQL transaction in the editor.
            let returned = try await workspace.commitQueryEdits(editor.changes, target: editor.target)
            editor.applied(returned)
            if let index = resultEditors.first(where: { $0.value === editor })?.key {
                results[index].rows = editor.rows
                version += 1
            }
        } catch { editor.error = error.localizedDescription }
    }

    func exportText(_ format: ExportFormat) -> String {
        guard let result = currentResult else { return "" }
        return ResultExporter.export(columns: result.columns, rows: result.rows, format: format, dialect: driver.dialect)
    }
}
