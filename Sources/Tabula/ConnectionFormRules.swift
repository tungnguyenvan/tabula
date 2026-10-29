import Foundation
import TabulaFoundation

/// The connection form's rules, apart from its view: what a pasted connection string fills in, and when the
/// form may be saved or tested.
enum ConnectionFormRules {
    /// The form after a connection string was pasted into the Host field.
    struct Pasted: Equatable {
        var config: ConnectionConfig
        var password: String
        /// The URL named another database kind: the kind's own defaults (port, TLS) mustn't overwrite it.
        var changedKind: Bool
    }

    /// What pasting `text` over `form` (whose host was `oldHost`) gives, or nil when `text` isn't a connection
    /// string. The connection keeps its id, name, tag, timeout and SSH server; a URL without a password keeps the
    /// saved one only for the same server (kind, host and port), so it is never sent to another.
    static func pasted(_ text: String, over form: ConnectionConfig, password: String, oldHost: String) -> Pasted? {
        guard let (parsed, parsedPassword) = ConnectionConfig.parse(connectionString: text) else { return nil }
        var filled = parsed
        filled.id = form.id
        if filled.name.isEmpty {
            filled.name = form.name
        }
        if filled.tag == ConnectionConfig().tag {
            filled.tag = form.tag
        }
        filled.connectTimeout = form.connectTimeout
        // A URL names the database, not how to reach it: the SSH server stays, for the kinds that can use it.
        filled.ssh = filled.kind == .postgres || filled.kind == .mysql ? form.ssh : nil
        let newPassword: String
        if let parsedPassword {
            newPassword = parsedPassword
        } else if filled.host != oldHost || filled.port != form.port || filled.kind != form.kind {
            newPassword = ""
        } else {
            newPassword = password
        }
        return Pasted(config: filled, password: newPassword, changedKind: filled.kind != form.kind)
    }

    /// Whether the form holds enough to connect.
    static func isValid(_ config: ConnectionConfig) -> Bool {
        switch config.kind {
        case .sqlite: return !config.filePath.isEmpty
        case .redis:
            let database = config.database.trimmingCharacters(in: .whitespaces)
            return (1...65535).contains(config.port) && (database.isEmpty || (Int(database).map { $0 >= 0 } ?? false))
        case .postgres, .mysql:
            return !config.user.isEmpty && (1...65535).contains(config.port) && config.ssh?.problem == nil
        case .mongodb: return !config.host.isEmpty && (config.srv == true || (1...65535).contains(config.port))
        }
    }
}
