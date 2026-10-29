import AppKit
import SwiftUI
import TabulaAI
import TabulaFoundation

struct AISettingsView: View {
    @Bindable private var ai = AIService.shared
    @State private var ollama = OllamaModels()

    private var assistant: AIProviderKind { ai.settings.provider }
    private var typing: AIProviderKind { ai.settings.provider(for: .inline) }
    private var usesOllama: Bool { assistant == .ollama || (ai.settings.inlineSuggestions && typing == .ollama) }
    /// Model downloads are only offered once a provider that runs them in Tabula is chosen.
    private var usesBuiltIn: Bool { assistant == .builtIn || (ai.settings.inlineSuggestions && typing == .builtIn) }

    var body: some View {
        Form {
            Section {
                Toggle("Use AI to write and complete SQL", isOn: $ai.settings.enabled)
                Toggle("Let the chat run read-only queries", isOn: $ai.settings.assistantQueries)
                    .disabled(!ai.settings.enabled)
            } footer: {
                Text(
                    "Table and column names, keys and the SQL in the editor are sent. With read-only queries on, the chat "
                        + "can also run SELECT statements (or MongoDB reads) and sees up to \(Defaults.AI.agentRowLimit) rows of "
                        + "each result; on Production connections it asks you first. Ask AI, Fix with AI and suggestions never see rows."
                )
            }

            if ai.settings.enabled {
                Section {
                    Picker("Provider", selection: $ai.settings.provider) {
                        ForEach(AIProviderKind.allCases) { Text($0.displayName).tag($0) }
                    }
                    ProviderFields(kind: assistant, purpose: .generate, ollama: ollama)
                    TestRow(purpose: .generate)
                } header: {
                    Text("Ask AI and Fix with AI")
                } footer: {
                    Text("⌘K in a query tab, or the button under a failed statement.")
                }

                Section {
                    Toggle("Suggest SQL while I type", isOn: $ai.settings.inlineSuggestions)
                    if ai.settings.inlineSuggestions {
                        Picker("Provider", selection: $ai.settings.inlineProvider) {
                            Text(assistant.supportsInline ? "Same as above" : "Same as above (too slow)")
                                .tag(AIProviderKind?.none)
                            Divider()
                            ForEach(AIProviderKind.allCases.filter(\.supportsInline)) {
                                Text($0.displayName).tag(AIProviderKind?.some($0))
                            }
                        }
                        if ai.settings.inlineProvider != nil || typing.supportsInline {
                            ProviderFields(
                                kind: typing,
                                purpose: .inline,
                                ollama: ollama,
                                showsShared: ai.settings.inlineProvider != nil
                            )
                            TestRow(purpose: .inline)
                        }
                    }
                } header: {
                    Text("Suggestions while typing")
                } footer: {
                    Text(
                        typing.supportsInline
                            ? "A suggestion appears in grey when you pause; Tab accepts it. A small model on this Mac keeps up best."
                            : "Command-line agents are too slow to suggest while typing. Choose a local model or an API here."
                    )
                }

                if usesBuiltIn {
                    BuiltInModelsSection()
                }
                if usesOllama {
                    LocalModelsSection(ollama: ollama)
                }

                PromptsSection()

                Section {
                    Toggle("Allow on Production connections", isOn: $ai.settings.allowProduction)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: Layout.Settings.width, height: Layout.Settings.aiHeight)
        .task(id: usesOllama) { if usesOllama { await ollama.refresh() } }
    }
}

/// Address, key and model of one provider, for one purpose.
private struct ProviderFields: View {
    let kind: AIProviderKind
    let purpose: AIRequest.Purpose
    let ollama: OllamaModels
    /// Whether to show settings shared with the other purpose (address, key). They appear once, under
    /// Ask AI, unless suggestions use a different provider.
    var showsShared = true
    @Bindable private var ai = AIService.shared
    @State private var cliPath: String?
    @State private var lookingForCLI = false

    private var modelBinding: Binding<String> {
        let store: WritableKeyPath<AISettings, [String: String]> = purpose == .inline ? \.inlineModels : \.models
        return Binding(
            get: { ai.settings[keyPath: store][kind.rawValue] ?? "" },
            set: { ai.settings[keyPath: store][kind.rawValue] = $0 }
        )
    }

    private var baseURLBinding: Binding<String> {
        Binding(get: { ai.settings.baseURLs[kind.rawValue] ?? "" }, set: { ai.settings.baseURLs[kind.rawValue] = $0 })
    }

    var body: some View {
        switch kind {
        case .builtIn:
            Picker("Model", selection: modelBinding) {
                let current = ai.settings.model(kind, for: purpose)
                let installed = LocalModelStore().installed().map(\.id)
                if !installed.contains(current) {
                    Text(current.isEmpty ? "None" : "\(BuiltInModels.name(of: current)) (not downloaded)")
                        .tag(modelBinding.wrappedValue)
                }
                ForEach(installed, id: \.self) { Text(BuiltInModels.name(of: $0)).tag($0) }
            }
        case .appleIntelligence:
            if let reason = AppleIntelligenceProvider.unavailableReason {
                Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            } else {
                Label(
                    "Ready. Runs on this Mac; nothing is sent over the network.",
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)
            }
        case .ollama:
            if showsShared {
                TextField("Server", text: baseURLBinding, prompt: Text(kind.defaultBaseURL))
            }
            Picker("Model", selection: modelBinding) {
                let current = ai.settings.model(kind, for: purpose)
                if !ollama.installed.contains(where: { $0.name == current }) {
                    Text(current.isEmpty ? "None" : "\(current) (not downloaded)").tag(modelBinding.wrappedValue)
                }
                ForEach(ollama.installed) { Text($0.name).tag($0.name) }
            }
        case .openAICompatible:
            if showsShared {
                TextField("Base URL", text: baseURLBinding, prompt: Text(kind.defaultBaseURL))
                APIKeyField(kind: kind)
            }
            TextField(
                "Model",
                text: modelBinding,
                prompt: Text(purpose == .inline ? "Same as Ask AI" : "e.g. gpt-4.1, or a LiteLLM model name")
            )
            if purpose == .generate {
                EffortPicker(kind: kind)
            }
        case .anthropic:
            if showsShared {
                APIKeyField(kind: kind)
            }
            TextField(
                "Model",
                text: modelBinding,
                prompt: Text(purpose == .inline ? "Same as Ask AI; claude-haiku-5-5 is faster" : kind.defaultModel)
            )
            if purpose == .generate {
                EffortPicker(kind: kind)
            }
        case .claudeCode, .codex:
            Group {
                if lookingForCLI {
                    ProgressView().controlSize(.small)
                } else if let cliPath {
                    LabeledContent("Found", value: cliPath)
                } else {
                    Label(
                        "Not found. Install it, sign in once in Terminal, then reopen Settings.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                }
            }
            .task(id: kind) {
                lookingForCLI = true
                cliPath = await CLIProvider.locate(kind == .claudeCode ? .claude : .codex)
                lookingForCLI = false
            }
            TextField("Model", text: modelBinding, prompt: Text("The tool's default"))
            if purpose == .generate {
                EffortPicker(kind: kind)
            }
        }
    }
}

/// An API key field bound to one provider: it loads that provider's key and saves to it, whatever the
/// pickers do meanwhile.
private struct APIKeyField: View {
    let kind: AIProviderKind
    @State private var key = ""
    @State private var loaded = false
    @State private var error: String?

    var body: some View {
        SecureField("API key", text: $key)
            .onSubmit(save)
            .onDisappear(perform: save)
            .task(id: kind) {
                key = await AIService.shared.apiKey(for: kind)
                loaded = true
            }
        if let error {
            Text(error).font(.caption).foregroundStyle(.red)
        }
    }

    private func save() {
        guard loaded else { return }
        let key = key
        let kind = kind
        Task {
            do {
                try await AIService.shared.setAPIKey(key, for: kind)
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

private struct TestRow: View {
    let purpose: AIRequest.Purpose
    @State private var result: Result<String, Error>?
    @State private var testing = false

    var body: some View {
        HStack {
            Button("Test") { run() }.disabled(testing)
            if testing {
                ProgressView().controlSize(.small)
            }
            Spacer()
            switch result {
            case .success(let reply):
                Label("Answered “\(reply.prefix(40))”", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .failure(let error): Text(error.localizedDescription).foregroundStyle(.red).lineLimit(3)
            case nil: EmptyView()
            }
        }
    }

    private func run() {
        testing = true
        result = nil
        // Let the key field's save (on Return / leaving it) land first.
        Task {
            defer { testing = false }
            do { result = .success(try await AIService.shared.test(purpose)) } catch { result = .failure(error) }
        }
    }
}

/// Edits one system prompt; empty or "Restore Default" goes back to Tabula's.
struct PromptEditor: View {
    let prompt: SQLPrompts.PromptKind
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.barPadding) {
            Text("\(prompt.title) instructions").font(.headline)
            Text(
                "Sent as the system prompt. {database} becomes the database's name (PostgreSQL, MySQL / MariaDB, SQLite). "
                    + "The schema and your SQL are added after it automatically. MongoDB connections use built-in shell prompts "
                    + "unless you change this one."
            )
            .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(Layout.Font.mono)
                .frame(width: Layout.Settings.width, height: Layout.Settings.promptHeight)
                .overlay(
                    RoundedRectangle(cornerRadius: Layout.cornerRadius).strokeBorder(Color(nsColor: .separatorColor))
                )
            HStack {
                Button("Restore Default") { text = prompt.defaultTemplate }
                    .disabled(text == prompt.defaultTemplate)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    // The default is stored as "no override", so later improvements to it still apply.
                    AIService.shared.settings.prompts[prompt.rawValue] = text == prompt.defaultTemplate ? nil : text
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Layout.barPadding * 2)
        .onAppear { text = AIService.shared.settings.instructions(prompt) ?? prompt.defaultTemplate }
    }
}

/// Settings rows that open the prompt editor.
struct PromptsSection: View {
    @Bindable private var ai = AIService.shared
    @State private var editing: SQLPrompts.PromptKind?

    var body: some View {
        Section {
            ForEach(SQLPrompts.PromptKind.allCases) { prompt in
                LabeledContent(prompt.title) {
                    HStack {
                        Text(ai.settings.instructions(prompt) == nil ? "Default" : "Custom").foregroundStyle(.secondary)
                        Button("Edit…") { editing = prompt }
                    }
                }
            }
        } header: {
            Text("Instructions")
        } footer: {
            Text(
                "The system prompts Tabula sends. Change them to set a style, language or rules (for example: answer in Vietnamese, always add LIMIT)."
            )
        }
        .sheet(item: $editing) { PromptEditor(prompt: $0) }
    }
}

/// Reasoning effort for providers that take one. Higher thinks longer and costs more; suggestions while
/// typing always use the quickest.
struct EffortPicker: View {
    let kind: AIProviderKind
    @Bindable private var ai = AIService.shared

    var body: some View {
        if !kind.effortLevels.isEmpty {
            Picker(
                "Effort",
                selection: Binding(
                    get: { ai.settings.efforts[kind.rawValue] ?? "" },
                    set: { ai.settings.efforts[kind.rawValue] = $0.isEmpty ? nil : $0 }
                )
            ) {
                Text("Default").tag("")
                Divider()
                ForEach(kind.effortLevels, id: \.self) { Text($0.capitalized).tag($0) }
            }
            .help("How much the model thinks before answering. Higher is slower and costs more.")
        }
    }
}
