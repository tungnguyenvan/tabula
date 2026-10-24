import AppKit
import SwiftUI
import TabulaCore

/// Local models served by Ollama, for the AI settings.
@MainActor @Observable
final class OllamaModels {
    private(set) var version: String?
    private(set) var installed: [OllamaLibrary.InstalledModel] = []
    /// Model name → download progress (nil fraction while Ollama prepares).
    private(set) var downloads: [String: OllamaLibrary.PullProgress] = [:]
    private(set) var checked = false
    var error: String?
    private var library: OllamaLibrary { OllamaLibrary(baseURL: AIService.shared.settings.resolvedBaseURL) }

    func refresh() async {
        version = await library.version()
        installed = (try? await library.installed()) ?? []
        checked = true
    }

    func isInstalled(_ name: String) -> Bool {
        installed.contains { $0.name == name || $0.name == name + ":latest" }
    }

    func download(_ name: String) {
        guard downloads[name] == nil else { return }
        downloads[name] = OllamaLibrary.PullProgress(status: "Starting…", fraction: nil)
        let library = library
        Task {
            do {
                try await library.pull(name) { progress in
                    Task { @MainActor in self.downloads[name] = progress }
                }
                error = nil
                if AIService.shared.settings.model.isEmpty { AIService.shared.settings.model = name }
            } catch {
                self.error = error.localizedDescription
            }
            downloads[name] = nil
            await refresh()
        }
    }

    func delete(_ name: String) {
        let library = library
        Task {
            do {
                try await library.delete(name)
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
            await refresh()
        }
    }
}

struct AISettingsView: View {
    @Bindable private var ai = AIService.shared
    @State private var apiKey = ""
    /// The provider `apiKey` belongs to. Switching providers tears the field down before the new key loads,
    /// so saving must not assume the current provider.
    @State private var keyProvider: AIProviderKind?
    @State private var ollama = OllamaModels()
    @State private var cliPath: String?
    @State private var lookingForCLI = false
    @State private var testResult: Result<String, Error>?
    @State private var testing = false

    private var provider: AIProviderKind { ai.settings.provider }

    var body: some View {
        Form {
            Section {
                Toggle("Use AI to write and complete SQL", isOn: $ai.settings.enabled)
                Picker("Provider", selection: $ai.settings.provider) {
                    ForEach(AIProviderKind.allCases) { Text($0.displayName).tag($0) }
                }
                .disabled(!ai.settings.enabled)
            } footer: {
                Text("Ask AI with ⌘K in a query tab, or fix a failed statement. Only table and column names and the SQL in the editor are sent, never rows from your tables.")
            }

            if ai.settings.enabled {
                providerSection
                if provider == .ollama { localModelsSection }
                Section {
                    // Shown off (and locked) for providers that can't suggest while typing.
                    Toggle("Suggest SQL while I type", isOn: Binding(
                        get: { ai.settings.inlineSuggestions && provider.supportsInline },
                        set: { ai.settings.inlineSuggestions = $0 }))
                        .disabled(!provider.supportsInline)
                    Toggle("Allow on Production connections", isOn: $ai.settings.allowProduction)
                } footer: {
                    Text(provider.supportsInline
                         ? "A suggestion appears in grey when you pause; Tab accepts it."
                         : "Command-line agents are too slow to suggest while typing; use Ask AI (⌘K) instead.")
                }
                Section {
                    HStack {
                        Button("Test") { runTest() }.disabled(testing)
                        if testing { ProgressView().controlSize(.small) }
                        Spacer()
                        switch testResult {
                        case .success(let reply): Label("Answered “\(reply.prefix(40))”", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        case .failure(let error): Text(error.localizedDescription).foregroundStyle(.red).lineLimit(3)
                        case nil: EmptyView()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: Layout.Settings.width, height: Layout.Settings.aiHeight)
        .task(id: provider) { await providerChanged() }
    }

    @ViewBuilder
    private var providerSection: some View {
        Section(provider.displayName) {
            switch provider {
            case .appleIntelligence:
                if let reason = AppleIntelligenceProvider.unavailableReason {
                    Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                } else {
                    Label("Ready. Runs on this Mac; nothing is sent over the network.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            case .ollama:
                TextField("Server", text: $ai.settings.baseURL, prompt: Text(provider.defaultBaseURL))
                Picker("Model", selection: $ai.settings.model) {
                    if !ollama.installed.contains(where: { $0.name == ai.settings.model }) {
                        Text(ai.settings.model.isEmpty ? "None" : ai.settings.model).tag(ai.settings.model)
                    }
                    ForEach(ollama.installed) { Text($0.name).tag($0.name) }
                }
            case .openAICompatible:
                TextField("Base URL", text: $ai.settings.baseURL, prompt: Text(provider.defaultBaseURL))
                apiKeyField
                TextField("Model", text: $ai.settings.model, prompt: Text("e.g. gpt-4.1, or a LiteLLM model name"))
                TextField("Model for suggestions", text: $ai.settings.inlineModel, prompt: Text("Same as Model"))
            case .anthropic:
                apiKeyField
                TextField("Model", text: $ai.settings.model, prompt: Text(provider.defaultModel))
                TextField("Model for suggestions", text: $ai.settings.inlineModel, prompt: Text("Same as Model; claude-haiku-5-5 is faster"))
            case .claudeCode, .codex:
                if lookingForCLI {
                    ProgressView().controlSize(.small)
                } else if let cliPath {
                    LabeledContent("Found", value: cliPath)
                } else {
                    Label("Not found on your shell's PATH. Install it, sign in once in Terminal, then reopen Settings.",
                          systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                TextField("Model", text: $ai.settings.model, prompt: Text("The tool's default"))
            }
        }
    }

    private var apiKeyField: some View {
        // Saved on Return, on Test and when Settings closes, not on every keystroke.
        SecureField("API key", text: $apiKey)
            .onSubmit { Task { await saveKey() } }
            .onDisappear { Task { await saveKey() } }
    }

    @ViewBuilder
    private var localModelsSection: some View {
        Section {
            if !ollama.checked {
                ProgressView().controlSize(.small)
            } else if ollama.version == nil {
                Label("Ollama isn't running. Install it, open it, then come back here.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Link("Download Ollama", destination: URL(string: "https://ollama.com/download")!)
            } else {
                ForEach(Defaults.AI.recommendedLocalModels) { model in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(model.name)
                            Text(model.summary).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        localModelControl(model.name)
                    }
                }
                ForEach(ollama.installed.filter { model in !Defaults.AI.recommendedLocalModels.contains { $0.name == model.name } }) { model in
                    HStack {
                        Text(model.name)
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: model.size, countStyle: .file)).foregroundStyle(.secondary)
                        localModelControl(model.name)
                    }
                }
            }
            if let error = ollama.error { Text(error).foregroundStyle(.red) }
        } header: {
            Text("Local models")
        } footer: {
            if let version = ollama.version { Text("Ollama \(version). Models are stored and run by Ollama on this Mac.") }
        }
    }

    @ViewBuilder
    private func localModelControl(_ name: String) -> some View {
        if let progress = ollama.downloads[name] {
            if let fraction = progress.fraction {
                ProgressView(value: fraction).frame(width: Layout.Settings.progressWidth)
            } else {
                Text(progress.status).font(.caption).foregroundStyle(.secondary)
            }
        } else if ollama.isInstalled(name) {
            if ai.settings.model == name {
                Label("In use", systemImage: "checkmark").foregroundStyle(.secondary)
            } else {
                Button("Use") { ai.settings.model = name }
            }
            Menu {
                Button("Delete", role: .destructive) { ollama.delete(name) }
            } label: { Image(systemName: "ellipsis") }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        } else {
            Button("Download") { ollama.download(name) }
        }
    }

    private func providerChanged() async {
        testResult = nil
        await saveKey()
        keyProvider = nil
        apiKey = provider.needsAPIKey ? await ai.apiKey(for: provider) : ""
        keyProvider = provider.needsAPIKey ? provider : nil
        switch provider {
        case .ollama:
            await ollama.refresh()
        case .claudeCode, .codex:
            lookingForCLI = true
            cliPath = await CLIProvider.locate(provider == .claudeCode ? .claude : .codex)
            lookingForCLI = false
        case .appleIntelligence, .openAICompatible, .anthropic:
            break
        }
    }

    /// Saves the key shown in the field for the provider it was loaded for.
    @discardableResult
    private func saveKey() async -> Bool {
        guard let owner = keyProvider else { return true }
        do {
            try await ai.setAPIKey(apiKey, for: owner)
            return true
        } catch {
            testResult = .failure(error)
            return false
        }
    }

    private func runTest() {
        testing = true
        testResult = nil
        Task {
            defer { testing = false }
            guard await saveKey() else { return }
            do { testResult = .success(try await ai.test()) } catch { testResult = .failure(error) }
        }
    }
}
