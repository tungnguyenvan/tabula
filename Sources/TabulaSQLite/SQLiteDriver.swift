import Foundation
import SQLite3
import TabulaDrivers
import TabulaFoundation
import TabulaSQL

public actor SQLiteDriver: DatabaseDriver {
    public nonisolated let kind: DatabaseKind = .sqlite
    public nonisolated let dialect: any QueryDialect = SQLDialect(flavor: .sqlite)
    public nonisolated let catalog: any DatabaseCatalog
    /// Stop interrupts the running statement on the connection.
    public nonisolated let queryCancellation = QueryCancellationSupport.server
    private var db: OpaquePointer?
    /// Reaches the running statement while the actor is busy stepping it. A statement only runs inside
    /// `execute`, which never suspends, so the connection can't close while one is in progress.
    private nonisolated let interrupter: SQLiteInterrupter

    /// Opens (or creates) the database file at `path`.
    public init(path: String) throws {
        let expanded = (path as NSString).expandingTildeInPath
        guard !expanded.isEmpty else {
            throw DatabaseError("Choose a SQLite database file.")
        }
        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(expanded, &opened, flags, nil) == SQLITE_OK, let handle = opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open database"
            sqlite3_close(opened)
            throw DatabaseError(message)
        }
        sqlite3_busy_timeout(handle, Defaults.sqliteBusyTimeoutMilliseconds)
        db = handle
        interrupter = SQLiteInterrupter(handle: handle)
        catalog = SQLiteCatalog(interrupter: interrupter)
    }

    public func close() {
        sqlite3_close_v2(db)
        db = nil
    }

    private func requireHandle() throws -> OpaquePointer {
        guard let db else {
            throw DatabaseError("The database is closed.")
        }
        return db
    }

    public func execute(_ sql: String) throws -> QueryResult {
        let db = try requireHandle()
        let scope = QueryCancelScope.current
        try scope?.checkCancellation()
        let run = interrupter.begin()
        let interrupter = self.interrupter
        var attachment: UUID?
        if let scope {
            let token = scope.attach {
                interrupter.interrupt(run, because: .stop) ? .requested : .notRunning
            }
            guard let token else {
                interrupter.end(run)
                throw QueryCancelledError()
            }
            attachment = token
        }

        let result = Result { () throws(Failure) -> QueryResult in try perform(sql, on: db) }
        if let attachment {
            scope?.detach(attachment)
        }
        let interruption = interrupter.end(run)
        guard case .failure(let failure) = result else {
            return try result.get()
        }
        guard let interruption, failure.code == SQLITE_INTERRUPT else {
            throw DatabaseError(failure.message)
        }
        switch interruption {
        case .stop:
            throw QueryCancelledError(serverInterrupted: true)
        case .timeLimit(let seconds):
            throw DatabaseError("The statement ran past the \(seconds)-second time limit and was stopped.")
        }
    }

    /// A statement that failed in SQLite, with its result code.
    private struct Failure: Error {
        let code: Int32
        let message: String

        init(_ code: Int32, on db: OpaquePointer) {
            self.code = code
            self.message = String(cString: sqlite3_errmsg(db))
        }
    }

    private func perform(_ sql: String, on db: OpaquePointer) throws(Failure) -> QueryResult {
        let started = Date()
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK else {
            throw Failure(prepared, on: db)
        }
        defer { sqlite3_finalize(statement) }

        let columnCount = Int(sqlite3_column_count(statement))
        let columns = (0..<columnCount).map { String(cString: sqlite3_column_name(statement, Int32($0))) }
        var rows: [[String?]] = []
        // SQLite types each value, not the column; a column holding any blob is written back as bytes.
        var binaryColumns: Set<Int> = []

        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE {
                break
            }
            guard step == SQLITE_ROW else {
                throw Failure(step, on: db)
            }
            var row: [String?] = []
            row.reserveCapacity(columnCount)
            for index in 0..<Int32(columnCount) {
                if sqlite3_column_type(statement, index) == SQLITE_BLOB {
                    binaryColumns.insert(Int(index))
                }
                row.append(Self.text(statement, index))
            }
            rows.append(row)
        }

        let affected: Int? = columnCount == 0 ? Int(sqlite3_changes(db)) : nil
        var result = QueryResult(
            columns: columns,
            rows: rows,
            affectedRows: affected,
            duration: Date().timeIntervalSince(started),
            statement: sql
        )
        result.binaryColumns = binaryColumns
        return result
    }

    private static func text(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_NULL:
            return nil
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, index))
            guard count > 0, let bytes = sqlite3_column_blob(statement, index) else {
                return BinaryText.text([])
            }
            return BinaryText.text(UnsafeRawBufferPointer(start: bytes, count: count))
        default:
            guard let cString = sqlite3_column_text(statement, index) else { return nil }
            return String(cString: cString)
        }
    }

    private func strings(_ sql: String) throws -> [[String?]] {
        try execute(sql).rows
    }

    private func records(_ sql: String) throws -> [Record] {
        try execute(sql).records
    }

    public func schemas() throws -> [String] {
        try records("PRAGMA database_list").compactMap { $0["name"] }
    }

    public func defaultSchema() -> String { "main" }

    public func tables(in schema: String) throws -> [TableRef] {
        let master =
            schema == "temp"
            ? "sqlite_temp_master" : "\(SQLDialect(flavor: .sqlite).quoteIdentifier(schema)).sqlite_master"
        return try records(
            "SELECT name, type FROM \(master) WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%' ORDER BY name"
        )
        .compactMap { row in
            guard let name = row["name"] else { return nil }
            return TableRef(schema: schema, name: name, kind: row["type"] == "view" ? .view : .table)
        }
    }

    public func columns(of table: TableRef) throws -> [ColumnInfo] {
        let d = SQLDialect(flavor: .sqlite)
        return try records("PRAGMA \(d.quoteIdentifier(table.schema)).table_info(\(d.literal(table.name)))")
            .map { row in
                ColumnInfo(
                    name: row["name"] ?? "",
                    dataType: row["type"] ?? "",
                    isNullable: row["notnull"] == "0",
                    defaultValue: row["dflt_value"],
                    // pk is the column's position in the primary key, 0 when it isn't part of it.
                    isPrimaryKey: (row.int("pk") ?? 0) > 0
                )
            }
    }

    public func indexes(of table: TableRef) throws -> [IndexInfo] {
        let d = SQLDialect(flavor: .sqlite)
        let schema = d.quoteIdentifier(table.schema)
        return try records("PRAGMA \(schema).index_list(\(d.literal(table.name)))")
            .compactMap { row in
                guard let name = row["name"] else { return nil }
                let columns = try records("PRAGMA \(schema).index_info(\(d.literal(name)))")
                    .map { $0["name"] ?? "(expression)" }
                let master = table.schema == "temp" ? "sqlite_temp_master" : "\(schema).sqlite_master"
                let definition =
                    try strings("SELECT sql FROM \(master) WHERE type = 'index' AND name = \(d.literal(name))").first?
                    .first ?? nil
                return IndexInfo(
                    name: name,
                    columns: columns,
                    isUnique: row["unique"] == "1",
                    isPrimary: row["origin"] == "pk",
                    definition: definition
                )
            }
    }
}
