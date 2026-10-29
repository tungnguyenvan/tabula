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
