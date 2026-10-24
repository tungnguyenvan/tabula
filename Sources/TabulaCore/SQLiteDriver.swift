import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public actor SQLiteDriver: DatabaseDriver {
    public nonisolated let kind: DatabaseKind = .sqlite
    private var db: OpaquePointer?

    /// Opens (or creates) the database file at `path`.
    public init(path: String) throws {
        let expanded = (path as NSString).expandingTildeInPath
        guard !expanded.isEmpty else { throw DatabaseError("Choose a SQLite database file.") }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        if sqlite3_open_v2(expanded, &handle, flags, nil) != SQLITE_OK {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open database"
            sqlite3_close(handle)
            throw DatabaseError(message)
        }
        sqlite3_busy_timeout(handle, 5000)
        db = handle
    }

    public func close() {
        sqlite3_close_v2(db)
        db = nil
    }

    private func requireHandle() throws -> OpaquePointer {
        guard let db else { throw DatabaseError("The database is closed.") }
        return db
    }

    public func execute(_ sql: String) throws -> QueryResult {
        let db = try requireHandle()
        let started = Date()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(statement) }

        let columnCount = Int(sqlite3_column_count(statement))
        let columns = (0..<columnCount).map { String(cString: sqlite3_column_name(statement, Int32($0))) }
        var rows: [[String?]] = []

        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw DatabaseError(String(cString: sqlite3_errmsg(db))) }
            var row: [String?] = []
            row.reserveCapacity(columnCount)
            for index in 0..<Int32(columnCount) {
                row.append(Self.text(statement, index))
            }
            rows.append(row)
        }

        let affected: Int? = columnCount == 0 ? Int(sqlite3_changes(db)) : nil
        return QueryResult(columns: columns, rows: rows, affectedRows: affected, duration: Date().timeIntervalSince(started), statement: sql)
    }

    private static func text(_ statement: OpaquePointer?, _ index: Int32) -> String? {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_NULL:
            return nil
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, index))
            guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return "x''" }
            let buffer = UnsafeRawBufferPointer(start: bytes, count: count)
            return "x'" + buffer.map { String(format: "%02x", $0) }.joined() + "'"
        default:
            guard let cString = sqlite3_column_text(statement, index) else { return nil }
            return String(cString: cString)
        }
    }

    private func strings(_ sql: String) throws -> [[String?]] {
        try execute(sql).rows
    }

    public func schemas() throws -> [String] {
        try strings("PRAGMA database_list").compactMap { $0.count > 1 ? $0[1] : nil }
    }

    public func defaultSchema() -> String { "main" }

    public func tables(in schema: String) throws -> [TableRef] {
        let master = schema == "temp" ? "sqlite_temp_master" : "\(SQLDialect(kind: .sqlite).quoteIdentifier(schema)).sqlite_master"
        return try strings("SELECT name, type FROM \(master) WHERE type IN ('table','view') AND name NOT LIKE 'sqlite_%' ORDER BY name")
            .compactMap { row in
                guard let name = row[0] else { return nil }
                return TableRef(schema: schema, name: name, kind: row[1] == "view" ? .view : .table)
            }
    }

    public func columns(of table: TableRef) throws -> [ColumnInfo] {
        let d = SQLDialect(kind: .sqlite)
        // cid, name, type, notnull, dflt_value, pk
        return try strings("PRAGMA \(d.quoteIdentifier(table.schema)).table_info(\(d.literal(table.name)))").map { row in
            ColumnInfo(
                name: row[1] ?? "",
                dataType: row[2] ?? "",
                isNullable: row[3] == "0",
                defaultValue: row[4],
                isPrimaryKey: (Int(row[5] ?? "0") ?? 0) > 0
            )
        }
    }

    public func indexes(of table: TableRef) throws -> [IndexInfo] {
        let d = SQLDialect(kind: .sqlite)
        let schema = d.quoteIdentifier(table.schema)
        // seq, name, unique, origin, partial
        return try strings("PRAGMA \(schema).index_list(\(d.literal(table.name)))").compactMap { row in
            guard let name = row[1] else { return nil }
            let columns = try strings("PRAGMA \(schema).index_info(\(d.literal(name)))").compactMap { $0[2] }
            let master = table.schema == "temp" ? "sqlite_temp_master" : "\(schema).sqlite_master"
            let definition = try strings("SELECT sql FROM \(master) WHERE type = 'index' AND name = \(d.literal(name))").first?.first ?? nil
            return IndexInfo(name: name, columns: columns, isUnique: row[2] == "1", isPrimary: row[3] == "pk", definition: definition)
        }
    }
}
