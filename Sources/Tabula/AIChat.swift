import AppKit
import SwiftUI
import TabulaCore

/// A conversation with the AI about one connection, shown in the panel on the right.
@MainActor @Observable
final class AIChatModel {
    struct Message: Identifiable, Equatable {
        enum Role { case user, assistant }
        let id = UUID()
        let role: Role
        var text: String
        /// The model's reasoning, when the provider shares it.
        var thinking = ""
        /// Seconds of reasoning before the answer began.
        var thoughtFor: TimeInterval?
        /// Still arriving.
        var streaming = false
    }

    private(set) var messages: [Message] = []
    /// Bumped as a streamed answer grows, so the list can follow it.
    private(set) var revision = 0
    var input = ""
    private(set) var busy = false
    var error: String?
    private var task: Task<Void, Never>?

    /// Sends `input` with the conversation so far, the schema and the SQL in the editor.
    func send(workspace: WorkspaceModel, editorSQL: String?) {
        let question = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !busy else { return }
        if let refusal = AIService.shared.refusal(for: workspace.config) {
            error = refusal
            return
        }
        let history = messages.suffix(Defaults.AI.chatHistoryMessages).map { ($0.role == .user ? "User" : "Assistant", $0.text) }
        messages.append(Message(role: .user, text: question))
        input = ""
        error = nil
        busy = true
        let kind = workspace.driver?.kind ?? workspace.config.kind
        let reply = Message(role: .assistant, text: "", streaming: true)
        messages.append(reply)
        task = Task {
            defer {
                busy = false
                update(reply.id) { $0.streaming = false }
                // Nothing came back (an error before the first token): no empty bubble.
                if let index = messages.firstIndex(where: { $0.id == reply.id }), messages[index].text.isEmpty, messages[index].thinking.isEmpty {
                    messages.remove(at: index)
                }
            }
            do {
                let schema = await workspace.loadedAISchema(for: [editorSQL ?? "", question].joined(separator: "\n"))
                let request = SQLPrompts.chat(question: question, history: history, editorSQL: editorSQL, schema: schema, kind: kind,
                instructions: AIService.shared.settings.instructions(.chat))
                try await receive(AIService.shared.stream(request), into: reply.id)
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    /// Appends the stream to the message, redrawing a few times a second rather than for every token.
    private func receive(_ stream: AIStream, into id: UUID) async throws {
        let started = Date()
        var lastRefresh = Date.distantPast
        var text = "", thinking = ""
        func flush() {
            update(id) { message in
                message.thinking += thinking
                message.text += text
                if message.thoughtFor == nil, !message.thinking.isEmpty, !message.text.isEmpty {
                    message.thoughtFor = Date().timeIntervalSince(started)
                }
            }
            text = ""
            thinking = ""
            lastRefresh = Date()
            revision += 1
        }
        // Whatever arrived before a failure stays in the message.
        defer {
            flush()
            update(id) { $0.text = $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        for try await event in stream {
            switch event {
            case .text(let piece): text += piece
            case .thinking(let piece): thinking += piece
            }
            if Date().timeIntervalSince(lastRefresh) >= Defaults.AI.streamRefreshInterval { flush() }
        }
    }

    #if DEBUG
    /// Plays a made-up answer at a steady pace, to look at how streaming and reasoning are shown.
    func simulate(question: String, thinking: String, answer: String, piece: Duration) {
        messages.append(Message(role: .user, text: question))
        let reply = Message(role: .assistant, text: "", streaming: true)
        messages.append(reply)
        busy = true
        task = Task {
            defer { busy = false; update(reply.id) { $0.streaming = false } }
            let stream = AIStream { continuation in
                Task {
                    for word in thinking.split(separator: " ") { try await Task.sleep(for: piece); continuation.yield(.thinking(word + " ")) }
                    for word in answer.split(separator: " ", omittingEmptySubsequences: false) {
                        try await Task.sleep(for: piece); continuation.yield(.text(word + " "))
                    }
                    continuation.finish()
                }
            }
            try? await receive(stream, into: reply.id)
        }
    }
    #endif

    private func update(_ id: UUID, _ change: (inout Message) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        change(&messages[index])
    }

    func stop() {
        task?.cancel()
        busy = false
    }

    func clear() {
        stop()
        messages = []
        error = nil
    }
}

/// Text and fenced SQL blocks of an answer, so code gets Insert / Run / Copy.
enum ChatSegment: Equatable {
    case text(String)
    case code(String)

    static func split(_ reply: String) -> [ChatSegment] {
        var segments: [ChatSegment] = []
        var rest = Substring(reply)
        while let open = rest.range(of: "```") {
            let before = rest[..<open.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            if !before.isEmpty { segments.append(.text(before)) }
            var body = rest[open.upperBound...]
            // Skip the language tag on the fence line.
            if let newline = body.firstIndex(of: "\n") { body = body[body.index(after: newline)...] }
            guard let close = body.range(of: "```") else {
                segments.append(.code(body.trimmingCharacters(in: .whitespacesAndNewlines)))
                return segments
            }
            let code = body[..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            if !code.isEmpty { segments.append(.code(code)) }
            rest = body[close.upperBound...]
        }
        let tail = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { segments.append(.text(tail)) }
        return segments
    }
}

struct AIChatView: View {
    let workspace: WorkspaceModel
    @Bindable var chat: AIChatModel
    @FocusState private var inputFocused: Bool
    @State private var editingInstructions = false
    /// Whether the end of the conversation is on screen; a streaming answer is followed only then, so scrolling
    /// up to read something stays put.
    @State private var atBottom = true

    private var queryTab: QueryTabModel? {
        if case .query(let query) = workspace.selectedTab { return query }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Layout.Chat.spacing) {
                        if chat.messages.isEmpty { emptyState }
                        ForEach(chat.messages) { message in
                            MessageView(message: message, insert: insert, run: run).id(message.id)
                        }

                        if let error = chat.error {
                            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled)
                        }
                        Color.clear.frame(height: 1).id(Self.endID)
                            .onAppear { atBottom = true }
                            .onDisappear { atBottom = false }
                    }
                    .padding(Layout.Chat.padding)
                }
                .onChange(of: chat.messages.count) { _, _ in
                    if let last = chat.messages.last?.id { withAnimation { proxy.scrollTo(last, anchor: .bottom) } }
                }
                // Follow an answer as it streams in, unless the user scrolled away from the end.
                .onChange(of: chat.revision) { _, _ in
                    if atBottom { proxy.scrollTo(Self.endID, anchor: .bottom) }
                }
            }
            Divider()
            composer
        }
        .sheet(isPresented: $editingInstructions) { PromptEditor(prompt: .chat) }
    }

    private static let endID = "end"

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Layout.barPadding) {
            Label("Ask about this database", systemImage: "sparkles").font(.headline)
            Text("Write or explain queries, find tables, or change the SQL in the editor. The AI sees table and column names, keys and the editor's SQL, never rows.")
                .font(.callout).foregroundStyle(.secondary)
            if AIService.shared.refusal(for: workspace.config) != nil {
                SettingsLink { Text("Turn on AI in Settings…") }
            }
        }
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: Layout.barPadding / 2) {
            input
            HStack(spacing: Layout.barPadding) {
                ModelPicker()
                ChatEffortPicker()
            }
        }
        .padding(Layout.Chat.padding)
        .onAppear { inputFocused = true }
    }

    private var input: some View {
        HStack(alignment: .bottom, spacing: Layout.barPadding) {
            TextField("Ask the AI", text: $chat.input, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...Layout.Chat.inputLines)
                .focused($inputFocused)
                .onSubmit(send)
            if chat.busy {
                Button("Stop") { chat.stop() }
            } else {
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.borderless)
                    .disabled(chat.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Send (↩)")
            }
            Menu {
                Button("Clear Conversation") { chat.clear() }
                Button("Edit Chat Instructions…") { editingInstructions = true }
                SettingsLink { Text("AI Settings…") }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private func send() {
        chat.send(workspace: workspace, editorSQL: queryTab?.sql)
    }

    /// Puts SQL in the current query tab, or a new one.
    private func insert(_ sql: String) {
        if let queryTab {
            queryTab.insertRequest = (sql, UUID())
        } else {
            workspace.newQueryTab(sql: sql)
        }
    }

    private func run(_ sql: String) {
        insert(sql)
        // Inserted SQL is selected, so running "the selection" runs exactly it.
        DispatchQueue.main.async {
            if let query = self.queryTab { query.runRequest = (false, query.runRequest.id + 1) }
        }
    }
}

private struct MessageView: View {
    let message: AIChatModel.Message
    let insert: (String) -> Void
    let run: (String) -> Void

    /// Set when the user opens or closes the reasoning; until then it is open while the model thinks.
    @State private var showThinking: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.barPadding) {
            Text(message.role == .user ? "You" : "AI").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            if message.role == .user {
                Text(message.text).textSelection(.enabled)
            } else {
                if !message.thinking.isEmpty {
                    DisclosureGroup(isExpanded: Binding(get: { showThinking ?? (message.streaming && message.text.isEmpty) },
                                                        set: { showThinking = $0 })) {
                        // Selectable text ignores hierarchical styles; the system's secondary label color sets it apart.
                        Text(message.thinking.trimmingCharacters(in: .whitespacesAndNewlines))
                            .font(.callout)
                            .foregroundColor(Color(nsColor: .secondaryLabelColor))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Label(thinkingTitle, systemImage: "brain").font(.callout).foregroundStyle(.secondary)
                    }
                } else if message.streaming && message.text.isEmpty {
                    HStack { ProgressView().controlSize(.small); Text("Thinking…").foregroundStyle(.secondary) }
                }
                ForEach(Array(ChatSegment.split(message.text).enumerated()), id: \.offset) { _, segment in
                    switch segment {
                    case .text(let text):
                        Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
                            .textSelection(.enabled)
                    case .code(let sql):
                        CodeBlock(sql: sql, insert: insert, run: run)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension MessageView {
    private var thinkingTitle: String {
        if message.streaming && message.text.isEmpty { return "Thinking…" }
        guard let seconds = message.thoughtFor else { return "Thinking" }
        return seconds < 1 ? "Thought briefly" : "Thought for \(Int(seconds.rounded())) s"
    }
}

private struct CodeBlock: View {
    let sql: String
    let insert: (String) -> Void
    let run: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(sql)
                .font(Layout.Font.monoSmall)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Layout.barPadding)
            Divider()
            HStack(spacing: Layout.barPadding) {
                Button("Insert") { insert(sql) }.help("Insert into the query editor")
                Button("Run") { run(sql) }.help("Insert into the query editor and run it")
                Spacer()
                Button { Clipboard.copy(sql) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).help("Copy")
            }
            .controlSize(.small)
            .padding(.horizontal, Layout.barPadding)
            .padding(.vertical, Layout.barPadding / 2)
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: Layout.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: Layout.cornerRadius).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

/// Which model answers in the chat (and Ask AI), switchable right under the message field.
private struct ModelPicker: View {
    @Bindable private var ai = AIService.shared
    private var models = BuiltInModels.shared

    private var current: String {
        let settings = ai.settings
        let kind = settings.provider
        let model = settings.model(kind, for: .generate)
        switch kind {
        case .builtIn: return model.isEmpty ? "Model on this Mac" : BuiltInModels.name(of: model)
        case .anthropic: return kind.suggestedModels.first { $0.id == model }?.name ?? model
        case .appleIntelligence: return "Apple Intelligence"
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .ollama, .openAICompatible: return model.isEmpty ? kind.displayName : model
        }
    }

    var body: some View {
        Menu {
            Section("On this Mac") {
                ForEach(models.installed, id: \.id) { model in
                    choice(BuiltInModels.name(of: model.id), kind: .builtIn, model: model.id)
                }
                if models.installed.isEmpty {
                    SettingsLink { Text("Download a Model…") }
                }
                choice("Apple Intelligence", kind: .appleIntelligence, model: "")
                    .disabled(AppleIntelligenceProvider.unavailableReason != nil)
                if let ollama = ai.settings.models[AIProviderKind.ollama.rawValue], !ollama.isEmpty {
                    choice("\(ollama) (Ollama)", kind: .ollama, model: ollama)
                }
            }
            Section("Claude API") {
                ForEach(AIProviderKind.anthropic.suggestedModels, id: \.id) { model in
                    choice(model.name, kind: .anthropic, model: model.id)
                }
            }
            if let openAI = ai.settings.models[AIProviderKind.openAICompatible.rawValue], !openAI.isEmpty {
                Section("OpenAI-compatible") { choice(openAI, kind: .openAICompatible, model: openAI) }
            }
            Section("Installed tools") {
                choice("Claude Code", kind: .claudeCode, model: ai.settings.models[AIProviderKind.claudeCode.rawValue] ?? "")
                choice("Codex", kind: .codex, model: ai.settings.models[AIProviderKind.codex.rawValue] ?? "")
            }
            Divider()
            SettingsLink { Text("Manage Models…") }
        } label: {
            Label(current, systemImage: "cpu").font(Layout.Font.small)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Model for the chat and Ask AI")
        .onAppear { models.refresh() }
    }

    private func choice(_ title: String, kind: AIProviderKind, model: String) -> some View {
        let selected = ai.settings.provider == kind && (model.isEmpty || ai.settings.model(kind, for: .generate) == model)
        return Button {
            ai.settings.provider = kind
            if !model.isEmpty { ai.settings.models[kind.rawValue] = model }
        } label: {
            if selected { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }
}

/// Effort for the chat's model, when it takes one (recent Claude models, Claude Code, Codex, OpenAI reasoning).
private struct ChatEffortPicker: View {
    @Bindable private var ai = AIService.shared

    var body: some View {
        let kind = ai.settings.provider
        if !kind.effortLevels.isEmpty {
            Menu {
                Picker("Effort", selection: Binding(
                    get: { ai.settings.efforts[kind.rawValue] ?? "" },
                    set: { ai.settings.efforts[kind.rawValue] = $0.isEmpty ? nil : $0 })) {
                    Text("Default").tag("")
                    ForEach(kind.effortLevels, id: \.self) { Text($0.capitalized).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label("Effort: \((ai.settings.efforts[kind.rawValue] ?? "default").capitalized)", systemImage: "gauge.with.dots.needle.50percent")
                    .font(Layout.Font.small)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("How much the model thinks before answering. Higher is slower and costs more.")
        }
    }
}
