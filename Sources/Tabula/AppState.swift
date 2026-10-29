import Foundation
import Observation
import TabulaAI
import TabulaFoundation
import TabulaStorage

@MainActor @Observable
final class AppState {
    /// TABULA_DATA_DIR points the app at a separate store (used for testing).
    let store: ConnectionStore = {
        guard let directory = ProcessInfo.processInfo.environment["TABULA_DATA_DIR"] else {
            return ConnectionStore()
        }
        return ConnectionStore(
            directory: URL(fileURLWithPath: directory),
            keychainService: "app.tabula.connections.test"
        )
    }()
    /// Saved AI conversations, next to the connections (in TABULA_DATA_DIR when that is set).
    nonisolated static let chatStore: ChatStore = {
        guard let directory = ProcessInfo.processInfo.environment["TABULA_DATA_DIR"] else {
            return ChatStore()
        }
        return ChatStore(base: URL(fileURLWithPath: directory))
    }()
    /// The saved query library, next to the connections (in TABULA_DATA_DIR when that is set).
    nonisolated static let queryLibrary: QueryLibrary = {
        guard let directory = ProcessInfo.processInfo.environment["TABULA_DATA_DIR"] else {
            return QueryLibrary()
        }
        return QueryLibrary(base: URL(fileURLWithPath: directory))
    }()
    private(set) var connections: [ConnectionConfig] = []
    var lastError: String?
    /// Keychain calls run here, in order, and off the main thread: macOS may block them while it asks
    /// the user for access, and a read must see the writes queued before it.
    private let keychain = DispatchQueue(label: "app.tabula.keychain")
    /// Passwords already read this launch, so opening a connection again doesn't hit the Keychain (and its prompt).
    private var passwordCache: [UUID: String?] = [:]

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
            let data = try? Data(contentsOf: URL(fileURLWithPath: directory).appendingPathComponent("passwords.json"))
        else { return nil }
        // Debug test store only: without passwords.json the Keychain is used.
        return try? JSONDecoder().decode([String: String].self, from: data)
    }()
    #endif

    func password(for id: UUID) async -> String? {
        #if DEBUG
        if let passwords = Self.testPasswords {
            return passwords[id.uuidString]
        }
        #endif
        if let cached = passwordCache[id] {
            return cached
        }
        let store = store
        let password = await withCheckedContinuation { continuation in
            keychain.async { continuation.resume(returning: store.password(for: id)) }
        }
        passwordCache[id] = password
        return password
    }

    private func setPassword(_ password: String?, for id: UUID) {
        passwordCache[id] = password?.isEmpty == false ? password : nil
        #if DEBUG
        if Self.testPasswords != nil {
            return
        }
        #endif
        let store = store
        keychain.async {
            do {
                try store.setPassword(password, for: id)
            } catch {
                let message = "Could not save the password: \(error.localizedDescription)"
                Task { @MainActor [weak self] in self?.lastError = message }
            }
        }
    }

    func save(_ config: ConnectionConfig, password: String?) {
        if let index = connections.firstIndex(where: { $0.id == config.id }) {
            connections[index] = config
        } else {
            connections.append(config)
        }
        setPassword(password, for: config.id)
        persist()
    }

    func duplicate(_ config: ConnectionConfig) {
        var copy = config
        copy.id = UUID()
        copy.name = config.displayName + " copy"
        Task {
            let password = await password(for: config.id)
            save(copy, password: password)
        }
    }

    func delete(_ id: UUID) {
        connections.removeAll { $0.id == id }
        setPassword(nil, for: id)
        Self.chatStore.remove(id)
        WorkspaceModel.stateStore.remove(id)
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
