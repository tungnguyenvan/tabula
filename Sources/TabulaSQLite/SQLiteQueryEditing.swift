import Foundation
import TabulaDrivers
import TabulaFoundation
import TabulaSQL

/// SQLite's result edits: plain literals, which the column's affinity reads as its type, matched by the key and by
/// the shown text of the edited columns' old values, returning the row as it is after the update.
struct SQLiteResultEditWriter: ResultEditWriter {
    var kind: DatabaseKind { .sqlite }

    func statement(for edit: QueryRowEdit, in target: QueryEditTarget) throws -> String {
        let columns = target.columns
        guard edit.original.count == columns.count, !edit.values.isEmpty else {
            throw DatabaseError("Invalid result edit.")
        }
        let keys = columns.indices.filter { columns[$0].isKey }
        guard !keys.isEmpty, keys.allSatisfy({ edit.original[$0] != nil }) else {
            throw DatabaseError("A complete primary key is required to edit a result row.")
        }
        let d = SQLDialect(flavor: .sqlite)
        func literal(_ value: String?) throws -> String {
            guard value?.contains("\0") != true else {
                throw DatabaseError("SQLite text values cannot contain a NUL character here.")
            }
            return d.literal(value)
        }
        var assignments: [String] = []
        for (index, value) in edit.values.sorted(by: { $0.key < $1.key }) {
            guard columns.indices.contains(index), columns[index].editable, !columns[index].isKey else {
                throw DatabaseError("This result column is read-only.")
            }
            assignments.append("\(d.quoteIdentifier(columns[index].name)) = \(try literal(value))")
        }
        // The key finds the row (and its index); the edited columns must still read as they were shown, so a
        // concurrent change isn't silently overwritten. Shown text is CAST(… AS TEXT), which a REAL shown with
        // fewer digits than it holds also matches.
        var conditions = try keys.map { "\(d.quoteIdentifier(columns[$0].name)) IS \(try literal(edit.original[$0]))" }
        for index in edit.values.keys.sorted() where !keys.contains(index) {
            let name = d.quoteIdentifier(columns[index].name)
            conditions.append("CAST(\(name) AS TEXT) IS \(try literal(edit.original[index]))")
        }
        let predicate = conditions.joined(separator: " AND ")
        return
            "UPDATE \(d.qualified(target.table)) SET \(assignments.joined(separator: ", ")) WHERE \(predicate) RETURNING "
            + columns.map { d.quoteIdentifier($0.name) }.joined(separator: ", ")
    }

    /// SQLite's type affinity of a declared column type (sqlite.org/datatype3.html, 3.1).
    enum Affinity: Equatable {
        case integer, text, blob, real, numeric

        init(declaredType: String) {
            let type = declaredType.uppercased()
            if type.contains("INT") {
                self = .integer
            } else if type.contains("CHAR") || type.contains("CLOB") || type.contains("TEXT") {
                self = .text
            } else if type.contains("BLOB") || type.isEmpty {
                self = .blob
            } else if type.contains("REAL") || type.contains("FLOA") || type.contains("DOUB") {
                self = .real
            } else {
                self = .numeric
            }
        }

        /// A value typed as text is stored with the column's own type. A BLOB-affinity column (or one declared
        /// without a type) would keep it as text, changing the value's type, so those stay read-only.
        var takesTypedText: Bool { self != .blob }
    }
}

extension SQLiteDriver {
    /// The table a result can be edited in: a plain SELECT of one real table (not a view or virtual table) with
    /// its whole primary key in the result. Columns that are generated, of BLOB affinity or holding bytes stay
    /// read-only; nil when no column could be edited.
    /// `async`, as the protocol declares it: a synchronous method would lose to the protocol's default (nil) when
    /// called with `await`.
    public func queryEditTarget(for result: QueryResult) async throws -> QueryEditTarget? {
        guard let source = EditableSelect.source(result.statement, flavor: .sqlite),
            result.sqliteOrigins.count == result.columns.count, !result.columns.isEmpty
        else { return nil }
        let origins = result.sqliteOrigins.compactMap { $0 }
        guard origins.count == result.columns.count, let first = origins.first,
            origins.allSatisfy({ $0.database == first.database && $0.table == first.table }),
            Set(origins.map { $0.column.lowercased() }).count == origins.count,
            source.last?.lowercased() == first.table.lowercased(),
            source.count == 1 || source.first?.lowercased() == first.database.lowercased()
        else { return nil }
        let d = SQLDialect(flavor: .sqlite)
        let schema = d.quoteIdentifier(first.database)
        let master = first.database == "temp" ? "sqlite_temp_master" : "\(schema).sqlite_master"
        let kind = try execute(
            "SELECT type, sql FROM \(master) WHERE name = \(d.literal(first.table)) COLLATE NOCASE"
        )
        .rows
        guard kind.count == 1, kind[0][0] == "table",
            kind[0][1]?.uppercased().hasPrefix("CREATE VIRTUAL") != true
        else { return nil }
        // table_xinfo: hidden is 2 or 3 for generated columns; pk is the column's place in the primary key.
        let info = try execute("PRAGMA \(schema).table_xinfo(\(d.literal(first.table)))").records
        var byName: [String: QueryEditTarget.Column] = [:]
        for (position, row) in info.enumerated() {
            guard let name = row["name"] else { continue }
            let affinity = SQLiteResultEditWriter.Affinity(declaredType: row["type"] ?? "")
            let isKey = (row.int("pk") ?? 0) > 0
            byName[name.lowercased()] = QueryEditTarget.Column(
                name: name,
                attribute: Int16(clamping: position),
                typeOID: 0,
                typeName: row["type"] ?? "",
                isKey: isKey,
                editable: !isKey && row["hidden"] == "0" && affinity.takesTypedText
            )
        }
        let keys = byName.values.filter(\.isKey)
        guard !keys.isEmpty,
            keys.allSatisfy({ SQLiteResultEditWriter.Affinity(declaredType: $0.typeName).takesTypedText })
        else { return nil }
        var columns = origins.compactMap { byName[$0.column.lowercased()] }
        guard columns.count == result.columns.count else { return nil }
        // A key column holding bytes can't be matched by its text; another such column can't be written as text.
        for index in result.binaryColumns where columns.indices.contains(index) {
            if columns[index].isKey {
                return nil
            }
            columns[index].editable = false
        }
        let present = Set(columns.filter(\.isKey).map(\.name))
        guard keys.allSatisfy({ present.contains($0.name) }), columns.contains(where: \.editable) else { return nil }
        return QueryEditTarget(
            table: TableRef(schema: first.database, name: byName[first.table.lowercased()]?.name ?? first.table),
            tableOID: 0,
            columns: columns,
            writer: SQLiteResultEditWriter()
        )
    }

    /// Runs on the short-lived connection the app opens for a commit: under BEGIN IMMEDIATE (the write lock), the
    /// table's shape is checked again, and every edit must find exactly its row, or nothing is saved.
    public func commitQueryEdits(_ edits: [QueryRowEdit], target: QueryEditTarget) async throws -> [Int: [String?]] {
        guard !edits.isEmpty else {
            return [:]
        }
        guard target.kind == .sqlite, Set(edits.map(\.row)).count == edits.count else {
            throw DatabaseError("Invalid SQLite result edit.")
        }
        let statements = try edits.map { try target.statement(for: $0) }
        _ = try execute("BEGIN IMMEDIATE")
        do {
            let projected = target.columns.map { dialect.quoteIdentifier($0.name) }.joined(separator: ", ")
            let probe = try execute("SELECT \(projected) FROM \(dialect.qualified(target.table)) LIMIT 0")
            guard let current = try await queryEditTarget(for: probe), current.table == target.table,
                current.columns == target.columns
            else {
                throw DatabaseError("The source table changed. Run the query again before editing.")
            }
            var returned: [Int: [String?]] = [:]
            for (edit, sql) in zip(edits, statements) {
                let updated = try execute(sql)
                guard updated.rows.count == 1 else {
                    throw DatabaseError(
                        "The row changed or was removed since this query ran. Nothing was saved; run the query again."
                    )
                }
                returned[edit.row] = updated.rows[0]
            }
            _ = try execute("COMMIT")
            return returned
        } catch {
            // The commit's own error is reported; a failed ROLLBACK ends with this connection.
            _ = try? execute("ROLLBACK")
            throw error
        }
    }
}
