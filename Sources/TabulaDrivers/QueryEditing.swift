import Foundation
import TabulaFoundation
import TabulaSQL

/// A verified, single base-table result with its complete primary key. Attribute numbers keep aliases and quoted
/// names unambiguous. Unsupported data types, generated columns and key columns stay read-only.
public struct QueryEditTarget: Sendable {
    public var table: TableRef
    public var tableOID: UInt32
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
        public init(
            name: String,
            attribute: Int16,
            typeOID: UInt32,
            typeName: String,
            isKey: Bool,
            editable: Bool,
            mysqlType: String? = nil,
            mysqlDefinition: [String?]? = nil
        ) {
            self.name = name
            self.attribute = attribute
            self.typeOID = typeOID
            self.typeName = typeName
            self.isKey = isKey
            self.editable = editable
            self.mysqlType = mysqlType
            self.mysqlDefinition = mysqlDefinition
        }
    }
    /// Writes the statements for edits of this result.
    public let writer: any ResultEditWriter
    /// The database the result came from, as its writer knows it.
    public var kind: DatabaseKind { writer.kind }

    public init(
        table: TableRef,
        tableOID: UInt32,
        columns: [Column],
        writer: any ResultEditWriter,
        mysqlTableIdentity: String? = nil
    ) {
        self.table = table
        self.tableOID = tableOID
        self.columns = columns
        self.writer = writer
        self.mysqlTableIdentity = mysqlTableIdentity
    }

    public func editableRow(_ row: Int, in rows: [[String?]]) -> Bool {
        guard rows.indices.contains(row), rows[row].count == columns.count else { return false }
        let keys = columns.indices.filter { columns[$0].isKey }
        guard !keys.isEmpty, keys.allSatisfy({ rows[row][$0] != nil }) else { return false }
        return rows.indices.allSatisfy { other in
            other == row || !keys.allSatisfy { rows[other].indices.contains($0) && rows[other][$0] == rows[row][$0] }
        }
    }

    /// The statement that applies `edit`, written by the engine that made the target.
    public func statement(for edit: QueryRowEdit) throws -> String {
        try writer.statement(for: edit, in: self)
    }
}

/// Writes the UPDATE for one edited result row, matching the row by its key and by the old values of the edited
/// columns, so a concurrent change is reported rather than overwritten. Each engine that can edit results
/// supplies one.
public protocol ResultEditWriter: Sendable {
    /// The database the statements are written for.
    var kind: DatabaseKind { get }
    func statement(for edit: QueryRowEdit, in target: QueryEditTarget) throws -> String
}

public struct QueryRowEdit: Sendable {
    public var row: Int
    public var original: [String?]
    public var values: [Int: String?]
    public init(row: Int, original: [String?], values: [Int: String?]) {
        self.row = row
        self.original = original
        self.values = values
    }
}

extension DatabaseDriver {
    public func queryEditTarget(for result: QueryResult) async throws -> QueryEditTarget? { nil }
    public func commitQueryEdits(_ edits: [QueryRowEdit], target: QueryEditTarget) async throws -> [Int: [String?]] {
        throw DatabaseError("Editing query results is not supported by this driver.")
    }
}
