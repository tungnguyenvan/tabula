import Foundation

/// PostgreSQL's catalog: pg_catalog and the statistics views.
struct PostgresCatalog: DatabaseCatalog, RoutineCatalog {
    private let d = SQLDialect(flavor: .postgres)

    var routines: (any RoutineCatalog)? { self }

    func serverVersion(on driver: any DatabaseDriver) async throws -> String {
        guard let version = try await driver.value("SELECT version()") else { throw DatabaseError("The server didn't report its version.") }
        return version
    }

    /// Keeps public on the path for extensions and shared tables.
    func useSchema(_ schema: String, on driver: any DatabaseDriver) async throws {
        let path = schema == "public" ? [schema] : [schema, "public"]
        _ = try await driver.execute("SET search_path TO " + path.map(d.quoteIdentifier).joined(separator: ", "))
    }

    func serverDatabases(on driver: any DatabaseDriver) async throws -> [String] {
        try await driver.execute("""
            SELECT datname FROM pg_database
            WHERE datallowconn AND NOT datistemplate AND has_database_privilege(datname, 'CONNECT')
            ORDER BY datname
            """).rows.compactMap { $0.first ?? nil }
    }

    func currentDatabase(on driver: any DatabaseDriver) async throws -> String? {
        try await driver.value("SELECT current_database()")
    }

    func foreignKeys(in schema: String, on driver: any DatabaseDriver) async throws -> [ForeignKeyInfo] {
        // Column lists are joined with the unit separator, which can't appear in identifiers in practice.
        let separator = "\u{1F}"
        return try await driver.execute("""
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
            """).records.map { row in
            ForeignKeyInfo(name: row["name"] ?? "", table: TableRef(schema: schema, name: row["table_name"] ?? ""),
                           columns: (row["columns"] ?? "").components(separatedBy: separator),
                           referencedTable: TableRef(schema: row["ref_schema"] ?? schema, name: row["ref_table"] ?? ""),
                           referencedColumns: (row["ref_columns"] ?? "").components(separatedBy: separator))
        }
    }

    func metrics(schema: String, on driver: any DatabaseDriver) async throws -> MetricsSample {
        guard let overview = try await driver.execute("""
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
            let stats = try await driver.execute("""
            SELECT xact_commit, xact_rollback, blks_read, blks_hit, tup_returned, tup_fetched, tup_inserted, tup_updated,
                   tup_deleted, deadlocks, temp_bytes
            FROM pg_stat_database WHERE datname = current_database()
            """).records.first else { throw DatabaseError("The server returned no statistics.") }
        let reads = stats.number("blks_read"), hits = stats.number("blks_hit")
        let connections = overview.number("connections"), maxConnections = overview.number("max_connections")
        let inserted = stats.number("tup_inserted"), updated = stats.number("tup_updated"), deleted = stats.number("tup_deleted")

        let tables = try await driver.execute("""
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

    // MARK: Routines

    var kinds: [RoutineInfo.Kind] { [.function, .procedure, .trigger] }

    func routines(in schema: String, on driver: any DatabaseDriver) async throws -> [RoutineInfo] {
        let functions = try await driver.execute("""
            SELECT p.oid::text AS oid, p.proname AS name, p.prokind AS kind,
                   pg_get_function_identity_arguments(p.oid) AS args, pg_get_function_result(p.oid) AS result
            FROM pg_proc p
            JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = \(d.literal(schema)) AND p.prokind IN ('f', 'p')
              AND NOT EXISTS (SELECT 1 FROM pg_depend e WHERE e.objid = p.oid AND e.deptype = 'e')
            ORDER BY p.proname, args
            """).records.map { row in
            RoutineInfo(kind: row["kind"] == "p" ? .procedure : .function, schema: schema, name: row["name"] ?? "",
                        arguments: row["args"] ?? "", detail: row["result"].map { "returns \($0)" } ?? "", oid: row["oid"])
        }
        let triggers = try await driver.execute("""
            SELECT t.oid::text AS oid, t.tgname AS name, c.relname AS table_name,
                   CASE WHEN t.tgtype & 2 = 2 THEN 'BEFORE' WHEN t.tgtype & 64 = 64 THEN 'INSTEAD OF' ELSE 'AFTER' END AS timing,
                   concat_ws(' OR ', CASE WHEN t.tgtype & 4 = 4 THEN 'INSERT' END, CASE WHEN t.tgtype & 16 = 16 THEN 'UPDATE' END,
                             CASE WHEN t.tgtype & 8 = 8 THEN 'DELETE' END, CASE WHEN t.tgtype & 32 = 32 THEN 'TRUNCATE' END) AS events
            FROM pg_trigger t
            JOIN pg_class c ON c.oid = t.tgrelid
            JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = \(d.literal(schema)) AND NOT t.tgisinternal
            ORDER BY c.relname, t.tgname
            """).records.map { row in
            RoutineInfo(kind: .trigger, schema: schema, name: row["name"] ?? "", table: row["table_name"],
                        detail: "\(row["timing"] ?? "") \(row["events"] ?? "") ON \(row["table_name"] ?? "")", oid: row["oid"])
        }
        return functions + triggers
    }

    func definition(of routine: RoutineInfo, on driver: any DatabaseDriver) async throws -> String {
        guard let oid = routine.oid else { throw DatabaseError("Unknown \(routine.kind.displayName.lowercased()) \(routine.name).") }
        let text = routine.kind == .trigger
            ? try await driver.value("SELECT pg_get_triggerdef(\(d.literal(oid))::oid, true)").map { $0 + ";" }
            : try await driver.value("SELECT pg_get_functiondef(\(d.literal(oid))::oid)")
        return try RoutineText.required(text, for: routine)
    }

    func dropStatement(for routine: RoutineInfo) -> String {
        let qualified = "\(d.quoteIdentifier(routine.schema)).\(d.quoteIdentifier(routine.name))"
        switch routine.kind {
        case .trigger:
            return "DROP TRIGGER \(d.quoteIdentifier(routine.name)) ON \(d.quoteIdentifier(routine.schema)).\(d.quoteIdentifier(routine.table ?? ""))"
        case .procedure: return "DROP PROCEDURE \(qualified)(\(routine.arguments))"
        case .function: return "DROP FUNCTION \(qualified)(\(routine.arguments))"
        }
    }

    /// Functions and procedures: `CREATE OR REPLACE` replaces in place. Triggers are dropped and recreated in one
    /// transaction, so a mistake changes nothing.
    func replace(_ routine: RoutineInfo, original: String, with newDefinition: String, on driver: any DatabaseDriver) async throws {
        switch routine.kind {
        case .function, .procedure: _ = try await driver.execute(newDefinition)
        case .trigger: try await driver.applyInTransaction([dropStatement(for: routine), newDefinition])
        }
    }

    func template(for kind: RoutineInfo.Kind, schema: String, table: String?) -> String {
        let target = table.map(d.quoteIdentifier) ?? "table_name"
        switch kind {
        case .trigger:
            return """
                CREATE TRIGGER new_trigger
                BEFORE UPDATE ON \(d.quoteIdentifier(schema)).\(target)
                FOR EACH ROW EXECUTE FUNCTION \(d.quoteIdentifier(schema)).trigger_function();
                """
        case .procedure:
            return """
                CREATE OR REPLACE PROCEDURE \(d.quoteIdentifier(schema)).new_procedure()
                LANGUAGE plpgsql
                AS $$
                BEGIN
                END;
                $$;
                """
        case .function:
            return """
                CREATE OR REPLACE FUNCTION \(d.quoteIdentifier(schema)).new_function()
                RETURNS integer
                LANGUAGE sql
                AS $$
                    SELECT 1;
                $$;
                """
        }
    }
}
