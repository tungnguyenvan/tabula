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

    public enum AI {
        /// Pause after the last keystroke before asking a model for an inline suggestion.
        public static let inlineDelay: Double = 0.6
        public static let inlineMaxTokens = 1024
        public static let generateMaxTokens = 16000
        public static let inlineTimeout: Double = 15
        public static let generateTimeout: Double = 120
        /// Characters before the caret sent with an inline request.
        public static let inlineContextLength = 2000
        /// Tables described to the model; larger schemas are cut off.
        public static let schemaTableLimit = 150
        public static let anthropicVersion = "2026-10-21"
        /// Seconds a command-line tool gets to exit after being asked to stop.
        public static let terminateGrace: Double = 2
        /// Characters of a failing tool's output shown in an error.
        public static let errorLength = 400

        public struct LocalModel: Sendable, Identifiable {
            public let name: String
            public let summary: String
            public var id: String { name }
        }

        /// Small models that run well on a Mac and are good at SQL, offered for download.
        public static let recommendedLocalModels = [
            LocalModel(name: "qwen2.5-coder:1.5b", summary: "Fastest; good for inline suggestions (about 1 GB)"),
            LocalModel(name: "qwen2.5-coder:7b", summary: "Better queries; needs 8 GB of memory or more (about 5 GB)"),
            LocalModel(name: "sqlcoder:7b", summary: "Tuned for writing SQL from a question (about 4 GB)"),
            LocalModel(name: "duckdb-nsql:7b", summary: "Text-to-SQL model (about 4 GB)"),
        ]
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
