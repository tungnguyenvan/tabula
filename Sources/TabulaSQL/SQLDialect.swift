import Foundation
import TabulaFoundation

/// The SQL of one flavor: identifier quoting, literals, the statements Tabula writes for browsing and editing
/// tables, and how scripts are split, formatted and limited.
public struct SQLDialect: QueryDialect, Equatable {
    public let flavor: SQLFlavor

    public init(flavor: SQLFlavor) { self.flavor = flavor }

    public var lexicalRules: LexicalRules { flavor.lexicalRules }
    public var sql: SQLDialect? { self }

    public func quoteIdentifier(_ name: String) -> String {
        switch flavor {
        case .mysql: "`" + name.replacingOccurrences(of: "`", with: "``") + "`"
        case .postgres, .sqlite: "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
    }

    /// SQLite's main database needs no prefix.
    public func qualified(_ table: TableRef) -> String {
        if flavor == .sqlite && table.schema == "main" { return quoteIdentifier(table.name) }
        return quoteIdentifier(table.schema) + "." + quoteIdentifier(table.name)
    }

    /// A value of a column that holds bytes: `\x…` hex becomes a hex literal (PostgreSQL reads the `\x` text form
    /// itself); anything else in the column was typed as text and is written as text.
    public func literal(_ value: String?, binary: Bool) -> String {
        guard binary, let value, flavor != .postgres, let hex = BinaryText.hexDigits(value) else {
            return literal(value)
        }
        return "X'\(hex.uppercased())'"
    }

    public func literal(_ value: String?) -> String {
        guard let value else {
            return "NULL"
        }
        // MySQL reads a backslash as an escape unless the server's sql_mode has NO_BACKSLASH_ESCAPES, which Tabula
        // can't know: a value with one is written in hex, which reads the same in either mode.
        if flavor == .mysql, value.contains("\\") {
            return "_utf8mb4 X'" + BinaryText.hex(value.utf8) + "'"
        }
        return "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    public var beginTransaction: String? {
        flavor == .mysql ? "START TRANSACTION" : "BEGIN"
    }

    private func whereClause(_ filter: String?) -> String {
        guard let filter = filter?.trimmingCharacters(in: .whitespacesAndNewlines), !filter.isEmpty else { return "" }
        return " WHERE " + filter
    }

    public func selectPage(_ request: TablePageRequest) -> String {
        var sql = "SELECT * FROM \(qualified(request.table))" + whereClause(request.filter)
        if let orderBy = request.orderBy {
            sql += " ORDER BY \(quoteIdentifier(orderBy)) \(request.ascending ? "ASC" : "DESC")"
        }
        return sql + " LIMIT \(request.limit) OFFSET \(request.offset)"
    }

    public func countRows(_ table: TableRef, filter: String?) -> String {
        "SELECT COUNT(*) FROM \(qualified(table))" + whereClause(filter)
    }

    /// Without a key nothing may match: an empty predicate would touch every row.
    private func matchPrimaryKey(_ key: [(column: String, value: String?)], binaryColumns: Set<String>) -> String {
        guard !key.isEmpty else {
            return "1 = 0"
        }
        return
            key.map { pair in
                pair.value == nil
                    ? "\(quoteIdentifier(pair.column)) IS NULL"
                    : "\(quoteIdentifier(pair.column)) = \(literal(pair.value, binary: binaryColumns.contains(pair.column)))"
            }
            .joined(separator: " AND ")
    }

    /// `binaryColumns`: the names of the columns that hold bytes (see `literal(_:binary:)`).
    public func update(
        _ table: TableRef,
        set values: [(column: String, value: String?)],
        key: [(column: String, value: String?)],
        binaryColumns: Set<String>
    ) -> String {
        let assignments =
            values.map {
                "\(quoteIdentifier($0.column)) = \(literal($0.value, binary: binaryColumns.contains($0.column)))"
            }
            .joined(separator: ", ")
        return
            "UPDATE \(qualified(table)) SET \(assignments) WHERE \(matchPrimaryKey(key, binaryColumns: binaryColumns))"
    }

    public func delete(
        _ table: TableRef,
        key: [(column: String, value: String?)],
        binaryColumns: Set<String>
    ) -> String {
        "DELETE FROM \(qualified(table)) WHERE \(matchPrimaryKey(key, binaryColumns: binaryColumns))"
    }

    public func insert(
        _ table: TableRef,
        values: [(column: String, value: String?)],
        binaryColumns: Set<String>
    ) -> String {
        guard !values.isEmpty else {
            return flavor == .mysql
                ? "INSERT INTO \(qualified(table)) () VALUES ()"
                : "INSERT INTO \(qualified(table)) DEFAULT VALUES"
        }
        let columns = values.map { quoteIdentifier($0.column) }.joined(separator: ", ")
        let literals = values.map { literal($0.value, binary: binaryColumns.contains($0.column)) }
            .joined(separator: ", ")
        return "INSERT INTO \(qualified(table)) (\(columns)) VALUES (\(literals))"
    }

    /// Rows are matched by primary key; a table without one can only gain rows.
    public func statements(for changes: TableChanges) throws -> [String] {
        try plannedStatements(for: changes).map(\.sql)
    }

    /// The statements with what proves each update or delete reached its one row, so a row deleted meanwhile, or a
    /// key whose shown text doesn't equal the stored value (a MySQL FLOAT), fails the commit instead of saving
    /// nothing. PostgreSQL and SQLite count the rows a statement matched; MySQL counts only rows it changed, so
    /// there the row is counted first.
    public func plannedStatements(for changes: TableChanges) throws -> [PlannedStatement] {
        func key(_ row: Int) -> [(column: String, value: String?)] {
            changes.keyColumns.map { (changes.columns[$0], changes.rows[row][$0]) }
        }
        if changes.keyColumns.isEmpty, !changes.deleted.isEmpty || !changes.updates.isEmpty {
            throw DatabaseError("\(changes.table.name) has no primary key, so its rows can't be changed or deleted.")
        }
        let binary = Set(
            changes.binaryColumns.compactMap { changes.columns.indices.contains($0) ? changes.columns[$0] : nil }
        )
        func keyed(_ sql: String, row: Int) -> PlannedStatement {
            let match = matchPrimaryKey(key(row), binaryColumns: binary)
            return flavor == .mysql
                ? PlannedStatement(
                    sql: sql,
                    row: row,
                    check: "SELECT COUNT(*) FROM \(qualified(changes.table)) WHERE \(match)"
                )
                : PlannedStatement(sql: sql, row: row, mustAffectOne: true)
        }
        return changes.deleted.sorted()
            .map { keyed(delete(changes.table, key: key($0), binaryColumns: binary), row: $0) }
            + changes.updates.map {
                keyed(update(changes.table, set: $0.values, key: key($0.row), binaryColumns: binary), row: $0.row)
            }
            + changes.insertions.map { PlannedStatement(sql: insert(changes.table, values: $0, binaryColumns: binary)) }
    }

    public func selectSample(_ table: TableRef, limit: Int) -> String {
        "SELECT * FROM \(qualified(table)) LIMIT \(limit);"
    }

    public func truncate(_ table: TableRef) -> String {
        flavor == .sqlite ? "DELETE FROM \(qualified(table))" : "TRUNCATE TABLE \(qualified(table))"
    }

    public func drop(_ table: TableRef) -> String {
        "DROP \(table.kind == .view ? "VIEW" : "TABLE") \(qualified(table))"
    }

    public func statements(in script: String) -> [ScriptStatement] {
        SQLSplitter.statements(in: script, flavor: flavor)
    }

    public func beautify(_ script: String) -> String {
        SQLFormatter.format(script, flavor: flavor)
    }

    /// Adds `LIMIT n` to a plain SELECT that has no LIMIT of its own. Writes, an existing LIMIT / FETCH and locking
    /// clauses are left alone.
    public func applyingRowLimit(_ statement: String, limit: Int) -> String {
        let tokens = SQLLexer.tokens(statement, flavor: flavor)
        let significant = tokens.filter { $0.kind != .whitespace && $0.kind != .comment }
        guard let first = significant.first, first.keyword == "SELECT" || first.keyword == "WITH" else {
            return statement
        }
        var depth = 0
        for token in significant {
            if token.text == "(" { depth += 1 } else if token.text == ")" { depth -= 1 }
            guard depth == 0 else { continue }
            if ["LIMIT", "FETCH", "FOR", "INTO", "INSERT", "UPDATE", "DELETE", "TOP", "OFFSET"].contains(token.keyword)
            {
                return statement
            }
        }
        guard let last = significant.last(where: { $0.text != ";" }) else {
            return statement
        }
        let text = statement as NSString
        let end = NSMaxRange(last.range)
        return text.substring(to: end) + " LIMIT \(limit)" + text.substring(from: end)
    }

    public func readOnlyViolation(_ statement: String) -> String? {
        SQLReadOnlyCheck.violation(statement, flavor: flavor)
    }

    public func role(ofWord word: SQLToken) -> WordRole? {
        SQLKeywords.set.contains(word.keyword) ? .keyword : nil
    }

    @MainActor
    public func completions(
        in text: String,
        caret: Int,
        catalog: any CompletionCatalog
    ) -> (range: NSRange, items: [String]) {
        let context = SQLCompletion.context(in: text, caret: caret, flavor: flavor, schemas: catalog.schemaNames)
        let items = SQLCompletion.suggestions(
            for: context,
            tables: catalog.tableNames,
            columns: { catalog.columnNames(of: $0) },
            allColumns: catalog.allColumnNames,
            tablesInSchema: { catalog.tableNames(inSchema: $0) }
        )
        return (context.partialRange, items)
    }

    public func referencedTables(in text: String) -> [SQLCompletion.TableName] {
        SQLCompletion.tables(in: text, flavor: flavor)
    }
}
