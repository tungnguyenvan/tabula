import Foundation
import Observation
import TabulaAI
import TabulaFoundation
import TabulaStorage

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
        var loaded =
            UserDefaults.standard.data(forKey: Self.settingsKey)
            // Settings saved in a format this version can't read start over from the defaults.
            .flatMap { try? JSONDecoder().decode(AISettings.self, from: $0) } ?? AISettings()
        #if DEBUG
        // Applied before the single assignment below: mutating `settings` afterwards, even here in init,
        // would trigger didSet and save the overrides as the developer's real settings.
        let environment = ProcessInfo.processInfo.environment
        if let provider = environment["TABULA_DEBUG_AI_PROVIDER"].flatMap(AIProviderKind.init) {
            loaded.provider = provider
            loaded.inlineProvider = environment["TABULA_DEBUG_AI_INLINE_PROVIDER"].flatMap(AIProviderKind.init)
            loaded.enabled = true
            loaded.baseURLs[provider.rawValue] = environment["TABULA_DEBUG_AI_URL"]
            loaded.models[provider.rawValue] = environment["TABULA_DEBUG_AI_MODEL"]
            loaded.inlineModels[provider.rawValue] = environment["TABULA_DEBUG_AI_MODEL"]
            // TABULA_DEBUG_AI_ALLOW_PRODUCTION: try the assistant on a Production-tagged test connection.
            if environment["TABULA_DEBUG_AI_ALLOW_PRODUCTION"] != nil { loaded.allowProduction = true }
            // TABULA_DEBUG_AI_QUERIES=0 tries the chat without queries; otherwise they are on.
            loaded.assistantQueries = environment["TABULA_DEBUG_AI_QUERIES"] != "0"
        }
        #endif
        settings = loaded
    }

    private func save() {
        // AISettings holds plain values, which always encode.
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: Self.settingsKey)
        }
    }

    private func item(for provider: AIProviderKind) -> KeychainItem {
        KeychainItem(
            service: Self.keychainService,
            account: provider.rawValue,
            label: "Tabula AI (\(provider.displayName))"
        )
    }

    func apiKey(for provider: AIProviderKind) async -> String {
        #if DEBUG
        // Test runs pass the key in the environment, so they never touch the Keychain.
        if let key = ProcessInfo.processInfo.environment["TABULA_AI_KEY"] { return key }
        #endif
        if let key = keys[provider] {
            return key
        }
        let item = item(for: provider)
        let key = await withCheckedContinuation { continuation in
            keychain.async { continuation.resume(returning: item.read() ?? "") }
        }
        // A failed read (locked Keychain, denied access) looks like "no key"; only remember real keys.
        if !key.isEmpty {
            keys[provider] = key
        }
        return key
    }

    /// Stores the key off the main thread (the Keychain may block while it asks the user).
    func setAPIKey(_ key: String, for provider: AIProviderKind) async throws {
        guard keys[provider] != key else { return }
        let item = item(for: provider)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            keychain.async { continuation.resume(with: Result { try item.write(key) }) }
        }
        keys[provider] = key
    }

    /// Why AI can't be used for this connection, or nil when it can.
    func refusal(for connection: ConnectionConfig) -> String? {
        if !settings.enabled {
            return "Turn on the AI assistant in Settings › AI."
        }
        if connection.tag == .production && !settings.allowProduction {
            return "AI is off for Production connections. You can allow it in Settings › AI."
        }
        return nil
    }

    /// Whether to ask the model for suggestions while typing.
    func suggestsInline(for connection: ConnectionConfig) -> Bool {
        refusal(for: connection) == nil && settings.inlineSuggestions && settings.provider(for: .inline).supportsInline
    }

    /// Sends the request to the provider configured for its purpose (Ask AI or suggestions while typing).
    func complete(_ request: AIRequest) async throws -> String {
        try await provider(for: request.purpose).complete(request)
    }

    /// The backend chosen for this kind of request, with its address, model and key.
    private func provider(for purpose: AIRequest.Purpose) async -> any AIProvider {
        let settings = settings
        let kind = settings.provider(for: purpose)
        return AIProviders.make(
            settings.endpoint(for: purpose, apiKey: kind.needsAPIKey ? await apiKey(for: kind) : "")
        )
    }

    /// The answer as the model writes it, with its reasoning when the provider shares it.
    func stream(_ request: AIRequest) async -> AIStream {
        await provider(for: request.purpose).stream(request)
    }

    /// A tiny round trip, for the Test buttons in Settings.
    func test(_ purpose: AIRequest.Purpose) async throws -> String {
        let reply = try await complete(
            AIRequest(purpose: purpose, instructions: "Reply with the single word OK.", prompt: "Say OK.")
        )
        return reply.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
