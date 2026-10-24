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
    /// Incremented by the menu bar to run from the editor (selection or current statement / everything).
    var runRequest: (all: Bool, id: Int) = (false, 0)

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
        results = []
        defer { running = false; version += 1 }

        workspace?.recordHistory(script)
        let statements = SQLSplitter.split(script, kind: driver.kind)
        for (index, statement) in statements.enumerated() {
            do {
                results.append(try await driver.execute(statement))
            } catch {
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
