import Foundation
import Security
import TabulaFoundation

/// Generic passwords by account, as the Keychain keeps them; tests use one in memory.
public protocol PasswordKeychain: Sendable {
    /// The value, nil when there is none; throws when it exists but can't be read (access denied, locked).
    func read(account: String) throws -> String?
    /// Stores the value, or removes the item for nil.
    func write(_ value: String?, account: String, label: String?) throws
}

/// The login Keychain, items under one service.
public struct SystemKeychain: PasswordKeychain {
    public let service: String

    public init(service: String) {
        self.service = service
    }

    public func read(account: String) throws -> String? {
        try KeychainItem(service: service, account: account).readThrowing()
    }

    public func write(_ value: String?, account: String, label: String?) throws {
        try KeychainItem(service: service, account: account, label: label).write(value)
    }
}

/// Persists connection settings as JSON in Application Support; passwords go to the Keychain.
public struct ConnectionStore: Sendable {
    public let fileURL: URL
    private let keychain: any PasswordKeychain

    public init(directory: URL? = nil, keychainService: String = "app.tabula.connections") {
        self.init(directory: directory, keychain: SystemKeychain(service: keychainService))
    }

    public init(directory: URL? = nil, keychain: any PasswordKeychain) {
        let base =
            directory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tabula", isDirectory: true)
        self.fileURL = base.appendingPathComponent("connections.json")
        self.keychain = keychain
    }

    /// The saved connections, and where a copy of the file went when some of it couldn't be read.
    public struct Loaded: Sendable {
        public var connections: [ConnectionConfig]
        public var setAside: URL?
    }

    /// Reads every connection it can. When the file, or one of its connections, can't be read (damaged, or
    /// written by a newer Tabula with a kind this one doesn't know), the file is first copied aside: the next
    /// save writes only what was read, and would otherwise erase the rest.
    public func load() throws -> Loaded {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return Loaded(connections: [], setAside: nil)
        }
        let data = try Data(contentsOf: fileURL)
        let entries = try? JSONDecoder().decode([LossyConnection].self, from: data)
        let connections = entries?.compactMap(\.value) ?? []
        guard entries == nil || connections.count != entries?.count else {
            return Loaded(connections: connections, setAside: nil)
        }
        let folder = fileURL.deletingLastPathComponent()
        // Until something is saved every launch finds the same file; one copy of it is enough.
        let earlier = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        if let copy = earlier.first(where: {
            $0.lastPathComponent.hasPrefix("connections.unreadable-") && (try? Data(contentsOf: $0)) == data
        }) {
            return Loaded(connections: connections, setAside: copy)
        }
        let aside =
            folder
            .appendingPathComponent(
                "connections.unreadable-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).json"
            )
        try FileManager.default.copyItem(at: fileURL, to: aside)
        return Loaded(connections: connections, setAside: aside)
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

    // Every connection's password is in one item, so the Keychain asks once and one "Always Allow" covers them
    // all (#266). Each connection used to have an item of its own; one is moved over the first time it is read.

    static let sharedAccount = "connection-passwords"
    static let sharedLabel = "Tabula database passwords"

    /// Every password in the shared item, by connection id; empty when there is none yet.
    public func passwords() throws -> [UUID: String] {
        guard let text = try keychain.read(account: Self.sharedAccount) else {
            return [:]
        }
        guard let stored = try? JSONDecoder().decode([String: String].self, from: Data(text.utf8)) else {
            throw DatabaseError("The saved passwords in the Keychain can't be read.")
        }
        return Dictionary(
            uniqueKeysWithValues: stored.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } }
        )
    }

    public func password(for id: UUID) -> String? {
        let shared = try? passwords()
        if let password = shared?[id] {
            return password
        }
        guard let legacy = try? keychain.read(account: id.uuidString), !legacy.isEmpty else {
            return nil
        }
        // Moved only when the shared item could be read, so a refused read never overwrites the others.
        if var shared {
            shared[id] = legacy
            if (try? write(shared)) != nil {
                try? keychain.write(nil, account: id.uuidString, label: nil)
            }
        }
        return legacy
    }

    /// Stores (or, for nil or empty, removes) a connection's password. The shared item must be readable first:
    /// writing it unread would drop every other connection's password.
    public func setPassword(_ password: String?, for id: UUID) throws {
        var shared = try passwords()
        if let password, !password.isEmpty {
            shared[id] = password
        } else {
            shared[id] = nil
        }
        try write(shared)
        try? keychain.write(nil, account: id.uuidString, label: nil)
    }

    private func write(_ passwords: [UUID: String]) throws {
        let stored = Dictionary(uniqueKeysWithValues: passwords.map { ($0.key.uuidString, $0.value) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let text = String(decoding: try encoder.encode(stored), as: UTF8.self)
        try keychain.write(stored.isEmpty ? nil : text, account: Self.sharedAccount, label: Self.sharedLabel)
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
        try? readThrowing()
    }

    /// The value, nil when there is no item; throws when one exists but can't be read (access denied, locked).
    public func readThrowing() throws -> String? {
        var item = query
        item[kSecReturnData as String] = true
        item[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainError(status: status)
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
        guard updated == errSecItemNotFound else {
            throw KeychainError(status: updated)
        }

        let item = query.merging(attributes) { _, new in new }
        let added = SecItemAdd(item as CFDictionary, nil)
        // Another writer may have created it since the update found nothing. Keep that item's access controls too.
        if added == errSecDuplicateItem {
            let retried = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
            guard retried == errSecSuccess else {
                throw KeychainError(status: retried)
            }
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

/// One saved connection, or nil when this version can't read it.
private struct LossyConnection: Decodable {
    let value: ConnectionConfig?

    init(from decoder: Decoder) throws {
        value = try? ConnectionConfig(from: decoder)
    }
}
