import Foundation

/// PostgreSQL's origin for a result column. Display aliases are never used to construct updates.
public struct QueryColumnOrigin: Sendable, Equatable {
    public var tableOID: UInt32
    public var attribute: Int16
    public init(tableOID: UInt32, attribute: Int16) {
        self.tableOID = tableOID
        self.attribute = attribute
    }
}

/// SQLite's column metadata: the database (schema), table and column a result column reads, past any alias.
public struct SQLiteColumnOrigin: Sendable, Equatable {
    public var database: String
    public var table: String
    public var column: String

    public init(database: String, table: String, column: String) {
        self.database = database
        self.table = table
        self.column = column
    }
}

/// MySQL's wire metadata distinguishes display aliases from physical table and column names.
public struct MySQLQueryColumnOrigin: Sendable, Equatable {
    public var schema: String
    public var table: String
    public var originalTable: String
    public var originalName: String
    public var dataType: UInt32
    public var characterSet: UInt32

    public init(
        schema: String,
        table: String,
        originalTable: String,
        originalName: String,
        dataType: UInt32,
        characterSet: UInt32
    ) {
        self.schema = schema
        self.table = table
        self.originalTable = originalTable
        self.originalName = originalName
        self.dataType = dataType
        self.characterSet = characterSet
    }
}
