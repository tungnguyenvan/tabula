import Foundation

/// Identifier quoting, literals and the SQL Tabula generates for table browsing and editing.
public struct SQLDialect: Sendable {
    public var kind: DatabaseKind

    public init(kind: DatabaseKind) { self.kind = kind }

    public func quoteIdentifier(_ name: String) -> String {
        switch kind {
        case .mysql:
            return "`" + name.replacingOccurrences(of: "`", with: "``") + "`"
        case .postgres, .sqlite, .redis:
            return "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
    }

    public func qualified(_ table: TableRef) -> String {
        if kind == .sqlite && table.schema == "main" {
            return quoteIdentifier(table.name)
        }
        return quoteIdentifier(table.schema) + "." + quoteIdentifier(table.name)
    }

    public func literal(_ value: String?) -> String {
        guard let value else { return "NULL" }
        var escaped = value.replacingOccurrences(of: "'", with: "''")
        if kind == .mysql {
            // MySQL treats backslash as an escape character unless NO_BACKSLASH_ESCAPES is set.
            escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "''")
        }
        return "'" + escaped + "'"
    }

    public var beginTransaction: String {
        kind == .mysql ? "START TRANSACTION" : "BEGIN"
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
        sql += " LIMIT \(request.limit) OFFSET \(request.offset)"
        return sql
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
            return kind == .mysql
                ? "INSERT INTO \(qualified(table)) () VALUES ()"
                : "INSERT INTO \(qualified(table)) DEFAULT VALUES"
        }
        let columns = values.map { quoteIdentifier($0.column) }.joined(separator: ", ")
        let literals = values.map { literal($0.value) }.joined(separator: ", ")
        return "INSERT INTO \(qualified(table)) (\(columns)) VALUES (\(literals))"
    }

    public func truncate(_ table: TableRef) -> String {
        kind == .sqlite ? "DELETE FROM \(qualified(table))" : "TRUNCATE TABLE \(qualified(table))"
    }

    public func drop(_ table: TableRef) -> String {
        "DROP \(table.kind == .view ? "VIEW" : "TABLE") \(qualified(table))"
    }
}
