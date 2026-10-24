import Foundation
import Security

/// Persists connection settings as JSON in Application Support; passwords go to the Keychain.
public struct ConnectionStore: Sendable {
    public let fileURL: URL
    private let keychainService: String

    public init(directory: URL? = nil, keychainService: String = "app.tabula.connections") {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tabula", isDirectory: true)
        self.fileURL = base.appendingPathComponent("connections.json")
        self.keychainService = keychainService
    }

    public func load() throws -> [ConnectionConfig] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode([ConnectionConfig].self, from: Data(contentsOf: fileURL))
    }

    public func save(_ connections: [ConnectionConfig]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(connections).write(to: fileURL, options: .atomic)
    }

    // MARK: Keychain

    private func query(for id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: id.uuidString,
        ]
    }

    public func password(for id: UUID) -> String? {
        var item = query(for: id)
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setPassword(_ password: String?, for id: UUID) {
        SecItemDelete(query(for: id) as CFDictionary)
        guard let password, !password.isEmpty else { return }
        var item = query(for: id)
        item[kSecValueData as String] = Data(password.utf8)
        item[kSecAttrLabel as String] = "Tabula database connection"
        SecItemAdd(item as CFDictionary, nil)
    }
}
