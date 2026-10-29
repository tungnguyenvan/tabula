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

    public func literal(_ value: String?) -> String {
        guard let value else { return "NULL" }
        // MySQL treats backslash as an escape character unless NO_BACKSLASH_ESCAPES is set.
        let unescaped = flavor.lexicalRules.backslashEscapes ? value.replacingOccurrences(of: "\\", with: "\\\\") : value
        return "'" + unescaped.replacingOccurrences(of: "'", with: "''") + "'"
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
    private func matchPrimaryKey(_ key: [(column: String, value: String?)]) -> String {
        guard !key.isEmpty else { return "1 = 0" }
        return key.map { pair in
            pair.value == nil
                ? "\(quoteIdentifier(pair.column)) IS NULL"
                : "\(quoteIdentifier(pair.column)) = \(literal(pair.value))"
        }.joined(separator: " AND ")
    }

    public func update(_ table: TableRef, set values: [(column: String, value: String?)], key: [(column: String, value: String?)]) -> String {
        let assignments = values.map { "\(quoteIdentifier($0.column)) = \(literal($0.value))" }.joined(separator: ", ")
        return "UPDATE \(qualified(table)) SET \(assignments) WHERE \(matchPrimaryKey(key))"
    }

    public func delete(_ table: TableRef, key: [(column: String, value: String?)]) -> String {
        "DELETE FROM \(qualified(table)) WHERE \(matchPrimaryKey(key))"
    }

    public func insert(_ table: TableRef, values: [(column: String, value: String?)]) -> String {
        guard !values.isEmpty else {
            return flavor == .mysql
                ? "INSERT INTO \(qualified(table)) () VALUES ()"
                : "INSERT INTO \(qualified(table)) DEFAULT VALUES"
        }
        let columns = values.map { quoteIdentifier($0.column) }.joined(separator: ", ")
        let literals = values.map { literal($0.value) }.joined(separator: ", ")
        return "INSERT INTO \(qualified(table)) (\(columns)) VALUES (\(literals))"
    }

    /// Rows are matched by primary key; a table without one can only gain rows.
    public func statements(for changes: TableChanges) throws -> [String] {
        func key(_ row: Int) -> [(column: String, value: String?)] {
            changes.keyColumns.map { (changes.columns[$0], changes.rows[row][$0]) }
        }
        if changes.keyColumns.isEmpty, !changes.deleted.isEmpty || !changes.updates.isEmpty {
            throw DatabaseError("\(changes.table.name) has no primary key, so its rows can't be changed or deleted.")
        }
        return changes.deleted.sorted().map { delete(changes.table, key: key($0)) }
            + changes.updates.map { update(changes.table, set: $0.values, key: key($0.row)) }
            + changes.insertions.map { insert(changes.table, values: $0) }
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
        guard let first = significant.first, first.keyword == "SELECT" || first.keyword == "WITH" else { return statement }
        var depth = 0
        for token in significant {
            if token.text == "(" { depth += 1 } else if token.text == ")" { depth -= 1 }
            guard depth == 0 else { continue }
            if ["LIMIT", "FETCH", "FOR", "INTO", "INSERT", "UPDATE", "DELETE", "TOP", "OFFSET"].contains(token.keyword) { return statement }
        }
        guard let last = significant.last(where: { $0.text != ";" }) else { return statement }
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

    public func completions(in text: String, caret: Int, catalog: any CompletionCatalog) -> (range: NSRange, items: [String]) {
        let context = SQLCompletion.context(in: text, caret: caret, flavor: flavor, schemas: catalog.schemaNames)
        let items = SQLCompletion.suggestions(for: context, tables: catalog.tableNames, columns: { catalog.columnNames(of: $0) },
                                              allColumns: catalog.allColumnNames, tablesInSchema: { catalog.tableNames(inSchema: $0) })
        return (context.partialRange, items)
    }

    public func referencedTables(in text: String) -> [SQLCompletion.TableName] {
        SQLCompletion.tables(in: text, flavor: flavor)
    }
}
