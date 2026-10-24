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
    /// Queries remembered in a workspace's history.
    public static let historyLimit = 200
    /// Entries kept in the console log; older ones are dropped.
    public static let consoleLogLimit = 1000

    public enum Redis {
        /// COUNT hint for SCAN / HSCAN / SSCAN / ZSCAN.
        public static let scanBatch = 500
        /// Bytes of a value shown in the keys table.
        public static let previewLength = 200
        /// Elements loaded per page of a collection.
        public static let pageSize = 200
        /// The server default for `databases`, used when CONFIG GET is not allowed.
        public static let databaseCount = 16
    }

    public enum Metrics {
        /// Largest tables listed in the metrics view.
        public static let tableLimit = 25
        public static let refreshInterval: Double = 3
        public static let refreshChoices: [Double] = [1, 3, 5, 10, 30]
        /// How much history the charts keep.
        public static let historySeconds: Double = 600
    }

    public enum Diagram {
        /// Tables drawn in the relationship diagram; bigger schemas are cut off with a notice.
        public static let tableLimit = 200
    }

    public enum Updates {
        public static let requestTimeout: Double = 20
        public static let checkInterval: TimeInterval = 24 * 60 * 60
        /// Download progress is reported in steps of this fraction.
        public static let progressStep = 0.01
    }
}

/// Fixed values defined by the database protocols.
enum ProtocolConstants {
    /// MySQL ER_UNSUPPORTED_PS: the statement can't be prepared and must be sent as text.
    static let mysqlUnsupportedPreparedStatement: UInt16 = 1295
    /// Redis PTTL replies.
    static let redisNoExpiry = -1
    static let redisMissingKey = -2
}
