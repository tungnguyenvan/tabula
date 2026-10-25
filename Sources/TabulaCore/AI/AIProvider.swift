import Foundation

/// What the app asks a model to do.
public struct AIRequest: Sendable, Equatable {
    public enum Purpose: Sendable {
        /// Write or edit SQL from a description; quality matters more than speed.
        case generate
        /// Continue the statement at the caret while the user types; must be fast and short.
        case inline
    }

    public var purpose: Purpose
    public var instructions: String
    public var prompt: String

    public init(purpose: Purpose, instructions: String, prompt: String) {
        self.purpose = purpose
        self.instructions = instructions
        self.prompt = prompt
    }

    var maxTokens: Int { purpose == .inline ? Defaults.AI.inlineMaxTokens : Defaults.AI.generateMaxTokens }
}

/// One way of running a model. Each backend (on-device, local server, HTTP API, command-line agent)
/// implements this, so the editor doesn't care which one the user picked.
public protocol AIProvider: Sendable {
    func complete(_ request: AIRequest) async throws -> String
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

    public init(kind: AIProviderKind, baseURL: String = "", model: String = "", apiKey: String = "") {
        self.kind = kind
        self.baseURL = baseURL.isEmpty ? kind.defaultBaseURL : baseURL
        self.model = model
        self.apiKey = apiKey
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
    /// Per provider (keyed by raw value): server address, model for Ask AI, model for suggestions.
    public var baseURLs: [String: String] = [:]
    public var models: [String: String] = [:]
    public var inlineModels: [String: String] = [:]

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
        return AIEndpoint(kind: kind, baseURL: baseURL(kind), model: model(kind, for: purpose), apiKey: apiKey)
    }

    // Settings saved by earlier builds may lack newer fields.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        provider = (try? c.decodeIfPresent(AIProviderKind.self, forKey: .provider)) ?? .appleIntelligence
        inlineSuggestions = try c.decodeIfPresent(Bool.self, forKey: .inlineSuggestions) ?? true
        inlineProvider = try? c.decodeIfPresent(AIProviderKind.self, forKey: .inlineProvider)
        allowProduction = try c.decodeIfPresent(Bool.self, forKey: .allowProduction) ?? false
        baseURLs = try c.decodeIfPresent([String: String].self, forKey: .baseURLs) ?? [:]
        models = try c.decodeIfPresent([String: String].self, forKey: .models) ?? [:]
        inlineModels = try c.decodeIfPresent([String: String].self, forKey: .inlineModels) ?? [:]
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

        var text: String {
            var lines: [String] = []
            if let defaultSchema { lines.append("Default schema: \(defaultSchema)") }
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

    public static func generate(description: String, current: String?, schema: Schema, kind: DatabaseKind) -> AIRequest {
        var prompt = "Schema:\n\(schema.text)\n\n"
        if let current, !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prompt += "Current SQL:\n\(current)\n\nChange it as follows: \(description)"
        } else {
            prompt += "Write SQL for: \(description)"
        }
        return AIRequest(purpose: .generate, instructions: """
            You write \(kind.displayName) SQL for a database client. Use only tables and columns from the schema. \
            \(tableNamesRule) \
            Reply with the SQL alone: no explanation, no Markdown fences. Use a comment line (-- ...) only when \
            something needs a short note.
            """, prompt: prompt)
    }

    public static func fix(sql: String, error: String, schema: Schema, kind: DatabaseKind) -> AIRequest {
        AIRequest(purpose: .generate, instructions: """
            You fix \(kind.displayName) SQL. \(tableNamesRule) Reply with the corrected SQL alone: no explanation, \
            no Markdown fences.
            """, prompt: "Schema:\n\(schema.text)\n\nSQL:\n\(sql)\n\nThe server answered:\n\(redacted(error))")
    }

    /// Database errors can quote row values ("Key (email)=(an@example.com) already exists", "invalid input
    /// value 'x'"); those are replaced before the message goes to a model. The SQL itself is the user's.
    public static func redacted(_ error: String) -> String {
        var text = error
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

    /// One turn of the chat panel: earlier turns, the editor's SQL and the schema come along.
    public static func chat(question: String, history: [(role: String, text: String)], editorSQL: String?,
                            schema: Schema, kind: DatabaseKind) -> AIRequest {
        var prompt = "Schema:\n\(schema.text)\n\n"
        if let editorSQL, !editorSQL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prompt += "SQL in the editor:\n\(editorSQL.prefix(Defaults.AI.chatEditorLength))\n\n"
        }
        if !history.isEmpty {
            prompt += "Conversation so far:\n" + history.map { "\($0.role): \($0.text)" }.joined(separator: "\n\n") + "\n\n"
        }
        prompt += "User: \(question)"
        return AIRequest(purpose: .generate, instructions: """
            You are the SQL assistant of a \(kind.displayName) database client. Answer briefly. Put every query \
            in a ```sql fenced block. Use only tables and columns from the schema. \(tableNamesRule) \
            You can't see the data, only its structure; say so if a question needs the data.
            """, prompt: prompt)
    }

    /// Asks for the text that continues `before`, placed before `after`. Only the text near the caret is
    /// sent, which keeps the request small and fast.
    public static func inline(before: String, after: String, schema: Schema, kind: DatabaseKind) -> AIRequest {
        let before = String(before.suffix(Defaults.AI.inlineContextLength)), after = String(after.prefix(Defaults.AI.inlineContextLength / 4))
        return AIRequest(purpose: .inline, instructions: """
            You complete \(kind.displayName) SQL as the user types. \(tableNamesRule) Reply with only the characters to insert at \
            <cursor>, at most one line, nothing else. Reply with an empty message if nothing fits.
            """, prompt: "Schema:\n\(schema.text)\n\n\(before)<cursor>\(after)")
    }

    /// Removes Markdown fences and chatter that models add despite instructions.
    public static func cleanSQL(_ text: String) -> String {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
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
        return line
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
        case .claudeCode: CLIProvider(tool: .claude, model: endpoint.model)
        case .codex: CLIProvider(tool: .codex, model: endpoint.model)
        }
    }
}
