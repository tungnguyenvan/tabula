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
    /// Rows the sidebar's "New Query" asks for.
    public static let sampleQueryLimit = 100
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

    public enum Mongo {
        /// Documents read to learn a collection's fields (and their types) for the grid and completion.
        public static let sampleSize = 100
        /// Documents per round trip when a cursor needs more than one batch.
        public static let batchSize = 500
        /// Most documents one query returns into the results grid, whatever its own limit.
        public static let maxDocuments = 50_000
        /// Spaces per level when a document is written out over several lines.
        public static let indentWidth = 2
        /// Nested values up to this many characters stay on one line in pretty output.
        public static let inlineWidth = 60
        /// Database opened when the connection names none.
        public static let defaultDatabase = "test"
        /// Database that authenticates the user when the connection names none (the drivers' default).
        public static let authDatabase = "admin"
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
        /// Pause after the last keystroke before asking a model for an inline suggestion: remote providers,
        /// and models on this Mac (fast enough to ask sooner).
        public static let inlineDelay: Double = 0.6
        public static let localInlineDelay: Double = 0.25
        public static let inlineMaxTokens = 1024
        public static let generateMaxTokens = 16000
        public static let inlineTimeout: Double = 15
        public static let generateTimeout: Double = 120
        /// Built-in local models (llama.cpp): tokens of context, prompt batch size, buffer for one token's
        /// text, and how long an unused model stays in memory.
        public static let localContextLength: UInt32 = 8192
        public static let localBatchSize: UInt32 = 512
        public static let localPieceLength: Int32 = 256
        public static let localUnloadDelay: Double = 5 * 60
        /// Tokens a built-in model may write: a line while typing, a query for Ask AI.
        public static let localInlineTokens = 48
        /// A token repeated this many times in a row ends the answer.
        public static let localRepeatLimit = 3
        /// Longest suggestion shown while typing.
        public static let inlineMaxCharacters = 120
        public static let localGenerateTokens = 1024
        /// Earlier chat messages sent with each question, and characters of the editor's SQL.
        public static let chatHistoryMessages = 12
        public static let chatEditorLength = 8000
        /// Characters before the caret sent with an inline request.
        public static let inlineContextLength = 2000
        /// Foreign keys described to the model.
        public static let schemaForeignKeyLimit = 300
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
            /// Small enough to answer while the user types.
            public let forTyping: Bool
            public var id: String { name }
        }

        /// Light models that run well on a Mac, offered for download in Settings, smallest first.
        public static let recommendedLocalModels = [
            LocalModel(name: "qwen2.5-coder:0.5b", summary: "Fastest, about 0.4 GB. Good for suggestions while typing.", forTyping: true),
            LocalModel(name: "qwen2.5-coder:1.5b", summary: "About 1 GB. Fast suggestions that know SQL better.", forTyping: true),
            LocalModel(name: "deepseek-coder:1.3b", summary: "About 0.8 GB. Another fast code model.", forTyping: true),
            LocalModel(name: "qwen2.5-coder:3b", summary: "About 2 GB. Writes whole queries well on most Macs.", forTyping: false),
            LocalModel(name: "qwen2.5-coder:7b", summary: "About 5 GB, 16 GB of memory recommended. Best local queries.", forTyping: false),
            LocalModel(name: "sqlcoder:7b", summary: "About 4 GB. Tuned for SQL from a question.", forTyping: false),
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
