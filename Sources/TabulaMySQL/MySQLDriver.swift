import Foundation
import Logging
import MySQLNIO
import NIOCore
import NIOPosix
import NIOSSL
import TabulaDrivers
import TabulaFoundation
import TabulaSQL

public actor MySQLDriver: DatabaseDriver {
    /// ER_UNSUPPORTED_PS: the statement can't be prepared and must be sent as text.
    static let unsupportedPreparedStatement: UInt16 = 1295

    /// ER_QUERY_INTERRUPTED: KILL QUERY ended the statement.
    static let queryInterrupted: UInt16 = 1317

    public nonisolated let kind: DatabaseKind = .mysql
    public nonisolated let dialect: any QueryDialect = SQLDialect(flavor: .mysql)
    public nonisolated let catalog: any DatabaseCatalog = MySQLCatalog()
    public nonisolated let queryCancellation: QueryCancellationSupport
    private let connection: MySQLConnection
    private let initialDatabase: String
    /// How to open the control connection Stop sends KILL QUERY from.
    private let settings: Settings
    /// The server's id of this connection, nil when it couldn't be read (then Stop isn't offered).
    private let connectionID: UInt64?
    private let executionGate = QueryExecutionGate()
    private var activeExecution: UUID?
    private var cancellationTask: Task<QueryCancelOutcome, Never>?
    private var closed = false

    /// What a connection to the same server, as the same user, needs.
    private struct Settings: Sendable {
        let address: SocketAddress
        let user: String
        let database: String
        let password: String?
        let tls: TLSConfiguration?
        let serverHostname: String?
        let logger: Logger

        func connect(timeout: TimeInterval, describing what: String) async throws -> MySQLConnection {
            try await withTimeout(seconds: timeout, what, discard: { _ = $0.close() }) {
                try await MySQLConnection.connect(
                    to: address,
                    username: user,
                    database: database,
                    password: password,
                    tlsConfiguration: tls,
                    serverHostname: serverHostname,
                    logger: logger,
                    on: MultiThreadedEventLoopGroup.singleton.next()
                )
                .get()
            }
        }
    }

    private init(connection: MySQLConnection, initialDatabase: String, settings: Settings, connectionID: UInt64?) {
        self.connection = connection
        self.initialDatabase = initialDatabase
        self.settings = settings
        self.connectionID = connectionID
        self.queryCancellation = connectionID == nil ? .afterCurrentStatement : .server
    }

    /// `tlsServerName` overrides the name TLS checks, for connections through an SSH tunnel to 127.0.0.1.
    public static func connect(
        _ config: ConnectionConfig,
        password: String?,
        tlsServerName: String? = nil
    ) async throws -> MySQLDriver {
        var logger = Logger(label: "tabula.mysql")
        logger.logLevel = .error
        let host = config.resolvedHost
        let port = config.port
        let tls = config.tlsConfiguration()

        do {
            let settings = Settings(
                address: try await config.resolveAddress(),
                user: config.user,
                database: config.database,
                password: password?.isEmpty == true ? nil : password,
                tls: tls,
                serverHostname: tlsServerName ?? config.serverName(usingTLS: tls != nil),
                logger: logger
            )
            let connection = try await settings.connect(
                timeout: config.timeout,
                describing: "Connecting to \(host):\(port)"
            )
            // Without its id Stop can't find the statement; the connection works as before without Stop.
            let id = try? await connection.simpleQuery("SELECT CONNECTION_ID()").get().first
                .flatMap {
                    Self.values($0).first ?? nil
                }
            return MySQLDriver(
                connection: connection,
                initialDatabase: config.database,
                settings: settings,
                connectionID: id.flatMap(UInt64.init)
            )
        } catch MySQLError.secureConnectionRequired {
            throw DatabaseError(
                "The server requires an encrypted connection to authenticate this user (caching_sha2_password). Set TLS to “Required”."
            )
        } catch {
            throw DatabaseError(Self.describe(error))
        }
    }

    public func close() async {
        closed = true
        try? await connection.close().get()
    }

    static func describe(_ error: any Error) -> String {
        // Our own errors (timeouts, TLS setup) already read well.
        if let database = error as? DatabaseError {
            return database.message
        }
        if let mysql = error as? MySQLError {
            if case .server(let packet) = mysql {
                return "\(packet.errorMessage) (\(packet.errorCode.rawValue))"
            }
            return mysql.message
        }
        return String(describing: error)
    }

    public func execute(_ sql: String) async throws -> QueryResult {
        let scope = QueryCancelScope.current
        try scope?.checkCancellation()
        await executionGate.acquire()
        defer { executionGate.release() }
        try scope?.checkCancellation()
        guard let scope, connectionID != nil else {
            do { return try await perform(sql, wireSQL: sql) } catch { throw DatabaseError(Self.describe(error)) }
        }
        let id = UUID()
        // At the start, on the same line, so PROCESSLIST shows it and error line numbers stay the user's.
        let marker = "/* tabula-run:\(id.uuidString) */"
        let token = scope.attach { [weak self] in
            guard let self else {
                return .notRunning
            }
            return await self.cancelExecution(id, marker: marker)
        }
        guard let token else {
            throw QueryCancelledError()
        }
        activeExecution = id
        let result: Result<QueryResult, any Error>
        do {
            result = .success(try await perform(sql, wireSQL: marker + " " + sql))
        } catch {
            result = .failure(error)
        }
        // Invalidate before awaiting: a delayed Stop must not take this execution for a later one.
        activeExecution = nil
        scope.detach(token)
        // KILL QUERY may land after the statement ended; a harmless statement takes it before the next query
        // can, since that waits for the gate.
        if let cancellationTask, await cancellationTask.value == .requested, !closed {
            _ = try? await connection.simpleQuery("DO 0 /* tabula-cancel-drain */").get()
        }
        cancellationTask = nil
        guard case .failure(let error) = result else {
            return try result.get()
        }
        if scope.isCancelled, case MySQLError.server(let packet) = error,
            packet.errorCode.rawValue == Self.queryInterrupted
        {
            throw QueryCancelledError(serverInterrupted: true)
        }
        throw DatabaseError(Self.describe(error))
    }

    private func cancelExecution(_ id: UUID, marker: String) async -> QueryCancelOutcome {
        guard !closed, activeExecution == id else {
            return .notRunning
        }
        if let cancellationTask {
            return await cancellationTask.value
        }
        let task = Task { await self.sendCancellation(id, marker: marker) }
        cancellationTask = task
        return await task.value
    }

    /// Finds this execution's statement by connection id and marker, then sends KILL QUERY from a connection
    /// of its own. Stop can arrive before the server lists the statement, so it looks again for a moment.
    private func sendCancellation(_ id: UUID, marker: String) async -> QueryCancelOutcome {
        guard let connectionID else {
            return .unsupported
        }
        let control: MySQLConnection
        do {
            control = try await settings.connect(
                timeout: 5,
                describing: "Opening the MySQL connection that stops queries"
            )
        } catch {
            return .failed(Self.describe(error))
        }
        let find = """
            SELECT ID FROM information_schema.PROCESSLIST
            WHERE ID = \(connectionID) AND LEFT(INFO, \(marker.count)) = \(dialect.literal(marker))
            """
        var outcome = QueryCancelOutcome.notRunning
        let deadline = Date().addingTimeInterval(3)
        do {
            while !closed, activeExecution == id {
                if try await !control.simpleQuery(find).get().isEmpty {
                    _ = try await control.simpleQuery("KILL QUERY \(connectionID)").get()
                    outcome = .requested
                    break
                }
                guard Date() < deadline else {
                    outcome = .failed("The running statement could not be found in the process list.")
                    break
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        } catch {
            outcome = .failed(Self.describe(error))
        }
        try? await control.close().get()
        return outcome
    }

    /// Runs `wireSQL`, the statement as sent (with a marker), reporting `sql`. Throws MySQLNIO's error unchanged,
    /// so `execute` can still read its code.
    private func perform(_ sql: String, wireSQL: String) async throws -> QueryResult {
        let started = Date()
        if SQLSplitter.returnsRows(sql) {
            return try await textQuery(wireSQL, sql: sql, started: started)
        }
        // The prepared-statement protocol reports affected rows.
        let affected = AffectedRowsBox()
        do {
            let rows = try await connection.query(wireSQL, onMetadata: { affected.value = Int($0.affectedRows) })
                .get()
            if let first = rows.first {
                return Self.result(columns: first.columnDefinitions, rows: rows, started: started, sql: sql)
            }
            return QueryResult(
                affectedRows: affected.value,
                duration: Date().timeIntervalSince(started),
                statement: sql
            )
        } catch MySQLError.server(let packet) where packet.errorCode.rawValue == Self.unsupportedPreparedStatement {
            // ER_UNSUPPORTED_PS: statement not allowed as a prepared statement; use the text protocol.
            return try await textQuery(wireSQL, sql: sql, started: started)
        }
    }

    /// Keeps the result's columns when it has no rows, so an empty SELECT still shows its header.
    private func textQuery(_ wireSQL: String, sql: String, started: Date) async throws -> QueryResult {
        let query = MySQLTextQuery(sql: wireSQL)
        try await connection.send(query, logger: connection.logger).get()
        return Self.result(columns: query.columns, rows: query.rows, started: started, sql: sql)
    }

    private static func result(
        columns definitions: [MySQLProtocol.ColumnDefinition41],
        rows: [MySQLRow],
        started: Date,
        sql: String
    ) -> QueryResult {
        var result = QueryResult(
            columns: definitions.map(\.name),
            rows: rows.map(Self.values),
            affectedRows: definitions.isEmpty ? 0 : nil,
            duration: Date().timeIntervalSince(started),
            statement: sql
        )
        if !definitions.isEmpty {
            result.mysqlOrigins = definitions.map {
                .init(
                    schema: $0.schema,
                    table: $0.table,
                    originalTable: $0.orgTable,
                    originalName: $0.orgName,
                    dataType: UInt32($0.columnType.rawValue),
                    characterSet: UInt32($0.characterSet.rawValue)
                )
            }
        }
        return result
    }

    private static func values(_ row: MySQLRow) -> [String?] {
        zip(row.columnDefinitions, row.values)
            .map { column, buffer in
                guard let buffer else { return nil }
                let data = MySQLData(
                    type: column.columnType,
                    format: row.format,
                    buffer: buffer,
                    isUnsigned: column.flags.contains(.COLUMN_UNSIGNED)
                )
                if let text = data.string {
                    return text
                }
                if let double = data.double {
                    return String(double)
                }
                if let date = data.date {
                    return dateFormatter.string(from: date)
                }
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
        if !initialDatabase.isEmpty {
            return initialDatabase
        }
        let current = try await strings("SELECT DATABASE()").first?.first ?? nil
        return current ?? ""
    }

    public func tables(in schema: String) async throws -> [TableRef] {
        try await records(
            """
            SELECT TABLE_NAME, TABLE_TYPE FROM information_schema.TABLES
            WHERE TABLE_SCHEMA = \(dialect.literal(schema)) ORDER BY TABLE_NAME
            """
        )
        .compactMap { row in
            guard let name = row["TABLE_NAME"] else { return nil }
            return TableRef(schema: schema, name: name, kind: row["TABLE_TYPE"] == "VIEW" ? .view : .table)
        }
    }

    public func columns(of table: TableRef) async throws -> [ColumnInfo] {
        let d = dialect
        return try await records(
            """
            SELECT COLUMN_NAME, COLUMN_TYPE, IS_NULLABLE, COLUMN_DEFAULT, COLUMN_KEY, COLUMN_COMMENT
            FROM information_schema.COLUMNS
            WHERE TABLE_SCHEMA = \(d.literal(table.schema)) AND TABLE_NAME = \(d.literal(table.name))
            ORDER BY ORDINAL_POSITION
            """
        )
        .map { row in
            ColumnInfo(
                name: row["COLUMN_NAME"] ?? "",
                dataType: row["COLUMN_TYPE"] ?? "",
                isNullable: row["IS_NULLABLE"] == "YES",
                defaultValue: row["COLUMN_DEFAULT"],
                isPrimaryKey: row["COLUMN_KEY"] == "PRI",
                comment: (row["COLUMN_COMMENT"]?.isEmpty ?? true) ? nil : row["COLUMN_COMMENT"]
            )
        }
    }

    public func indexes(of table: TableRef) async throws -> [IndexInfo] {
        let d = dialect
        let rows = try await records(
            """
            SELECT INDEX_NAME, NON_UNIQUE, COLUMN_NAME FROM information_schema.STATISTICS
            WHERE TABLE_SCHEMA = \(d.literal(table.schema)) AND TABLE_NAME = \(d.literal(table.name))
            ORDER BY INDEX_NAME = 'PRIMARY' DESC, INDEX_NAME, SEQ_IN_INDEX
            """
        )
        var order: [String] = []
        var byName: [String: IndexInfo] = [:]
        for row in rows {
            guard let name = row["INDEX_NAME"] else { continue }
            if byName[name] == nil {
                order.append(name)
                byName[name] = IndexInfo(
                    name: name,
                    columns: [],
                    isUnique: row["NON_UNIQUE"] == "0",
                    isPrimary: name == "PRIMARY"
                )
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
