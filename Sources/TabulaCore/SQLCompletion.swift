import Foundation

/// Context-aware completion for the SQL editor: table names after FROM / JOIN, a table's columns after
/// `alias.`, and otherwise keywords plus the tables and columns the statement already uses.
public enum SQLCompletion {
    public enum Scope: Equatable, Sendable {
        /// Table names; `schema` is set when the user typed `schema.`.
        case tables(schema: String?)
        /// Columns of the table behind `qualifier` (a table name or alias), in `schema` when written as
        /// `schema.table.`.
        case columns(qualifier: String, schema: String?)
        case anything
    }

    /// A table as written in the statement: `orders`, or `sales.orders` with its schema.
    public struct TableName: Hashable, Comparable, Sendable {
        public var schema: String?
        public var name: String

        public init(schema: String? = nil, name: String) {
            self.schema = schema
            self.name = name
        }

        public static func < (lhs: TableName, rhs: TableName) -> Bool {
            (lhs.schema ?? "", lhs.name) < (rhs.schema ?? "", rhs.name)
        }
    }

    public struct Context: Equatable, Sendable {
        /// The word being typed, which a completion replaces (UTF-16).
        public var partialRange: NSRange
        public var partial: String
        public var scope: Scope
        /// alias or table name (lower-cased) → the table, for the statement around the caret.
        public var tables: [String: TableName]
    }

    /// Words after which a table name is expected.
    private static let tableKeywords: Set<String> = ["FROM", "JOIN", "INTO", "UPDATE", "TABLE", "DESCRIBE", "DESC", "TRUNCATE"]
    /// Words that can't be an alias after a table name.
    private static let notAliases: Set<String> = SQLKeywords.set

    /// `schemas` are the database's schema names, so `sales.` is read as a schema rather than an alias.
    public static func context(in text: String, caret: Int, kind: DatabaseKind, schemas: [String] = []) -> Context {
        let statement = SQLSplitter.statement(at: caret, in: text, kind: kind)
        let base = statement?.range.location ?? 0
        let tokens = SQLLexer.tokens(text, kind: kind)
        let before = tokens.filter { $0.range.location < caret }

        var partialRange = NSRange(location: caret, length: 0)
        var partial = ""
        var rest = before
        if let last = before.last, last.kind == .word, NSMaxRange(last.range) == caret {
            partialRange = last.range
            partial = last.text
            rest.removeLast()
        }
        let significant = rest.filter { $0.kind != .whitespace && $0.kind != .comment }
        let statementTokens = tokens.filter { $0.range.location >= base && (statement.map { $0.range.location + $0.range.length + 1 } ?? Int.max) > $0.range.location }
        let statementTables = referencedTables(statementTokens)
        let scope: Scope
        if let dot = significant.last, dot.text == ".", significant.count >= 2,
           NSMaxRange(dot.range) == partialRange.location {
            let qualifier = unquoted(significant[significant.count - 2].text)
            // `FROM sales.` (or any known schema name) names a schema; otherwise `x.` is a table or alias.
            let afterTableKeyword = significant.count >= 3 && tableKeywords.contains(significant[significant.count - 3].keyword)
            // An alias defined in the statement wins over a schema of the same name.
            let isAlias = statementTables.keys.contains(qualifier.lowercased())
            let isSchema = afterTableKeyword || (!isAlias && schemas.contains { $0.caseInsensitiveCompare(qualifier) == .orderedSame })
            // schema.table. - the word before the qualifier is itself followed by a dot.
            let schema = significant.count >= 4 && significant[significant.count - 3].text == "."
                ? unquoted(significant[significant.count - 4].text) : nil
            scope = isSchema && schema == nil ? .tables(schema: qualifier) : .columns(qualifier: qualifier, schema: schema)
        } else if let previous = significant.last, tableKeywords.contains(previous.keyword) {
            scope = .tables(schema: nil)
        } else {
            scope = .anything
        }
        return Context(partialRange: partialRange, partial: partial, scope: scope, tables: statementTables)
    }

    /// Every table a statement names after FROM / JOIN / UPDATE / INTO.
    public static func tables(in sql: String, kind: DatabaseKind) -> [TableName] {
        Array(Set(referencedTables(SQLLexer.tokens(sql, kind: kind)).values)).sorted()
    }

    /// Tables named after FROM / JOIN / UPDATE / INTO, keyed by alias and by name.
    static func referencedTables(_ tokens: [SQLToken]) -> [String: TableName] {
        let words = tokens.filter { $0.kind != .whitespace && $0.kind != .comment }
        var result: [String: TableName] = [:]
        var index = 0
        while index < words.count {
            guard tableKeywords.contains(words[index].keyword), index + 1 < words.count else { index += 1; continue }
            var position = index + 1
            var schema: String?
            if position + 2 < words.count, words[position + 1].text == "." {
                schema = unquoted(words[position].text)
                position += 2
            }
            let nameToken = words[position]
            guard nameToken.kind == .word || nameToken.kind == .quotedIdentifier else { index += 1; continue }
            let name = TableName(schema: schema, name: unquoted(nameToken.text))
            result[name.name.lowercased()] = name
            var aliasIndex = position + 1
            if aliasIndex < words.count, words[aliasIndex].keyword == "AS" { aliasIndex += 1 }
            if aliasIndex < words.count, words[aliasIndex].kind == .word || words[aliasIndex].kind == .quotedIdentifier,
               !notAliases.contains(words[aliasIndex].keyword) {
                result[unquoted(words[aliasIndex].text).lowercased()] = name
            }
            index = position + 1
        }
        return result
    }

    /// Ranked suggestions for `context`. `columns` returns a table's columns when they are known.
    /// `allColumns` are columns of every known table, offered when the statement names no table yet
    /// (for example `SELECT na` before the FROM clause is written).
    /// `tablesInSchema` returns another schema's tables when known (nil while they load).
    public static func suggestions(for context: Context, tables: [String], columns: (TableName) -> [String]?,
                                   allColumns: [String] = [], tablesInSchema: (String) -> [String]? = { _ in nil }) -> [String] {
        // Groups in priority order: what the statement uses comes before everything else.
        let groups: [[String]]
        switch context.scope {
        case .tables(let schema):
            groups = [schema.map { tablesInSchema($0) ?? [] } ?? tables]
        case .columns(let qualifier, let schema):
            // An explicit schema.table wins; otherwise the alias or name as the statement defines it.
            let table = schema.map { TableName(schema: $0, name: qualifier) }
                ?? context.tables[qualifier.lowercased()] ?? TableName(name: qualifier)
            groups = [columns(table) ?? []]
        case .anything:
            guard !context.partial.isEmpty else { return [] }
            let usedColumns = context.tables.isEmpty ? allColumns : Set(context.tables.values).sorted().flatMap { columns($0) ?? [] }
            // Match the user's case for keywords.
            let keywords = context.partial.first?.isLowercase == true ? SQLKeywords.all.map { $0.lowercased() } : SQLKeywords.all
            groups = [usedColumns, tables, keywords]
        }
        let partial = context.partial.lowercased()
        var seen = Set<String>()
        return groups.flatMap { group in
            group.filter { $0.lowercased().hasPrefix(partial) && $0.count > partial.count }
                .sorted { ($0.count, $0) < ($1.count, $1) }
        }
        .filter { seen.insert($0.lowercased()).inserted }
    }

    private static func unquoted(_ name: String) -> String {
        guard let first = name.first, ["\"", "`"].contains(first), name.count >= 2 else { return name }
        return String(name.dropFirst().dropLast())
    }
}
