import Foundation
import TabulaDrivers
import TabulaFoundation
import TabulaSQL

/// SQLite's catalog: sqlite_master and pragmas. An attached database is a schema; there are no other databases.
struct SQLiteCatalog: DatabaseCatalog, RoutineCatalog {
    private let d = SQLDialect(flavor: .sqlite)
    /// The connection's, for the assistant's time limit.
    let interrupter: SQLiteInterrupter

    var routines: (any RoutineCatalog)? { self }

    func serverVersion(on driver: any DatabaseDriver) async throws -> String {
        guard let version = try await driver.value("SELECT sqlite_version()") else {
            throw DatabaseError("SQLite didn't report its version.")
        }
        return "SQLite " + version
    }

    /// Unqualified names already search main, temp and then the attached databases.
    func useSchema(_ schema: String, on driver: any DatabaseDriver) async throws {}

    func serverDatabases(on driver: any DatabaseDriver) async throws -> [String] { [] }
    func currentDatabase(on driver: any DatabaseDriver) async throws -> String? { nil }

    func foreignKeys(in schema: String, on driver: any DatabaseDriver) async throws -> [ForeignKeyInfo] {
        var keys: [ForeignKeyInfo] = []
        for table in try await driver.tables(in: schema) where table.kind == .table {
            let rows =
                try await driver.execute(
                    "PRAGMA \(d.quoteIdentifier(schema)).foreign_key_list(\(d.literal(table.name)))"
                )
                .records
            var byID: [String: ForeignKeyInfo] = [:]
            var order: [String] = []
            for row in rows {
                let id = row["id"] ?? ""
                if byID[id] == nil {
                    order.append(id)
                    byID[id] = ForeignKeyInfo(
                        name: "fk_\(table.name)_\(id)",
                        table: table,
                        columns: [],
                        referencedTable: TableRef(schema: schema, name: row["table"] ?? ""),
                        referencedColumns: []
                    )
                }
                byID[id]?.columns.append(row["from"] ?? "")
                // "to" is NULL when the key references the other table's primary key implicitly.
                if let to = row["to"] { byID[id]?.referencedColumns.append(to) }
            }
            keys += order.compactMap { byID[$0] }
        }
        return keys
    }

    func metrics(schema: String, on driver: any DatabaseDriver) async throws -> MetricsSample {
        func pragma(_ name: String) async throws -> Double {
            guard let text = try await driver.value("PRAGMA \(d.quoteIdentifier(schema)).\(name)"),
                let value = Double(text)
            else {
                throw DatabaseError("SQLite didn't report \(name).")
            }
            return value
        }
        let pageSize = try await pragma("page_size")
        let pageCount = try await pragma("page_count")
        let free = try await pragma("freelist_count")
        let journal = try await driver.value("PRAGMA \(d.quoteIdentifier(schema)).journal_mode") ?? ""
        let version = try await driver.value("SELECT sqlite_version()") ?? ""
        var tables: [MetricsSample.TableStat] = []
        for table in try await driver.tables(in: schema).filter({ $0.kind == .table })
            .prefix(Defaults.Metrics.tableLimit)
        {
            let rows = try await driver.value("SELECT COUNT(*) FROM \(d.qualified(table))").flatMap { Int($0) }
            tables.append(.init(name: table.name, rows: rows, dataBytes: nil, indexBytes: nil))
        }
        // Per-table sizes need the dbstat virtual table, which only some SQLite builds include; without it the
        // sizes stay unknown.
        let sizeQuery =
            "SELECT name, SUM(pgsize) AS size FROM dbstat(\(d.literal(schema))) WHERE aggregate = TRUE GROUP BY name"
        if let sizes = try? await driver.execute(sizeQuery).records {
            let byName = Dictionary(
                sizes.compactMap { row in row["name"].map { ($0, row.int("size") ?? 0) } },
                uniquingKeysWith: +
            )
            for index in tables.indices {
                tables[index].dataBytes = byName[tables[index].name]
            }
        }
        tables.sort { ($0.rows ?? 0) > ($1.rows ?? 0) }
        return MetricsSample(
            groups: [
                .init(
                    "Database",
                    [
                        .init("SQLite", version),
                        .init("File size", MetricFormat.bytes(pageSize * pageCount)),
                        .init("Free pages", "\(MetricFormat.number(free)) (\(MetricFormat.bytes(free * pageSize)))"),
                        .init("Page size", MetricFormat.bytes(pageSize)),
                        .init("Journal mode", journal.uppercased()),
                        .init("Tables", "\(tables.count)"),
                    ]
                )
            ],
            tables: tables
        )
    }

    // MARK: Read-only sessions

    /// query_only refuses every write on the connection; SQLite has no statement timeout of its own, so the
    /// connection's interrupter ends a statement that runs past it.
    func prepareReadOnlySession(timeoutSeconds: Int, on driver: any DatabaseDriver) async throws {
        _ = try await driver.execute("PRAGMA query_only = ON")
        interrupter.timeLimitSeconds = timeoutSeconds
    }

    func readOnlyTransaction(timeoutSeconds: Int) -> [String]? { nil }

    // MARK: Routines

    var kinds: [RoutineInfo.Kind] { [.trigger] }

    private func master(_ schema: String) -> String {
        schema == "temp" ? "sqlite_temp_master" : "\(d.quoteIdentifier(schema)).sqlite_master"
    }

    func routines(in schema: String, on driver: any DatabaseDriver) async throws -> [RoutineInfo] {
        try await driver.execute(
            "SELECT name, tbl_name FROM \(master(schema)) WHERE type = 'trigger' ORDER BY tbl_name, name"
        )
        .records
        .map { row in
            RoutineInfo(
                kind: .trigger,
                schema: schema,
                name: row["name"] ?? "",
                table: row["tbl_name"],
                detail: "ON \(row["tbl_name"] ?? "")"
            )
        }
    }

    func definition(of routine: RoutineInfo, on driver: any DatabaseDriver) async throws -> String {
        let text = try await driver.value(
            "SELECT sql FROM \(master(routine.schema)) WHERE type = 'trigger' AND name = \(d.literal(routine.name))"
        )
        return try RoutineText.required(text.map { $0 + ";" }, for: routine)
    }

    /// The main database needs no prefix.
    func dropStatement(for routine: RoutineInfo) -> String {
        let name =
            routine.schema == "main"
            ? d.quoteIdentifier(routine.name)
            : "\(d.quoteIdentifier(routine.schema)).\(d.quoteIdentifier(routine.name))"
        return "DROP TRIGGER \(name)"
    }

    /// Dropped and recreated in one transaction, so a mistake changes nothing.
    func replace(
        _ routine: RoutineInfo,
        original: String,
        with newDefinition: String,
        on driver: any DatabaseDriver
    ) async throws {
        try await driver.applyInTransaction([dropStatement(for: routine), newDefinition])
    }

    func template(for kind: RoutineInfo.Kind, schema: String, table: String?) -> String {
        "CREATE TRIGGER new_trigger AFTER UPDATE ON \(table.map(d.quoteIdentifier) ?? "table_name")\nBEGIN\n    SELECT 1;\nEND;"
    }
}
