import Foundation
import Logging
import MySQLNIO
import NIOPosix

public actor MySQLDriver: DatabaseDriver {
    public nonisolated let kind: DatabaseKind = .mysql
    private let connection: MySQLConnection
    private let initialDatabase: String

    private init(connection: MySQLConnection, initialDatabase: String) {
        self.connection = connection
        self.initialDatabase = initialDatabase
    }

    public static func connect(_ config: ConnectionConfig, password: String?) async throws -> MySQLDriver {
        var logger = Logger(label: "tabula.mysql")
        logger.logLevel = .error
        let host = config.host.isEmpty ? "127.0.0.1" : config.host
        let port = config.port

        let tls: TLSConfiguration?
        switch config.tls {
        case .disable:
            tls = nil
        case .require:
            var tlsConfig = TLSConfiguration.makeClientConfiguration()
            tlsConfig.certificateVerification = .none
            tls = tlsConfig
        case .verifyFull:
            tls = .makeClientConfiguration()
        }

        do {
            // Name resolution blocks, so keep it off the caller's executor.
            let address = try await withTimeout(seconds: 15, "Resolving \(host)") {
                try await Task.detached { try SocketAddress.makeAddressResolvingHost(host, port: port) }.value
            }
            let user = config.user, database = config.database
            let password = password?.isEmpty == true ? nil : password
            let serverHostname = tls == nil || isIPAddress(host) ? nil : host
            let connection = try await withTimeout(seconds: 15, "Connecting to \(host):\(port)", discard: { _ = $0.close() }) { [logger] in
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
                if let first = rows.first {
                    return QueryResult(columns: first.columnDefinitions.map(\.name),
                                       rows: rows.map(Self.values),
                                       duration: Date().timeIntervalSince(started), statement: sql)
                }
                return QueryResult(affectedRows: affected.value, duration: Date().timeIntervalSince(started), statement: sql)
            } catch MySQLError.server(let packet) where packet.errorCode.rawValue == 1295 {
                // ER_UNSUPPORTED_PS: statement not allowed as a prepared statement; use the text protocol.
                return try await textQuery(sql, started: started)
            }
        } catch {
            throw DatabaseError(Self.describe(error))
        }
    }

    private func textQuery(_ sql: String, started: Date) async throws -> QueryResult {
        let rows = try await connection.simpleQuery(sql).get()
        let columns = rows.first?.columnDefinitions.map(\.name) ?? []
        return QueryResult(columns: columns, rows: rows.map(Self.values),
                           affectedRows: columns.isEmpty ? 0 : nil,
                           duration: Date().timeIntervalSince(started), statement: sql)
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

    public func schemas() async throws -> [String] {
        try await strings("SHOW DATABASES").compactMap { $0.first ?? nil }
    }

    public func defaultSchema() async throws -> String {
        if !initialDatabase.isEmpty { return initialDatabase }
        let current = try await strings("SELECT DATABASE()").first?.first ?? nil
        return current ?? ""
    }

    public func tables(in schema: String) async throws -> [TableRef] {
        try await strings("""
            SELECT TABLE_NAME, TABLE_TYPE FROM information_schema.TABLES
            WHERE TABLE_SCHEMA = \(dialect.literal(schema)) ORDER BY TABLE_NAME
            """).compactMap { row in
            guard let name = row[0] else { return nil }
            return TableRef(schema: schema, name: name, kind: row[1] == "VIEW" ? .view : .table)
        }
    }

    public func columns(of table: TableRef) async throws -> [ColumnInfo] {
        let d = dialect
        return try await strings("""
            SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_DEFAULT, COLUMN_KEY, COLUMN_COMMENT
            FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = \(d.literal(table.schema)) AND TABLE_NAME = \(d.literal(table.name))
            ORDER BY ORDINAL_POSITION
            """).map { row in
            ColumnInfo(name: row[0] ?? "", dataType: row[1] ?? "", isNullable: row[2] == "YES",
                       defaultValue: row[3], isPrimaryKey: row[4] == "PRI",
                       comment: (row[5]?.isEmpty ?? true) ? nil : row[5])
        }
    }

    public func indexes(of table: TableRef) async throws -> [IndexInfo] {
        let d = dialect
        let rows = try await strings("""
            SELECT INDEX_NAME, NON_UNIQUE, COLUMN_NAME FROM information_schema.STATISTICS
            WHERE TABLE_SCHEMA = \(d.literal(table.schema)) AND TABLE_NAME = \(d.literal(table.name))
            ORDER BY INDEX_NAME = 'PRIMARY' DESC, INDEX_NAME, SEQ_IN_INDEX
            """)
        var order: [String] = []
        var byName: [String: IndexInfo] = [:]
        for row in rows {
            guard let name = row[0] else { continue }
            if byName[name] == nil {
                order.append(name)
                byName[name] = IndexInfo(name: name, columns: [], isUnique: row[1] == "0", isPrimary: name == "PRIMARY")
            }
            if let column = row[2] { byName[name]?.columns.append(column) }
        }
        return order.compactMap { byName[$0] }
    }
}

/// SNI must be a hostname; TLS libraries reject literal IP addresses.
func isIPAddress(_ host: String) -> Bool {
    var v4 = in_addr(), v6 = in6_addr()
    return inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1
}

/// Collects the affected-row count from MySQLNIO's metadata callback.
private final class AffectedRowsBox: @unchecked Sendable {
    var value: Int?
}
