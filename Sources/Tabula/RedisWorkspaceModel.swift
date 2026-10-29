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
            var single: RedisBytes?
            if keySelection.count == 1, let row = keySelection.first, keys.indices.contains(row) {
                single = keys[row].key
            }
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
        do {
            databases = try await driver.databases()
        } catch {
            // The list stays as it was rather than showing the current database alone, as if it were the only one.
            keysError = "Couldn't list the databases: \(error.localizedDescription)"
        }
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
        let summaries: [RedisKeySummary]
        do {
            summaries = try await driver.summaries(of: [key])
        } catch {
            // The key may well still exist: keep its row and say why it wasn't updated.
            keysError = "Couldn't re-read \(key.display): \(error.localizedDescription)"
            return
        }
        // `summaries` leaves out keys that no longer exist.
        if let summary = summaries.first {
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
