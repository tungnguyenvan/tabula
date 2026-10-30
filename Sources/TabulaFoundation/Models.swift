import Foundation

public enum DatabaseKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case postgres, mysql, sqlite, redis, mongodb

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .postgres: "PostgreSQL"
        case .mysql: "MySQL / MariaDB"
        case .sqlite: "SQLite"
        case .redis: "Redis"
        case .mongodb: "MongoDB"
        }
    }

    public var defaultPort: Int {
        switch self {
        case .postgres: 5432
        case .mysql: 3306
        case .sqlite: 0
        case .redis: 6379
        case .mongodb: 27017
        }
    }

    public var isFileBased: Bool { self == .sqlite }

    /// MongoDB: collections of documents, queried with shell statements instead of SQL.
    public var isDocument: Bool { self == .mongodb }
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
    /// Seconds to wait while connecting; nil uses `Defaults.connectTimeout`. Optional so older saved files still load.
    public var connectTimeout: Double?
    /// MongoDB: the database that holds the user (authSource); nil uses admin.
    public var authSource: String?
    /// MongoDB: `host` is a DNS seed list name (mongodb+srv://, e.g. Atlas).
    public var srv: Bool?
    /// PostgreSQL / MySQL: reach the server through this SSH server. Optional so older saved files still load.
    public var ssh: SSHConfig?

    public init(
        id: UUID = UUID(),
        name: String = "",
        kind: DatabaseKind = .postgres,
        host: String = Defaults.host,
        port: Int? = nil,
        user: String = "",
        database: String = "",
        filePath: String = "",
        tls: TLSMode = .disable,
        tag: ConnectionTag = .none,
        connectTimeout: Double? = nil,
        authSource: String? = nil,
        srv: Bool? = nil,
        ssh: SSHConfig? = nil
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
        self.connectTimeout = connectTimeout
        self.authSource = authSource
        self.srv = srv
        self.ssh = ssh
    }

    /// The host to connect to: the one entered, or the local machine when it was left blank. Spaces and line
    /// breaks around it (a paste often brings one) are no part of any host name.
    public var resolvedHost: String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Defaults.host : trimmed
    }

    /// Seconds to wait while connecting.
    public var timeout: Double { connectTimeout ?? Defaults.connectTimeout }

    public var displayName: String {
        if !name.isEmpty {
            return name
        }
        if kind.isFileBased {
            return (filePath as NSString).lastPathComponent
        }
        if kind == .redis {
            return "\(host):\(port)"
        }
        return database.isEmpty ? "\(host):\(port)" : "\(database) @ \(host)"
    }

    public var subtitle: String {
        if kind.isFileBased {
            return filePath
        }
        let userPart = user.isEmpty ? "" : "\(user)@"
        if kind == .redis {
            return "\(userPart)\(host):\(port) · db\(database.isEmpty ? "0" : database)"
        }
        let dbPart = database.isEmpty ? "" : "/\(database)"
        // A DNS seed list names no port; the servers' ports come from DNS.
        if kind == .mongodb && srv == true {
            return "\(userPart)\(host)\(dbPart) · DNS seed list"
        }
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

    public init(
        name: String,
        dataType: String,
        isNullable: Bool,
        defaultValue: String?,
        isPrimaryKey: Bool,
        comment: String? = nil
    ) {
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
/// One result row read by column name (case-insensitive; MySQL reports information_schema names in capitals).
public struct Record: Sendable {
    private let index: [String: Int]
    public let values: [String?]

    init(index: [String: Int], values: [String?]) {
        self.index = index
        self.values = values
    }

    static func index(_ columns: [String]) -> [String: Int] {
        Dictionary(columns.enumerated().map { ($1.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
    }

    public subscript(_ column: String) -> String? {
        guard let position = index[column.lowercased()], position < values.count else { return nil }
        return values[position]
    }

    public func number(_ column: String) -> Double { Double(self[column] ?? "") ?? 0 }
    public func int(_ column: String) -> Int? { self[column].flatMap { Int($0) } }
}

public struct QueryResult: Sendable {
    public var columns: [String]
    public var rows: [[String?]]
    public var affectedRows: Int?
    public var duration: TimeInterval
    public var statement: String
    /// MongoDB: each row's whole document as shell text, which keeps the field types the cells don't show.
    public var documents: DocumentTexts?
    /// PostgreSQL source metadata; an alias in `columns` is not a writable database column name.
    public var origins: [QueryColumnOrigin] = []
    /// MySQL protocol origins, separate from PostgreSQL OIDs. Display aliases are never physical names.
    public var mysqlOrigins: [MySQLQueryColumnOrigin]?
    /// SQLite: where each column comes from, nil for an expression.
    public var sqliteOrigins: [SQLiteColumnOrigin?] = []
    /// Columns whose values are bytes, shown as `BinaryText` (SQLite: columns holding at least one blob).
    public var binaryColumns: Set<Int> = []

    public init(
        columns: [String] = [],
        rows: [[String?]] = [],
        affectedRows: Int? = nil,
        duration: TimeInterval = 0,
        statement: String = "",
        documents: DocumentTexts? = nil
    ) {
        self.columns = columns
        self.rows = rows
        self.affectedRows = affectedRows
        self.duration = duration
        self.statement = statement
        self.documents = documents
    }

    public var hasResultSet: Bool { !columns.isEmpty }

    /// Rows addressed by column name, so catalog queries never depend on column positions.
    public var records: [Record] {
        let index = Record.index(columns)
        return rows.map { Record(index: index, values: $0) }
    }

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
