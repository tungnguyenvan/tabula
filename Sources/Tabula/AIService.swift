import Foundation
import Observation
import TabulaCore

/// The AI settings and the one place the app asks a model for something.
@MainActor @Observable
final class AIService {
    static let shared = AIService()

    var settings: AISettings {
        didSet { save() }
    }

    private static let settingsKey = "TabulaAISettings"
    private static let keychainService = "app.tabula.ai"
    private let defaults = UserDefaults.standard
    /// API keys per provider, read once per launch (the Keychain may prompt).
    private var keys: [AIProviderKind: String] = [:]
    private let keychain = DispatchQueue(label: "app.tabula.ai.keychain")

    private init() {
        settings = defaults.data(forKey: Self.settingsKey).flatMap { try? JSONDecoder().decode(AISettings.self, from: $0) } ?? AISettings()
        #if DEBUG
        if let provider = ProcessInfo.processInfo.environment["TABULA_DEBUG_AI_PROVIDER"].flatMap(AIProviderKind.init) {
            settings.provider = provider
            settings.enabled = true
            if let url = ProcessInfo.processInfo.environment["TABULA_DEBUG_AI_URL"] { settings.baseURL = url }
            if let model = ProcessInfo.processInfo.environment["TABULA_DEBUG_AI_MODEL"] { settings.model = model }
        }
        #endif
    }

    private func save() {
        if let data = try? JSONEncoder().encode(settings) { defaults.set(data, forKey: Self.settingsKey) }
    }

    private func item(for provider: AIProviderKind) -> KeychainItem {
        KeychainItem(service: Self.keychainService, account: provider.rawValue, label: "Tabula AI (\(provider.displayName))")
    }

    func apiKey(for provider: AIProviderKind) async -> String {
        #if DEBUG
        // Test runs pass the key in the environment, so they never touch the Keychain.
        if let key = ProcessInfo.processInfo.environment["TABULA_AI_KEY"] { return key }
        #endif
        if let key = keys[provider] { return key }
        let item = item(for: provider)
        let key = await withCheckedContinuation { continuation in
            keychain.async { continuation.resume(returning: item.read() ?? "") }
        }
        keys[provider] = key
        return key
    }

    func setAPIKey(_ key: String, for provider: AIProviderKind) throws {
        try item(for: provider).write(key)
        keys[provider] = key
    }

    /// Why AI can't be used for this connection, or nil when it can.
    func refusal(for connection: ConnectionConfig) -> String? {
        if !settings.enabled { return "Turn on the AI assistant in Settings › AI." }
        if connection.tag == .production && !settings.allowProduction {
            return "AI is off for Production connections. You can allow it in Settings › AI."
        }
        return nil
    }

    /// Whether to ask the model for suggestions while typing.
    func suggestsInline(for connection: ConnectionConfig) -> Bool {
        refusal(for: connection) == nil && settings.inlineSuggestions && settings.provider.supportsInline
    }

    func complete(_ request: AIRequest) async throws -> String {
        let settings = settings
        let provider = AIProviders.make(settings, apiKey: await apiKey(for: settings.provider))
        return try await provider.complete(request)
    }

    /// A tiny round trip, for the Test button in Settings.
    func test() async throws -> String {
        let reply = try await complete(AIRequest(purpose: .generate, instructions: "Reply with the single word OK.", prompt: "Say OK."))
        return reply.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
