import Foundation
import Logging
import PostgresNIO

public actor PostgresDriver: DatabaseDriver {
    public nonisolated let kind: DatabaseKind = .postgres
    private let connection: PostgresConnection
    private let logger: Logger

    private init(connection: PostgresConnection, logger: Logger) {
        self.connection = connection
        self.logger = logger
    }

    public static func connect(_ config: ConnectionConfig, password: String?) async throws -> PostgresDriver {
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
        do {
            let connection = try await withTimeout(seconds: config.timeout, "Connecting to \(config.host):\(config.port)",
                                                   discard: { _ = $0.close() as EventLoopFuture<Void> }) { [configuration, logger] in
                try await PostgresConnection.connect(configuration: configuration, id: 1, logger: logger)
            }
            return PostgresDriver(connection: connection, logger: logger)
        } catch {
            throw DatabaseError(Self.describe(error))
        }
    }

    public func close() async {
        try? await connection.close()
    }

    public func execute(_ sql: String) async throws -> QueryResult {
        let started = Date()
        do {
            if SQLSplitter.returnsRows(sql) {
                let sequence = try await connection.query(PostgresQuery(unsafeSQL: sql), logger: logger)
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
            let result = try await connection.query(sql).get()
            let columns = result.rows.first.map { row in row.map(\.columnName) } ?? []
            let rows = result.rows.map { row in row.map { PostgresValueFormatter.string($0.bytes, oid: $0.dataType.rawValue) } }
            let affected = columns.isEmpty ? result.metadata.rows : nil
            return QueryResult(columns: columns, rows: rows, affectedRows: affected, duration: Date().timeIntervalSince(started), statement: sql)
        } catch {
            throw DatabaseError(Self.describe(error))
        }
    }

    static func describe(_ error: any Error) -> String {
        // Our own errors (timeouts, TLS setup) already read well.
        if let database = error as? DatabaseError { return database.message }
        if let psql = error as? PSQLError {
            if let message = psql.serverInfo?[.message] {
                var text = message
                if let detail = psql.serverInfo?[.detail] { text += "\n" + detail }
                if let hint = psql.serverInfo?[.hint] { text += "\nHint: " + hint }
                if let position = psql.serverInfo?[.position] { text += "\n(at character \(position))" }
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
