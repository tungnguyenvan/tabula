import Foundation

/// Every tunable default in one place. Values a user may want to change are also exposed in Settings
/// (the app passes them back in); the rest are protocol or safety limits.
public enum Defaults {
    public static let applicationName = "Tabula"
    /// Host used when a connection leaves it blank.
    public static let host = "127.0.0.1"
    /// How long connecting (name resolution, TCP, TLS and authentication) may take before giving up.
    public static let connectTimeout: Double = 15
    /// Rows fetched per page of a table.
    public static let pageSize = 300
    public static let pageSizeChoices = [100, 300, 1000, 5000]
    /// How long SQLite waits on a locked database before failing a statement.
    public static let sqliteBusyTimeoutMilliseconds: Int32 = 5000
    /// Rows a query tab's SELECT returns unless it sets its own LIMIT; nil runs it as written.
    public static let queryRowLimit: Int? = 300
    public static let queryRowLimitChoices = [100, 300, 1000, 5000]
    /// Tables whose columns are loaded up front for SQL completion; larger schemas load on demand.
    public static let completionPrefetchLimit = 300
    /// Queries remembered in a workspace's history.
    public static let historyLimit = 200
    /// Seconds between saves of an open workspace's tabs (when they changed), so a crash loses little.
    public static let workspaceStateSaveInterval: Double = 10
    /// Rows the sidebar's "New Query" asks for.
    public static let sampleQueryLimit = 100
    /// Entries kept in the console log; older ones are dropped.
    public static let consoleLogLimit = 1000
    /// Seconds a command-line tool gets to exit after being asked to stop.
    public static let processTerminateGrace: Double = 2
    /// Characters of a command-line tool's error output shown in a message.
    public static let toolErrorLength = 400






}
