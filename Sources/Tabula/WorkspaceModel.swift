import Foundation
import Observation
import TabulaCore

@MainActor @Observable
final class WorkspaceModel {
    enum Status: Equatable {
        case connecting, connected, failed(String)
    }

    enum Tab: Identifiable {
        case table(TableTabModel)
        case query(QueryTabModel)
        case diagram(DiagramModel)
        case metrics(MetricsModel)

        var id: UUID {
            switch self {
            case .table(let model): model.id
            case .query(let model): model.id
            case .diagram(let model): model.id
            case .metrics(let model): model.id
            }
        }

        @MainActor var title: String {
            switch self {
            case .table(let model): model.table.name
            case .query(let model): model.title
            case .diagram(let model): model.title
            case .metrics: "Metrics"
            }
        }
    }

    let config: ConnectionConfig
    private let password: String?
    private(set) var driver: (any DatabaseDriver)?
    private(set) var status: Status = .connecting
    private(set) var serverVersion: String?
    private(set) var connectedAt: Date?

    var schemas: [String] = []
    var selectedSchema: String = ""
    private(set) var tables: [TableRef] = [] {
        // Reloading tables (refresh, schema switch, DDL) drops what completion knew; loads still in flight
        // for the old list see the generation change and throw their results away.
        didSet { columnCache = [:]; loadingColumns = []; cacheGeneration += 1 }
    }
    /// Column names per table, filled on demand for SQL completion.
    /// "schema.table" (lower-cased) → column names.
    private var columnCache: [String: [String]] = [:]
    private var cacheGeneration = 0
    private var loadingColumns: Set<String> = []
    private var prefetchingColumns = false
    private var schemaTableCache: [String: [String]] = [:]
    /// Bumped when completion learns new table or column names, so the editor can refresh its suggestion.
    private(set) var completionVersion = 0
    private var loadingSchemaTables: Set<String> = []
    var tableSearch = ""
    var tablesError: String?
    private(set) var loadingTables = false

    private(set) var tabs: [Tab] = []
    var selectedTabID: UUID?
    var history: [String] = []
    var showInspector = false
    /// The console log panel under the tabs (⇧⌘C).
    var showConsole = false
    let log = QueryLogModel()
    var showPalette = false
    /// Incremented to move keyboard focus to the sidebar's table filter (⌥⌘F).
    var sidebarFilterFocusRequest = 0
    /// Tabs closed most recently last, for "Reopen Closed Tab" (⇧⌘T).
    private var closedTabs: [ClosedTab] = []

    enum ClosedTab {
        case table(TableRef, TableTabModel.Mode)
        case query(title: String, sql: String)
    }
    /// Rows selected in the active grid, shown in the row inspector.
    var inspectedRows = IndexSet()
    private var queryCounter = 0

    init(config: ConnectionConfig, password: String?) {
        self.config = config
        self.password = password
    }

    var filteredTables: [TableRef] {
        guard !tableSearch.isEmpty else { return tables }
        return tables.filter { $0.name.localizedCaseInsensitiveContains(tableSearch) }
    }

    var selectedTab: Tab? { tabs.first { $0.id == selectedTabID } }

    var selectedTableTab: TableTabModel? {
        if case .table(let model) = selectedTab { return model }
        return nil
    }

    func connect() async {
        status = .connecting
        do {
            let log = log
            let driver = LoggingDriver(try await DriverFactory.connect(config, password: password)) { entry in
                Task { @MainActor in log.append(entry) }
            }
            self.driver = driver
            status = .connected
            connectedAt = Date()
            serverVersion = await driver.serverVersion()
            schemas = (try? await driver.schemas()) ?? []
            let preferred = (try? await driver.defaultSchema()) ?? ""
            selectedSchema = schemas.contains(preferred) ? preferred : (schemas.first ?? preferred)
            await loadTables()
            if tabs.isEmpty { newQueryTab() }
            #if DEBUG
            DebugHooks.workspaceConnected(self)
            #endif
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func reconnect() async {
        await disconnect()
        tabs.removeAll()
        selectedTabID = nil
        await connect()
    }

    func disconnect() async {
        await driver?.close()
        driver = nil
    }

    func selectSchema(_ schema: String) async {
        guard schema != selectedSchema else { return }
        selectedSchema = schema
        await loadTables()
    }

    func loadTables() async {
        guard let driver else { return }
        loadingTables = true
        defer { loadingTables = false }
        do {
            tables = try await driver.tables(in: selectedSchema)
            if tabs.contains(where: { if case .query = $0 { return true }; return false }) { prefetchColumns() }
            tablesError = nil
        } catch {
            tables = []
            tablesError = error.localizedDescription
        }
    }

    func refresh() async {
        await loadTables()
        if let table = selectedTableTab { await table.reload() }
    }

    /// The tab opened by browsing the sidebar; the next browse replaces it instead of adding a tab
    /// (so arrowing through tables doesn't pile up tabs). Editing, filtering or opening it explicitly keeps it.
    private(set) var previewTabID: UUID?

    /// Opens a table. `preview` (sidebar browsing) reuses the preview tab when it has nothing worth keeping.
    func open(_ table: TableRef, mode: TableTabModel.Mode = .data, preview: Bool = false) {
        if let existing = tabs.first(where: { if case .table(let model) = $0 { return model.table == table }; return false }) {
            selectedTabID = existing.id
            if case .table(let model) = existing { model.mode = mode }
            if !preview && existing.id == previewTabID { previewTabID = nil }
            return
        }
        guard let driver else { return }
        let model = TableTabModel(table: table, driver: driver)
        model.mode = mode
        model.focusGridOnLoad = !preview
        if preview, let previewID = previewTabID, let index = tabs.firstIndex(where: { $0.id == previewID }),
           case .table(let old) = tabs[index], !old.hasChanges, !old.isFiltered {
            tabs[index] = .table(model)
        } else {
            tabs.append(.table(model))
        }
        previewTabID = preview ? model.id : nil
        selectedTabID = model.id
        Task { await model.reload() }
    }

    func isPreview(_ id: UUID) -> Bool { id == previewTabID }

    /// Keeps the preview tab open for good (double-click on it, or when it gains state worth keeping).
    func pin(_ id: UUID) {
        if previewTabID == id { previewTabID = nil }
    }

    /// Opens (or switches to) the relationship diagram of the current schema.
    func openDiagram() {
        guard let driver else { return }
        if let existing = tabs.first(where: { if case .diagram(let model) = $0 { return model.schema == selectedSchema }; return false }) {
            selectedTabID = existing.id
            return
        }
        let model = DiagramModel(schema: selectedSchema, driver: driver)
        tabs.append(.diagram(model))
        selectedTabID = model.id
    }

    func openMetrics() {
        guard let driver else { return }
        if let existing = tabs.first(where: { if case .metrics = $0 { return true }; return false }) {
            selectedTabID = existing.id
            return
        }
        let schema = selectedSchema
        // Polling every few seconds would bury the user's own statements in the console log.
        let source = (driver as? LoggingDriver)?.unlogged ?? driver
        let model = MetricsModel { try await source.metrics(schema: schema) }
        tabs.append(.metrics(model))
        selectedTabID = model.id
    }

    func newQueryTab(sql: String = "") {
        guard let driver else { return }
        queryCounter += 1
        let model = QueryTabModel(title: "Query \(queryCounter)", sql: sql, driver: driver, workspace: self)
        tabs.append(.query(model))
        selectedTabID = model.id
        prefetchColumns()
    }

    /// Loads the columns of the schema's tables in the background, so completion knows them before the
    /// statement names a table.
    func prefetchColumns() {
        guard let driver, !prefetchingColumns else { return }
        let pending = tables.prefix(Defaults.completionPrefetchLimit).filter { columnCache[Self.columnKey($0)] == nil }
        guard !pending.isEmpty else { return }
        prefetchingColumns = true
        let generation = cacheGeneration
        Task {
            defer { prefetchingColumns = false }
            for table in pending {
                let key = Self.columnKey(table)
                guard generation == cacheGeneration else { return }
                guard columnCache[key] == nil, !loadingColumns.contains(key) else { continue }
                loadingColumns.insert(key)
                let names = (try? await driver.columns(of: table).map(\.name)) ?? []
                guard generation == cacheGeneration else { return }
                loadingColumns.remove(key)
                columnCache[key] = names
                completionVersion += 1
            }
        }
    }

    /// Table names of another schema, for completing `schema.`; nil while they load.
    func tableNames(inSchema schema: String) -> [String]? {
        if schema.caseInsensitiveCompare(selectedSchema) == .orderedSame { return tables.map(\.name) }
        let key = schema.lowercased()
        if let cached = schemaTableCache[key] { return cached }
        guard let driver, !loadingSchemaTables.contains(key),
              let name = schemas.first(where: { $0.caseInsensitiveCompare(schema) == .orderedSame }) else { return nil }
        loadingSchemaTables.insert(key)
        Task {
            schemaTableCache[key] = (try? await driver.tables(in: name).map(\.name)) ?? []
            completionVersion += 1
            loadingSchemaTables.remove(key)
        }
        return nil
    }

    /// The schema for Ask AI and Fix with AI: waits for columns still loading (up to the prefetch
    /// limit), so the model isn't told that tables have none.
    func loadedAISchema() async -> SQLPrompts.Schema {
        if let driver {
            let generation = cacheGeneration
            for table in tables.prefix(Defaults.completionPrefetchLimit) where columnCache[Self.columnKey(table)] == nil {
                let names = (try? await driver.columns(of: table).map(\.name)) ?? []
                guard generation == cacheGeneration else { break }
                columnCache[Self.columnKey(table)] = names
            }
        }
        return aiSchema()
    }

    /// The schema as the AI sees it: table names and the columns loaded so far, never rows.
    func aiSchema() -> SQLPrompts.Schema {
        SQLPrompts.Schema(tables: tables.map { ($0.name, columnCache[Self.columnKey($0)] ?? []) })
    }

    /// Every column name loaded so far, for completion before a table is named.
    var knownColumnNames: [String] {
        let prefix = selectedSchema.lowercased() + "."
        return Array(Set(columnCache.filter { $0.key.hasPrefix(prefix) }.values.joined())).sorted()
    }

    private static func columnKey(_ table: TableRef) -> String {
        "\(table.schema.lowercased()).\(table.name.lowercased())"
    }

    func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        switch tabs[index] {
        case .table(let model): closedTabs.append(.table(model.table, model.mode))
        case .query(let model):
            model.assistant.cancel()
            if !model.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                closedTabs.append(.query(title: model.title, sql: model.sql))
            }
        case .diagram, .metrics:
            break
        }
        if closedTabs.count > 20 { closedTabs.removeFirst() }
        tabs.remove(at: index)
        if selectedTabID == id {
            selectedTabID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
    }

    func closeSelectedTab() {
        if let id = selectedTabID { close(id) }
    }

    /// Whether closing this tab would throw away uncommitted edits.
    func hasUnsavedChanges(_ id: UUID) -> Bool {
        guard case .table(let model) = tabs.first(where: { $0.id == id }) else { return false }
        return model.hasChanges
    }

    var canReopenTab: Bool { !closedTabs.isEmpty }

    func reopenClosedTab() {
        guard let last = closedTabs.popLast() else { return }
        switch last {
        case .table(let table, let mode):
            open(table, mode: mode)
        case .query(let title, let sql):
            newQueryTab(sql: sql)
            if case .query(let model) = selectedTab { model.title = title }
        }
    }

    /// ⌘1…⌘8 select that tab; ⌘9 selects the last one, as in browsers.
    func selectTab(number: Int) {
        guard !tabs.isEmpty else { return }
        let index = number == 9 ? tabs.count - 1 : number - 1
        if tabs.indices.contains(index) { selectedTabID = tabs[index].id }
    }

    func selectAdjacentTab(_ offset: Int) {
        guard let current = tabs.firstIndex(where: { $0.id == selectedTabID }), !tabs.isEmpty else { return }
        selectedTabID = tabs[(current + offset + tabs.count) % tabs.count].id
    }

    func recordHistory(_ sql: String) {
        history.removeAll { $0 == sql }
        history.insert(sql, at: 0)
        if history.count > Defaults.historyLimit { history.removeLast(history.count - Defaults.historyLimit) }
    }

    /// A table's column names if already loaded; otherwise starts loading them and returns nil,
    /// so completion offers them from the next keystroke on.
    func columnNames(of table: SQLCompletion.TableName) -> [String]? {
        let ref: TableRef
        if let schemaName = table.schema, schemaName.caseInsensitiveCompare(selectedSchema) != .orderedSame {
            // Another schema: only one the database has. A mistyped one gets no columns rather than a
            // same-named table's from the selected schema.
            guard let schema = schemas.first(where: { $0.caseInsensitiveCompare(schemaName) == .orderedSame }) else { return nil }
            ref = TableRef(schema: schema, name: table.name)
        } else if let known = tables.first(where: { $0.name.caseInsensitiveCompare(table.name) == .orderedSame }) {
            ref = known
        } else {
            return nil
        }
        let key = Self.columnKey(ref)
        if let cached = columnCache[key] { return cached }
        guard let driver, !loadingColumns.contains(key) else { return nil }
        loadingColumns.insert(key)
        let generation = cacheGeneration
        Task {
            let names = (try? await driver.columns(of: ref).map(\.name)) ?? []
            guard generation == cacheGeneration else { return }
            loadingColumns.remove(key)
            columnCache[key] = names
            completionVersion += 1
        }
        return nil
    }

    /// Runs a destructive table operation (truncate/drop) after the UI has confirmed it.
    func perform(_ sql: String, on table: TableRef) async throws {
        guard let driver else { throw DatabaseError("Not connected. Reconnect and try again.") }
        _ = try await driver.execute(sql)
        if sql.hasPrefix("DROP") {
            tabs.removeAll { if case .table(let model) = $0 { return model.table == table }; return false }
            if selectedTab == nil { selectedTabID = tabs.last?.id }
        }
        await refresh()
    }
}
