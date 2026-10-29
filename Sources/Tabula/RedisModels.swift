import AppKit
import Foundation
import Observation
import TabulaFoundation
import TabulaRedis

@MainActor @Observable
final class RedisWorkspaceModel {
    enum Mode: String, CaseIterable, Identifiable {
        case keys = "Keys"
        case console = "Console"
        case metrics = "Metrics"
        var id: String { rawValue }
    }

    let config: ConnectionConfig
    private let password: String?
    private(set) var driver: RedisDriver?
    private(set) var status: WorkspaceModel.Status = .connecting
    private(set) var connectedAt: Date?
    var mode: Mode = .keys

    private(set) var databases: [(index: Int, keys: Int)] = []
    private(set) var database = 0

    var pattern = "*"
    var typeFilter: RedisKeyType?
    private(set) var keys: [RedisKeySummary] = []
    /// Bumped whenever `keys` changes, so the grid reloads.
    private(set) var keysVersion = 0
    /// Rows selected in the keys table.
    var keySelection = IndexSet() {
        didSet {
            guard keySelection != oldValue else { return }
            let single =
                keySelection.count == 1
                ? keySelection.first.flatMap { keys.indices.contains($0) ? keys[$0].key : nil } : nil
            if single != selectedKey {
                selectedKey = single
            }
        }
    }
    private(set) var scanCursor = "0"
    private(set) var loadingKeys = false
    /// Bumped by every restart, so a scan still running for an old pattern or filter drops its results.
    private var scanGeneration = 0
    var keysError: String?
    var selectedKey: RedisBytes? {
        didSet { if selectedKey != oldValue { openSelectedKey() } }
    }
    private(set) var keyModel: RedisKeyModel?
    var patternFocusRequest = 0
    var showNewKey = false
    let console: RedisConsoleModel
    private(set) var metrics: MetricsModel?

    init(config: ConnectionConfig, password: String?) {
        self.config = config
        self.password = password
        self.console = RedisConsoleModel(config: config)
    }

    var hasMoreKeys: Bool { scanCursor != "0" }

    /// "item:2" before "item:10", like Finder.
    static func naturalOrder(_ a: RedisKeySummary, _ b: RedisKeySummary) -> Bool {
        a.key.display.localizedStandardCompare(b.key.display) == .orderedAscending
    }

    func connect() async {
        status = .connecting
        do {
            let driver = try await RedisDriver.connect(config, password: password)
            self.driver = driver
            console.driver = driver
            console.workspace = self
            metrics = MetricsModel { try await driver.metrics() }
            database = await driver.database
            status = .connected
            connectedAt = Date()
            await reloadDatabases()
            await reloadKeys()
            #if DEBUG
            DebugHooks.redisConnected(self)
            #endif
        } catch {
            status = .failed(PasswordEscapes.message(for: error, password: password))
        }
    }

    func disconnect() async {
        await driver?.close()
        driver = nil
    }

    func reconnect() async {
        await disconnect()
        keys = []
        selectedKey = nil
        await connect()
    }

    func reloadDatabases() async {
        guard let driver else { return }
        databases = (try? await driver.databases()) ?? [(database, 0)]
    }

    func selectDatabase(_ index: Int) async {
        guard let driver, index != database else { return }
        do {
            try await driver.select(index)
            database = index
            selectedKey = nil
            await reloadKeys()
        } catch {
            keysError = error.localizedDescription
        }
    }

    /// Called when the console ran SELECT, so the browser follows it.
    func databaseChanged(to index: Int) async {
        guard index != database else { return }
        database = index
        selectedKey = nil
        await reloadKeys()
    }

    /// Restarts the scan with the current pattern and type filter.
    func reloadKeys() async {
        scanGeneration += 1
        scanCursor = "0"
        keys = []
        keySelection = []
        keysVersion += 1
        await loadMoreKeys(restart: true)
    }

    func loadMoreKeys(restart: Bool = false) async {
        guard let driver, restart || (hasMoreKeys && !loadingKeys) else { return }
        let generation = scanGeneration
        loadingKeys = true
        defer { if generation == scanGeneration { loadingKeys = false } }
        do {
            let page = try await driver.scanKeys(from: scanCursor, match: pattern, type: typeFilter)
            guard generation == scanGeneration else { return }
            let known = Set(keys.map(\.key))
            // SCAN can return a key more than once; keep the first.
            let fresh = Array(Set(page.keys).subtracting(known))
            let summaries = try await driver.summaries(of: fresh)
            guard generation == scanGeneration else { return }
            keys += summaries.sorted(by: Self.naturalOrder)
            keysVersion += 1
            scanCursor = page.cursor
            keysError = nil
        } catch {
            if generation == scanGeneration {
                keysError = error.localizedDescription
            }
        }
    }

    func refresh() async {
        await reloadDatabases()
        let selected = selectedKey
        await reloadKeys()
        if let selected, keys.contains(where: { $0.key == selected }) {
            await keyModel?.reload()
        } else {
            selectedKey = nil
        }
    }

    private func openSelectedKey() {
        if suppressReopen {
            return
        }
        guard let driver, let key = selectedKey else {
            keyModel = nil
            return
        }
        let model = RedisKeyModel(key: key, driver: driver, workspace: self)
        keyModel = model
        Task { await model.reload() }
    }

    func delete(_ keysToDelete: [RedisBytes]) async {
        guard let driver else { return }
        do {
            _ = try await driver.delete(keysToDelete)
            let removed = Set(keysToDelete)
            keys.removeAll { removed.contains($0.key) }
            keysVersion += 1
            keySelection = []
            await reloadDatabases()
        } catch {
            keysError = error.localizedDescription
        }
    }

    /// Creates a key with its first value, refusing to overwrite an existing one.
    func create(key: RedisBytes, type: RedisKeyType, values: [RedisBytes], ttl: Int?) async throws {
        guard let driver else { return }
        if try await driver.exists(key) {
            throw DatabaseError("A key named “\(key.display)” already exists.")
        }
        try await driver.add(key, type: type, values: values)
        if let ttl {
            try await driver.setTTL(key, seconds: ttl)
        }
        if let summary = try await driver.summaries(of: [key]).first {
            keys.append(summary)
            keys.sort(by: Self.naturalOrder)
            keysVersion += 1
            select(key)
        }
        await reloadDatabases()
    }

    func renamed(_ old: RedisBytes, to new: RedisBytes) {
        if let index = keys.firstIndex(where: { $0.key == old }) {
            keys[index].key = new
            keys.sort(by: Self.naturalOrder)
            keysVersion += 1
        }
        select(new, reopen: false)
    }

    /// Selects a key's row (and opens it below the table).
    func select(_ key: RedisBytes, reopen: Bool = true) {
        guard let index = keys.firstIndex(where: { $0.key == key }) else { return }
        if !reopen {
            suppressReopen = true
        }
        keySelection = [index]
        suppressReopen = false
    }
    private var suppressReopen = false

    /// Re-reads one row after the key was edited elsewhere (detail pane, inline edit).
    func refreshSummary(_ key: RedisBytes) async {
        guard let driver, let index = keys.firstIndex(where: { $0.key == key }) else { return }
        if let summary = try? await driver.summaries(of: [key]).first {
            keys[index] = summary
        } else {
            keys.remove(at: index)
            keySelection = []
        }
        keysVersion += 1
    }

    // MARK: Inline edits in the keys table (columns: key, type, ttl, size, value)

    enum KeyColumn: Int { case key, type, ttl, size, value }

    func isEditable(row: Int, column: Int) -> Bool {
        guard keys.indices.contains(row), let column = KeyColumn(rawValue: column) else { return false }
        switch column {
        case .key: return keys[row].key.isText
        case .ttl: return true
        case .value:
            return keys[row].type == .string && keys[row].length <= RedisDriver.maxEditableStringBytes
                && keys[row].length < 200
        case .type, .size: return false
        }
    }

    func edit(row: Int, column: Int, value: String?) async {
        guard let driver, keys.indices.contains(row), let column = KeyColumn(rawValue: column) else { return }
        let summary = keys[row]
        do {
            switch column {
            case .key:
                guard let value, !value.isEmpty else { return }
                try await driver.rename(summary.key, to: RedisBytes(value))
                renamed(summary.key, to: RedisBytes(value))
                keyModel?.keyWasRenamed(to: RedisBytes(value))
                return
            case .ttl:
                try await driver.setTTL(summary.key, seconds: try RedisTTL.parse(value ?? ""))
            case .value:
                try await driver.setString(summary.key, to: RedisBytes(value ?? ""))
            case .type, .size:
                return
            }
            keysError = nil
        } catch {
            keysError = error.localizedDescription
            NSSound.beep()
        }
        await refreshSummary(summary.key)
        if keyModel?.key == summary.key {
            await keyModel?.reload()
        }
    }

    func confirmDelete(_ keysToDelete: [RedisBytes]) {
        guard !keysToDelete.isEmpty else { return }
        let message =
            keysToDelete.count == 1
            ? "Delete key “\(keysToDelete[0].display)”?" : "Delete \(keysToDelete.count) keys?"
        let detail =
            config.tag == .production
            ? "This is a PRODUCTION connection. This cannot be undone." : "This cannot be undone."
        if Confirmation.ask(message, detail: detail, action: "Delete") { Task { await delete(keysToDelete) } }
    }
}

/// The key shown in the detail pane.
@MainActor @Observable
final class RedisKeyModel {
    private(set) var key: RedisBytes
    let driver: RedisDriver
    private weak var workspace: RedisWorkspaceModel?

    private(set) var info: RedisKeyInfo?
    private(set) var loading = false
    var error: String?

    // Strings
    private(set) var stringValue: RedisBytes?
    private(set) var stringTruncated = false
    var draft = ""

    // Collections
    private(set) var columns: [String] = []
    private(set) var rows: [[RedisBytes]] = []
    private(set) var next: String?
    private(set) var version = 0

    init(key: RedisBytes, driver: RedisDriver, workspace: RedisWorkspaceModel) {
        self.key = key
        self.driver = driver
        self.workspace = workspace
    }

    var type: RedisKeyType { info?.type ?? .unknown }
    var canEditString: Bool { stringValue?.isText == true && !stringTruncated }
    var hasStringChanges: Bool { canEditString && draft != stringValue?.text }
    var canEditCells: Bool { [.hash, .list, .set, .zset].contains(type) }

    func reload() async {
        loading = true
        defer {
            loading = false
            version += 1
        }
        do {
            let info = try await driver.info(key)
            self.info = info
            if info.type == .unknown {
                error = "This key no longer exists."
                return
            }
            if info.type == .string {
                let value = try await driver.string(key)
                stringValue = value.value
                stringTruncated = value.truncated
                draft = value.value.text ?? value.value.display
            } else {
                let page = try await driver.page(key, type: info.type, after: nil)
                columns = page.columns
                rows = page.rows
                next = page.next
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func loadMore() async {
        guard let next, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            let page = try await driver.page(key, type: type, after: next)
            if page.columns.count > columns.count {
                columns = page.columns
            }
            rows += page.rows.map { row in
                row + Array(repeating: RedisBytes(""), count: max(0, columns.count - row.count))
            }
            self.next = page.next
            version += 1
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func perform(_ action: () async throws -> Void) async {
        do {
            try await action()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        await reload()
        await workspace?.refreshSummary(key)
    }

    func keyWasRenamed(to newKey: RedisBytes) {
        key = newKey
    }

    func saveString() async {
        guard hasStringChanges else { return }
        await perform { try await driver.setString(key, to: RedisBytes(draft)) }
    }

    func formatJSON() {
        guard let data = draft.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data),
            let pretty = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            ),
            let text = String(data: pretty, encoding: .utf8)
        else {
            NSSound.beep()
            return
        }
        draft = text
    }

    func setTTL(seconds: Int?) async {
        await perform { try await driver.setTTL(key, seconds: seconds) }
    }

    func rename(to newName: String) async {
        let newKey = RedisBytes(newName)
        guard !newName.isEmpty, newKey != key else { return }
        do {
            try await driver.rename(key, to: newKey)
            let old = key
            key = newKey
            workspace?.renamed(old, to: newKey)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func isEditable(row: Int, column: Int) -> Bool {
        guard canEditCells, rows.indices.contains(row), rows[row].indices.contains(column), rows[row][column].isText
        else { return false }
        return !(type == .list && column == 0)
    }

    func update(row: Int, column: Int, to value: String?) async {
        guard rows.indices.contains(row) else { return }
        guard isEditable(row: row, column: column) else {
            error =
                type == .list && column == 0
                ? "List indexes can't be edited." : "Binary values can't be edited here; use the console."
            return
        }
        let current = rows[row]
        await perform {
            try await driver.update(
                key,
                type: type,
                element: current[0],
                column: column,
                to: RedisBytes(value ?? ""),
                row: current
            )
        }
    }

    func remove(rows indices: IndexSet) async {
        let elements = indices.filter { rows.indices.contains($0) }.map { rows[$0][0] }
        guard !elements.isEmpty else { return }
        await perform { try await driver.remove(key, type: type, elements: elements) }
    }

    func add(_ values: [String]) async {
        await perform { try await driver.add(key, type: type, values: values.map(RedisBytes.init)) }
    }

    func copyText(_ indices: IndexSet) -> String {
        indices.filter { rows.indices.contains($0) }.map { rows[$0].map(\.display).joined(separator: "\t") }
            .joined(separator: "\n")
    }
}

/// The redis-cli style console.
@MainActor @Observable
final class RedisConsoleModel {
    struct Entry: Identifiable {
        let id = UUID()
        let prompt: String
        let command: String
        let output: String
        let isError: Bool
    }

    let config: ConnectionConfig
    var driver: RedisDriver?
    weak var workspace: RedisWorkspaceModel?
    private(set) var entries: [Entry] = []
    var input = ""
    private(set) var running = false
    private var history: [String] = []
    private var historyIndex: Int?

    init(config: ConnectionConfig) { self.config = config }

    var prompt: String {
        let database = workspace?.database ?? 0
        return "\(config.host):\(config.port)" + (database == 0 ? "" : "[\(database)]") + ">"
    }

    func run() async {
        let line = input.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !running, let driver else { return }
        let prompt = self.prompt
        input = ""
        historyIndex = nil
        if history.last != line {
            history.append(line)
        }

        if line.lowercased() == "clear" {
            entries = []
            return
        }
        let arguments: [[UInt8]]
        do {
            arguments = try RedisCommandLine.parse(line)
        } catch {
            entries.append(
                Entry(
                    prompt: prompt,
                    command: line,
                    output: "Invalid argument(s): \(error.localizedDescription)",
                    isError: true
                )
            )
            return
        }
        if let refusal = RedisCommandLine.refusal(for: arguments) {
            entries.append(Entry(prompt: prompt, command: line, output: refusal, isError: true))
            return
        }
        if RedisCommandLine.isDestructive(arguments)
            || (config.tag == .production && !RedisCommandLine.isReadOnly(arguments))
        {
            guard confirm(line) else {
                entries.append(Entry(prompt: prompt, command: line, output: "Cancelled.", isError: true))
                return
            }
        }

        running = true
        defer { running = false }
        do {
            let reply = try await driver.send(arguments)
            var isError = false
            if case .error = reply {
                isError = true
            }
            entries.append(Entry(prompt: prompt, command: line, output: reply.formatted(), isError: isError))
            let database = await driver.database
            await workspace?.databaseChanged(to: database)
        } catch {
            entries.append(Entry(prompt: prompt, command: line, output: error.localizedDescription, isError: true))
        }
    }

    private func confirm(_ line: String) -> Bool {
        Confirmation.ask(
            "Run “\(line.prefix(120))”?",
            detail: config.tag == .production
                ? "This is a PRODUCTION connection." : "This command can delete or change a lot of data.",
            action: "Run"
        )
    }

    func historyUp() {
        guard !history.isEmpty else { return }
        let index = max(0, (historyIndex ?? history.count) - 1)
        historyIndex = index
        input = history[index]
    }

    func historyDown() {
        guard let index = historyIndex else { return }
        if index + 1 < history.count {
            historyIndex = index + 1
            input = history[index + 1]
        } else {
            historyIndex = nil
            input = ""
        }
    }

    func clear() { entries = [] }
}
