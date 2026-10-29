import Foundation
import TabulaDrivers
import TabulaFoundation
import TabulaSQL
import TabulaUpdates

/// What the app asks a model to do.
public struct AIRequest: Sendable, Equatable {
    public enum Purpose: Sendable {
        /// Write or edit SQL from a description; quality matters more than speed.
        case generate
        /// Continue the statement at the caret while the user types; must be fast and short.
        case inline
    }

    /// Text around the caret, for models that complete code by filling in the middle.
    public struct Fill: Sendable, Equatable {
        public var prefix: String
        public var suffix: String
    }

    public var purpose: Purpose
    public var instructions: String
    public var prompt: String
    public var fill: Fill?

    public init(purpose: Purpose, instructions: String, prompt: String, fill: Fill? = nil) {
        self.purpose = purpose
        self.instructions = instructions
        self.prompt = prompt
        self.fill = fill
    }

    var maxTokens: Int { purpose == .inline ? Defaults.AI.inlineMaxTokens : Defaults.AI.generateMaxTokens }
}

/// One way of running a model. Each backend (on-device, local server, HTTP API, command-line agent)
/// implements this, so the editor doesn't care which one the user picked.
public protocol AIProvider: Sendable {
    func complete(_ request: AIRequest) async throws -> String
    /// The answer as it is generated, with the model's reasoning when it shares it. Backends that can't
    /// stream send the whole answer at the end (see the default in AIStreaming.swift).
    func stream(_ request: AIRequest) -> AIStream
}

/// The backends Tabula can use.
public enum AIProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case builtIn, appleIntelligence, ollama, openAICompatible, anthropic, claudeCode, codex

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .builtIn: "Model on this Mac (runs in Tabula)"
        case .appleIntelligence: "Apple Intelligence (on device)"
        case .ollama: "Local model (Ollama)"
        case .openAICompatible: "OpenAI-compatible API (LiteLLM, LM Studio, OpenAI…)"
        case .anthropic: "Claude API"
        case .claudeCode: "Claude Code (installed CLI)"
        case .codex: "Codex (installed CLI)"
        }
    }

    /// Models offered in the chat panel's picker, newest first, as (id, display name).
    public var suggestedModels: [(id: String, name: String)] {
        switch self {
        case .anthropic: [("claude-opus-5-5", "Claude Opus 5.5"), ("claude-sonnet-5-5", "Claude Sonnet 5.5"), ("claude-haiku-5-5", "Claude Haiku 5.5")]
        case .builtIn, .appleIntelligence, .ollama, .openAICompatible, .claudeCode, .codex: []
        }
    }

    /// Reasoning effort levels the provider accepts, lowest first; empty when it has none.
    public var effortLevels: [String] {
        switch self {
        case .anthropic, .claudeCode: ["low", "medium", "high", "xhigh", "max"]
        case .codex, .openAICompatible: ["low", "medium", "high"]
        case .builtIn, .appleIntelligence, .ollama: []
        }
    }

    /// Runs on this Mac, so suggestions can be asked for after a shorter pause.
    public var runsLocally: Bool { self == .builtIn || self == .appleIntelligence || self == .ollama }

    /// Whether the backend answers quickly enough to suggest as you type.
    public var supportsInline: Bool { self != .claudeCode && self != .codex }

    public var needsAPIKey: Bool { self == .anthropic || self == .openAICompatible }

    public var defaultBaseURL: String {
        switch self {
        case .ollama: "http://localhost:11434"
        case .openAICompatible: "http://localhost:4000/v1"
        case .anthropic: "https://api.anthropic.com"
        case .builtIn, .appleIntelligence, .claudeCode, .codex: ""
        }
    }

    public var defaultModel: String {
        switch self {
        case .builtIn: LocalModel.catalog.first { !$0.forTyping }?.id ?? ""
        case .ollama: Defaults.AI.recommendedLocalModels.first { !$0.forTyping }?.name ?? ""
        case .anthropic: "claude-opus-5-5"
        case .openAICompatible, .appleIntelligence, .claudeCode, .codex: ""
        }
    }

    /// A faster model for suggestions while typing, when the provider has an obvious one.
    public var defaultInlineModel: String? {
        switch self {
        case .builtIn: LocalModel.catalog.first { $0.forTyping }?.id
        case .ollama: Defaults.AI.recommendedLocalModels.first { $0.forTyping }?.name
        case .appleIntelligence, .openAICompatible, .anthropic, .claudeCode, .codex: nil
        }
    }
}

/// Where one request goes: the backend, its address, the model and the key, already chosen for the
/// request's purpose.
public struct AIEndpoint: Sendable, Equatable {
    public var kind: AIProviderKind
    public var baseURL: String
    public var model: String
    public var apiKey: String
    /// Reasoning effort, for providers that take one; nil leaves the provider's default.
    public var effort: String?

    public init(kind: AIProviderKind, baseURL: String = "", model: String = "", apiKey: String = "", effort: String? = nil) {
        self.kind = kind
        self.baseURL = baseURL.isEmpty ? kind.defaultBaseURL : baseURL
        self.model = model
        self.apiKey = apiKey
        self.effort = effort
    }
}

/// The user's AI choices. Each provider keeps its own address and models, so switching back and forth
/// loses nothing. API keys are not here: they live in the Keychain.
public struct AISettings: Codable, Equatable, Sendable {
    public var enabled = false
    /// Ask AI and Fix with AI.
    public var provider: AIProviderKind = .appleIntelligence
    public var inlineSuggestions = true
    /// Suggestions while typing; nil uses `provider`. A small local model is often the better choice:
    /// command-line agents and large hosted models are too slow to keep up with typing.
    public var inlineProvider: AIProviderKind?
    /// Production connections never send anything unless this is on.
    public var allowProduction = false
    /// The chat assistant may run read-only queries and see their results (at most `Defaults.AI.agentRowLimit` rows).
    /// It can always look up the structure. On Production connections each query needs the user's approval.
    public var assistantQueries = true
    /// Per provider (keyed by raw value): server address, model for Ask AI, model for suggestions.
    public var baseURLs: [String: String] = [:]
    public var models: [String: String] = [:]
    public var inlineModels: [String: String] = [:]
    /// Per provider: reasoning effort for Ask AI, Fix and chat; missing means the provider's default.
    public var efforts: [String: String] = [:]
    /// Per prompt kind (raw value): the user's own system prompt; missing or empty means the default.
    public var prompts: [String: String] = [:]

    public init() {}

    public func provider(for purpose: AIRequest.Purpose) -> AIProviderKind {
        purpose == .inline ? (inlineProvider ?? provider) : provider
    }

    public func baseURL(_ kind: AIProviderKind) -> String { baseURLs[kind.rawValue] ?? "" }

    /// The model to use; empty means the provider's own default (Apple, the CLIs).
    public func model(_ kind: AIProviderKind, for purpose: AIRequest.Purpose) -> String {
        let main = models[kind.rawValue].flatMap { $0.isEmpty ? nil : $0 } ?? kind.defaultModel
        guard purpose == .inline else { return main }
        return inlineModels[kind.rawValue].flatMap { $0.isEmpty ? nil : $0 } ?? kind.defaultInlineModel ?? main
    }

    public func endpoint(for purpose: AIRequest.Purpose, apiKey: String) -> AIEndpoint {
        let kind = provider(for: purpose)
        // Suggestions while typing always use the provider's quickest setting.
        let effort = purpose == .inline ? nil : efforts[kind.rawValue].flatMap { kind.effortLevels.contains($0) ? $0 : nil }
        return AIEndpoint(kind: kind, baseURL: baseURL(kind), model: model(kind, for: purpose), apiKey: apiKey, effort: effort)
    }

    /// The user's own system prompt for `prompt`, or nil for the default.
    public func instructions(_ prompt: SQLPrompts.PromptKind) -> String? {
        prompts[prompt.rawValue].flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }

    // Settings saved by earlier builds may lack newer fields.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        provider = (try? c.decodeIfPresent(AIProviderKind.self, forKey: .provider)) ?? .appleIntelligence
        inlineSuggestions = try c.decodeIfPresent(Bool.self, forKey: .inlineSuggestions) ?? true
        inlineProvider = try? c.decodeIfPresent(AIProviderKind.self, forKey: .inlineProvider)
        allowProduction = try c.decodeIfPresent(Bool.self, forKey: .allowProduction) ?? false
        // Settings from before the chat had tools were saved under "rows are never sent": queries stay off
        // until the user turns them on.
        assistantQueries = try c.decodeIfPresent(Bool.self, forKey: .assistantQueries) ?? false
        baseURLs = try c.decodeIfPresent([String: String].self, forKey: .baseURLs) ?? [:]
        models = try c.decodeIfPresent([String: String].self, forKey: .models) ?? [:]
        inlineModels = try c.decodeIfPresent([String: String].self, forKey: .inlineModels) ?? [:]
        efforts = try c.decodeIfPresent([String: String].self, forKey: .efforts) ?? [:]
        prompts = try c.decodeIfPresent([String: String].self, forKey: .prompts) ?? [:]
    }
}

public enum AIError: LocalizedError, Equatable {
    case notConfigured(String)
    case unavailable(String)
    case server(String)
    case refused

    public var errorDescription: String? {
        switch self {
        case .notConfigured(let message), .unavailable(let message), .server(let message): message
        case .refused: "The model declined this request."
        }
    }
}

/// Prompts for SQL work, and cleanup of what models send back.
public enum SQLPrompts {
    /// The database structure as the model sees it: names, column types, keys. Never row data.
    public struct Schema: Sendable {
        public struct Column: Sendable {
            public var name: String
            public var type: String?
            public var isPrimaryKey: Bool

            public init(name: String, type: String? = nil, isPrimaryKey: Bool = false) {
                self.name = name
                self.type = type
                self.isPrimaryKey = isPrimaryKey
            }
        }

        public struct Table: Sendable {
            /// As it must be written in SQL, schema included (`dev.transactions`).
            public var name: String
            /// Empty when only the name is sent (inline requests describe just the tables in use).
            public var columns: [Column]

            public init(name: String, columns: [Column]) {
                self.name = name
                self.columns = columns
            }
        }

        public var tables: [Table]
        /// "dev.orders.customer_id -> dev.customers.id"
        public var foreignKeys: [String]
        /// The schema unqualified names resolve to, mentioned so the model qualifies the others.
        public var defaultSchema: String?

        public init(tables: [Table], foreignKeys: [String] = [], defaultSchema: String? = nil) {
            self.tables = tables
            self.foreignKeys = foreignKeys
            self.defaultSchema = defaultSchema
        }

        public init(tables: [(name: String, columns: [String])]) {
            self.init(tables: tables.map { Table(name: $0.name, columns: $0.columns.map { Column(name: $0) }) })
        }

        /// MongoDB: collections and the fields sampled from their documents.
        public var isDocument = false

        var text: String {
            var lines: [String] = []
            if let defaultSchema { lines.append(isDocument ? "Database: \(defaultSchema)" : "Default schema: \(defaultSchema)") }
            lines += tables.prefix(Defaults.AI.schemaTableLimit).map { table in
                guard !table.columns.isEmpty else { return table.name }
                let columns = table.columns.map { column in
                    [column.name, column.type, column.isPrimaryKey ? "PK" : nil].compactMap { $0 }.joined(separator: " ")
                }
                return "\(table.name)(\(columns.joined(separator: ", ")))"
            }
            if !foreignKeys.isEmpty {
                lines.append("Foreign keys:")
                lines += foreignKeys.prefix(Defaults.AI.schemaForeignKeyLimit)
            }
            return lines.joined(separator: "\n")
        }
    }

    /// Repeated in every instruction: unqualified names may resolve elsewhere than the user expects.
    static let tableNamesRule = "Write table names exactly as the schema lists them, keeping any schema prefix."

    /// The same rule for collections, which the shell reaches as `db.name` or `db.getCollection("name")`.
    static let collectionNamesRule = "Write collection names exactly as the schema lists them; use db.getCollection(\"name\") "
        + "for names that aren't plain identifiers. A name listed as other_db.collection is in another database: "
        + "db.getSiblingDB(\"other_db\").getCollection(\"collection\")."
    /// Tabula reads shell statements; it doesn't run JavaScript.
    static let shellRule = "Write MongoDB shell statements only, such as db.orders.find({ … }).sort({ … }) or "
        + "db.orders.aggregate([ … ]): no variables, loops, functions or print calls. Put each statement on its own line."

    /// The system prompts, each editable in Settings › AI. `{database}` becomes the database's name
    /// (PostgreSQL, MySQL / MariaDB, SQLite, MongoDB). MongoDB has its own defaults, since it isn't queried with SQL.
    public enum PromptKind: String, CaseIterable, Identifiable, Sendable {
        case chat, generate, fix, inline
        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .chat: "Chat"
            case .generate: "Ask AI"
            case .fix: "Fix with AI"
            case .inline: "Suggestions while typing"
            }
        }

        public var defaultTemplate: String {
            switch self {
            case .chat:
                return "You are the SQL assistant of a {database} database client. Answer briefly. Put every query in a "
                    + "```sql fenced block. Use only tables and columns from the schema. \(tableNamesRule)"
            case .generate:
                return "You write {database} SQL for a database client. Use only tables and columns from the schema. "
                    + "\(tableNamesRule) Reply with the SQL alone: no explanation, no Markdown fences. Use a comment line "
                    + "(-- ...) only when something needs a short note."
            case .fix:
                return "You fix {database} SQL. \(tableNamesRule) Reply with the corrected SQL alone: no explanation, no Markdown fences."
            case .inline:
                return "You complete {database} SQL as the user types. \(tableNamesRule) Reply with only the characters to "
                    + "insert at <cursor>, at most one line, nothing else. Reply with an empty message if nothing fits."
            }
        }
    }

}

extension SQLPrompts.PromptKind {
    /// The defaults for MongoDB connections.
    public var documentTemplate: String {
        switch self {
        case .chat:
            return "You are the MongoDB assistant of a database client. Answer briefly. Put every command in a ```javascript "
                + "fenced block. \(SQLPrompts.shellRule) Use only collections and fields from the schema. \(SQLPrompts.collectionNamesRule) "
                + "The schema's fields are sampled from documents."
        case .generate:
            return "You write MongoDB shell commands for a database client. \(SQLPrompts.shellRule) Use only collections and fields "
                + "from the schema. \(SQLPrompts.collectionNamesRule) Reply with the commands alone: no explanation, no Markdown "
                + "fences. Use a comment line (// ...) only when something needs a short note."
        case .fix:
            return "You fix MongoDB shell commands. \(SQLPrompts.shellRule) \(SQLPrompts.collectionNamesRule) Reply with the "
                + "corrected command alone: no explanation, no Markdown fences."
        case .inline:
            return "You complete MongoDB shell commands as the user types. \(SQLPrompts.collectionNamesRule) Reply with only the "
                + "characters to insert at <cursor>, at most one line, nothing else. Reply with an empty message if nothing fits."
        }
    }
}

extension SQLPrompts {
    /// The instructions for a request: the user's own template if set, else the default.
    static func instructions(_ prompt: PromptKind, custom: String?, kind: DatabaseKind) -> String {
        let template = custom.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            ?? (kind.isDocument ? prompt.documentTemplate : prompt.defaultTemplate)
        return template.replacingOccurrences(of: "{database}", with: kind.displayName)
    }

    /// What the prompt calls the user's code.
    static func language(_ kind: DatabaseKind) -> String { kind.isDocument ? "MongoDB shell commands" : "SQL" }

    public static func generate(description: String, current: String?, schema: Schema, kind: DatabaseKind,
                                instructions custom: String? = nil) -> AIRequest {
        var prompt = "Schema:\n\(schema.text)\n\n"
        if let current, !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prompt += "Current \(language(kind)):\n\(current)\n\nChange it as follows: \(description)"
        } else {
            prompt += "Write \(language(kind)) for: \(description)"
        }
        return AIRequest(purpose: .generate, instructions: instructions(.generate, custom: custom, kind: kind), prompt: prompt)
    }

    public static func fix(sql: String, error: String, schema: Schema, kind: DatabaseKind, instructions custom: String? = nil) -> AIRequest {
        AIRequest(purpose: .generate, instructions: instructions(.fix, custom: custom, kind: kind), prompt: "Schema:\n\(schema.text)\n\n\(language(kind)):\n\(sql)\n\nThe server answered:\n\(redacted(error, kind: kind))")
    }

    /// Database errors can quote row values ("Key (email)=(an@example.com) already exists", "invalid input
    /// value 'x'", MongoDB's "dup key: { email: \"an@example.com\" }"); those are replaced before the message goes
    /// to a model. The SQL itself is the user's.
    public static func redacted(_ error: String, kind: DatabaseKind = .postgres) -> String {
        var text = error
        if kind.isDocument {
            text = redactingDuplicateKeys(text)
            // MongoDB quotes values in double quotes; on SQL databases those are identifiers, worth keeping.
            text = text.replacingOccurrences(of: #""(?:[^"\\]|\\.)*""#, with: "\"…\"", options: .regularExpression)
        }
        let patterns = [
            #"\)=\((?:[^()]|\([^()]*\))*\)"#,  // Postgres key details: (column)=(value)
            #"'(?:[^']|'')*'"#,                    // quoted literals (MySQL quotes the values it reports)
        ]
        let replacements = [")=(…)", "'…'"]
        for (pattern, replacement) in zip(patterns, replacements) {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return text
    }

    /// `dup key: { email: "a@b", n: 5 }` → `dup key: { … }`, braces matched so nested documents go too.
    private static func redactingDuplicateKeys(_ text: String) -> String {
        var result = ""
        var rest = Substring(text)
        while let marker = rest.range(of: "dup key: {") {
            result += rest[..<marker.upperBound]
            var depth = 1
            var index = marker.upperBound
            while index < rest.endIndex, depth > 0 {
                if rest[index] == "{" { depth += 1 } else if rest[index] == "}" { depth -= 1 }
                index = rest.index(after: index)
            }
            result += " … }"
            rest = rest[index...]
        }
        return result + rest
    }

    /// One turn of the chat panel: earlier turns, the editor's SQL and the schema come along.
    /// `tools` describes the assistant's tools (`AgentProtocol.instructions`); `steps` are the tool calls made
    /// for this question so far, with their results. Without tools, the model is told to answer.
    public static func chat(question: String, history: [(role: String, text: String)], editorSQL: String?,
                            schema: Schema, kind: DatabaseKind, instructions custom: String? = nil,
                            tools: String? = nil, steps: [(call: AgentToolCall, result: String)] = []) -> AIRequest {
        var prompt = "Schema:\n\(schema.text)\n\n"
        if let editorSQL, !editorSQL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prompt += "\(language(kind)) in the editor:\n\(editorSQL.prefix(Defaults.AI.chatEditorLength))\n\n"
        }
        if !history.isEmpty {
            prompt += "Conversation so far:\n" + history.map { "\($0.role): \($0.text)" }.joined(separator: "\n\n") + "\n\n"
        }
        prompt += "User: \(question)"
        if !steps.isEmpty {
            prompt += "\n\nYour tool calls for this question so far:"
            for step in steps {
                prompt += "\n\n```tool\n\(step.call.json)\n```\nResult:\n\(step.result)"
            }
            prompt += tools == nil ? "\n\nNo more tools now: answer the user with what you found."
                : "\n\nContinue: use another tool, or answer the user."
        }
        var system = instructions(.chat, custom: custom, kind: kind)
        if let tools { system += "\n\n" + tools }
        return AIRequest(purpose: .generate, instructions: system, prompt: prompt)
    }

    /// Asks for the text that continues `before`, placed before `after`. Only the text near the caret is
    /// sent, which keeps the request small and fast.
    public static func inline(before: String, after: String, schema: Schema, kind: DatabaseKind,
                              instructions custom: String? = nil) -> AIRequest {
        let before = String(before.suffix(Defaults.AI.inlineContextLength)), after = String(after.prefix(Defaults.AI.inlineContextLength / 4))
        // For fill-in-the-middle models the schema rides along as comments above the text.
        let comment = kind.isDocument ? "// " : "-- "
        let header = schema.text.split(separator: "\n").map { comment + $0 }.joined(separator: "\n")
        let fill = AIRequest.Fill(prefix: header + "\n" + before, suffix: after)
        return AIRequest(purpose: .inline, instructions: instructions(.inline, custom: custom, kind: kind), prompt: "Schema:\n\(schema.text)\n\n\(before)<cursor>\(after)", fill: fill)
    }

    /// Removes Markdown fences and chatter that models add despite instructions.
    public static func cleanSQL(_ text: String) -> String {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Reasoning a server left in the answer (`…</think>`, sometimes without the opening tag) isn't SQL.
        if let close = body.range(of: "</think>", options: .backwards) { body = String(body[close.upperBound...]) }
        if let open = body.range(of: "```") {
            var inner = body[open.upperBound...]
            // Drop a language tag on the fence line.
            if let newline = inner.firstIndex(of: "\n") { inner = inner[inner.index(after: newline)...] }
            if let close = inner.range(of: "```") { inner = inner[..<close.lowerBound] }
            body = String(inner)
        }
        return body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The inline continuation: one line, without repeating text already typed.
    public static func cleanContinuation(_ text: String, before: String) -> String {
        var line = cleanSQL(text).components(separatedBy: .newlines).first ?? ""
        line = line.replacingOccurrences(of: "<cursor>", with: "")
        // Models sometimes repeat the word being completed; keep only what is new.
        let tail = before.split(whereSeparator: { $0.isWhitespace }).last.map(String.init) ?? ""
        if !tail.isEmpty, before.last?.isWhitespace == false, line.lowercased().hasPrefix(tail.lowercased()) {
            line = String(line.dropFirst(tail.count))
        }
        // Don't double the space the user already typed.
        if before.last?.isWhitespace == true { line = String(line.drop(while: { $0 == " " })) }
        // A run of one repeated character is a model looping, not SQL.
        while let last = line.last, line.hasSuffix(String(repeating: last, count: 4)), last.isNumber || last.isLetter {
            line = String(line.dropLast(line.reversed().prefix(while: { $0 == last }).count))
            line = line.trimmingCharacters(in: .whitespaces)
        }
        return String(line.prefix(Defaults.AI.inlineMaxCharacters))
    }
}

/// Builds the backend an endpoint names.
public enum AIProviders {
    public static func make(_ endpoint: AIEndpoint) -> any AIProvider {
        switch endpoint.kind {
        case .builtIn: BuiltInProvider(endpoint)
        case .appleIntelligence: AppleIntelligenceProvider()
        case .ollama: OllamaProvider(endpoint)
        case .openAICompatible: OpenAICompatibleProvider(endpoint)
        case .anthropic: AnthropicProvider(endpoint)
        case .claudeCode: CLIProvider(tool: .claude, model: endpoint.model, effort: endpoint.effort)
        case .codex: CLIProvider(tool: .codex, model: endpoint.model, effort: endpoint.effort)
        }
    }
}
