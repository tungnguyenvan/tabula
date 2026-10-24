import Foundation

public struct ForeignKeyInfo: Hashable, Sendable, Identifiable {
    public var name: String
    public var table: TableRef
    public var columns: [String]
    public var referencedTable: TableRef
    /// Empty when SQLite points at the referenced table's primary key implicitly.
    public var referencedColumns: [String]
    public var id: String { "\(table.id).\(name)" }

    public init(name: String, table: TableRef, columns: [String], referencedTable: TableRef, referencedColumns: [String]) {
        self.name = name
        self.table = table
        self.columns = columns
        self.referencedTable = referencedTable
        self.referencedColumns = referencedColumns
    }
}

/// One refresh of server statistics.
public struct MetricsSample: Sendable {
    public struct Item: Sendable, Hashable {
        public var label: String
        public var value: String
        public init(_ label: String, _ value: String) { self.label = label; self.value = value }
    }

    public struct Group: Sendable, Identifiable {
        public var title: String
        public var items: [Item]
        public var id: String { title }
        public init(_ title: String, _ items: [Item]) { self.title = title; self.items = items.filter { !$0.value.isEmpty } }
    }

    public struct TableStat: Sendable, Identifiable, Hashable {
        public var name: String
        public var rows: Int?
        public var dataBytes: Int?
        public var indexBytes: Int?
        public var id: String { name }
        public var totalBytes: Int? { dataBytes.map { $0 + (indexBytes ?? 0) } }
    }

    public var time: Date
    public var groups: [Group]
    /// Cumulative counters (transactions, commands…); rates come from the difference between samples.
    public var counters: [String: Double]
    /// Point-in-time values worth charting (connections, memory…).
    public var gauges: [String: Double]
    public var tables: [TableStat]

    public init(time: Date = Date(), groups: [Group], counters: [String: Double] = [:], gauges: [String: Double] = [:], tables: [TableStat] = []) {
        self.time = time
        self.groups = groups
        self.counters = counters
        self.gauges = gauges
        self.tables = tables
    }
}

enum Units {
    static let kibibyte: Double = 1024
    static let mebibyte: Double = 1024 * 1024
    static let secondsPerMinute = 60
    static let secondsPerHour = 60 * 60
    static let secondsPerDay = 24 * 60 * 60
}

extension MetricsSample.TableStat {
    /// From a row with name, row_count, data_bytes and index_bytes columns.
    init(_ row: Record) {
        self.init(name: row["name"] ?? "", rows: row.int("row_count"), dataBytes: row.int("data_bytes"), indexBytes: row.int("index_bytes"))
    }
}

public enum MetricFormat {
    public static func bytes(_ value: Double?) -> String {
        guard let value else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }

    public static func duration(seconds: Double?) -> String {
        guard var seconds = seconds.map({ Int($0) }) else { return "" }
        let days = seconds / Units.secondsPerDay; seconds %= Units.secondsPerDay
        let hours = seconds / Units.secondsPerHour; seconds %= Units.secondsPerHour
        let minutes = seconds / Units.secondsPerMinute
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m \(seconds % Units.secondsPerMinute)s"
    }

    public static func percent(_ part: Double, of total: Double) -> String {
        guard total > 0 else { return "—" }
        return (part / total).formatted(.percent.precision(.fractionLength(1)))
    }

    public static func number(_ value: Double?) -> String {
        guard let value else { return "" }
        return value.formatted(.number.precision(.fractionLength(0)))
    }
}

extension DatabaseDriver {
    // MARK: Foreign keys

    public func foreignKeys(in schema: String) async throws -> [ForeignKeyInfo] {
        let d = dialect
        switch kind {
        case .postgres:
            // Column lists are joined with the unit separator, which can't appear in identifiers in practice.
            let separator = "\u{1F}"
            let rows = try await execute("""
                SELECT con.conname AS name, cl.relname AS table_name, tn.nspname AS ref_schema, tcl.relname AS ref_table,
                  array_to_string(ARRAY(SELECT a.attname FROM unnest(con.conkey) WITH ORDINALITY AS k(num, ord)
                    JOIN pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = k.num ORDER BY k.ord), \(d.literal(separator))) AS columns,
                  array_to_string(ARRAY(SELECT a.attname FROM unnest(con.confkey) WITH ORDINALITY AS k(num, ord)
                    JOIN pg_attribute a ON a.attrelid = con.confrelid AND a.attnum = k.num ORDER BY k.ord), \(d.literal(separator))) AS ref_columns
                FROM pg_constraint con
                JOIN pg_class cl ON cl.oid = con.conrelid
                JOIN pg_namespace n ON n.oid = cl.relnamespace
                JOIN pg_class tcl ON tcl.oid = con.confrelid
                JOIN pg_namespace tn ON tn.oid = tcl.relnamespace
                WHERE con.contype = 'f' AND n.nspname = \(d.literal(schema))
                ORDER BY cl.relname, con.conname
                """).records
            return rows.map { row in
                ForeignKeyInfo(name: row["name"] ?? "", table: TableRef(schema: schema, name: row["table_name"] ?? ""),
                               columns: (row["columns"] ?? "").components(separatedBy: separator),
                               referencedTable: TableRef(schema: row["ref_schema"] ?? schema, name: row["ref_table"] ?? ""),
                               referencedColumns: (row["ref_columns"] ?? "").components(separatedBy: separator))
            }
        case .mysql:
            let rows = try await execute("""
                SELECT CONSTRAINT_NAME, TABLE_NAME, COLUMN_NAME, REFERENCED_TABLE_SCHEMA, REFERENCED_TABLE_NAME, REFERENCED_COLUMN_NAME
                FROM information_schema.KEY_COLUMN_USAGE
                WHERE TABLE_SCHEMA = \(d.literal(schema)) AND REFERENCED_TABLE_NAME IS NOT NULL
                ORDER BY TABLE_NAME, CONSTRAINT_NAME, ORDINAL_POSITION
                """).records
            var keys: [ForeignKeyInfo] = []
            for row in rows {
                let name = row["CONSTRAINT_NAME"] ?? "", table = row["TABLE_NAME"] ?? ""
                let column = row["COLUMN_NAME"] ?? "", referenced = row["REFERENCED_COLUMN_NAME"] ?? ""
                if let last = keys.last, last.name == name, last.table.name == table {
                    keys[keys.count - 1].columns.append(column)
                    keys[keys.count - 1].referencedColumns.append(referenced)
                } else {
                    keys.append(ForeignKeyInfo(name: name, table: TableRef(schema: schema, name: table), columns: [column],
                                               referencedTable: TableRef(schema: row["REFERENCED_TABLE_SCHEMA"] ?? schema,
                                                                         name: row["REFERENCED_TABLE_NAME"] ?? ""),
                                               referencedColumns: [referenced]))
                }
            }
            return keys
        case .sqlite:
            var keys: [ForeignKeyInfo] = []
            for table in try await tables(in: schema) where table.kind == .table {
                let rows = try await execute("PRAGMA \(d.quoteIdentifier(schema)).foreign_key_list(\(d.literal(table.name)))").records
                var byID: [String: ForeignKeyInfo] = [:]
                var order: [String] = []
                for row in rows {
                    let id = row["id"] ?? ""
                    if byID[id] == nil {
                        order.append(id)
                        byID[id] = ForeignKeyInfo(name: "fk_\(table.name)_\(id)", table: table, columns: [],
                                                  referencedTable: TableRef(schema: schema, name: row["table"] ?? ""), referencedColumns: [])
                    }
                    byID[id]?.columns.append(row["from"] ?? "")
                    // "to" is NULL when the key references the other table's primary key implicitly.
                    if let to = row["to"] { byID[id]?.referencedColumns.append(to) }
                }
                keys += order.compactMap { byID[$0] }
            }
            return keys
        case .redis:
            return []
        }
    }

    // MARK: Metrics

    public func metrics(schema: String) async throws -> MetricsSample {
        switch kind {
        case .postgres: return try await postgresMetrics()
        case .mysql: return try await mysqlMetrics(schema: schema)
        case .sqlite: return try await sqliteMetrics(schema: schema)
        case .redis: throw DatabaseError("Use RedisDriver.metrics() for Redis.")
        }
    }

    private func value(_ sql: String) async throws -> String? {
        try await execute(sql).rows.first?.first ?? nil
    }

    private func postgresMetrics() async throws -> MetricsSample {
        guard let overview = try await execute("""
            SELECT current_database() AS database, version() AS version,
                   EXTRACT(EPOCH FROM now() - pg_postmaster_start_time()) AS uptime,
                   pg_database_size(current_database()) AS size, current_setting('max_connections') AS max_connections,
                   (SELECT count(*) FROM pg_stat_activity) AS connections,
                   (SELECT count(*) FROM pg_stat_activity WHERE state = 'active') AS active,
                   (SELECT count(*) FROM pg_stat_activity WHERE state LIKE 'idle in transaction%') AS idle_in_transaction,
                   (SELECT COALESCE(EXTRACT(EPOCH FROM max(now() - query_start)), 0) FROM pg_stat_activity
                     WHERE state = 'active' AND pid <> pg_backend_pid()) AS longest_query,
                   (SELECT count(*) FROM pg_locks WHERE NOT granted) AS waiting_locks
            """).records.first,
            let stats = try await execute("""
            SELECT xact_commit, xact_rollback, blks_read, blks_hit, tup_returned, tup_fetched, tup_inserted, tup_updated,
                   tup_deleted, deadlocks, temp_bytes
            FROM pg_stat_database WHERE datname = current_database()
            """).records.first else { throw DatabaseError("The server returned no statistics.") }
        let reads = stats.number("blks_read"), hits = stats.number("blks_hit")
        let connections = overview.number("connections"), maxConnections = overview.number("max_connections")
        let inserted = stats.number("tup_inserted"), updated = stats.number("tup_updated"), deleted = stats.number("tup_deleted")

        let tables = try await execute("""
            SELECT s.schemaname || '.' || s.relname AS name, s.n_live_tup AS row_count,
                   pg_table_size(s.relid) AS data_bytes, pg_indexes_size(s.relid) AS index_bytes
            FROM pg_stat_user_tables s ORDER BY pg_total_relation_size(s.relid) DESC LIMIT \(Defaults.Metrics.tableLimit)
            """).records.map(MetricsSample.TableStat.init)

        return MetricsSample(
            groups: [
                .init("Server", [
                    .init("Version", overview["version"]?.components(separatedBy: " on ").first ?? ""),
                    .init("Uptime", MetricFormat.duration(seconds: overview.number("uptime"))),
                    .init("Database", overview["database"] ?? ""),
                    .init("Database size", MetricFormat.bytes(overview.number("size"))),
                ]),
                .init("Connections", [
                    .init("Open", "\(Int(connections)) of \(Int(maxConnections))"),
                    .init("Active", MetricFormat.number(overview.number("active"))),
                    .init("Idle in transaction", MetricFormat.number(overview.number("idle_in_transaction"))),
                    .init("Longest running query", MetricFormat.duration(seconds: overview.number("longest_query"))),
                    .init("Waiting for locks", MetricFormat.number(overview.number("waiting_locks"))),
                ]),
                .init("Activity (since stats reset)", [
                    .init("Cache hit ratio", MetricFormat.percent(hits, of: hits + reads)),
                    .init("Commits", MetricFormat.number(stats.number("xact_commit"))),
                    .init("Rollbacks", MetricFormat.number(stats.number("xact_rollback"))),
                    .init("Rows inserted / updated / deleted",
                          [inserted, updated, deleted].map { MetricFormat.number($0) }.joined(separator: " / ")),
                    .init("Deadlocks", MetricFormat.number(stats.number("deadlocks"))),
                    .init("Temp files written", MetricFormat.bytes(stats.number("temp_bytes"))),
                ]),
            ],
            counters: ["Transactions/s": stats.number("xact_commit") + stats.number("xact_rollback"),
                       "Rows read/s": stats.number("tup_returned") + stats.number("tup_fetched"),
                       "Rows written/s": inserted + updated + deleted],
            gauges: ["Connections": connections, "Active queries": overview.number("active")],
            tables: tables)
    }

    private func mysqlMetrics(schema: String) async throws -> MetricsSample {
        var status: [String: Double] = [:]
        for row in try await execute("SHOW GLOBAL STATUS").records {
            if let name = row["Variable_name"], let value = row["Value"].flatMap(Double.init) { status[name] = value }
        }
        var variables: [String: String] = [:]
        for row in try await execute("SHOW GLOBAL VARIABLES WHERE Variable_name IN ('max_connections', 'version', 'version_comment', 'innodb_buffer_pool_size')").records {
            if let name = row["Variable_name"] { variables[name] = row["Value"] ?? "" }
        }
        let s = { (name: String) in status[name] ?? 0 }
        let size = try await value("SELECT SUM(DATA_LENGTH + INDEX_LENGTH) FROM information_schema.TABLES WHERE TABLE_SCHEMA = \(dialect.literal(schema))")
        let requests = s("Innodb_buffer_pool_read_requests"), diskReads = s("Innodb_buffer_pool_reads")

        let tables = try await execute("""
            SELECT TABLE_NAME AS name, TABLE_ROWS AS row_count, DATA_LENGTH AS data_bytes, INDEX_LENGTH AS index_bytes
            FROM information_schema.TABLES
            WHERE TABLE_SCHEMA = \(dialect.literal(schema)) AND TABLE_TYPE = 'BASE TABLE'
            ORDER BY DATA_LENGTH + INDEX_LENGTH DESC LIMIT \(Defaults.Metrics.tableLimit)
            """).records.map(MetricsSample.TableStat.init)

        return MetricsSample(
            groups: [
                .init("Server", [
                    .init("Version", "\(variables["version"] ?? "") \(variables["version_comment"] ?? "")".trimmingCharacters(in: .whitespaces)),
                    .init("Uptime", MetricFormat.duration(seconds: s("Uptime"))),
                    .init("Database", schema),
                    .init("Database size", MetricFormat.bytes(size.flatMap(Double.init))),
                    .init("Buffer pool", MetricFormat.bytes(variables["innodb_buffer_pool_size"].flatMap(Double.init))),
                ]),
                .init("Connections", [
                    .init("Open", "\(Int(s("Threads_connected"))) of \(variables["max_connections"] ?? "?")"),
                    .init("Running", MetricFormat.number(s("Threads_running"))),
                    .init("Max used", MetricFormat.number(s("Max_used_connections"))),
                    .init("Aborted connects", MetricFormat.number(s("Aborted_connects"))),
                ]),
                .init("Activity (since start)", [
                    .init("Buffer pool hit ratio", MetricFormat.percent(requests - diskReads, of: requests)),
                    .init("Queries", MetricFormat.number(s("Questions"))),
                    .init("Selects / inserts / updates / deletes",
                          [s("Com_select"), s("Com_insert"), s("Com_update"), s("Com_delete")].map { MetricFormat.number($0) }.joined(separator: " / ")),
                    .init("Slow queries", MetricFormat.number(s("Slow_queries"))),
                    .init("Received / sent", "\(MetricFormat.bytes(s("Bytes_received"))) / \(MetricFormat.bytes(s("Bytes_sent")))"),
                ]),
            ],
            counters: ["Queries/s": s("Questions"), "Writes/s": s("Com_insert") + s("Com_update") + s("Com_delete"),
                       "Network in KB/s": s("Bytes_received") / Units.kibibyte, "Network out KB/s": s("Bytes_sent") / Units.kibibyte],
            gauges: ["Connections": s("Threads_connected"), "Running threads": s("Threads_running")],
            tables: tables)
    }

    private func sqliteMetrics(schema: String) async throws -> MetricsSample {
        let d = dialect
        let pragma = { (name: String) async throws -> Double in
            Double(try await self.value("PRAGMA \(d.quoteIdentifier(schema)).\(name)") ?? "") ?? 0
        }
        let pageSize = try await pragma("page_size"), pageCount = try await pragma("page_count"), free = try await pragma("freelist_count")
        let journal = try await value("PRAGMA \(d.quoteIdentifier(schema)).journal_mode") ?? ""
        let version = try await value("SELECT sqlite_version()") ?? ""
        var tables: [MetricsSample.TableStat] = []
        for table in try await self.tables(in: schema).filter({ $0.kind == .table }).prefix(Defaults.Metrics.tableLimit) {
            let rows = try await value("SELECT COUNT(*) FROM \(d.qualified(table))").flatMap { Int($0) }
            tables.append(.init(name: table.name, rows: rows, dataBytes: nil, indexBytes: nil))
        }
        // Per-table sizes need the optional dbstat virtual table.
        let sizeQuery = "SELECT name, SUM(pgsize) AS size FROM dbstat(\(d.literal(schema))) WHERE aggregate = TRUE GROUP BY name"
        if let sizes = try? await execute(sizeQuery).records {
            let byName = Dictionary(sizes.compactMap { row in row["name"].map { ($0, row.int("size") ?? 0) } }, uniquingKeysWith: +)
            for index in tables.indices { tables[index].dataBytes = byName[tables[index].name] }
        }
        tables.sort { ($0.rows ?? 0) > ($1.rows ?? 0) }
        return MetricsSample(
            groups: [
                .init("Database", [
                    .init("SQLite", version),
                    .init("File size", MetricFormat.bytes(pageSize * pageCount)),
                    .init("Free pages", "\(MetricFormat.number(free)) (\(MetricFormat.bytes(free * pageSize)))"),
                    .init("Page size", MetricFormat.bytes(pageSize)),
                    .init("Journal mode", journal.uppercased()),
                    .init("Tables", "\(tables.count)"),
                ]),
            ],
            tables: tables)
    }
}

extension RedisDriver {
    /// Parses INFO into a sample: memory, clients, throughput, hit rate, persistence, replication, keyspace.
    public func metrics() async throws -> MetricsSample {
        let text = try await run([.text("INFO"), .text("everything")]).string ?? ""
        var info: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 { info[String(parts[0])] = String(parts[1]) }
        }
        let n = { (key: String) in Double(info[key] ?? "") ?? 0 }
        let hits = n("keyspace_hits"), misses = n("keyspace_misses")
        let maxMemory = n("maxmemory")
        let keyspace = info.keys.filter { $0.hasPrefix("db") && Int($0.dropFirst(2)) != nil }
            .sorted { Int($0.dropFirst(2))! < Int($1.dropFirst(2))! }
            .map { MetricsSample.Item($0, info[$0]?.replacingOccurrences(of: ",", with: ", ") ?? "") }
        return MetricsSample(
            groups: [
                .init("Server", [
                    .init("Version", info["redis_version"].map { "Redis " + $0 } ?? ""),
                    .init("Mode", info["redis_mode"] ?? ""),
                    .init("Role", info["role"] ?? ""),
                    .init("Uptime", MetricFormat.duration(seconds: n("uptime_in_seconds"))),
                    .init("OS", info["os"] ?? ""),
                ]),
                .init("Memory", [
                    .init("Used", info["used_memory_human"] ?? ""),
                    .init("Peak", info["used_memory_peak_human"] ?? ""),
                    .init("Limit", maxMemory > 0 ? "\(MetricFormat.bytes(maxMemory)) (\(info["maxmemory_policy"] ?? ""))" : "none"),
                    .init("Fragmentation ratio", info["mem_fragmentation_ratio"] ?? ""),
                    .init("Evicted keys", MetricFormat.number(n("evicted_keys"))),
                ]),
                .init("Clients & throughput", [
                    .init("Connected clients", MetricFormat.number(n("connected_clients"))),
                    .init("Blocked clients", MetricFormat.number(n("blocked_clients"))),
                    .init("Ops/s (server)", MetricFormat.number(n("instantaneous_ops_per_sec"))),
                    .init("Hit rate", MetricFormat.percent(hits, of: hits + misses)),
                    .init("Commands processed", MetricFormat.number(n("total_commands_processed"))),
                    .init("Expired keys", MetricFormat.number(n("expired_keys"))),
                ]),
                .init("Persistence & replication", [
                    .init("Last RDB save", n("rdb_last_save_time") > 0
                          ? Date(timeIntervalSince1970: n("rdb_last_save_time")).formatted(date: .abbreviated, time: .shortened) : ""),
                    .init("Changes since save", MetricFormat.number(n("rdb_changes_since_last_save"))),
                    .init("AOF", info["aof_enabled"] == "1" ? "on" : "off"),
                    .init("Replicas", MetricFormat.number(n("connected_slaves"))),
                ]),
                .init("Keyspace", keyspace.isEmpty ? [.init("Keys", "none")] : keyspace),
            ],
            counters: ["Commands/s": n("total_commands_processed"), "Network in KB/s": n("total_net_input_bytes") / Units.kibibyte,
                       "Network out KB/s": n("total_net_output_bytes") / Units.kibibyte],
            gauges: ["Memory MB": n("used_memory") / Units.mebibyte, "Clients": n("connected_clients")])
    }
}
