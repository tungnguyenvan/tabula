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
    case appleIntelligence, ollama, openAICompatible, anthropic, claudeCode, codex

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
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
        case .appleIntelligence, .claudeCode, .codex: ""
        }
    }

    public var defaultModel: String {
        switch self {
        case .ollama: Defaults.AI.recommendedLocalModels.first?.name ?? ""
        case .anthropic: "claude-opus-5-5"
        case .openAICompatible, .appleIntelligence, .claudeCode, .codex: ""
        }
    }
}

/// The user's AI choices. The API key is not here: it lives in the Keychain.
public struct AISettings: Codable, Equatable, Sendable {
    public var enabled = false
    public var provider: AIProviderKind = .appleIntelligence
    public var baseURL = ""
    public var model = ""
    /// Model for inline suggestions; empty uses `model`. A smaller model keeps typing responsive.
    public var inlineModel = ""
    public var inlineSuggestions = true
    /// Production connections never send anything unless this is on.
    public var allowProduction = false

    public init() {}

    public var resolvedBaseURL: String { baseURL.isEmpty ? provider.defaultBaseURL : baseURL }
    public var resolvedModel: String { model.isEmpty ? provider.defaultModel : model }
    public func modelName(for purpose: AIRequest.Purpose) -> String {
        purpose == .inline && !inlineModel.isEmpty ? inlineModel : resolvedModel
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
    /// Table and column names only - never row data.
    public struct Schema: Sendable {
        public var tables: [(name: String, columns: [String])]
        public init(tables: [(name: String, columns: [String])]) { self.tables = tables }

        var text: String {
            tables.prefix(Defaults.AI.schemaTableLimit)
                .map { "\($0.name)(\($0.columns.joined(separator: ", ")))" }
                .joined(separator: "\n")
        }
    }

    public static func generate(description: String, current: String?, schema: Schema, kind: DatabaseKind) -> AIRequest {
        var prompt = "Schema:\n\(schema.text)\n\n"
        if let current, !current.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prompt += "Current SQL:\n\(current)\n\nChange it as follows: \(description)"
        } else {
            prompt += "Write SQL for: \(description)"
        }
        return AIRequest(purpose: .generate, instructions: """
            You write \(kind.displayName) SQL for a database client. Use only tables and columns from the schema. \
            Reply with the SQL alone: no explanation, no Markdown fences. Use a comment line (-- ...) only when \
            something needs a short note.
            """, prompt: prompt)
    }

    public static func fix(sql: String, error: String, schema: Schema, kind: DatabaseKind) -> AIRequest {
        AIRequest(purpose: .generate, instructions: """
            You fix \(kind.displayName) SQL. Reply with the corrected SQL alone: no explanation, no Markdown fences.
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

    /// Asks for the text that continues `before`, placed before `after`. Only the text near the caret is
    /// sent, which keeps the request small and fast.
    public static func inline(before: String, after: String, schema: Schema, kind: DatabaseKind) -> AIRequest {
        let before = String(before.suffix(Defaults.AI.inlineContextLength)), after = String(after.prefix(Defaults.AI.inlineContextLength / 4))
        return AIRequest(purpose: .inline, instructions: """
            You complete \(kind.displayName) SQL as the user types. Reply with only the characters to insert at \
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

/// Builds the backend the settings name.
public enum AIProviders {
    public static func make(_ settings: AISettings, apiKey: String) -> any AIProvider {
        switch settings.provider {
        case .appleIntelligence: AppleIntelligenceProvider()
        case .ollama: OllamaProvider(settings: settings)
        case .openAICompatible: OpenAICompatibleProvider(settings: settings, apiKey: apiKey)
        case .anthropic: AnthropicProvider(settings: settings, apiKey: apiKey)
        case .claudeCode: CLIProvider(tool: .claude, settings: settings)
        case .codex: CLIProvider(tool: .codex, settings: settings)
        }
    }
}
