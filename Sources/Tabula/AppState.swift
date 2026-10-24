import Foundation
import Observation
import TabulaCore

@MainActor @Observable
final class AppState {
    /// TABULA_DATA_DIR points the app at a separate store (used for testing).
    let store: ConnectionStore = {
        guard let directory = ProcessInfo.processInfo.environment["TABULA_DATA_DIR"] else { return ConnectionStore() }
        return ConnectionStore(directory: URL(fileURLWithPath: directory), keychainService: "app.tabula.connections.test")
    }()
    private(set) var connections: [ConnectionConfig] = []
    var lastError: String?

    init() {
        do {
            connections = try store.load()
        } catch {
            lastError = "Could not read saved connections: \(error.localizedDescription)"
        }
    }

    func connection(_ id: UUID?) -> ConnectionConfig? {
        connections.first { $0.id == id }
    }

    #if DEBUG
    /// With TABULA_DATA_DIR, debug builds read passwords from passwords.json there, so test runs never touch the Keychain.
    static let testPasswords: [String: String]? = {
        guard let directory = ProcessInfo.processInfo.environment["TABULA_DATA_DIR"],
              let data = try? Data(contentsOf: URL(fileURLWithPath: directory).appendingPathComponent("passwords.json")) else { return nil }
        return try? JSONDecoder().decode([String: String].self, from: data)
    }()
    #endif

    /// Reads the Keychain off the main thread: macOS may block the call while it asks the user for access.
    func password(for id: UUID) async -> String? {
        #if DEBUG
        if let passwords = Self.testPasswords { return passwords[id.uuidString] }
        #endif
        let store = store
        return await Task.detached { store.password(for: id) }.value
    }

    func save(_ config: ConnectionConfig, password: String?) {
        if let index = connections.firstIndex(where: { $0.id == config.id }) {
            connections[index] = config
        } else {
            connections.append(config)
        }
        let store = store
        Task.detached { store.setPassword(password, for: config.id) }
        persist()
    }

    func duplicate(_ config: ConnectionConfig) {
        var copy = config
        copy.id = UUID()
        copy.name = config.displayName + " copy"
        let store = store
        Task {
            let password = await Task.detached { store.password(for: config.id) }.value
            save(copy, password: password)
        }
    }

    func delete(_ id: UUID) {
        connections.removeAll { $0.id == id }
        let store = store
        Task.detached { store.setPassword(nil, for: id) }
        persist()
    }

    func move(from source: IndexSet, to destination: Int) {
        connections.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    private func persist() {
        do {
            try store.save(connections)
        } catch {
            lastError = "Could not save connections: \(error.localizedDescription)"
        }
    }
}
