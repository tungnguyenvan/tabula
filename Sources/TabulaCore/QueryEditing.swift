import Foundation

/// PostgreSQL's origin for a result column. Display aliases are never used to construct updates.
public struct QueryColumnOrigin: Sendable, Equatable {
    public var tableOID: UInt32
    public var attribute: Int16
    public init(tableOID: UInt32, attribute: Int16) { self.tableOID = tableOID; self.attribute = attribute }
}

/// A verified, single base-table result with its complete primary key. Attribute numbers keep aliases and quoted
/// names unambiguous. Unsupported data types, generated columns and key columns stay read-only.
public struct QueryEditTarget: Sendable {
    public var table: TableRef
    public var tableOID: UInt32
    public var kind: DatabaseKind
    /// Persistent InnoDB dictionary ID; unlike names or CREATE_TIME this changes after DROP/CREATE.
    public var mysqlTableIdentity: String?
    public var columns: [Column]
    public struct Column: Sendable, Equatable {
        public var name: String
        public var attribute: Int16
        public var typeOID: UInt32
        public var typeName: String
        public var isKey: Bool
        public var editable: Bool
        public var mysqlType: String?
        public var mysqlDefinition: [String?]?
        public init(name: String, attribute: Int16, typeOID: UInt32, typeName: String, isKey: Bool, editable: Bool, mysqlType: String? = nil, mysqlDefinition: [String?]? = nil) {
            self.name = name; self.attribute = attribute; self.typeOID = typeOID; self.typeName = typeName
            self.isKey = isKey; self.editable = editable
            self.mysqlType = mysqlType; self.mysqlDefinition = mysqlDefinition
        }
    }
    public init(table: TableRef, tableOID: UInt32, columns: [Column], kind: DatabaseKind = .postgres, mysqlTableIdentity: String? = nil) {
        self.table = table; self.tableOID = tableOID; self.columns = columns
        self.kind = kind; self.mysqlTableIdentity = mysqlTableIdentity
    }

    /// Text whose PostgreSQL display representation round-trips without a time zone, locale or binary codec.
    public static let scalarTypes: Set<UInt32> = [16, 20, 21, 23, 25, 1042, 1043, 1700, 2950]

    public func editableRow(_ row: Int, in rows: [[String?]]) -> Bool {
        guard rows.indices.contains(row), rows[row].count == columns.count else { return false }
        let keys = columns.indices.filter { columns[$0].isKey }
        guard !keys.isEmpty, keys.allSatisfy({ rows[row][$0] != nil }) else { return false }
        return rows.indices.allSatisfy { other in
            other == row || !keys.allSatisfy { rows[other].indices.contains($0) && rows[other][$0] == rows[row][$0] }
        }
    }

    public func statement(for edit: QueryRowEdit) throws -> String {
        if kind == .mysql { return try mysqlStatement(for: edit) }
        guard kind == .postgres else { throw DatabaseError("Editing is not supported for this database.") }
        guard edit.original.count == columns.count, !edit.values.isEmpty else { throw DatabaseError("Invalid result edit.") }
        let keyIndices = columns.indices.filter { columns[$0].isKey }
        guard !keyIndices.isEmpty, keyIndices.allSatisfy({ edit.original[$0] != nil }) else {
            throw DatabaseError("A complete primary key is required to edit a result row.")
        }
        let d = SQLDialect(flavor: .postgres)
        // E strings are independent of standard_conforming_strings, including backslashes in pasted values.
        func literal(_ value: String?, column: Column) throws -> String {
            guard let value else { return "NULL" }
            guard !value.contains("\0") else { throw DatabaseError("PostgreSQL text values cannot contain a NUL character.") }
            let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "''")
            let types: [UInt32: String] = [16: "bool", 20: "int8", 21: "int2", 23: "int4", 25: "text", 1042: "bpchar", 1043: "varchar", 1700: "numeric", 2950: "uuid"]
            guard let type = types[column.typeOID] else { throw DatabaseError("This column type cannot safely be used in a result update.") }
            return "E'\(escaped)'::pg_catalog.\(type)"
        }
        var assignments: [String] = []
        for (index, value) in edit.values.sorted(by: { $0.key < $1.key }) {
            guard columns.indices.contains(index), columns[index].editable, !columns[index].isKey else {
                throw DatabaseError("This result column is read-only.")
            }
            assignments.append("\(d.quoteIdentifier(columns[index].name)) = \(try literal(value, column: columns[index]))")
        }
        // Match the old edited values too: don't silently overwrite a concurrent change.
        let matched = Set(keyIndices).union(edit.values.keys).sorted()
        let predicate = try matched.map { index in
            "\(d.quoteIdentifier(columns[index].name)) IS NOT DISTINCT FROM \(try literal(edit.original[index], column: columns[index]))"
        }.joined(separator: " AND ")
        return "UPDATE ONLY \(d.qualified(table)) SET \(assignments.joined(separator: ", ")) WHERE \(predicate) RETURNING "
            + columns.map { d.quoteIdentifier($0.name) }.joined(separator: ", ")
    }
}

public struct QueryRowEdit: Sendable {
    public var row: Int
    public var original: [String?]
    public var values: [Int: String?]
    public init(row: Int, original: [String?], values: [Int: String?]) {
        self.row = row; self.original = original; self.values = values
    }
}

extension DatabaseDriver {
    public func queryEditTarget(for result: QueryResult) async throws -> QueryEditTarget? { nil }
    public func commitQueryEdits(_ edits: [QueryRowEdit], target: QueryEditTarget) async throws -> [Int: [String?]] {
        throw DatabaseError("Editing query results is not supported by this driver.")
    }
}
