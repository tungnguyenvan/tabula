import Foundation
import Logging
import PostgresNIO

public actor PostgresDriver: DatabaseDriver {
    public nonisolated let kind: DatabaseKind = .postgres
    public nonisolated let dialect: any QueryDialect = SQLDialect(flavor: .postgres)
    private let connection: PostgresConnection
    private let logger: Logger
    public nonisolated let queryCancellation: QueryCancellationSupport
    private let configuration: PostgresConnection.Configuration
    private let backendPID: Int32
    /// With the PID, identifies this server session (PIDs are reused): backend_start in microseconds.
    private let backendStart: Int64
    private let executionGate = QueryExecutionGate()
    private var activeExecution: UUID?
    private var cancellationTask: Task<QueryCancelOutcome, Never>?
    private var closed = false

    private init(connection: PostgresConnection, logger: Logger, configuration: PostgresConnection.Configuration,
                 backendPID: Int32, backendStart: Int64) {
        self.connection = connection
        self.logger = logger
        self.configuration = configuration
        self.backendPID = backendPID
        self.backendStart = backendStart
        self.queryCancellation = backendPID == 0 ? .afterCurrentStatement : .server
    }

    /// `tlsServerName` overrides the name TLS checks, for connections through an SSH tunnel to 127.0.0.1.
    public static func connect(_ config: ConnectionConfig, password: String?, tlsServerName: String? = nil) async throws -> PostgresDriver {
        var logger = Logger(label: "tabula.postgres")
        logger.logLevel = .error
        let tls: PostgresConnection.Configuration.TLS = try config.tlsConfiguration()
            .map { .require(try NIOSSLContext(configuration: $0)) } ?? .disable
        var configuration = PostgresConnection.Configuration(
            host: config.resolvedHost,
            port: config.port,
            username: config.user,
            password: password?.isEmpty == true ? nil : password,
            database: config.database.isEmpty ? nil : config.database,
            tls: tls
        )
        configuration.options.connectTimeout = .milliseconds(Int64(config.timeout * 1000))
        configuration.options.additionalStartupParameters = [("application_name", Defaults.applicationName)]
        if let tlsServerName { configuration.options.tlsServerName = tlsServerName }
        do {
            let connection = try await withTimeout(seconds: config.timeout, "Connecting to \(config.host):\(config.port)",
                                                   discard: { _ = $0.close() as EventLoopFuture<Void> }) { [configuration, logger] in
                try await PostgresConnection.connect(configuration: configuration, id: 1, logger: logger)
            }
            do {
                let identity = try await connection.query("""
                    SELECT pid::text, (extract(epoch FROM backend_start) * 1000000)::bigint::text
                    FROM pg_catalog.pg_stat_activity WHERE pid = pg_catalog.pg_backend_pid()
                    """).get()
                let row = Self.textRows(identity).first ?? []
                guard row.count == 2, let pid = row[0].flatMap(Int32.init), let started = row[1].flatMap(Int64.init) else {
                    return PostgresDriver(connection: connection, logger: logger, configuration: configuration,
                                          backendPID: 0, backendStart: 0)
                }
                return PostgresDriver(connection: connection, logger: logger, configuration: configuration,
                                      backendPID: pid, backendStart: started)
            } catch {
                // PostgreSQL-compatible servers may not expose pg_stat_activity. Stop is optional; connecting isn't.
                return PostgresDriver(connection: connection, logger: logger, configuration: configuration,
                                      backendPID: 0, backendStart: 0)
            }
        } catch {
            throw DatabaseError(Self.describe(error))
        }
    }

    public func close() async {
        // Closing must not wait for a long statement; closing the socket ends it as before.
        closed = true
        try? await connection.close()
    }

    public func execute(_ sql: String) async throws -> QueryResult {
        let scope = QueryCancelScope.current
        try scope?.checkCancellation()
        await executionGate.acquire()
        defer { executionGate.release() }
        guard !closed else { throw DatabaseError("The database is closed.") }
        try scope?.checkCancellation()
        let id = UUID()
        // The marker is at the beginning so pg_stat_activity's query truncation cannot remove it.
        let marker = "/* tabula-run:\(id.uuidString) */"
        let prefix = marker + "\n"
        let attachment: UUID?
        if let scope {
            guard let token = scope.attach({ [weak self] in
                guard let self else { return .notRunning }
                return await self.cancelExecution(id, marker: marker)
            }) else { throw QueryCancelledError() }
            attachment = token
        } else { attachment = nil }
        activeExecution = id
        let result: Result<QueryResult, any Error>
        do {
            result = .success(try await executeStatement(sql, wireSQL: prefix + sql))
        } catch {
            result = .failure(error)
        }
        // Invalidate before awaiting: a delayed Stop must not acquire this execution's identity.
        activeExecution = nil
        if let attachment { scope?.detach(attachment) }
        // The next query cannot start until every cancellation request has drained. In particular, a
        // pg_cancel_backend signal must never overtake the statement it belonged to.
        if let cancellationTask, await cancellationTask.value == .requested, !closed {
            // pg_cancel_backend delivers a signal, not an acknowledgement from the target backend. A
            // harmless round trip after the control response absorbs a late signal before releasing the
            // connection to unrelated work. In an aborted user transaction it simply fails; no transaction
            // control statements are issued, and the user still owns COMMIT/ROLLBACK.
            _ = try? await connection.query(PostgresQuery(unsafeSQL: "SELECT 1 /* tabula-cancel-drain */"), logger: logger).get()
        }
        cancellationTask = nil
        if case .failure(let error) = result, scope?.isCancelled == true,
           let psql = error as? PSQLError, psql.serverInfo?[.sqlState] == "57014" {
            throw QueryCancelledError(serverInterrupted: true)
        }
        do { return try result.get() }
        catch { throw DatabaseError(Self.describe(error, positionOffset: prefix.count)) }
    }

    private func cancelExecution(_ id: UUID, marker: String) async -> QueryCancelOutcome {
        guard !closed, activeExecution == id else { return .notRunning }
        if let cancellationTask { return await cancellationTask.value }
        let task = Task { await self.sendCancellation(id, marker: marker) }
        cancellationTask = task
        return await task.value
    }

    private func sendCancellation(_ id: UUID, marker: String) async -> QueryCancelOutcome {
        let control: PostgresConnection
        do {
            var controlConfiguration = configuration
            controlConfiguration.options.connectTimeout = .seconds(5)
            control = try await withTimeout(seconds: 5, "Opening PostgreSQL cancellation connection",
                discard: { _ = $0.close() as EventLoopFuture<Void> }) { [controlConfiguration, logger] in
                try await PostgresConnection.connect(configuration: controlConfiguration, id: 2, logger: logger)
            }
        } catch { return .failed(Self.describe(error)) }
        // Run independently of the user's transaction (including an aborted transaction). The backend
        // identity and this execution's unique statement prefix must both match: a PID alone could reach
        // a later statement. Stop can arrive before the server has marked the statement active, so look
        // again briefly while this execution is still the one in progress.
        let sql = """
            SELECT pg_catalog.pg_cancel_backend(pid)::text
            FROM pg_catalog.pg_stat_activity
            WHERE pid = \(backendPID) AND (extract(epoch FROM backend_start) * 1000000)::bigint = \(backendStart)
              AND state = 'active' AND left(query, \(marker.count)) = \(dialect.literal(marker))
            """
        var outcome = QueryCancelOutcome.notRunning
        let deadline = Date().addingTimeInterval(3)
        do {
            while !closed, activeExecution == id {
                let rows = Self.textRows(try await control.query(PostgresQuery(unsafeSQL: sql), logger: logger).get())
                if rows.first?.first == "true" { outcome = .requested; break }
                guard Date() < deadline else {
                    outcome = .failed("The running statement could not be found in pg_stat_activity.")
                    break
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        } catch { outcome = .failed(Self.describe(error)) }
        try? await control.close()
        return outcome
    }

    /// Throws the PostgresNIO error unchanged, so `execute` can still read its SQLSTATE.
    private func executeStatement(_ sql: String, wireSQL: String) async throws -> QueryResult {
        let started = Date()
        if SQLSplitter.returnsRows(sql) {
            let sequence = try await connection.query(PostgresQuery(unsafeSQL: wireSQL), logger: logger)
            let metadata = Array(sequence.columns)
            let columns = metadata.map { (name: $0.name, oid: $0.dataType.rawValue) }
            var rows: [[String?]] = []
            for try await row in sequence {
                var values: [String?] = []
                values.reserveCapacity(columns.count)
                for (cell, column) in zip(row, columns) {
                    values.append(PostgresValueFormatter.string(cell.bytes, oid: column.oid))
                }
                rows.append(values)
            }
            var result = QueryResult(columns: columns.map(\.name), rows: rows, duration: Date().timeIntervalSince(started), statement: sql)
            result.origins = metadata.map { QueryColumnOrigin(tableOID: UInt32(bitPattern: $0.tableOID), attribute: $0.columnAttributeNumber) }
            return result
        }

        // Commands: the legacy API exposes the command tag (affected row count).
        let result = try await connection.query(PostgresQuery(unsafeSQL: wireSQL), logger: logger).get()
        let columns = result.rows.first.map { row in row.map(\.columnName) } ?? []
        let rows = result.rows.map { row in row.map { PostgresValueFormatter.string($0.bytes, oid: $0.dataType.rawValue) } }
        let affected = columns.isEmpty ? result.metadata.rows : nil
        return QueryResult(columns: columns, rows: rows, affectedRows: affected, duration: Date().timeIntervalSince(started), statement: sql)
    }

    private static func textRows(_ result: PostgresQueryResult) -> [[String?]] {
        result.rows.map { row in row.map { PostgresValueFormatter.string($0.bytes, oid: $0.dataType.rawValue) } }
    }

    /// `positionOffset` takes text Tabula prepended to the user's statement out of error positions.
    static func describe(_ error: any Error, positionOffset: Int = 0) -> String {
        // Our own errors (timeouts, TLS setup) already read well.
        if let database = error as? DatabaseError { return database.message }
        if let psql = error as? PSQLError {
            if let message = psql.serverInfo?[.message] {
                var text = message
                if let detail = psql.serverInfo?[.detail] { text += "\n" + detail }
                if let hint = psql.serverInfo?[.hint] { text += "\nHint: " + hint }
                if let position = psql.serverInfo?[.position] {
                    let shown = Int(position).map { String(max(1, $0 - positionOffset)) } ?? position
                    text += "\n(at character \(shown))"
                }
                return text
            }
            if let underlying = psql.underlying { return "\(underlying)" }
            return String(reflecting: psql.code)
        }
        return String(describing: error)
    }

    private func strings(_ sql: String) async throws -> [[String?]] {
        try await execute(sql).rows
    }

    private func records(_ sql: String) async throws -> [Record] {
        try await execute(sql).records
    }

    public func schemas() async throws -> [String] {
        try await strings("""
            SELECT nspname FROM pg_namespace
            WHERE nspname NOT LIKE 'pg\\_%' AND nspname <> 'information_schema'
            ORDER BY nspname
            """).compactMap { $0[0] }
    }

    public func defaultSchema() async throws -> String {
        let current = try await strings("SELECT current_schema()").first?.first ?? nil
        return current ?? "public"
    }

    public func tables(in schema: String) async throws -> [TableRef] {
        let d = dialect
        return try await records("""
            SELECT c.relname AS name, c.relkind AS kind FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = \(d.literal(schema)) AND c.relkind IN ('r','p','v','m','f')
            ORDER BY c.relname
            """).compactMap { row in
            guard let name = row["name"] else { return nil }
            let kind: TableKind = (row["kind"] == "v" || row["kind"] == "m") ? .view : .table
            return TableRef(schema: schema, name: name, kind: kind)
        }
    }

    public func columns(of table: TableRef) async throws -> [ColumnInfo] {
        let d = dialect
        return try await records("""
            SELECT a.attname AS name,
                   format_type(a.atttypid, a.atttypmod) AS data_type,
                   NOT a.attnotnull AS nullable,
                   pg_get_expr(ad.adbin, ad.adrelid) AS default_value,
                   EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid = a.attrelid AND i.indisprimary AND a.attnum = ANY(i.indkey)) AS primary_key,
                   col_description(a.attrelid, a.attnum) AS comment
            FROM pg_attribute a
            LEFT JOIN pg_attrdef ad ON ad.adrelid = a.attrelid AND ad.adnum = a.attnum
            WHERE a.attrelid = \(d.literal(d.qualified(table)))::regclass AND a.attnum > 0 AND NOT a.attisdropped
            ORDER BY a.attnum
            """).map { row in
            ColumnInfo(name: row["name"] ?? "", dataType: row["data_type"] ?? "", isNullable: row["nullable"] == "true",
                       defaultValue: row["default_value"], isPrimaryKey: row["primary_key"] == "true", comment: row["comment"])
        }
    }

    public func indexes(of table: TableRef) async throws -> [IndexInfo] {
        let d = dialect
        return try await records("""
            SELECT ic.relname AS name, i.indisunique AS is_unique, i.indisprimary AS is_primary,
                   pg_get_indexdef(i.indexrelid) AS definition,
                   array_to_string(ARRAY(
                       SELECT pg_get_indexdef(i.indexrelid, k + 1, true)
                       FROM generate_subscripts(i.indkey, 1) AS k ORDER BY k), ', ') AS columns
            FROM pg_index i
            JOIN pg_class ic ON ic.oid = i.indexrelid
            WHERE i.indrelid = \(d.literal(d.qualified(table)))::regclass
            ORDER BY i.indisprimary DESC, ic.relname
            """).map { row in
            IndexInfo(name: row["name"] ?? "", columns: (row["columns"] ?? "").components(separatedBy: ", ").filter { !$0.isEmpty },
                      isUnique: row["is_unique"] == "true", isPrimary: row["is_primary"] == "true", definition: row["definition"])
        }
    }
}
