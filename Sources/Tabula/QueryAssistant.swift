import Foundation
import Observation
import SwiftUI
import TabulaAI
import TabulaFoundation

/// Ask AI and Fix with AI for one query tab.
@MainActor @Observable
final class QueryAssistant {
    var showPrompt = false
    var prompt = ""
    /// Incremented to submit the prompt from outside the bar (debug automation).
    var submitRequest = 0
    private(set) var busy = false
    /// What the model is doing while it works: the end of its reasoning, then of the SQL it is writing.
    private(set) var progress: Progress?
    var error: String?

    enum Progress: Equatable {
        case thinking(String)
        case writing(String)
    }
    private var task: Task<Void, Never>?
    private var current: UUID?

    /// Builds the request (which may wait for the schema), sends it and hands the cleaned-up SQL to
    /// `apply`, unless the connection may not use AI.
    func run(
        for connection: ConnectionConfig,
        request: @escaping () async -> AIRequest,
        apply: @escaping (String) -> Void
    ) {
        if let refusal = AIService.shared.refusal(for: connection) {
            error = refusal
            showPrompt = true
            return
        }
        task?.cancel()
        busy = true
        error = nil
        let id = UUID()
        current = id
        task = Task {
            // A newer request owns `busy`; an older one finishing late must not clear it.
            defer {
                if current == id {
                    busy = false
                    progress = nil
                }
            }
            do {
                let reply = try await receive(AIService.shared.stream(await request()), id: id)
                let sql = SQLPrompts.cleanSQL(reply)
                guard !Task.isCancelled else { return }
                guard !sql.isEmpty else {
                    error = "The model returned nothing to insert."
                    return
                }
                apply(sql)
                prompt = ""
                showPrompt = false
            } catch {
                if !Task.isCancelled {
                    self.error = error.localizedDescription
                }
            }
        }
    }

    #if DEBUG
    /// Plays a made-up answer at a steady pace, to look at the progress line.
    func simulate(thinking: String, answer: String, piece: Duration, apply: @escaping (String) -> Void) {
        busy = true
        showPrompt = true
        let id = UUID()
        current = id
        task = Task {
            defer {
                if current == id {
                    busy = false
                    progress = nil
                }
            }
            let stream = AIStream { continuation in
                Task {
                    for word in thinking.split(separator: " ") {
                        try await Task.sleep(for: piece)
                        continuation.yield(.thinking(word + " "))
                    }
                    for word in answer.split(separator: " ") {
                        try await Task.sleep(for: piece)
                        continuation.yield(.text(word + " "))
                    }
                    continuation.finish()
                }
            }
            if let reply = try? await receive(stream, id: id) {
                apply(SQLPrompts.cleanSQL(reply))
            }
        }
    }
    #endif

    /// Collects the answer, showing the reasoning and the SQL as they arrive (a few times a second).
    private func receive(_ stream: AIStream, id: UUID) async throws -> String {
        var text = ""
        var thinking = ""
        var lastRefresh = Date.distantPast
        for try await event in stream {
            switch event {
            case .text(let piece): text += piece
            case .thinking(let piece): thinking += piece
            }
            guard current == id, Date().timeIntervalSince(lastRefresh) >= Defaults.AI.streamRefreshInterval else {
                continue
            }
            lastRefresh = Date()
            progress = text.isEmpty ? .thinking(Self.tail(thinking)) : .writing(Self.tail(text))
        }
        return text
    }

    /// The last words of a growing text, on one line.
    private static func tail(_ text: String) -> String {
        String(text.suffix(Defaults.AI.progressLength)).replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    func cancel() {
        task?.cancel()
        current = nil
        busy = false
        progress = nil
    }
}

/// The Ask AI bar above the editor (⌘K).
struct AIPromptBar: View {
    @Bindable var assistant: QueryAssistant
    let hasSelection: Bool
    /// "SQL", or "MongoDB shell" for MongoDB.
    var language = "SQL"
    let submit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            bar
            if assistant.busy, let progress = assistant.progress {
                AIProgressLine(progress: progress)
                    .padding(.horizontal, Layout.barPadding).padding(.bottom, Layout.barPadding / 2)
            }
            if let error = assistant.error {
                Text(error).font(Layout.Font.small).foregroundStyle(.red).lineLimit(3).textSelection(.enabled)
                    .padding(.horizontal, Layout.barPadding).padding(.bottom, Layout.barPadding / 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .barBackground()
        .onAppear { focused = true }
        .onExitCommand {
            assistant.cancel()
            assistant.showPrompt = false
        }
    }

    private var submitTitle: String {
        if hasSelection {
            return "Edit"
        }
        return language == "SQL" ? "Write SQL" : "Write Query"
    }

    private var bar: some View {
        HStack(spacing: Layout.barPadding) {
            Image(systemName: "sparkles").foregroundStyle(.secondary)
            TextField(
                hasSelection ? "How should the selected \(language) change?" : "Describe the query you want",
                text: $assistant.prompt
            )
            .textFieldStyle(.plain)
            .focused($focused)
            .onSubmit(submit)
            .disabled(assistant.busy)
            if assistant.busy {
                ProgressView().controlSize(.small)
                Button("Stop") { assistant.cancel() }
            } else {
                Button(submitTitle, action: submit)
                    .disabled(assistant.prompt.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
            BarButton(symbol: "xmark", help: "Close (⎋)") {
                assistant.cancel()
                assistant.showPrompt = false
            }
        }
        .controlSize(.small)
        .padding(.horizontal, Layout.barPadding)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: Layout.barHeight)
    }
}

/// One line of what the model is doing: the end of its reasoning, or of the SQL it is writing.
struct AIProgressLine: View {
    let progress: QueryAssistant.Progress

    var body: some View {
        HStack(spacing: Layout.barPadding / 2) {
            switch progress {
            case .thinking(let text):
                Image(systemName: "brain").foregroundStyle(.secondary)
                Text(text).foregroundStyle(.secondary)
            case .writing(let text):
                Image(systemName: "pencil").foregroundStyle(.secondary)
                Text(text).font(Layout.Font.monoSmall).foregroundStyle(.secondary)
            }
        }
        .font(Layout.Font.small)
        .lineLimit(1)
        .truncationMode(.head)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
