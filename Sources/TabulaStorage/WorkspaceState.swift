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

    /// PostgreSQL: the database the window had moved to; nil for the saved connection's own.
    public var database: String?
    public var schema: String?
    public var tabs: [Tab]
    /// The selected tab, an index into `tabs`.
    public var selected: Int?
    /// Query history, newest first.
    public var history: [String]

    public init(
        database: String? = nil,
        schema: String? = nil,
        tabs: [Tab] = [],
        selected: Int? = nil,
        history: [String] = []
    ) {
        self.database = database
        self.schema = schema
        self.tabs = tabs
        self.selected = selected
        self.history = history
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
