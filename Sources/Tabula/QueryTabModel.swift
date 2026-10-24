import Foundation
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
    /// The statement that failed in the last run, for Fix with AI.
    private(set) var failedStatement: String?

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
        guard !script.isEmpty, !running else { return }
        running = true
        error = nil
        failedStatement = nil
        results = []
        defer { running = false; version += 1 }

        workspace?.recordHistory(script)
        let statements = SQLSplitter.split(script, kind: driver.kind)
        for (index, statement) in statements.enumerated() {
            // The tab was closed mid-script: don't keep running statements nobody will see.
            if Task.isCancelled { break }
            do {
                let limited = rowLimit.map { driver.dialect.applyingRowLimit(statement, limit: $0) } ?? statement
                results.append(try await driver.execute(limited))
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

    func exportText(_ format: ExportFormat) -> String {
        guard let result = currentResult else { return "" }
        return ResultExporter.export(columns: result.columns, rows: result.rows, format: format, dialect: driver.dialect)
    }
}
