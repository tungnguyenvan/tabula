import AppKit
import Observation
import TabulaDrivers
import TabulaFoundation
import TabulaTransfer

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
    private(set) var resultEditNotes: [Int: String] = [:]
    var showResultPreview = false
    var resultEditor: QueryResultEditor? { resultEditors[selectedResult] }
    var hasResultChanges: Bool { resultEditors.values.contains(where: \.hasChanges) }
    var committingResults: Bool { resultEditors.values.contains(where: \.committing) }

    private(set) var error: String?
    private(set) var running = false
    private(set) var stopping = false
    private(set) var runStatus: String?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    /// The current or most recent run's scope; a late Stop answer is matched against it.
    @ObservationIgnored private var cancelScope: QueryCancelScope?
    @ObservationIgnored private var stopNote: String?

    var canStop: Bool { running && !stopping && driver.queryCancellation == .server }
    var stopHelp: String {
        guard driver.queryCancellation == .server else {
            return
                "Stopping a running statement is not supported for \(driver.kind.displayName). Wait for it to finish."
        }
        let cancel = "Cancel the current \(driver.kind.displayName) statement and skip the remaining statements (⌘.)."
        switch driver.kind {
        case .sqlite:
            return cancel + " SQLite rolls back an open transaction when the stopped statement changes rows."
        case .mongodb:
            return cancel + " Documents the command already changed stay changed."
        default:
            return cancel + " The transaction is not committed or rolled back."
        }
    }
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
    /// Incremented by Query › Save to Library… (⌥⌘S); the tab asks for a keyword.
    var saveToLibraryRequest = 0
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

    /// Runs `text` (the editor selection, or the whole editor when nil) statement by statement. The run
    /// lives in a task this tab owns, so Stop and closing the tab can end it.
    func run(_ text: String? = nil) async {
        let script = (text?.isEmpty == false ? text! : sql).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !script.isEmpty, !running, workspace?.openingDatabase == nil, !committingResults, confirmDiscardResults()
        else { return }
        running = true
        stopping = false
        runStatus = nil
        stopNote = nil
        error = nil
        failedStatement = nil
        results = []
        resultEditors = [:]
        resultEditNotes = [:]
        let scope = QueryCancelScope()
        cancelScope = scope
        let task = Task { [weak self] in
            guard let self else { return }
            await QueryCancelScope.$current.withValue(scope) { await self.perform(script, scope: scope) }
        }
        runTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            scope.requestStop()
            Task { await scope.cancel() }
        }
    }

    private func perform(_ script: String, scope: QueryCancelScope) async {
        defer {
            running = false
            stopping = false
            runTask = nil
            version += 1
        }
        workspace?.recordHistory(script)
        let statements = driver.dialect.split(script)
        var interrupted = false
        for (index, statement) in statements.enumerated() {
            // Stop (or closing the tab) ends the run here: no further statement is sent.
            if scope.isCancelled || Task.isCancelled {
                break
            }
            do {
                let limited = rowLimit.map { driver.dialect.applyingRowLimit(statement, limit: $0) } ?? statement
                let result = try await driver.execute(limited)
                results.append(result)
                // Metadata/catalog checks may reject a result, but must not turn a successful query into an error.
                // They are statements too, so they don't run once the user has stopped, nor count as stoppable work.
                if !scope.isCancelled {
                    do {
                        let target = try await QueryCancelScope.$current.withValue(nil) {
                            try await driver.queryEditTarget(for: result)
                        }
                        if let target {
                            resultEditors[results.count - 1] = QueryResultEditor(target: target, rows: result.rows)
                        }
                    } catch { resultEditNotes[results.count - 1] = error.localizedDescription }
                }
            } catch let cancelled as QueryCancelledError {
                interrupted = cancelled.serverInterrupted
                break
            } catch {
                failedStatement = statement
                let prefix = statements.count > 1 ? "Statement \(index + 1) of \(statements.count) failed:\n" : ""
                self.error = prefix + error.localizedDescription
                break
            }
        }
        if scope.isCancelled, error == nil {
            runStatus = Self.stoppedMessage(
                completed: results.count,
                total: statements.count,
                interrupted: interrupted ? driver.kind : nil,
                detail: stopNote
            )
        }
        // Show the last result set, which is what the user usually wants after a script.
        selectedResult = results.lastIndex(where: \.hasResultSet) ?? max(0, results.count - 1)
        // Schema may have changed (CREATE/DROP/ALTER).
        if !scope.isCancelled, results.contains(where: { !$0.hasResultSet }) {
            await QueryCancelScope.$current.withValue(nil) { await workspace?.loadTables() }
        }
    }

    /// `interrupted`: the database whose server cancelled the running statement, nil when none was cancelled.
    private static func stoppedMessage(
        completed: Int,
        total: Int,
        interrupted: DatabaseKind?,
        detail: String?
    ) -> String {
        var text = interrupted != nil ? "Query cancelled." : "Stopped."
        if total > 1 {
            text += " \(completed) of \(total) statements completed; the rest were not run."
        }
        switch interrupted {
        case .postgres:
            text +=
                " If a transaction was open, PostgreSQL has marked it failed: run ROLLBACK (or ROLLBACK TO SAVEPOINT) before continuing."
        case .sqlite:
            text += " If a transaction was open and the statement changed rows, SQLite has rolled the transaction back."
        case .mysql:
            text += " An open transaction stays open, with the changes made before the stopped statement."
        case .mongodb:
            text += " Documents the command had already changed stay changed."
        default:
            break
        }
        if let detail {
            text += "\n" + detail
        }
        return text
    }

    /// Stop: no further statements run, and the server is asked to cancel the one in progress. Nothing is
    /// committed or rolled back on the user's behalf.
    func stop() {
        guard canStop, let scope = cancelScope else { return }
        stopping = true
        scope.requestStop()
        Task { [weak self] in
            let outcome = await scope.cancel()
            // The run may already have ended by the time the answer arrives, so the note goes to whichever is current.
            guard let self, self.cancelScope === scope else { return }
            let note: String
            switch outcome {
            case .failed(let message):
                note = "The server could not cancel the running statement: \(message)"
            case .unsupported:
                note = "This database cannot cancel a running statement; only remaining statements are skipped."
            case .requested, .notRunning: return
            }
            if self.running {
                self.stopNote = note
                self.runStatus = note + " Waiting for it to finish…"
            } else {
                self.runStatus = (self.runStatus.map { $0 + "\n" } ?? "") + note
            }
        }
    }

    /// The tab is going away: no further statements run, and a supported driver cancels the current one.
    func cancelRun() {
        guard running, let scope = cancelScope else { return }
        stopping = true
        scope.requestStop()
        // Task.cancel alone only cancels NIO's consumer, not necessarily the server statement. Keep the
        // run task alive until the driver has cancelled/drained the actual statement.
        Task { await scope.cancel() }
    }

    func suspendResultEditing() {
        for editor in resultEditors.values {
            editor.suspended = true
        }
    }

    func confirmDiscardResults() -> Bool {
        guard !committingResults else { return false }
        return !hasResultChanges
            || Confirmation.ask(
                "Discard uncommitted query result changes?",
                detail:
                    "Commit the result changes first if you want to keep them. Saving the SQL file does not save data changes.",
                action: "Discard Changes"
            )
    }

    func commitResult() async {
        guard let editor = resultEditor, !editor.suspended, editor.hasChanges, !running, !committingResults,
            let workspace, workspace.openingDatabase == nil
        else { return }
        if workspace.config.tag == .production,
            !Confirmation.ask(
                "Commit result changes on a PRODUCTION connection?",
                detail: "This updates rows in \(editor.target.table.schema).\(editor.target.table.name).",
                action: "Commit"
            )
        {
            return
        }
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

    func exportText(_ format: ExportFormat) throws -> String {
        guard let result = currentResult else {
            throw DatabaseError("Run a query that returns rows first.")
        }
        return try ResultExporter.export(
            columns: result.columns,
            rows: result.rows,
            format: format,
            binaryColumns: result.binaryColumns,
            dialect: driver.dialect
        )
    }
}
