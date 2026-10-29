import AppKit
import SwiftUI
import TabulaAI
import TabulaFoundation

/// The AI conversations about one connection, shown in the panel on the right. They are saved on this Mac,
/// so earlier ones can be opened again. While answering, the assistant may use tools (`AgentTool`).
@MainActor @Observable
final class AIChatModel {
    typealias Message = ChatMessage

    private let connectionID: UUID
    private let store: ChatStore
    /// Saved conversations, newest first.
    private(set) var conversations: [ChatConversation]
    /// The conversation shown; nil until a new one gets its first message.
    private(set) var currentID: UUID?
    private(set) var messages: [Message] = []
    /// Bumped as a streamed answer grows, so the list can follow it.
    private(set) var revision = 0
    var input = ""
    private(set) var busy = false
    var error: String?
    private var task: Task<Void, Never>?
    /// Identifies the running answer, so one that was stopped can't change the chat when it finally ends.
    private var run: UUID?
    /// The model reply being written, if any.
    private var replyID: UUID?
    /// A Production query waiting for the user's answer.
    private var approval: (id: UUID, continuation: CheckedContinuation<Bool, Never>)?

    init(connectionID: UUID) {
        self.connectionID = connectionID
        store = AppState.chatStore
        let loaded = store.load(connectionID)
        conversations = loaded.conversations
        reportSetAside(loaded)
        // Opening the panel again shows where the user left off.
        if let latest = conversations.first {
            currentID = latest.id
            messages = latest.messages
        }
    }

    var title: String { conversations.first { $0.id == currentID }?.title ?? "New Chat" }

    // MARK: Conversations

    func newConversation() {
        stop()
        currentID = nil
        messages = []
        error = nil
    }

    func open(_ id: UUID) {
        guard id != currentID, let conversation = conversations.first(where: { $0.id == id }) else { return }
        stop()
        currentID = id
        messages = conversation.messages
        error = nil
    }

    func delete(_ id: UUID) {
        if id == currentID {
            newConversation()
        }
        conversations.removeAll { $0.id == id }
        deleted.insert(id)
        persist()
    }

    /// Conversations deleted here, so merging with the file (below) doesn't bring them back.
    private var deleted: Set<UUID> = []

    /// Writes the current conversation into the saved list.
    private func save() {
        guard let currentID, messages.contains(where: { $0.role == .user }) else { return }
        let conversation = ChatConversation(
            id: currentID,
            title: ChatConversation.title(for: messages),
            updated: Date(),
            messages: messages
        )
        conversations.removeAll { $0.id == currentID }
        conversations.insert(conversation, at: 0)
        persist()
    }

    /// Tells the user when saved chats couldn't be read, instead of showing an empty history as if there were none.
    private func reportSetAside(_ loaded: ChatStore.Loaded) {
        guard let setAside = loaded.setAside else {
            return
        }
        error = "Saved chats for this connection couldn't be read. They were moved to \(setAside.path)."
    }

    private func persist() {
        // Another window with this connection may have saved conversations of its own meanwhile.
        let known = Set(conversations.map(\.id)).union(deleted)
        let loaded = store.load(connectionID)
        reportSetAside(loaded)
        conversations += loaded.conversations.filter { !known.contains($0.id) }
        conversations.sort { $0.updated > $1.updated }
        do {
            try store.save(conversations, for: connectionID)
        } catch {
            self.error = "The conversation couldn't be saved: \(error.localizedDescription)"
        }
    }

    // MARK: Asking

    /// Sends `input` with the conversation so far, the schema and the SQL in the editor, then lets the
    /// assistant use tools until it answers.
    func send(workspace: WorkspaceModel, editorSQL: String?) {
        let question = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !busy else { return }
        if let refusal = AIService.shared.refusal(for: workspace.config) {
            error = refusal
            return
        }
        let history = Self.history(messages.suffix(Defaults.AI.chatHistoryMessages))
        if currentID == nil {
            currentID = UUID()
        }
        messages.append(Message(role: .user, text: question))
        save()
        input = ""
        error = nil
        busy = true
        let kind = workspace.driver?.kind ?? workspace.config.kind
        let canQuery = AIService.shared.settings.assistantQueries
        let askFirst = workspace.config.tag == .production
        let run = UUID()
        self.run = run
        var reply = startReply(preparing: true)
        task = Task {
            defer {
                if self.run == run {
                    finish(reply)
                    busy = false
                    self.run = nil
                    save()
                }
            }
            do {
                let schema = await workspace.loadedAISchema(for: [editorSQL ?? "", question].joined(separator: "\n"))
                try Task.checkCancellation()
                update(reply) { $0.preparing = false }
                let tools = AgentProtocol.instructions(kind: kind, canQuery: canQuery)
                var steps: [(call: AgentToolCall, result: String)] = []
                for step in 0..<Defaults.AI.agentMaxSteps {
                    let last = step == Defaults.AI.agentMaxSteps - 1
                    if step > 0 {
                        reply = startReply(preparing: false)
                    }
                    let request = SQLPrompts.chat(
                        question: question,
                        history: history,
                        editorSQL: editorSQL,
                        schema: schema,
                        kind: kind,
                        instructions: AIService.shared.settings.instructions(.chat),
                        tools: last ? nil : tools,
                        steps: steps
                    )
                    try await receive(AIService.shared.stream(request), into: reply)
                    // A cancelled stream ends without an error; a stopped answer must not go on to use a tool.
                    try Task.checkCancellation()
                    guard self.run == run else {
                        throw CancellationError()
                    }
                    guard !last,
                        let call = messages.first(where: { $0.id == reply })
                            .flatMap({ AgentProtocol.call(in: $0.text) })
                    else { break }
                    // What the model wrote before the request stays; the request shows as a tool step.
                    update(reply) { $0.text = AgentProtocol.visibleText($0.text) }
                    finish(reply)
                    let result = try await use(
                        call,
                        workspace: workspace,
                        canQuery: canQuery,
                        askFirst: askFirst,
                        run: run
                    )
                    steps.append((call, result))
                    save()
                }
            } catch {
                if !Task.isCancelled {
                    self.error = error.localizedDescription
                }
            }
        }
    }

    /// Runs a tool call, after asking when it is a Production query, and shows it in the conversation.
    private func use(
        _ call: AgentToolCall,
        workspace: WorkspaceModel,
        canQuery: Bool,
        askFirst: Bool,
        run: UUID
    ) async throws -> String {
        let isQuery = call.tool == .runQuery
        let step = Message(
            role: .tool,
            text: "",
            tool: .init(call: call, status: isQuery && askFirst ? .awaitingApproval : .running)
        )
        messages.append(step)
        revision += 1
        func done(_ status: Message.ToolStep.Status, _ result: String) -> String {
            update(step.id) {
                $0.tool?.status = status
                $0.tool?.result = result
            }
            return result
        }
        if isQuery && !canQuery {
            return done(.denied, "Refused: queries are turned off in Settings › AI. Answer from the structure.")
        }
        if isQuery && askFirst {
            let allowed = await withCheckedContinuation { continuation in
                // Stopped meanwhile: answer at once instead of waiting for a button that is gone.
                guard self.run == run, !Task.isCancelled else {
                    return continuation.resume(returning: false)
                }
                if let earlier = approval {
                    earlier.continuation.resume(returning: false)
                }
                approval = (step.id, continuation)
            }
            try Task.checkCancellation()
            guard self.run == run else {
                throw CancellationError()
            }
            guard allowed else {
                return done(.denied, "The user didn't allow this query. Answer without it, or suggest it as SQL.")
            }
            update(step.id) { $0.tool?.status = .running }
        }
        let toolbox = try await workspace.agentToolbox()
        try Task.checkCancellation()
        guard self.run == run else {
            throw CancellationError()
        }
        let result = await toolbox.run(call)
        try Task.checkCancellation()
        return done(.done, result)
    }

    /// The user's answer to a Production query.
    func answer(_ id: UUID, allow: Bool) {
        guard let approval, approval.id == id else { return }
        self.approval = nil
        approval.continuation.resume(returning: allow)
    }

    private func startReply(preparing: Bool) -> UUID {
        let reply = Message(role: .assistant, text: "", streaming: true, preparing: preparing)
        messages.append(reply)
        replyID = reply.id
        return reply.id
    }

    /// Earlier messages as the model reads them: tool steps with their (shortened) results.
    private static func history(_ messages: ArraySlice<Message>) -> [(role: String, text: String)] {
        messages.compactMap { message in
            switch message.role {
            case .user: return ("User", message.text)
            case .assistant:
                let text = AgentProtocol.visibleText(message.text)
                return text.isEmpty ? nil : ("Assistant", text)
            case .tool:
                guard let step = message.tool, step.status == .done else { return nil }
                let result =
                    step.result.count > Defaults.AI.agentHistoryResultLength
                    ? String(step.result.prefix(Defaults.AI.agentHistoryResultLength)) + "…" : step.result
                return (
                    "Tool",
                    "\(step.call.summary): \(step.call.query ?? step.call.table ?? step.call.schema ?? "")\n\(result)"
                )
            }
        }
    }

    /// Appends the stream to the message, redrawing a few times a second rather than for every token.
    private func receive(_ stream: AIStream, into id: UUID) async throws {
        let started = Date()
        var lastRefresh = Date.distantPast
        var text = ""
        var thinking = ""
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
            if Date().timeIntervalSince(lastRefresh) >= Defaults.AI.streamRefreshInterval {
                flush()
            }
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
            defer {
                busy = false
                update(reply.id) { $0.streaming = false }
            }
            let stream = AIStream { continuation in
                Task {
                    for word in thinking.split(separator: " ") {
                        try await Task.sleep(for: piece)
                        continuation.yield(.thinking(word + " "))
                    }
                    for word in answer.split(separator: " ", omittingEmptySubsequences: false) {
                        try await Task.sleep(for: piece)
                        continuation.yield(.text(word + " "))
                    }
                    continuation.finish()
                }
            }
            // A made-up demo stream (debug builds) that can't fail.
            try? await receive(stream, into: reply.id)
        }
    }
    #endif

    private func update(_ id: UUID, _ change: (inout Message) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        change(&messages[index])
    }

    /// Ends a reply: it stops showing progress, and one that never got any text disappears.
    private func finish(_ id: UUID) {
        if replyID == id {
            replyID = nil
        }
        update(id) {
            $0.streaming = false
            $0.preparing = false
        }
        if let index = messages.firstIndex(where: { $0.id == id }), messages[index].role == .assistant,
            AgentProtocol.visibleText(messages[index].text).isEmpty, messages[index].thinking.isEmpty
        {
            messages.remove(at: index)
        }
    }

    /// Ends the answer at once, even if the request is slow to give up, so the next message can go out.
    func stop() {
        task?.cancel()
        task = nil
        if let approval {
            self.approval = nil
            approval.continuation.resume(returning: false)
        }
        if let replyID {
            finish(replyID)
        }
        for index in messages.indices
        where messages[index].tool.map({ $0.status == .running || $0.status == .awaitingApproval }) == true {
            messages[index].tool?.status = .stopped
        }
        if run != nil {
            run = nil
            save()
        }
        busy = false
    }
}

struct AIChatView: View {
    let workspace: WorkspaceModel
    @Bindable var chat: AIChatModel
    @FocusState private var inputFocused: Bool
    @State private var editingInstructions = false
    @State private var confirmingDelete = false
    /// Whether the end of the conversation is on screen; a streaming answer is followed only then, so scrolling
    /// up to read something stays put.
    @State private var atBottom = true

    private var queryTab: QueryTabModel? {
        if case .query(let query) = workspace.selectedTab {
            return query
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Layout.Chat.spacing) {
                        if chat.messages.isEmpty {
                            emptyState
                        }
                        ForEach(chat.messages) { message in
                            MessageView(message: message, insert: insert, run: run, answer: chat.answer).id(message.id)
                        }

                        if let error = chat.error {
                            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                                .textSelection(.enabled)
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
                    if atBottom {
                        proxy.scrollTo(Self.endID, anchor: .bottom)
                    }
                }
            }
            Divider()
            composer
        }
        .sheet(isPresented: $editingInstructions) { PromptEditor(prompt: .chat) }
        .confirmationDialog("Delete “\(chat.title)”?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { if let id = chat.currentID { chat.delete(id) } }
        } message: {
            Text("The conversation is removed from this Mac.")
        }
    }

    /// The conversation's title, which opens the saved ones, and a button for a new one.
    private var header: some View {
        HStack(spacing: Layout.barPadding) {
            Menu {
                if chat.conversations.isEmpty {
                    Text("No saved conversations")
                }
                ForEach(chat.conversations) { conversation in
                    Button {
                        chat.open(conversation.id)
                    } label: {
                        if conversation.id == chat.currentID {
                            Label(conversation.title, systemImage: "checkmark")
                        } else {
                            Text(conversation.title)
                        }
                        Text(conversation.updated.formatted(.relative(presentation: .named)))
                    }
                }
                Divider()
                Button("Delete This Conversation…", role: .destructive) { confirmingDelete = true }
                    .disabled(chat.currentID == nil)
            } label: {
                Label(chat.title, systemImage: "clock.arrow.circlepath").font(Layout.Font.small).lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .help("Earlier conversations with this connection")
            Spacer(minLength: 0)
            Button {
                chat.newConversation()
                inputFocused = true
            } label: {
                Label("New Chat", systemImage: "square.and.pencil")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .disabled(chat.messages.isEmpty)
            .help("New Chat")
        }
        .padding(.horizontal, Layout.Chat.padding)
        .padding(.vertical, Layout.barPadding)
    }

    private static let endID = "end"

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Layout.barPadding) {
            Label("Ask about this database", systemImage: "sparkles").font(.headline)
            Text(
                AIService.shared.settings.assistantQueries
                    ? "Write or explain queries, find tables, or change the SQL in the editor. The AI sees table and column names, keys and the editor's SQL, and can run read-only queries to look at the data\(workspace.config.tag == .production ? " after you allow each one" : ""). Earlier conversations are under the title above."
                    : "Write or explain queries, find tables, or change the SQL in the editor. The AI sees table and column names, keys and the editor's SQL, never rows. Earlier conversations are under the title above."
            )
            .font(.callout).foregroundStyle(.secondary)
            if !AIService.shared.settings.assistantQueries && AIService.shared.refusal(for: workspace.config) == nil {
                SettingsLink { Text("Let the AI run read-only queries…") }
            }
            if AIService.shared.refusal(for: workspace.config) != nil {
                SettingsLink { Text("Turn on AI in Settings…") }
            }
        }
    }

    /// One rounded box, as chat apps lay it out: the message on top, and below it the model and effort on the
    /// left and the actions on the right.
    private var composer: some View {
        VStack(alignment: .leading, spacing: Layout.barPadding / 2) {
            input
            HStack(spacing: Layout.barPadding) {
                // Truncate the model and effort before the actions, which must stay usable in a narrow panel.
                HStack(spacing: Layout.barPadding) {
                    ModelPicker()
                    ChatEffortPicker()
                }
                .lineLimit(1)
                .layoutPriority(0)
                Spacer(minLength: 0)
                Menu {
                    Button("New Chat") { chat.newConversation() }.disabled(chat.messages.isEmpty)
                    Button("Edit Chat Instructions…") { editingInstructions = true }
                    SettingsLink { Text("AI Settings…") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
                if chat.busy {
                    Button {
                        chat.stop()
                    } label: {
                        Image(systemName: "stop.circle.fill").font(.title2)
                    }
                    .buttonStyle(.borderless)
                    .help("Stop")
                } else {
                    Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                        .buttonStyle(.borderless)
                        .disabled(chat.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .help("Send (↩)")
                }
            }
        }
        .padding(Layout.barPadding)
        .background(
            Color(nsColor: .textBackgroundColor),
            in: RoundedRectangle(cornerRadius: Layout.Chat.composerRadius)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Layout.Chat.composerRadius)
                .strokeBorder(inputFocused ? Color.accentColor.opacity(0.6) : Color(nsColor: .separatorColor))
        }
        .padding(Layout.Chat.padding)
        .onAppear { inputFocused = true }
    }

    /// The message, growing up to `Layout.Chat.inputLines` lines and scrolling past that. A hidden copy of the text
    /// sizes the native editor; a vertical TextField clipped partial lines when its field editor scrolled.
    private var input: some View {
        Text(chat.input.isEmpty ? " " : chat.input)
            .font(.body)
            .lineLimit(1...Layout.Chat.inputLines)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Layout.Chat.inputInset)
            .hidden()
            .accessibilityHidden(true)
            .overlay {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $chat.input)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .focused($inputFocused)
                        .accessibilityLabel("Ask the AI")
                        // Return sends; Shift-Return starts a new line.
                        .onKeyPress(.return, phases: .down) { press in
                            if press.modifiers.contains(.shift) {
                                return .ignored
                            }
                            send()
                            return .handled
                        }
                    if chat.input.isEmpty {
                        Text("Ask the AI")
                            .foregroundStyle(.tertiary)
                            .padding(Layout.Chat.inputInset)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
            }
            .clipped()
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
            if let query = self.queryTab {
                query.runRequest = (false, query.runRequest.id + 1)
            }
        }
    }
}

private struct MessageView: View {
    let message: AIChatModel.Message
    let insert: (String) -> Void
    let run: (String) -> Void
    let answer: (UUID, Bool) -> Void

    /// Set when the user opens or closes the reasoning; until then it is open while the model thinks.
    @State private var showThinking: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.barPadding) {
            if let step = message.tool {
                ToolStepView(id: message.id, step: step, answer: answer)
            } else if message.role == .user {
                Text("You").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(message.text).textSelection(.enabled)
            } else {
                Text("AI").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if !message.thinking.isEmpty {
                    DisclosureGroup(
                        isExpanded: Binding(
                            get: { showThinking ?? (message.streaming && message.text.isEmpty) },
                            set: { showThinking = $0 }
                        )
                    ) {
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
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(message.preparing ? "Reading the schema…" : "Thinking…").foregroundStyle(.secondary)
                    }
                }
                ForEach(Array(ChatSegment.split(shownText).enumerated()), id: \.offset) { _, segment in
                    switch segment {
                    case .text(let text):
                        Text(
                            (try? AttributedString(
                                markdown: text,
                                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
                            )) ?? AttributedString(text)
                        )
                        .textSelection(.enabled)
                    case .code(let sql):
                        CodeBlock(sql: sql, insert: insert, run: run)
                    case .table(let table):
                        TableBlock(table: table)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension MessageView {
    /// A tool request at the end of a reply shows as its own step, not as text.
    private var shownText: String {
        message.streaming ? AgentProtocol.streamingText(message.text) : AgentProtocol.visibleText(message.text)
    }

    private var thinkingTitle: String {
        if message.streaming && message.text.isEmpty {
            return "Thinking…"
        }
        guard let seconds = message.thoughtFor else {
            return "Thinking"
        }
        return seconds < 1 ? "Thought briefly" : "Thought for \(Int(seconds.rounded())) s"
    }
}

/// A tool the assistant used: what it looked at, the query and the result, folded by default. On Production a
/// query waits here for the user's approval.
private struct ToolStepView: View {
    let id: UUID
    let step: AIChatModel.Message.ToolStep
    let answer: (UUID, Bool) -> Void
    @State private var expanded: Bool?

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.barPadding) {
            DisclosureGroup(
                isExpanded: Binding(get: { expanded ?? (step.status == .awaitingApproval) }, set: { expanded = $0 })
            ) {
                VStack(alignment: .leading, spacing: Layout.barPadding / 2) {
                    if let query = step.call.query {
                        Text(query).font(Layout.Font.monoSmall).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Layout.barPadding / 2)
                            .background(
                                Color(nsColor: .textBackgroundColor),
                                in: RoundedRectangle(cornerRadius: Layout.cornerRadius)
                            )
                    }
                    if !step.result.isEmpty {
                        Text(AgentToolbox.aligned(step.result)).font(Layout.Font.monoSmall)
                            .foregroundColor(Color(nsColor: .secondaryLabelColor))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } label: {
                HStack(spacing: Layout.barPadding / 2) {
                    if step.status == .running {
                        ProgressView().controlSize(.mini)
                    }
                    Label(title, systemImage: icon).font(.callout).foregroundStyle(.secondary)
                }
            }
            if step.status == .awaitingApproval {
                HStack {
                    Text("This is a Production connection. Run this query?").font(.callout)
                    Spacer(minLength: 0)
                    Button("Don't Allow") { answer(id, false) }
                    Button("Allow") { answer(id, true) }.buttonStyle(.borderedProminent)
                }
                .controlSize(.small)
            }
        }
    }

    private var title: String {
        switch step.status {
        case .running: return step.call.summary + "…"
        case .awaitingApproval: return "Wants to run a query"
        case .done: return step.call.summary
        case .denied: return step.call.summary + " (not allowed)"
        case .stopped: return step.call.summary + " (stopped)"
        }
    }

    private var icon: String {
        switch step.call.tool {
        case .listTables: return "list.bullet.rectangle"
        case .describeTable: return "tablecells"
        case .runQuery: return "play.rectangle"
        case .searchSavedQueries: return "books.vertical"
        }
    }
}

/// A Markdown table from an answer, as a grid with a header row; wide tables scroll sideways.
private struct TableBlock: View {
    let table: MarkdownTable

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: Layout.barPadding * 2, verticalSpacing: Layout.barPadding / 2)
            {
                GridRow {
                    ForEach(Array(table.header.enumerated()), id: \.offset) { column, title in
                        Self.text(title).fontWeight(.semibold)
                            .gridColumnAlignment(Self.alignment(table.alignments[column]))
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in Self.text(cell) }
                    }
                }
            }
            .textSelection(.enabled)
            .padding(Layout.barPadding)
        }
        .scrollIndicators(.automatic)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: Layout.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: Layout.cornerRadius).strokeBorder(Color(nsColor: .separatorColor)))
    }

    private static func text(_ markdown: String) -> Text {
        Text(
            (try? AttributedString(
                markdown: markdown,
                options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
            ))
                ?? AttributedString(markdown)
        )
    }

    private static func alignment(_ alignment: MarkdownTable.Alignment) -> HorizontalAlignment {
        switch alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
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
                Button {
                    Clipboard.copy(sql)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
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
                choice(
                    "Claude Code",
                    kind: .claudeCode,
                    model: ai.settings.models[AIProviderKind.claudeCode.rawValue] ?? ""
                )
                choice("Codex", kind: .codex, model: ai.settings.models[AIProviderKind.codex.rawValue] ?? "")
            }
            Divider()
            SettingsLink { Text("Manage Models…") }
        } label: {
            Label(current, systemImage: "cpu").font(Layout.Font.small)
        }
        .menuStyle(.borderlessButton)
        .help("Model for the chat and Ask AI")
        .onAppear { models.refresh() }
    }

    private func choice(_ title: String, kind: AIProviderKind, model: String) -> some View {
        let selected =
            ai.settings.provider == kind && (model.isEmpty || ai.settings.model(kind, for: .generate) == model)
        return Button {
            ai.settings.provider = kind
            if !model.isEmpty {
                ai.settings.models[kind.rawValue] = model
            }
        } label: {
            if selected {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
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
                Picker(
                    "Effort",
                    selection: Binding(
                        get: { ai.settings.efforts[kind.rawValue] ?? "" },
                        set: { ai.settings.efforts[kind.rawValue] = $0.isEmpty ? nil : $0 }
                    )
                ) {
                    Text("Default").tag("")
                    ForEach(kind.effortLevels, id: \.self) { Text($0.capitalized).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label(
                    "Effort: \((ai.settings.efforts[kind.rawValue] ?? "default").capitalized)",
                    systemImage: "gauge.with.dots.needle.50percent"
                )
                .font(Layout.Font.small)
            }
            .menuStyle(.borderlessButton)
            .help("How much the model thinks before answering. Higher is slower and costs more.")
        }
    }
}
