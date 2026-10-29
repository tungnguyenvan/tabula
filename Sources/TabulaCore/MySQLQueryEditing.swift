import Foundation

/// MySQL's wire metadata distinguishes display aliases from physical table and column names.
public struct MySQLQueryColumnOrigin: Sendable, Equatable {
    public var schema: String
    public var table: String
    public var originalTable: String
    public var originalName: String
    public var dataType: UInt32
    public var characterSet: UInt32

    public init(schema: String, table: String, originalTable: String, originalName: String,
                dataType: UInt32, characterSet: UInt32) {
        self.schema = schema; self.table = table; self.originalTable = originalTable; self.originalName = originalName
        self.dataType = dataType; self.characterSet = characterSet
    }
}

extension QueryEditTarget {
    /// Hex text needs no quote/backslash escaping and means the same thing with NO_BACKSLASH_ESCAPES enabled.
    static func mysqlLiteral(_ value: String?) -> String {
        guard let value else { return "NULL" }
        return "_utf8mb4 X'" + value.utf8.map { String(format: "%02x", $0) }.joined() + "'"
    }

    /// A plain exact numeric literal for an index lookup. Quoted numbers compare as DOUBLE in MySQL.
    static func mysqlNumericLiteral(_ value: String) throws -> String {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        let digits = parts[0].hasPrefix("-") ? parts[0].dropFirst() : parts[0]
        guard parts.count <= 2, !digits.isEmpty, digits.allSatisfy({ $0 >= "0" && $0 <= "9" }),
              parts.count == 1 || (!parts[1].isEmpty && parts[1].allSatisfy({ $0 >= "0" && $0 <= "9" })) else {
            throw DatabaseError("The primary key value is not a canonical MySQL number.")
        }
        return value
    }

    static let mysqlNumericTypes: Set<String> = ["tinyint", "smallint", "mediumint", "int", "bigint", "decimal"]
    static let mysqlTextTypes: Set<String> = ["char", "varchar", "tinytext", "text", "mediumtext", "longtext"]

    func mysqlValidatedIndices(for edit: QueryRowEdit) throws -> [Int] {
        guard kind == .mysql, edit.row >= 0, edit.original.count == columns.count, !edit.values.isEmpty,
              ([table.schema, table.name] + columns.map(\.name)).allSatisfy({ !$0.isEmpty && !$0.contains("\0") && !$0.contains("\\") }),
              Set(columns.map(\.name)).count == columns.count else { throw DatabaseError("Invalid result edit.") }
        let keys = columns.indices.filter { columns[$0].isKey }
        guard !keys.isEmpty, keys.allSatisfy({ edit.original[$0] != nil }) else {
            throw DatabaseError("A complete primary key is required to edit a result row.")
        }
        for index in Set(keys).union(edit.values.keys) {
            guard columns.indices.contains(index), let type = columns[index].mysqlType,
                  Self.mysqlNumericTypes.contains(type) || Self.mysqlTextTypes.contains(type) else {
                throw DatabaseError("This column type cannot safely be used in a result update.")
            }
        }
        for index in edit.values.keys {
            guard columns[index].editable, !columns[index].isKey else { throw DatabaseError("This result column is read-only.") }
        }
        return keys
    }

    func mysqlPredicate(for edit: QueryRowEdit, includeOriginals: Bool) throws -> String {
        let keys = try mysqlValidatedIndices(for: edit)
        let indices = includeOriginals ? Set(keys).union(edit.values.keys).sorted() : keys
        let d = SQLDialect(flavor: .mysql)
        return try indices.map { index in
            let name = d.quoteIdentifier(columns[index].name)
            let value = Self.mysqlLiteral(edit.original[index])
            // Compare canonical display text byte-for-byte. Numeric-vs-string comparison would coerce to
            // DOUBLE and can conflate distinct BIGINT/DECIMAL keys beyond 2^53. Text comparisons must not
            // ignore case or trailing spaces under a case-insensitive/padded table collation either.
            let displayed = Self.mysqlTextTypes.contains(columns[index].mysqlType ?? "")
                ? "CONVERT(\(name) USING utf8mb4)" : "CAST(\(name) AS CHAR CHARACTER SET utf8mb4)"
            let exact = "CAST(\(displayed) AS BINARY) <=> CAST(\(value) AS BINARY)"
            guard columns[index].isKey, let key = edit.original[index] else { return exact }
            // Also give the optimizer an indexable equality, so FOR UPDATE locks one key rather than scanning.
            let lookup = Self.mysqlNumericTypes.contains(columns[index].mysqlType ?? "") ? try Self.mysqlNumericLiteral(key) : value
            return "\(name) = \(lookup) AND \(exact)"
        }.joined(separator: " AND ")
    }

    func mysqlStatement(for edit: QueryRowEdit) throws -> String {
        let predicate = try mysqlPredicate(for: edit, includeOriginals: true)
        let d = SQLDialect(flavor: .mysql)
        let assignments = edit.values.sorted { $0.key < $1.key }.map { index, value in
            "\(d.quoteIdentifier(columns[index].name)) = \(Self.mysqlLiteral(value))"
        }.joined(separator: ", ")
        return "UPDATE \(d.qualified(table)) SET \(assignments) WHERE \(predicate)"
    }
}

extension MySQLDriver {
    public func queryEditTarget(for result: QueryResult) async throws -> QueryEditTarget? {
        guard let source = EditableSelect.relation(result.statement, flavor: .mysql),
              let origins = result.mysqlOrigins, !origins.isEmpty, origins.count == result.columns.count,
              let first = origins.first, !first.schema.isEmpty, !first.originalTable.isEmpty, !first.table.isEmpty,
              origins.allSatisfy({ $0.schema == first.schema && $0.originalTable == first.originalTable &&
                  $0.table == first.table && !$0.originalName.isEmpty }),
              Set(origins.map(\.originalName)).count == origins.count,
              source.names.last == first.originalTable, source.reference == first.table else { return nil }
        let database: String?
        if source.names.count == 2 { database = source.names[0] }
        else { database = try await execute("SELECT DATABASE()").rows.first?.first ?? nil }
        guard database == first.schema else { return nil }
        let table = TableRef(schema: first.schema, name: first.originalTable)
        // information_schema describes the permanent table even when this session is reading a temporary
        // table with the same name. The writer is another session: never let it write the permanent lookalike.
        let creation = try await execute("SHOW CREATE TABLE \(dialect.qualified(table))").rows
        guard creation.count == 1, creation[0].count >= 2, let ddl = creation[0][1],
              ddl.uppercased().hasPrefix("CREATE TABLE ") else { return nil }
        let whereTable = "TABLE_SCHEMA = \(QueryEditTarget.mysqlLiteral(table.schema)) AND TABLE_NAME = \(QueryEditTarget.mysqlLiteral(table.name))"
        let relation = try await execute("SELECT TABLE_TYPE, ENGINE FROM information_schema.TABLES WHERE \(whereTable)").rows
        guard relation.count == 1, relation[0] == ["BASE TABLE", "InnoDB"] else { return nil }
        let catalog = try await execute("""
            SELECT COLUMN_NAME, DATA_TYPE, COLUMN_TYPE, COLUMN_KEY, EXTRA, GENERATION_EXPRESSION,
                   CHARACTER_SET_NAME, COLLATION_NAME, IS_NULLABLE, ORDINAL_POSITION
            FROM information_schema.COLUMNS WHERE \(whereTable) ORDER BY ORDINAL_POSITION
            """).rows
        var columns: [String: QueryEditTarget.Column] = [:]
        for row in catalog {
            guard row.count == 10, let name = row[0], let type = row[1], let typeName = row[2],
                  let position = row[9].flatMap(Int16.init) else { return nil }
            let key = row[3] == "PRI"
            let scalar = QueryEditTarget.mysqlNumericTypes.contains(type) || QueryEditTarget.mysqlTextTypes.contains(type)
            let generated = !(row[5]?.isEmpty ?? false) || (row[4]?.uppercased().contains("GENERATED") ?? true)
            columns[name] = .init(name: name, attribute: position, typeOID: 0, typeName: typeName,
                                 isKey: key, editable: !key && !generated && scalar,
                                 mysqlType: type, mysqlDefinition: row)
        }
        let keys = columns.values.filter(\.isKey)
        guard !keys.isEmpty, keys.allSatisfy({
            QueryEditTarget.mysqlNumericTypes.contains($0.mysqlType ?? "") || QueryEditTarget.mysqlTextTypes.contains($0.mysqlType ?? "")
        }), keys.allSatisfy({ key in origins.contains { $0.originalName == key.name } }) else { return nil }
        var mapped: [QueryEditTarget.Column] = []
        for origin in origins {
            guard let column = columns[origin.originalName] else { return nil }
            // These wire types have exact text-protocol display forms. Reject binary/text confusion and any
            // unknown mapping rather than making a date, floating value, BIT or binary key writable.
            if QueryEditTarget.mysqlNumericTypes.contains(column.mysqlType ?? "") {
                guard [0, 1, 2, 3, 8, 9, 246].contains(origin.dataType) else { return nil }
            } else if QueryEditTarget.mysqlTextTypes.contains(column.mysqlType ?? "") {
                guard origin.characterSet != 63, [15, 249, 250, 251, 252, 253, 254].contains(origin.dataType) else { return nil }
            }
            mapped.append(column)
        }
        guard mapped.contains(where: \.editable) else { return nil }
        let identity = try await mysqlTableIdentity(table)
        return QueryEditTarget(table: table, tableOID: 0, columns: mapped, kind: .mysql, mysqlTableIdentity: identity)
    }

    /// Dictionary IDs are intentionally required: CREATE_TIME and a matching column shape cannot distinguish
    /// DROP/CREATE in the same second. Servers/accounts without dictionary visibility remain read-only.
    private func mysqlTableIdentity(_ table: TableRef) async throws -> String {
        let name = QueryEditTarget.mysqlLiteral(table.schema + "/" + table.name)
        for dictionary in ["INNODB_TABLES", "INNODB_SYS_TABLES"] {
            if let rows = try? await execute("SELECT TABLE_ID FROM information_schema.\(dictionary) WHERE NAME = \(name)").rows,
               rows.count == 1, let id = rows[0].first ?? nil, UInt64(id) != nil { return id }
        }
        throw DatabaseError("Tabula couldn't prove this table's persistent InnoDB identity, so the result stays read-only. This needs the PROCESS privilege, and table or database names that MySQL stores in encoded form (such as names with hyphens) aren't supported yet.")
    }

    /// The caller supplies a separate session; never commit an interactive user transaction implicitly.
    public func commitQueryEdits(_ edits: [QueryRowEdit], target: QueryEditTarget) async throws -> [Int: [String?]] {
        guard !edits.isEmpty else { return [:] }
        guard target.kind == .mysql, target.mysqlTableIdentity != nil,
              Set(edits.map(\.row)).count == edits.count else { throw DatabaseError("Invalid MySQL result edit.") }
        let statements = try edits.map { try target.statement(for: $0) }
        // These are session settings on the disposable writer connection. Strict mode prevents silent numeric
        // truncation, character replacement or NOT NULL coercion from being reported as a successful edit.
        _ = try await execute("SET SESSION innodb_lock_wait_timeout = 5")
        _ = try await execute("SET SESSION lock_wait_timeout = 5")
        _ = try await execute("SET SESSION sql_mode = CONCAT_WS(',', @@SESSION.sql_mode, 'STRICT_ALL_TABLES', 'NO_ENGINE_SUBSTITUTION', 'NO_BACKSLASH_ESCAPES')")
        _ = try await execute("START TRANSACTION")
        do {
            let projected = target.columns.map { dialect.quoteIdentifier($0.name) }.joined(separator: ", ")
            let from = "SELECT \(projected) FROM \(dialect.qualified(target.table))"
            // Acquire a transaction-duration metadata lock before catalog revalidation. A view replacement,
            // engine change or ALTER after the original query must never redirect a stale write.
            _ = try await execute(from + " LIMIT 0 FOR UPDATE")
            // MySQLNIO doesn't expose column definitions for an empty result. Probe one row for wire metadata;
            // an empty table is a conflict anyway. Give the probe a plain statement for the whitelist parser.
            var probe = try await execute(from + " LIMIT 1")
            probe.statement = from
            guard let current = try await queryEditTarget(for: probe), current.table == target.table,
                  current.mysqlTableIdentity == target.mysqlTableIdentity, current.columns == target.columns else {
                throw DatabaseError("The source table changed. Run the query again before editing.")
            }
            var returned: [Int: [String?]] = [:]
            for (edit, sql) in zip(edits, statements) {
                let predicate = try target.mysqlPredicate(for: edit, includeOriginals: true)
                let matched = try await execute(from + " WHERE " + predicate + " FOR UPDATE")
                guard matched.rows.count == 1 else { throw Self.mysqlEditConflict }
                let updated = try await execute(sql)
                // We already proved and locked exactly one matched row. MySQL reports *changed* rows, which
                // can be zero for a legitimate no-op such as DECIMAL 1.00 -> 1.0, or one with FOUND_ROWS enabled.
                guard let affected = updated.affectedRows, affected == 0 || affected == 1 else { throw Self.mysqlEditConflict }
                let key = try target.mysqlPredicate(for: edit, includeOriginals: false)
                let after = try await execute(from + " WHERE " + key + " FOR UPDATE")
                guard after.rows.count == 1 else { throw Self.mysqlEditConflict }
                returned[edit.row] = after.rows[0]
            }
            _ = try await execute("COMMIT")
            return returned
        } catch {
            _ = try? await execute("ROLLBACK")
            throw error
        }
    }

    private static var mysqlEditConflict: DatabaseError {
        DatabaseError("The row changed or was removed since this query ran. Nothing was saved; run the query again.")
    }
}
