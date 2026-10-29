import Foundation
import Security
import TabulaFoundation

/// Persists connection settings as JSON in Application Support; passwords go to the Keychain.
public struct ConnectionStore: Sendable {
    public let fileURL: URL
    private let keychainService: String

    public init(directory: URL? = nil, keychainService: String = "app.tabula.connections") {
        let base =
            directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tabula", isDirectory: true)
        self.fileURL = base.appendingPathComponent("connections.json")
        self.keychainService = keychainService
    }

    public func load() throws -> [ConnectionConfig] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        return try JSONDecoder().decode([ConnectionConfig].self, from: Data(contentsOf: fileURL))
    }

    public func save(_ connections: [ConnectionConfig]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(connections).write(to: fileURL, options: .atomic)
    }

    // MARK: Keychain

    public func password(for id: UUID) -> String? {
        KeychainItem(service: keychainService, account: id.uuidString).read()
    }

    public func setPassword(_ password: String?, for id: UUID) throws {
        try KeychainItem(service: keychainService, account: id.uuidString, label: "Tabula database connection")
            .write(password)
    }
}

/// One generic password in the login Keychain.
public struct KeychainItem: Sendable {
    public let service: String
    public let account: String
    public var label: String?

    public init(service: String, account: String, label: String? = nil) {
        self.service = service
        self.account = account
        self.label = label
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func read() -> String? {
        var item = query
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(item as CFDictionary, &result) == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Stores `value` without replacing an existing item's access permissions (including Always Allow). Only an
    /// explicit nil or empty value deletes it; authorization and other failures leave the existing item intact.
    public func write(_ value: String?) throws {
        guard let value, !value.isEmpty else {
            let removed = SecItemDelete(query as CFDictionary)
            guard removed == errSecSuccess || removed == errSecItemNotFound else {
                throw KeychainError(status: removed)
            }
            return
        }
        var attributes: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        if let label {
            attributes[kSecAttrLabel as String] = label
        }
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess {
            return
        }
        guard updated == errSecItemNotFound else { throw KeychainError(status: updated) }

        let item = query.merging(attributes) { _, new in new }
        let added = SecItemAdd(item as CFDictionary, nil)
        // Another writer may have created it since the update found nothing. Keep that item's access controls too.
        if added == errSecDuplicateItem {
            let retried = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard retried == errSecSuccess else { throw KeychainError(status: retried) }
        } else if added != errSecSuccess {
            throw KeychainError(status: added)
        }
    }
}

public struct KeychainError: LocalizedError {
    public let status: OSStatus
    public var errorDescription: String? {
        let reason = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
        return "Keychain: \(reason)"
    }
}
