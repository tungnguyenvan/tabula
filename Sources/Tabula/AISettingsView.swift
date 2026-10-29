import AppKit
import SwiftUI
import TabulaAI
import TabulaFoundation

/// Local models served by Ollama, for the AI settings.
@MainActor @Observable
final class OllamaModels {
    private(set) var version: String?
    private(set) var installed: [OllamaLibrary.InstalledModel] = []
    /// Model name → download progress (nil fraction while Ollama prepares).
    private(set) var downloads: [String: OllamaLibrary.PullProgress] = [:]
    private(set) var checked = false
    var error: String?
    private var library: OllamaLibrary {
        OllamaLibrary(baseURL: AIEndpoint(kind: .ollama, baseURL: AIService.shared.settings.baseURL(.ollama)).baseURL)
    }

    func refresh() async {
        version = await library.version()
        installed = (try? await library.installed()) ?? []
        checked = true
    }

    func isInstalled(_ name: String) -> Bool {
        installed.contains { $0.name == name || $0.name == name + ":latest" }
    }

    /// Downloads a model; `then` runs once it is installed (e.g. to start using it).
    func download(_ name: String, then: @escaping @MainActor () -> Void = {}) {
        guard downloads[name] == nil else { return }
        downloads[name] = OllamaLibrary.PullProgress(status: "Starting…", fraction: nil)
        let library = library
        Task {
            do {
                try await library.pull(name) { progress in
                    Task { @MainActor in self.downloads[name] = progress }
                }
                error = nil
                then()
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

private struct LocalModelsSection: View {
    let ollama: OllamaModels
    @Bindable private var ai = AIService.shared

    var body: some View {
        Section {
            if !ollama.checked {
                ProgressView().controlSize(.small)
            } else if ollama.version == nil {
                Label(
                    "Ollama runs the models on this Mac. Install it, open it, then come back here to download one.",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.orange)
                HStack {
                    Link("Download Ollama", destination: URL(string: "https://ollama.com/download")!)
                    Spacer()
                    Button("Check Again") { Task { await ollama.refresh() } }
                }
            } else {
                ForEach(Defaults.AI.recommendedLocalModels) { model in
                    row(name: model.name, summary: model.summary, forTyping: model.forTyping)
                }
                ForEach(
                    ollama.installed.filter { installed in
                        !Defaults.AI.recommendedLocalModels.contains { $0.name == installed.name }
                    }
                ) { model in
                    row(
                        name: model.name,
                        summary: ByteCountFormatter.string(fromByteCount: model.size, countStyle: .file),
                        forTyping: false
                    )
                }
            }
            if let error = ollama.error {
                Text(error).foregroundStyle(.red)
            }
        } header: {
            Text("Local models")
        } footer: {
            if let version = ollama.version {
                Text("Ollama \(version). Models are downloaded to and run on this Mac.")
            }
        }
    }

    private func row(name: String, summary: String, forTyping: Bool) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(name)
                Text(summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            control(name, forTyping: forTyping)
        }
    }

    @ViewBuilder
    private func control(_ name: String, forTyping: Bool) -> some View {
        if let progress = ollama.downloads[name] {
            if let fraction = progress.fraction {
                ProgressView(value: fraction).frame(width: Layout.Settings.progressWidth)
            } else {
                Text(progress.status).font(.caption).foregroundStyle(.secondary)
            }
        } else if ollama.isInstalled(name) {
            Menu {
                Button("Use for Ask AI") { useForAskAI(name) }
                Button("Use for Suggestions") { useForTyping(name) }
                Divider()
                Button("Delete", role: .destructive) { ollama.delete(name) }
            } label: {
                Text(usage(name))
            }
            .fixedSize()
        } else {
            Button("Download") {
                // Once downloaded, start using it for what it's suited to.
                ollama.download(name) { forTyping ? useForTyping(name) : useForAskAI(name) }
            }
        }
    }

    private func usage(_ name: String) -> String {
        let assistant = ai.settings.provider == .ollama && ai.settings.model(.ollama, for: .generate) == name
        let typing = ai.settings.provider(for: .inline) == .ollama && ai.settings.model(.ollama, for: .inline) == name
        switch (assistant, typing) {
        case (true, true): return "Used for both"
        case (true, false): return "Used for Ask AI"
        case (false, true): return "Used for suggestions"
        case (false, false): return "Installed"
        }
    }

    private func useForAskAI(_ name: String) {
        ai.settings.provider = .ollama
        ai.settings.models[AIProviderKind.ollama.rawValue] = name
    }

    private func useForTyping(_ name: String) {
        ai.settings.inlineSuggestions = true
        if ai.settings.provider != .ollama {
            ai.settings.inlineProvider = .ollama
        }
        ai.settings.inlineModels[AIProviderKind.ollama.rawValue] = name
    }
}

/// Model files Tabula runs itself: the catalog's downloads and files the user added.
@MainActor @Observable
final class BuiltInModels {
    static let shared = BuiltInModels()
    let store = LocalModelStore()
    private(set) var installed: [(id: String, size: Int64)] = []
    /// Model id → download progress (0…1).
    private(set) var downloads: [String: Double] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    var error: String?

    private init() { refresh() }

    func refresh() { installed = store.installed() }

    static func name(of id: String) -> String {
        LocalModel.catalog.first { $0.id == id }?.name ?? id
    }

    func download(_ model: LocalModel, then: @escaping @MainActor () -> Void) {
        guard tasks[model.id] == nil else { return }
        downloads[model.id] = 0
        let store = store
        tasks[model.id] = Task {
            do {
                try await store.download(model) { fraction in
                    Task { @MainActor in self.downloads[model.id] = fraction }
                }
                error = nil
                then()
            } catch is CancellationError {
            } catch let urlError as URLError where urlError.code == .cancelled {
            } catch {
                self.error = "\(model.name): \(error.localizedDescription)"
            }
            downloads[model.id] = nil
            tasks[model.id] = nil
            refresh()
        }
    }

    func cancel(_ id: String) { tasks[id]?.cancel() }

    func add(_ file: URL) -> String? {
        do {
            let id = try store.add(file)
            error = nil
            refresh()
            return id
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    func delete(_ id: String) {
        LocalModelRunner.shared.unload()
        do {
            try store.delete(id)
            error = nil
        } catch { self.error = error.localizedDescription }
        refresh()
    }
}

private struct BuiltInModelsSection: View {
    @Bindable private var ai = AIService.shared
    @State private var models = BuiltInModels.shared
    @State private var addingLink = false
    @State private var link = ""

    private var extraModels: [(id: String, size: Int64)] {
        models.installed.filter { installed in !LocalModel.catalog.contains { $0.id == installed.id } }
    }

    var body: some View {
        Section {
            ForEach(LocalModel.catalog) { model in
                row(id: model.id, name: model.name, detail: "\(size(model.size)) · \(model.summary)") {
                    downloadButton(model)
                }
            }
            ForEach(extraModels, id: \.id) { model in
                row(id: model.id, name: model.id, detail: size(model.size)) { EmptyView() }
            }
            HStack {
                Button("Add Model File…", action: chooseFile)
                Button("Add from Link…") { addingLink = true }
                Spacer()
                Button("Show in Finder") {
                    try? FileManager.default.createDirectory(
                        at: models.store.directory,
                        withIntermediateDirectories: true
                    )
                    NSWorkspace.shared.activateFileViewerSelecting([models.store.directory])
                }
            }
            if let error = models.error {
                Text(error).foregroundStyle(.red)
            }
        } header: {
            Text("Models on this Mac")
        } footer: {
            Text(
                "Models run inside Tabula and never leave this Mac. Any GGUF model works: add a file, or a link to one (for example from Hugging Face). Models are stored in Tabula's folder, not in the app."
            )
        }
        .onAppear { models.refresh() }
        .sheet(isPresented: $addingLink) { linkSheet }
    }

    private func row(id: String, name: String, detail: String, @ViewBuilder notInstalled: () -> some View) -> some View
    {
        HStack {
            VStack(alignment: .leading) {
                Text(name)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let progress = models.downloads[id] {
                ProgressView(value: progress).frame(width: Layout.Settings.progressWidth)
                Button {
                    models.cancel(id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless).help("Stop downloading")
            } else if models.installed.contains(where: { $0.id == id }) {
                Menu {
                    Button("Use for Ask AI") { use(id, for: .generate) }
                    Button("Use for Suggestions While Typing") { use(id, for: .inline) }
                    Divider()
                    Button("Delete", role: .destructive) { models.delete(id) }
                } label: {
                    Text(usage(id))
                }
                .fixedSize()
            } else {
                notInstalled()
            }
        }
    }

    private func downloadButton(_ model: LocalModel) -> some View {
        Button("Download") {
            models.download(model) { use(model.id, for: model.forTyping ? .inline : .generate) }
        }
    }

    private var linkSheet: some View {
        VStack(alignment: .leading, spacing: Layout.barPadding * 2) {
            Text("Add a model from a link").font(.headline)
            Text("A direct link to a .gguf file, such as a Hugging Face “resolve/main/…gguf” URL.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("https://huggingface.co/…/resolve/main/model.gguf", text: $link)
                .textFieldStyle(.roundedBorder)
                .frame(width: Layout.Settings.width - Layout.barPadding * 8)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { addingLink = false }.keyboardShortcut(.cancelAction)
                Button("Download") {
                    guard let url = URL(string: link.trimmingCharacters(in: .whitespaces)) else { return }
                    do {
                        let model = try models.store.model(from: url)
                        models.download(model) { use(model.id, for: .generate) }
                        addingLink = false
                        link = ""
                    } catch {
                        models.error = error.localizedDescription
                        addingLink = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(URL(string: link.trimmingCharacters(in: .whitespaces))?.scheme?.hasPrefix("http") != true)
            }
        }
        .padding(Layout.barPadding * 2)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "gguf") ?? .data]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a GGUF model file"
        guard panel.runModal() == .OK, let url = panel.url, let id = models.add(url) else { return }
        use(id, for: .generate)
    }

    private func use(_ id: String, for purpose: AIRequest.Purpose) {
        let key = AIProviderKind.builtIn.rawValue
        if purpose == .inline {
            ai.settings.inlineSuggestions = true
            if ai.settings.provider != .builtIn {
                ai.settings.inlineProvider = .builtIn
            }
            ai.settings.inlineModels[key] = id
        } else {
            ai.settings.provider = .builtIn
            ai.settings.models[key] = id
        }
    }

    private func usage(_ id: String) -> String {
        let assistant = ai.settings.provider == .builtIn && ai.settings.model(.builtIn, for: .generate) == id
        let typing = ai.settings.provider(for: .inline) == .builtIn && ai.settings.model(.builtIn, for: .inline) == id
        switch (assistant, typing) {
        case (true, true): return "Used for both"
        case (true, false): return "Used for Ask AI"
        case (false, true): return "Used for suggestions"
        case (false, false): return "Downloaded"
        }
    }

    private func size(_ bytes: Int64) -> String {
        bytes > 0 ? ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) : "Size unknown"
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
