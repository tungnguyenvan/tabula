import Foundation
import TabulaDrivers
import TabulaFoundation
import TabulaSQL

extension Defaults {
    public enum AI {
        /// Pause after the last keystroke before asking a model for an inline suggestion: remote providers,
        /// and models on this Mac (fast enough to ask sooner).
        public static let inlineDelay: Double = 0.6
        public static let localInlineDelay: Double = 0.25
        public static let inlineMaxTokens = 1024
        public static let generateMaxTokens = 16000
        public static let inlineTimeout: Double = 15
        public static let generateTimeout: Double = 120
        /// Seconds a request waits for columns that aren't loaded yet, beyond the tables it names; on a slow or
        /// large database the rest of the schema goes without columns rather than holding the request up.
        public static let schemaWait: Double = 3
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
        /// The chat assistant's tools: model turns per answer, rows and characters a query result may send,
        /// and how much of an earlier answer's tool results later questions still see.
        public static let agentMaxSteps = 8
        public static let agentRowLimit = 50
        public static let agentCellLength = 200
        public static let agentResultLength = 6000
        public static let agentHistoryResultLength = 1500
        /// Seconds a query the assistant runs may take (PostgreSQL and MySQL stop it after that).
        public static let agentQueryTimeout = 15
        /// Conversations kept per connection; older ones are dropped.
        public static let savedConversations = 50
        /// Characters of the first question that name a saved conversation.
        public static let conversationTitleLength = 60
        /// Seconds between screen updates while an answer streams in (each token would redraw too often).
        public static let streamRefreshInterval: Double = 0.05
        /// Characters of the reasoning or SQL shown under the Ask AI bar while the model works.
        public static let progressLength = 160
        public static let chatEditorLength = 8000
        /// Characters before the caret sent with an inline request.
        public static let inlineContextLength = 2000
        /// Foreign keys described to the model.
        public static let schemaForeignKeyLimit = 300
        /// Tables described to the model; larger schemas are cut off.
        public static let schemaTableLimit = 150
        public static let anthropicVersion = "2026-10-21"

        public struct LocalModel: Sendable, Identifiable {
            public let name: String
            public let summary: String
            /// Small enough to answer while the user types.
            public let forTyping: Bool
            public var id: String { name }
        }

        /// A model download reports its progress in steps of this fraction.
        public static let downloadProgressStep = 0.01
        /// Light models that run well on a Mac, offered for download in Settings, smallest first.
        public static let recommendedLocalModels = [
            LocalModel(
                name: "qwen2.5-coder:0.5b",
                summary: "Fastest, about 0.4 GB. Good for suggestions while typing.",
                forTyping: true
            ),
            LocalModel(
                name: "qwen2.5-coder:1.5b",
                summary: "About 1 GB. Fast suggestions that know SQL better.",
                forTyping: true
            ),
            LocalModel(name: "deepseek-coder:1.3b", summary: "About 0.8 GB. Another fast code model.", forTyping: true),
            LocalModel(
                name: "qwen2.5-coder:3b",
                summary: "About 2 GB. Writes whole queries well on most Macs.",
                forTyping: false
            ),
            LocalModel(
                name: "qwen2.5-coder:7b",
                summary: "About 5 GB, 16 GB of memory recommended. Best local queries.",
                forTyping: false
            ),
            LocalModel(name: "sqlcoder:7b", summary: "About 4 GB. Tuned for SQL from a question.", forTyping: false),
        ]
    }
}
