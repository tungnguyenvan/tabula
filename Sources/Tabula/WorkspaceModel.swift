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
        case routine(RoutineTabModel)

        var id: UUID {
            switch self {
            case .table(let model): model.id
            case .query(let model): model.id
            case .diagram(let model): model.id
            case .metrics(let model): model.id
            case .routine(let model): model.id
            }
        }

        @MainActor var title: String {
            switch self {
            case .table(let model): model.table.name
            case .query(let model): model.title
            case .diagram(let model): model.title
            case .metrics: "Metrics"
            case .routine(let model): model.title
            }
        }
    }

    /// The saved connection, with the database the window switched to (PostgreSQL), which isn't saved.
    private(set) var config: ConnectionConfig
    /// The saved connection's id, which identifies the window whatever database it is in.
    nonisolated let connectionID: UUID
    /// The database the server opens for the saved connection, before the window moves to another (PostgreSQL).
    private(set) var savedDatabase: String?
    private let password: String?
    private(set) var driver: (any DatabaseDriver)?
    private(set) var status: Status = .connecting
    private(set) var serverVersion: String?
    private(set) var connectedAt: Date?

    var schemas: [String] = []
    /// PostgreSQL: the server's databases this login may open, and the one the window is in.
    private(set) var databases: [String] = []
    private(set) var currentDatabase: String?
    var selectedSchema: String = ""
    private(set) var tables: [TableRef] = [] {
        // Reloading tables (refresh, schema switch, DDL) drops what completion knew; loads still in flight
        // for the old list see the generation change and throw their results away.
        didSet { columnCache = [:]; foreignKeyCache = nil; loadingColumns = []; cacheGeneration += 1 }
    }
    /// Column names per table, filled on demand for SQL completion.
    /// "schema.table" (lower-cased) → columns.
    private var columnCache: [String: [ColumnInfo]] = [:]
    /// Foreign keys of the selected schema, loaded for the AI the first time it is asked.
    private var foreignKeyCache: [ForeignKeyInfo]?
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
    var selectedTabID: UUID? {
        didSet { loadIfUnloaded() }
    }
    var history: [String] = []
    /// The state last saved for this connection or restored from it, so an unchanged one isn't written again.
    var savedState: WorkspaceState?
    /// Set once the saved state has been applied, or found missing. Until then the workspace's empty tabs (still
    /// connecting, or failed to) must not replace what was saved.
    var stateRestored = false
    /// Restored table tabs that haven't loaded their rows; each loads when first selected.
    var unloadedTabs: Set<UUID> = []
    /// Saves the state now and then while the workspace is open (one for its lifetime).
    var stateSaver: Task<Void, Never>?
    var showInspector = false
    /// What the right-hand panel shows.
    enum RightPanel: String, CaseIterable, Identifiable {
        case rowDetails = "Row Details", ai = "AI"
        var id: String { rawValue }
    }
    var rightPanel: RightPanel = .rowDetails
    let chat: AIChatModel

    /// Shows `panel` on the right, or hides the panel if it is already showing it.
    func toggleRightPanel(_ panel: RightPanel) {
        if showInspector && rightPanel == panel {
            showInspector = false
        } else {
            rightPanel = panel
            showInspector = true
        }
    }
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
        /// A tab tied to a file comes back as the file now on disk.
        case file(URL)
    }
    /// Rows selected in the active grid, shown in the row inspector.
    var inspectedRows = IndexSet()
    /// Numbers new query tabs (Query 1, Query 2…); restored tabs carry it on.
    var queryCounter = 0

    init(config: ConnectionConfig, password: String?) {
        self.config = config
        self.connectionID = config.id
        self.password = password
        chat = AIChatModel(connectionID: config.id)
    }

    var filteredTables: [TableRef] {
        guard !tableSearch.isEmpty else { return tables }
        return tables.filter { $0.name.localizedCaseInsensitiveContains(tableSearch) }
    }

    /// Functions, procedures and triggers of the selected schema.
    private(set) var routines: [RoutineInfo] = []

    var filteredRoutines: [RoutineInfo] {
        guard !tableSearch.isEmpty else { return routines }
        return routines.filter { $0.name.localizedCaseInsensitiveContains(tableSearch) || ($0.table?.localizedCaseInsensitiveContains(tableSearch) ?? false) }
    }

    func loadRoutines() async {
        guard let driver else { return }
        // Not every account may read the catalog for routines; the list is simply empty then.
        routines = (try? await driver.routines(in: selectedSchema)) ?? []
    }

    func openRoutine(_ routine: RoutineInfo) {
        guard let driver else { return }
        if let existing = tabs.first(where: { if case .routine(let model) = $0 { return model.routine?.id == routine.id }; return false }) {
            selectedTabID = existing.id
            return
        }
        let model = RoutineTabModel(routine: routine, driver: driver, workspace: self)
        tabs.append(.routine(model))
        selectedTabID = model.id
    }

    func newRoutine(_ kind: RoutineInfo.Kind, table: String? = nil) {
        guard let driver else { return }
        let model = RoutineTabModel(newKind: kind, template: driver.template(for: kind, schema: selectedSchema, table: table),
                                    driver: driver, workspace: self)
        tabs.append(.routine(model))
        selectedTabID = model.id
    }

    var selectedTab: Tab? { tabs.first { $0.id == selectedTabID } }

    var selectedTableTab: TableTabModel? {
        if case .table(let model) = selectedTab { return model }
        return nil
    }

    func connect() async {
        status = .connecting
        do {
            await setUp(try await openDriver(config))
            if tabs.isEmpty { await restoreState() }
            if tabs.isEmpty { newQueryTab() }
            // Files opened from Finder while no connection was ready.
            PendingSQLFiles.take().forEach(openSQLFile)
            #if DEBUG
            DebugHooks.workspaceConnected(self)
            #endif
        } catch {
            status = .failed(PasswordEscapes.message(for: error, password: password))
        }
    }

    private func openDriver(_ config: ConnectionConfig) async throws -> LoggingDriver {
        let log = log
        return LoggingDriver(try await DriverFactory.connect(config, password: password)) { entry in
            Task { @MainActor in log.append(entry) }
        }
    }

    /// Makes `driver` the window's connection and loads what the sidebar shows.
    private func setUp(_ driver: LoggingDriver) async {
        self.driver = driver
        status = .connected
        connectedAt = Date()
        serverVersion = await driver.serverVersion()
        currentDatabase = await driver.currentDatabase()
        if savedDatabase == nil { savedDatabase = currentDatabase }
        databases = (try? await driver.serverDatabases()) ?? []
        schemas = (try? await driver.schemas()) ?? []
        let preferred = (try? await driver.defaultSchema()) ?? ""
        selectedSchema = schemas.contains(preferred) ? preferred : (schemas.first ?? preferred)
        await applySchema()
        await loadTables()
    }

    private func confirmDiscardQueryResults() -> Bool {
        for case .query(let query) in tabs where query.hasResultChanges || query.committingResults {
            if !query.confirmDiscardResults() { return false }
        }
        return true
    }

    func reconnect() async {
        guard confirmDiscardQueryResults() else { return }
        // What was open comes back once connected again; until then the emptied tabs aren't saved.
        saveState()
        stateRestored = false
        for case .query(let query) in tabs { query.suspendResultEditing() }
        await disconnect()
        tabs.removeAll()
        selectedTabID = nil
        await connect()
    }

    func disconnect() async {
        // An answer in progress would go on using the closed connection (and open another).
        chat.stop()
        agentGeneration += 1
        agentOpening?.cancel()
        agentOpening = nil
        let agent = agentDriver
        agentDriver = nil
        await driver?.close()
        driver = nil
        await agent?.close()
    }

    /// Commits result edits through a short-lived connection so a user transaction on the query connection is
    /// never committed or rolled back by a GUI edit.
    func commitQueryEdits(_ edits: [QueryRowEdit], target: QueryEditTarget) async throws -> [Int: [String?]] {
        let writer = try await openDriver(config)
        do {
            let rows = try await writer.commitQueryEdits(edits, target: target)
            await writer.close()
            return rows
        } catch {
            await writer.close()
            throw error
        }
    }

    /// The chat assistant's own connection: read-only where the server allows it, so its queries can't change
    /// data or interfere with the user's transactions. Opened on first use; its statements show in the console.
    private var agentDriver: LoggingDriver?
    private var agentSchema: String?
    /// The agent's connection being opened; callers meanwhile wait for the same one.
    private var agentOpening: Task<LoggingDriver, any Error>?
    /// Bumped by `disconnect`, so a connection that finishes opening for the old database is closed, not kept.
    private var agentGeneration = 0

    func agentToolbox() async throws -> AgentToolbox {
        let generation = agentGeneration
        let driver: LoggingDriver
        if let agentDriver {
            driver = agentDriver
        } else {
            let target = config
            let opening = agentOpening ?? Task {
                let opened = try await openDriver(target)
                do {
                    try await AgentToolbox.prepare(opened)
                    try Task.checkCancellation()
                } catch {
                    await opened.close()
                    throw error
                }
                return opened
            }
            agentOpening = opening
            let opened = try await opening.value
            guard generation == agentGeneration else {
                await opened.close()
                throw CancellationError()
            }
            agentOpening = nil
            agentDriver = opened
            agentSchema = nil
            driver = opened
        }
        // Unqualified names resolve as in the user's queries.
        if agentSchema != selectedSchema {
            try await driver.useSchema(selectedSchema)
            agentSchema = selectedSchema
        }
        return AgentToolbox(driver: driver, currentSchema: selectedSchema)
    }

    /// Tabs whose edits would be lost by leaving the database: changed rows or an unsaved routine.
    var hasUnsavedChanges: Bool {
        tabs.contains { tab in
            switch tab {
            case .table(let model): model.hasChanges
            case .routine(let model): model.hasChanges
            case .query(let model): model.hasResultChanges || model.committingResults
            case .diagram, .metrics: false
            }
        }
    }

    /// The database being opened, while the window still shows the old one; nil otherwise.
    private(set) var openingDatabase: String?

    /// Moves the window to another database on the same server (PostgreSQL, where a connection reaches one
    /// database). The new database is connected first, so if it can't be opened nothing changes. Then query
    /// tabs keep their SQL, tabs showing the old database's tables and routines close, and the AI chat starts
    /// over, since its answers were about the old database. The saved connection is unchanged.
    func openDatabase(_ name: String, startingNewChat: Bool = true) async {
        guard name != currentDatabase, openingDatabase == nil, driver != nil else { return }
        openingDatabase = name
        defer { openingDatabase = nil }
        var target = config
        target.database = name
        let newDriver: LoggingDriver
        do {
            newDriver = try await openDriver(target)
        } catch {
            tablesError = "Couldn't open \(name): \(PasswordEscapes.message(for: error, password: password))"
            return
        }

        // The old workspace remained usable while connecting: check newly staged edits and commits now,
        // immediately before replacing it, not before the await above.
        guard confirmDiscardQueryResults() else {
            await newDriver.close()
            return
        }
        var queries: [QueryTabModel] = []
        for tab in tabs {
            guard case .query(let model) = tab else { continue }
            model.assistant.cancel()
            model.suspendResultEditing()
            queries.append(model)
        }
        await disconnect()
        config = target
        tabs.removeAll()
        selectedTabID = nil
        previewTabID = nil
        // Closed tables belonged to the old database; closed queries can come back.
        closedTabs.removeAll { if case .table = $0 { return true }; return false }
        inspectedRows = []
        schemaTableCache = [:]
        loadingSchemaTables = []
        if startingNewChat { chat.newConversation() }
        await setUp(newDriver)
        if queries.isEmpty {
            newQueryTab()
        } else {
            tabs = queries.map { .query($0.moved(to: newDriver, workspace: self)) }
            selectedTabID = tabs.first?.id
            prefetchColumns()
        }
    }

    func selectSchema(_ schema: String) async {
        guard schema != selectedSchema else { return }
        selectedSchema = schema
        await applySchema()
        await loadTables()
    }

    /// Unqualified names in queries resolve to the schema picked in the sidebar, as in other clients.
    private func applySchema() async {
        do {
            try await driver?.useSchema(selectedSchema)
        } catch {
            tablesError = "Couldn't switch to \(selectedSchema): \(error.localizedDescription)"
        }
    }

    func loadTables() async {
        guard let driver else { return }
        loadingTables = true
        defer { loadingTables = false }
        do {
            let loaded = try await driver.tables(in: selectedSchema)
            // The window may have moved to another database meanwhile.
            guard driver === self.driver else { return }
            tables = loaded
            await loadRoutines()
            if tabs.contains(where: { if case .query = $0 { return true }; return false }) { prefetchColumns() }
            tablesError = nil
        } catch {
            guard driver === self.driver else { return }
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
        guard let driver, config.kind.supportsDiagram else { return }
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

    /// Puts back the tabs of a saved state (see WorkspaceState.swift's `restoreState`).
    func setRestoredTabs(_ restored: [Tab], selected: UUID?) {
        tabs = restored
        selectedTabID = selected
        prefetchColumns()
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
                let columns = (try? await driver.columns(of: table)) ?? []
                guard generation == cacheGeneration else { return }
                loadingColumns.remove(key)
                columnCache[key] = columns
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
            let names = (try? await driver.tables(in: name).map(\.name)) ?? []
            guard driver === self.driver else { return }
            schemaTableCache[key] = names
            completionVersion += 1
            loadingSchemaTables.remove(key)
        }
        return nil
    }

    /// The schema for Ask AI and Fix with AI: waits for columns still loading (up to the prefetch limit)
    /// and for foreign keys, and adds tables of other schemas that `sql` names.
    func loadedAISchema(for sql: String) async -> SQLPrompts.Schema {
        guard let driver else { return aiSchema() }
        let generation = cacheGeneration
        // Tables the text names come first and are always loaded; the others only while time allows.
        var named: [TableRef] = []
        var extra: [TableRef] = []
        for reference in SQLCompletion.tables(in: sql, kind: driver.kind) {
            if let schemaName = reference.schema, schemaName.caseInsensitiveCompare(selectedSchema) != .orderedSame {
                guard let schema = schemas.first(where: { $0.caseInsensitiveCompare(schemaName) == .orderedSame }) else { continue }
                let table = TableRef(schema: schema, name: reference.name)
                named.append(table)
                extra.append(table)
            } else if let table = tables.first(where: { $0.name.caseInsensitiveCompare(reference.name) == .orderedSame }) {
                named.append(table)
            }
        }
        let others = tables.prefix(Defaults.completionPrefetchLimit).filter { table in !named.contains(table) }
        let deadline = ContinuousClock.now + .seconds(Defaults.AI.schemaWait)
        for (index, table) in (named + others).enumerated() where columnCache[Self.columnKey(table)] == nil {
            // Stop (the user cancelled) or run out of time: send what is known.
            if Task.isCancelled || (index >= named.count && ContinuousClock.now >= deadline) { break }
            let columns = (try? await driver.columns(of: table)) ?? []
            guard generation == cacheGeneration else { return aiSchema() }
            columnCache[Self.columnKey(table)] = columns
        }
        if foreignKeyCache == nil, !Task.isCancelled, ContinuousClock.now < deadline {
            let keys = (try? await driver.foreignKeys(in: selectedSchema)) ?? []
            if generation == cacheGeneration { foreignKeyCache = keys }
        }
        return aiSchema(extra: extra)
    }

    /// The schema as the AI sees it: names written as SQL needs them (schema-qualified), column types,
    /// primary and foreign keys. Never rows. With `focus`, only those tables get their columns, which keeps
    /// requests made while typing small.
    func aiSchema(focus: Set<String>? = nil, extra: [TableRef] = []) -> SQLPrompts.Schema {
        let kind = driver?.kind ?? config.kind
        func described(_ table: TableRef) -> SQLPrompts.Schema.Table {
            let name = aiName(table, kind: kind)
            let inFocus = focus.map { $0.contains(table.name.lowercased()) || $0.contains(name.lowercased()) } ?? true
            let columns = inFocus ? (columnCache[Self.columnKey(table)] ?? []).map {
                SQLPrompts.Schema.Column(name: $0.name, type: $0.dataType, isPrimaryKey: $0.isPrimaryKey)
            } : []
            return SQLPrompts.Schema.Table(name: name, columns: columns)
        }
        let keys = (foreignKeyCache ?? []).compactMap { key -> String? in
            guard let target = key.referencedColumns.first, let column = key.columns.first else { return nil }
            return "\(aiName(key.table, kind: kind)).\(column) -> \(aiName(key.referencedTable, kind: kind)).\(target)"
        }
        let defaultSchema = kind == .sqlite ? nil : selectedSchema
        var schema = SQLPrompts.Schema(tables: (tables + extra).map(described), foreignKeys: focus == nil ? keys : [], defaultSchema: defaultSchema)
        schema.isDocument = kind.isDocument
        return schema
    }

    /// `schema.table`, quoting names that need it; SQLite's main database needs no prefix.
    private func aiName(_ table: TableRef, kind: DatabaseKind) -> String {
        let d = SQLDialect(kind: kind)
        func part(_ name: String) -> String {
            name.range(of: "^[a-z_][a-z0-9_]*$", options: .regularExpression) != nil ? name : d.quoteIdentifier(name)
        }
        if kind == .sqlite && table.schema == "main" { return part(table.name) }
        // Collections are named as the shell reaches them from the current database.
        if kind.isDocument { return table.schema == selectedSchema ? table.name : "\(table.schema).\(table.name)" }
        return "\(part(table.schema)).\(part(table.name))"
    }

    /// Every column name loaded so far, for completion before a table is named.
    var knownColumnNames: [String] {
        let prefix = selectedSchema.lowercased() + "."
        return Array(Set(columnCache.filter { $0.key.hasPrefix(prefix) }.values.joined().map(\.name))).sorted()
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
            if let url = model.fileURL {
                closedTabs.append(.file(url))
            } else if !model.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                closedTabs.append(.query(title: model.title, sql: model.sql))
            }
        case .diagram, .metrics, .routine:
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

    /// Whether closing this tab would throw away uncommitted rows or unsaved edits to its file.
    func hasUnsavedChanges(_ id: UUID) -> Bool {
        switch tabs.first(where: { $0.id == id }) {
        case .table(let model): model.hasChanges
        case .query(let model): model.isEdited || model.hasResultChanges || model.committingResults
        default: false
        }
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
        case .file(let url):
            openSQLFile(url)
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
        if let cached = columnCache[key] { return cached.map(\.name) }
        guard let driver, !loadingColumns.contains(key) else { return nil }
        loadingColumns.insert(key)
        let generation = cacheGeneration
        Task {
            let columns = (try? await driver.columns(of: ref)) ?? []
            guard generation == cacheGeneration else { return }
            loadingColumns.remove(key)
            columnCache[key] = columns
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
