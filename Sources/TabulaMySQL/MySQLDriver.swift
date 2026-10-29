import Foundation
import Logging
import MySQLNIO
import NIOPosix
import TabulaDrivers
import TabulaFoundation
import TabulaSQL

public actor MySQLDriver: DatabaseDriver {
    /// ER_UNSUPPORTED_PS: the statement can't be prepared and must be sent as text.
    static let unsupportedPreparedStatement: UInt16 = 1295

    public nonisolated let kind: DatabaseKind = .mysql
    public nonisolated let dialect: any QueryDialect = SQLDialect(flavor: .mysql)
    public nonisolated let catalog: any DatabaseCatalog = MySQLCatalog()
    private let connection: MySQLConnection
    private let initialDatabase: String

    private init(connection: MySQLConnection, initialDatabase: String) {
        self.connection = connection
        self.initialDatabase = initialDatabase
    }

    /// `tlsServerName` overrides the name TLS checks, for connections through an SSH tunnel to 127.0.0.1.
    public static func connect(_ config: ConnectionConfig, password: String?, tlsServerName: String? = nil) async throws -> MySQLDriver {
        var logger = Logger(label: "tabula.mysql")
        logger.logLevel = .error
        let host = config.resolvedHost, port = config.port
        let tls = config.tlsConfiguration()

        do {
            let address = try await config.resolveAddress()
            let user = config.user, database = config.database
            let password = password?.isEmpty == true ? nil : password
            let serverHostname = tlsServerName ?? config.serverName(usingTLS: tls != nil)
            let connection = try await withTimeout(seconds: config.timeout, "Connecting to \(host):\(port)", discard: { _ = $0.close() }) { [logger] in
                try await MySQLConnection.connect(
                    to: address,
                    username: user,
                    database: database,
                    password: password,
                    tlsConfiguration: tls,
                    serverHostname: serverHostname,
                    logger: logger,
                    on: MultiThreadedEventLoopGroup.singleton.next()
                ).get()
            }
            return MySQLDriver(connection: connection, initialDatabase: database)
        } catch MySQLError.secureConnectionRequired {
            throw DatabaseError("The server requires an encrypted connection to authenticate this user (caching_sha2_password). Set TLS to “Required”.")
        } catch {
            throw DatabaseError(Self.describe(error))
        }
    }

    public func close() async {
        try? await connection.close().get()
    }

    static func describe(_ error: any Error) -> String {
        // Our own errors (timeouts, TLS setup) already read well.
        if let database = error as? DatabaseError { return database.message }
        if let mysql = error as? MySQLError {
            if case .server(let packet) = mysql {
                return "\(packet.errorMessage) (\(packet.errorCode.rawValue))"
            }
            return mysql.message
        }
        return String(describing: error)
    }

    public func execute(_ sql: String) async throws -> QueryResult {
        let started = Date()
        do {
            if SQLSplitter.returnsRows(sql) {
                return try await textQuery(sql, started: started)
            }
            // The prepared-statement protocol reports affected rows.
            let affected = AffectedRowsBox()
            do {
                let rows = try await connection.query(sql, onMetadata: { affected.value = Int($0.affectedRows) }).get()
                if !rows.isEmpty {
                    return Self.result(rows, started: started, sql: sql)
                }
                return QueryResult(affectedRows: affected.value, duration: Date().timeIntervalSince(started), statement: sql)
            } catch MySQLError.server(let packet) where packet.errorCode.rawValue == Self.unsupportedPreparedStatement {
                // ER_UNSUPPORTED_PS: statement not allowed as a prepared statement; use the text protocol.
                return try await textQuery(sql, started: started)
            }
        } catch {
            throw DatabaseError(Self.describe(error))
        }
    }

    private func textQuery(_ sql: String, started: Date) async throws -> QueryResult {
        let rows = try await connection.simpleQuery(sql).get()
        return Self.result(rows, started: started, sql: sql)
    }

    private static func result(_ rows: [MySQLRow], started: Date, sql: String) -> QueryResult {
        let definitions = rows.first?.columnDefinitions ?? []
        var result = QueryResult(columns: definitions.map(\.name), rows: rows.map(Self.values),
                                 affectedRows: definitions.isEmpty ? 0 : nil,
                                 duration: Date().timeIntervalSince(started), statement: sql)
        if !definitions.isEmpty {
            result.mysqlOrigins = definitions.map {
                .init(schema: $0.schema, table: $0.table, originalTable: $0.orgTable, originalName: $0.orgName,
                      dataType: UInt32($0.columnType.rawValue), characterSet: UInt32($0.characterSet.rawValue))
            }
        }
        return result
    }

    private static func values(_ row: MySQLRow) -> [String?] {
        zip(row.columnDefinitions, row.values).map { column, buffer in
            guard let buffer else { return nil }
            let data = MySQLData(type: column.columnType, format: row.format, buffer: buffer,
                                 isUnsigned: column.flags.contains(.COLUMN_UNSIGNED))
            if let text = data.string { return text }
            if let double = data.double { return String(double) }
            if let date = data.date { return dateFormatter.string(from: date) }
            var copy = buffer
            return (copy.readBytes(length: copy.readableBytes) ?? []).map { String(format: "%02x", $0) }.joined()
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private func strings(_ sql: String) async throws -> [[String?]] {
        try await execute(sql).rows
    }

    private func records(_ sql: String) async throws -> [Record] {
        try await execute(sql).records
    }

    public func schemas() async throws -> [String] {
        try await strings("SHOW DATABASES").compactMap { $0.first ?? nil }
    }

    public func defaultSchema() async throws -> String {
        if !initialDatabase.isEmpty { return initialDatabase }
        let current = try await strings("SELECT DATABASE()").first?.first ?? nil
        return current ?? ""
    }

    public func tables(in schema: String) async throws -> [TableRef] {
        try await records("""
            SELECT TABLE_NAME, TABLE_TYPE FROM information_schema.TABLES
            WHERE TABLE_SCHEMA = \(dialect.literal(schema)) ORDER BY TABLE_NAME
            """).compactMap { row in
            guard let name = row["TABLE_NAME"] else { return nil }
            return TableRef(schema: schema, name: name, kind: row["TABLE_TYPE"] == "VIEW" ? .view : .table)
        }
    }

    public func columns(of table: TableRef) async throws -> [ColumnInfo] {
        let d = dialect
        return try await records("""
            SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_DEFAULT, COLUMN_KEY, COLUMN_COMMENT
            FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = \(d.literal(table.schema)) AND TABLE_NAME = \(d.literal(table.name))
            ORDER BY ORDINAL_POSITION
            """).map { row in
            ColumnInfo(name: row["COLUMN_NAME"] ?? "", dataType: row["COLUMN_TYPE"] ?? "", isNullable: row["IS_NULLABLE"] == "YES",
                       defaultValue: row["COLUMN_DEFAULT"], isPrimaryKey: row["COLUMN_KEY"] == "PRI",
                       comment: (row["COLUMN_COMMENT"]?.isEmpty ?? true) ? nil : row["COLUMN_COMMENT"])
        }
    }

    public func indexes(of table: TableRef) async throws -> [IndexInfo] {
        let d = dialect
        let rows = try await records("""
            SELECT INDEX_NAME, NON_UNIQUE, COLUMN_NAME FROM information_schema.STATISTICS
            WHERE TABLE_SCHEMA = \(d.literal(table.schema)) AND TABLE_NAME = \(d.literal(table.name))
            ORDER BY INDEX_NAME = 'PRIMARY' DESC, INDEX_NAME, SEQ_IN_INDEX
            """)
        var order: [String] = []
        var byName: [String: IndexInfo] = [:]
        for row in rows {
            guard let name = row["INDEX_NAME"] else { continue }
            if byName[name] == nil {
                order.append(name)
                byName[name] = IndexInfo(name: name, columns: [], isUnique: row["NON_UNIQUE"] == "0", isPrimary: name == "PRIMARY")
            }
            if let column = row["COLUMN_NAME"] { byName[name]?.columns.append(column) }
        }
        return order.compactMap { byName[$0] }
    }
}

/// SNI must be a hostname; TLS libraries reject literal IP addresses.
/// Collects the affected-row count from MySQLNIO's metadata callback.
private final class AffectedRowsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int?
    var value: Int? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
