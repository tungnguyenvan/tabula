import Foundation
import TabulaCore

/// Each connection's tabs, schema, database and query history are saved, and come back when it is opened again
/// (Settings › General turns this off). Saved when the connection, its window or Tabula closes, on Reconnect, and
/// every `Defaults.workspaceStateSaveInterval` seconds while it changes.
extension WorkspaceModel {
    /// UserDefaults key of the setting; on unless turned off.
    static let restoresStateKey = "RestoreWorkspaceState"

    static var restoresState: Bool {
        UserDefaults.standard.object(forKey: restoresStateKey) as? Bool ?? true
    }

    /// Saved states, next to the connections (in TABULA_DATA_DIR when that is set).
    nonisolated static let stateStore: WorkspaceStateStore = {
        guard let directory = ProcessInfo.processInfo.environment["TABULA_DATA_DIR"] else { return WorkspaceStateStore() }
        return WorkspaceStateStore(base: URL(fileURLWithPath: directory))
    }()

    /// What is open now, as it would be saved.
    var currentState: WorkspaceState {
        var saved: [WorkspaceState.Tab] = []
        var selected: Int?
        for tab in tabs {
            switch tab {
            case .query(let model):
                saved.append(.query(title: model.title, sql: model.sql, file: model.fileURL))
            case .table(let model):
                saved.append(.table(schema: model.table.schema, name: model.table.name, kind: model.table.kind.rawValue, mode: model.mode.rawValue))
            case .diagram, .metrics, .routine:
                continue
            }
            if tab.id == selectedTabID { selected = saved.count - 1 }
        }
        let database = currentDatabase.flatMap { $0 == savedDatabase ? nil : $0 }
        return WorkspaceState(database: database, schema: selectedSchema.isEmpty ? nil : selectedSchema, tabs: saved,
                              selected: selected, history: history)
    }

    /// Writes what is open, when it changed since the last save. Nothing is written before the saved state was
    /// restored, so a connection that is still connecting, or failed to, keeps what it had.
    func saveState() {
        // While the window moves to another database its tabs are briefly gone.
        guard Self.restoresState, stateRestored, openingDatabase == nil else { return }
        let state = currentState
        guard state != savedState else { return }
        // A failed write (a full disk) is tried again at the next save.
        guard (try? Self.stateStore.save(state, for: connectionID)) != nil else { return }
        savedState = state
    }

    /// Brings back the saved state, once connected: the database (PostgreSQL) and schema first, then the tabs.
    /// Table tabs other than the selected one load their rows when first selected; tables no longer in the selected
    /// schema are left out, and a query tab whose .sql file is gone keeps its SQL without the file.
    func restoreState() async {
        defer {
            stateRestored = true
            startSavingState()
        }
        guard Self.restoresState, let state = Self.stateStore.load(connectionID) else { return }
        if let database = state.database, database != currentDatabase, databases.contains(database) {
            // The last conversation stays: it was about this database.
            await openDatabase(database, startingNewChat: false)
        }
        if let schema = state.schema, schema != selectedSchema, schemas.contains(schema) {
            await selectSchema(schema)
        }
        guard let driver else { return }

        var restored: [Tab] = []
        var selected: UUID?
        for (index, saved) in state.tabs.enumerated() {
            let tab: Tab
            switch saved {
            case .query(let title, let sql, let file):
                let model = QueryTabModel(title: title, sql: sql, driver: driver, workspace: self)
                if let file, let text = Self.contents(of: file) { model.attach(file, savedText: text) }
                tab = .query(model)
            case .table(let schema, let name, let kind, let mode):
                if schema == selectedSchema, !tables.contains(where: { $0.schema == schema && $0.name == name }) { continue }
                let model = TableTabModel(table: TableRef(schema: schema, name: name, kind: TableKind(rawValue: kind) ?? .table), driver: driver)
                model.mode = TableTabModel.Mode(rawValue: mode) ?? .data
                unloadedTabs.insert(model.id)
                tab = .table(model)
            }
            restored.append(tab)
            if index == state.selected { selected = tab.id }
        }
        // Continue numbering after the restored "Query n" tabs.
        let numbers = restored.compactMap { tab -> Int? in
            guard case .query(let model) = tab, model.title.hasPrefix("Query ") else { return nil }
            return Int(model.title.dropFirst("Query ".count))
        }
        queryCounter = max(queryCounter, numbers.max() ?? 0)
        history = state.history
        setRestoredTabs(restored, selected: selected ?? restored.first?.id)
        savedState = currentState
    }

    /// Loads a restored table tab's rows the first time it is selected.
    func loadIfUnloaded() {
        guard let id = selectedTabID, unloadedTabs.remove(id) != nil, case .table(let model) = selectedTab else { return }
        Task { await model.reload() }
    }

    /// Saves now and then while the workspace is open. The loop ends with the workspace.
    private func startSavingState() {
        guard stateSaver == nil else { return }
        stateSaver = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Defaults.workspaceStateSaveInterval))
                guard let self else { return }
                self.saveState()
            }
        }
    }

    private static func contents(of file: URL) -> String? {
        var encoding = String.Encoding.utf8
        return try? String(contentsOf: file, usedEncoding: &encoding)
    }
}
