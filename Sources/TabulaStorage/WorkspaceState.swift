import Foundation
import TabulaFoundation

/// What a connection's workspace had open, saved per connection so that opening it again brings it back.
public struct WorkspaceState: Codable, Equatable, Sendable {
    public enum Tab: Codable, Equatable, Sendable {
        /// A query tab: its title and SQL, and the .sql file it is tied to (the SQL may hold edits not saved to it).
        case query(title: String, sql: String, file: URL?)
        /// A table tab; `kind` is a `TableKind` and `mode` the tab's mode (Data, Structure), as raw values.
        case table(schema: String, name: String, kind: String, mode: String)
    }

    /// A table of the connection: `database` is the database it was in (PostgreSQL; nil where the connection
    /// reaches one database or lists databases as schemas).
    public struct TableKey: Codable, Hashable, Sendable {
        public var database: String?
        public var schema: String
        public var name: String

        public init(database: String?, schema: String, name: String) {
            self.database = database
            self.schema = schema
            self.name = name
        }
    }

    /// A table's filter bar: its visual rules or raw SQL condition, and the condition the rows were filtered by.
    public struct TableFilter: Codable, Equatable, Sendable {
        public struct Rule: Codable, Equatable, Sendable {
            public var column: String
            /// A `FilterRule.Operator` raw value.
            public var op: String
            public var value: String
            /// A `FilterRule.Conjunction` raw value.
            public var conjunction: String
            /// Whether the rule's checkbox is ticked.
            public var enabled: Bool

            public init(column: String, op: String, value: String, conjunction: String, enabled: Bool) {
                self.column = column
                self.op = op
                self.value = value
                self.conjunction = conjunction
                self.enabled = enabled
            }

            public init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                column = try container.decode(String.self, forKey: .column)
                op = try container.decode(String.self, forKey: .op)
                value = try container.decode(String.self, forKey: .value)
                conjunction = try container.decode(String.self, forKey: .conjunction)
                // Rules saved by 0.7.1 had no checkbox: every one was used.
                enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
            }
        }

        public var rules: [Rule]
        public var rawCondition: String
        public var usesRawCondition: Bool
        /// The SQL condition applied to the rows, exactly as it ran; empty when the filter wasn't applied. The bar
        /// may hold edits made after applying it.
        public var appliedCondition: String

        public init(rules: [Rule], rawCondition: String, usesRawCondition: Bool, appliedCondition: String) {
            self.rules = rules
            self.rawCondition = rawCondition
            self.usesRawCondition = usesRawCondition
            self.appliedCondition = appliedCondition
        }
    }

    public struct TableFilterEntry: Codable, Equatable, Sendable {
        public var table: TableKey
        public var filter: TableFilter

        public init(table: TableKey, filter: TableFilter) {
            self.table = table
            self.filter = filter
        }
    }

    /// PostgreSQL: the database the window had moved to; nil for the saved connection's own.
    public var database: String?
    public var schema: String?
    public var tabs: [Tab]
    /// The selected tab, an index into `tabs`.
    public var selected: Int?
    /// Query history, newest first.
    public var history: [String]
    /// The last filter of each table that had one, open in a tab or not.
    public var tableFilters: [TableFilterEntry]

    public init(
        database: String? = nil,
        schema: String? = nil,
        tabs: [Tab] = [],
        selected: Int? = nil,
        history: [String] = [],
        tableFilters: [TableFilterEntry] = []
    ) {
        self.database = database
        self.schema = schema
        self.tabs = tabs
        self.selected = selected
        self.history = history
        self.tableFilters = tableFilters
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        database = try container.decodeIfPresent(String.self, forKey: .database)
        schema = try container.decodeIfPresent(String.self, forKey: .schema)
        tabs = try container.decode([Tab].self, forKey: .tabs)
        selected = try container.decodeIfPresent(Int.self, forKey: .selected)
        history = try container.decode([String].self, forKey: .history)
        // States saved before 0.7.1 have no filters.
        tableFilters = try container.decodeIfPresent([TableFilterEntry].self, forKey: .tableFilters) ?? []
    }
}

/// Saved workspace states, one JSON file per connection in Application Support/Tabula/Workspaces.
public struct WorkspaceStateStore: Sendable {
    public let directory: URL

    /// `base` is the folder that holds connections.json (nil: Application Support/Tabula).
    public init(base: URL? = nil) {
        let root =
            base
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tabula", isDirectory: true)
        directory = root.appendingPathComponent("Workspaces", isDirectory: true)
    }

    private func fileURL(_ connection: UUID) -> URL {
        directory.appendingPathComponent("\(connection.uuidString).json")
    }

    /// Nil when nothing was saved or the file can't be read (an older or damaged one is ignored, then replaced).
    public func load(_ connection: UUID) -> WorkspaceState? {
        guard let data = try? Data(contentsOf: fileURL(connection)) else { return nil }
        return try? JSONDecoder().decode(WorkspaceState.self, from: data)
    }

    public func save(_ state: WorkspaceState, for connection: UUID) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: fileURL(connection), options: .atomic)
    }

    /// Removes a connection's state, when the connection is deleted.
    public func remove(_ connection: UUID) {
        try? FileManager.default.removeItem(at: fileURL(connection))
    }

    /// Removes every saved state, when remembering them is turned off.
    public func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }
}
