import Foundation
import TabulaDrivers
import TabulaFoundation
import TabulaSQL

/// MySQL's catalog: information_schema and the server's status variables.
struct MySQLCatalog: DatabaseCatalog, RoutineCatalog {
    private let d = SQLDialect(flavor: .mysql)

    var routines: (any RoutineCatalog)? { self }

    func serverVersion(on driver: any DatabaseDriver) async throws -> String {
        guard let version = try await driver.value("SELECT version()") else {
            throw DatabaseError("The server didn't report its version.")
        }
        return "MySQL " + version
    }

    func useSchema(_ schema: String, on driver: any DatabaseDriver) async throws {
        _ = try await driver.execute("USE \(d.quoteIdentifier(schema))")
    }

    /// MySQL lists its databases as schemas.
    func serverDatabases(on driver: any DatabaseDriver) async throws -> [String] { [] }
    func currentDatabase(on driver: any DatabaseDriver) async throws -> String? { nil }

    func foreignKeys(in schema: String, on driver: any DatabaseDriver) async throws -> [ForeignKeyInfo] {
        let rows =
            try await driver.execute(
                """
                SELECT CONSTRAINT_NAME, TABLE_NAME, COLUMN_NAME, REFERENCED_TABLE_SCHEMA, REFERENCED_TABLE_NAME, REFERENCED_COLUMN_NAME
                FROM information_schema.KEY_COLUMN_USAGE
                WHERE TABLE_SCHEMA = \(d.literal(schema)) AND REFERENCED_TABLE_NAME IS NOT NULL
                ORDER BY TABLE_NAME, CONSTRAINT_NAME, ORDINAL_POSITION
                """
            )
            .records
        var keys: [ForeignKeyInfo] = []
        for row in rows {
            let name = row["CONSTRAINT_NAME"] ?? ""
            let table = row["TABLE_NAME"] ?? ""
            let column = row["COLUMN_NAME"] ?? ""
            let referenced = row["REFERENCED_COLUMN_NAME"] ?? ""
            if let last = keys.last, last.name == name, last.table.name == table {
                keys[keys.count - 1].columns.append(column)
                keys[keys.count - 1].referencedColumns.append(referenced)
            } else {
                keys.append(
                    ForeignKeyInfo(
                        name: name,
                        table: TableRef(schema: schema, name: table),
                        columns: [column],
                        referencedTable: TableRef(
                            schema: row["REFERENCED_TABLE_SCHEMA"] ?? schema,
                            name: row["REFERENCED_TABLE_NAME"] ?? ""
                        ),
                        referencedColumns: [referenced]
                    )
                )
            }
        }
        return keys
    }

    func metrics(schema: String, on driver: any DatabaseDriver) async throws -> MetricsSample {
        var status: [String: Double] = [:]
        for row in try await driver.execute("SHOW GLOBAL STATUS").records {
            if let name = row["Variable_name"], let value = row["Value"].flatMap(Double.init) { status[name] = value }
        }
        var variables: [String: String] = [:]
        for row
            in try await driver.execute(
                "SHOW GLOBAL VARIABLES WHERE Variable_name IN ('max_connections', 'version', 'version_comment', 'innodb_buffer_pool_size')"
            )
            .records
        {
            if let name = row["Variable_name"] { variables[name] = row["Value"] ?? "" }
        }
        let s = { (name: String) in status[name] ?? 0 }
        let size = try await driver.value(
            "SELECT SUM(DATA_LENGTH + INDEX_LENGTH) FROM information_schema.TABLES WHERE TABLE_SCHEMA = \(d.literal(schema))"
        )
        let requests = s("Innodb_buffer_pool_read_requests")
        let diskReads = s("Innodb_buffer_pool_reads")

        let tables =
            try await driver.execute(
                """
                SELECT TABLE_NAME AS name, TABLE_ROWS AS row_count, DATA_LENGTH AS data_bytes, INDEX_LENGTH AS index_bytes
                FROM information_schema.TABLES
                WHERE TABLE_SCHEMA = \(d.literal(schema)) AND TABLE_TYPE = 'BASE TABLE'
                ORDER BY DATA_LENGTH + INDEX_LENGTH DESC LIMIT \(Defaults.Metrics.tableLimit)
                """
            )
            .records.map(MetricsSample.TableStat.init)

        return MetricsSample(
            groups: [
                .init(
                    "Server",
                    [
                        .init(
                            "Version",
                            "\(variables["version"] ?? "") \(variables["version_comment"] ?? "")"
                                .trimmingCharacters(in: .whitespaces)
                        ),
                        .init("Uptime", MetricFormat.duration(seconds: s("Uptime"))),
                        .init("Database", schema),
                        .init("Database size", MetricFormat.bytes(size.flatMap(Double.init))),
                        .init(
                            "Buffer pool",
                            MetricFormat.bytes(variables["innodb_buffer_pool_size"].flatMap(Double.init))
                        ),
                    ]
                ),
                .init(
                    "Connections",
                    [
                        .init("Open", "\(Int(s("Threads_connected"))) of \(variables["max_connections"] ?? "?")"),
                        .init("Running", MetricFormat.number(s("Threads_running"))),
                        .init("Max used", MetricFormat.number(s("Max_used_connections"))),
                        .init("Aborted connects", MetricFormat.number(s("Aborted_connects"))),
                    ]
                ),
                .init(
                    "Activity (since start)",
                    [
                        .init("Buffer pool hit ratio", MetricFormat.percent(requests - diskReads, of: requests)),
                        .init("Queries", MetricFormat.number(s("Questions"))),
                        .init(
                            "Selects / inserts / updates / deletes",
                            [s("Com_select"), s("Com_insert"), s("Com_update"), s("Com_delete")]
                                .map { MetricFormat.number($0) }.joined(separator: " / ")
                        ),
                        .init("Slow queries", MetricFormat.number(s("Slow_queries"))),
                        .init(
                            "Received / sent",
                            "\(MetricFormat.bytes(s("Bytes_received"))) / \(MetricFormat.bytes(s("Bytes_sent")))"
                        ),
                    ]
                ),
            ],
            counters: [
                "Queries/s": s("Questions"), "Writes/s": s("Com_insert") + s("Com_update") + s("Com_delete"),
                "Network in KB/s": s("Bytes_received") / Units.kibibyte,
                "Network out KB/s": s("Bytes_sent") / Units.kibibyte,
            ],
            gauges: ["Connections": s("Threads_connected"), "Running threads": s("Threads_running")],
            tables: tables
        )
    }

    // MARK: Read-only sessions

    /// MySQL limits statements in milliseconds (max_execution_time), MariaDB in seconds (max_statement_time); each
    /// server knows only its own variable. A server with neither keeps no limit; the read-only transaction still holds.
    func prepareReadOnlySession(timeoutSeconds: Int, on driver: any DatabaseDriver) async throws {
        _ = try await driver.execute("SET SESSION TRANSACTION READ ONLY")
        do {
            _ = try await driver.execute("SET SESSION max_execution_time = \(timeoutSeconds * 1000)")
        } catch {
            // MariaDB's name for the limit; a server with neither runs the assistant's queries without one.
            _ = try? await driver.execute("SET SESSION max_statement_time = \(timeoutSeconds)")
        }
    }

    func readOnlyTransaction(timeoutSeconds: Int) -> [String]? {
        ["START TRANSACTION READ ONLY"]
    }

    // MARK: Routines

    var kinds: [RoutineInfo.Kind] { [.function, .procedure, .trigger] }

    func routines(in schema: String, on driver: any DatabaseDriver) async throws -> [RoutineInfo] {
        let routines =
            try await driver.execute(
                """
                SELECT ROUTINE_NAME, ROUTINE_TYPE, DTD_IDENTIFIER FROM information_schema.ROUTINES
                WHERE ROUTINE_SCHEMA = \(d.literal(schema)) ORDER BY ROUTINE_NAME
                """
            )
            .records
            .map { row in
                RoutineInfo(
                    kind: row["ROUTINE_TYPE"] == "PROCEDURE" ? .procedure : .function,
                    schema: schema,
                    name: row["ROUTINE_NAME"] ?? "",
                    detail: row["DTD_IDENTIFIER"].map { "returns \($0)" } ?? ""
                )
            }
        let triggers =
            try await driver.execute(
                """
                SELECT TRIGGER_NAME, EVENT_OBJECT_TABLE, ACTION_TIMING, EVENT_MANIPULATION FROM information_schema.TRIGGERS
                WHERE TRIGGER_SCHEMA = \(d.literal(schema)) ORDER BY EVENT_OBJECT_TABLE, TRIGGER_NAME
                """
            )
            .records
            .map { row in
                RoutineInfo(
                    kind: .trigger,
                    schema: schema,
                    name: row["TRIGGER_NAME"] ?? "",
                    table: row["EVENT_OBJECT_TABLE"],
                    detail:
                        "\(row["ACTION_TIMING"] ?? "") \(row["EVENT_MANIPULATION"] ?? "") ON \(row["EVENT_OBJECT_TABLE"] ?? "")"
                )
            }
        return routines + triggers
    }

    private func keyword(_ kind: RoutineInfo.Kind) -> String {
        switch kind {
        case .trigger: "TRIGGER"
        case .procedure: "PROCEDURE"
        case .function: "FUNCTION"
        }
    }

    func definition(of routine: RoutineInfo, on driver: any DatabaseDriver) async throws -> String {
        let keyword = keyword(routine.kind)
        let row =
            try await driver.execute(
                "SHOW CREATE \(keyword) \(d.quoteIdentifier(routine.schema)).\(d.quoteIdentifier(routine.name))"
            )
            .records.first
        return try RoutineText.required(
            routine.kind == .trigger ? row?["SQL Original Statement"] : row?["Create \(keyword.capitalized)"],
            for: routine
        )
    }

    func dropStatement(for routine: RoutineInfo) -> String {
        "DROP \(keyword(routine.kind)) \(d.quoteIdentifier(routine.schema)).\(d.quoteIdentifier(routine.name))"
    }

    /// MySQL has no transactional DDL: the routine is dropped and recreated, and if the new definition fails, the
    /// original is put back before the error is reported.
    func replace(
        _ routine: RoutineInfo,
        original: String,
        with newDefinition: String,
        on driver: any DatabaseDriver
    ) async throws {
        _ = try await driver.execute(dropStatement(for: routine))
        do {
            _ = try await driver.execute(newDefinition)
        } catch {
            do {
                _ = try await driver.execute(original)
            } catch let restoreError {
                throw DatabaseError(
                    "\(error.localizedDescription)\nRestoring the original also failed: \(restoreError.localizedDescription). "
                        + "Its definition is still in the editor."
                )
            }
            throw DatabaseError(
                "\(error.localizedDescription)\nThe original \(routine.kind.displayName.lowercased()) was restored."
            )
        }
    }

    func template(for kind: RoutineInfo.Kind, schema: String, table: String?) -> String {
        let target = table.map(d.quoteIdentifier) ?? "table_name"
        switch kind {
        case .trigger:
            return
                "CREATE TRIGGER new_trigger BEFORE UPDATE ON \(target)\nFOR EACH ROW\nBEGIN\n    SET NEW.updated_at = NOW();\nEND"
        case .procedure: return "CREATE PROCEDURE new_procedure()\nBEGIN\n    SELECT 1;\nEND"
        case .function: return "CREATE FUNCTION new_function() RETURNS INT DETERMINISTIC\nBEGIN\n    RETURN 1;\nEND"
        }
    }
}
