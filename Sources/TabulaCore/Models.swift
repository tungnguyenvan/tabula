import Foundation

public enum DatabaseKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case postgres, mysql, sqlite

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .postgres: "PostgreSQL"
        case .mysql: "MySQL / MariaDB"
        case .sqlite: "SQLite"
        }
    }

    public var defaultPort: Int {
        switch self {
        case .postgres: 5432
        case .mysql: 3306
        case .sqlite: 0
        }
    }

    public var isFileBased: Bool { self == .sqlite }
}

public enum TLSMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Plain TCP.
    case disable
    /// Encrypt, but accept any server certificate.
    case require
    /// Encrypt and verify the server certificate and hostname.
    case verifyFull

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .disable: "Disabled"
        case .require: "Required (no verification)"
        case .verifyFull: "Verify certificate"
        }
    }
}

public enum ConnectionTag: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, local, development, staging, production

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .none: "None"
        case .local: "Local"
        case .development: "Development"
        case .staging: "Staging"
        case .production: "Production"
        }
    }
}

/// A saved connection. Passwords are kept in the Keychain, never in this struct's persisted form.
public struct ConnectionConfig: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: DatabaseKind
    public var host: String
    public var port: Int
    public var user: String
    public var database: String
    public var filePath: String
    public var tls: TLSMode
    public var tag: ConnectionTag

    public init(
        id: UUID = UUID(),
        name: String = "",
        kind: DatabaseKind = .postgres,
        host: String = "127.0.0.1",
        port: Int? = nil,
        user: String = "",
        database: String = "",
        filePath: String = "",
        tls: TLSMode = .disable,
        tag: ConnectionTag = .none
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.host = host
        self.port = port ?? kind.defaultPort
        self.user = user
        self.database = database
        self.filePath = filePath
        self.tls = tls
        self.tag = tag
    }

    public var displayName: String {
        if !name.isEmpty { return name }
        if kind.isFileBased { return (filePath as NSString).lastPathComponent }
        return database.isEmpty ? "\(host):\(port)" : "\(database) @ \(host)"
    }

    public var subtitle: String {
        if kind.isFileBased { return filePath }
        let userPart = user.isEmpty ? "" : "\(user)@"
        let dbPart = database.isEmpty ? "" : "/\(database)"
        return "\(userPart)\(host):\(port)\(dbPart)"
    }
}

public enum TableKind: String, Sendable, Hashable {
    case table, view
}

public struct TableRef: Hashable, Sendable, Identifiable {
    /// Postgres schema, MySQL database, or SQLite schema ("main").
    public var schema: String
    public var name: String
    public var kind: TableKind

    public init(schema: String, name: String, kind: TableKind = .table) {
        self.schema = schema
        self.name = name
        self.kind = kind
    }

    public var id: String { "\(schema).\(name)" }
}

public struct ColumnInfo: Hashable, Sendable, Identifiable {
    public var name: String
    public var dataType: String
    public var isNullable: Bool
    public var defaultValue: String?
    public var isPrimaryKey: Bool
    public var comment: String?

    public init(name: String, dataType: String, isNullable: Bool, defaultValue: String?, isPrimaryKey: Bool, comment: String? = nil) {
        self.name = name
        self.dataType = dataType
        self.isNullable = isNullable
        self.defaultValue = defaultValue
        self.isPrimaryKey = isPrimaryKey
        self.comment = comment
    }

    public var id: String { name }
}

public struct IndexInfo: Hashable, Sendable, Identifiable {
    public var name: String
    public var columns: [String]
    public var isUnique: Bool
    public var isPrimary: Bool
    public var definition: String?

    public init(name: String, columns: [String], isUnique: Bool, isPrimary: Bool, definition: String? = nil) {
        self.name = name
        self.columns = columns
        self.isUnique = isUnique
        self.isPrimary = isPrimary
        self.definition = definition
    }

    public var id: String { name }
}

/// The result of one statement. `rows` hold display text; `nil` is SQL NULL.
public struct QueryResult: Sendable {
    public var columns: [String]
    public var rows: [[String?]]
    public var affectedRows: Int?
    public var duration: TimeInterval
    public var statement: String

    public init(columns: [String] = [], rows: [[String?]] = [], affectedRows: Int? = nil, duration: TimeInterval = 0, statement: String = "") {
        self.columns = columns
        self.rows = rows
        self.affectedRows = affectedRows
        self.duration = duration
        self.statement = statement
    }

    public var hasResultSet: Bool { !columns.isEmpty }

    public var summary: String {
        let time = String(format: "%.0f ms", duration * 1000)
        if hasResultSet {
            return "\(rows.count) row\(rows.count == 1 ? "" : "s") · \(time)"
        }
        if let affectedRows {
            return "\(affectedRows) row\(affectedRows == 1 ? "" : "s") affected · \(time)"
        }
        return "OK · \(time)"
    }
}

public struct DatabaseError: LocalizedError, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
