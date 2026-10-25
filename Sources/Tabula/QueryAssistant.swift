import Foundation
import Observation
import SwiftUI
import TabulaCore

/// Ask AI and Fix with AI for one query tab.
@MainActor @Observable
final class QueryAssistant {
    var showPrompt = false
    var prompt = ""
    /// Incremented to submit the prompt from outside the bar (debug automation).
    var submitRequest = 0
    private(set) var busy = false
    var error: String?
    private var task: Task<Void, Never>?
    private var current: UUID?

    /// Builds the request (which may wait for the schema), sends it and hands the cleaned-up SQL to
    /// `apply`, unless the connection may not use AI.
    func run(for connection: ConnectionConfig, request: @escaping () async -> AIRequest, apply: @escaping (String) -> Void) {
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
            defer { if current == id { busy = false } }
            do {
                let sql = SQLPrompts.cleanSQL(try await AIService.shared.complete(await request()))
                guard !Task.isCancelled else { return }
                guard !sql.isEmpty else { error = "The model didn't return any SQL."; return }
                apply(sql)
                prompt = ""
                showPrompt = false
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    func cancel() {
        task?.cancel()
        current = nil
        busy = false
    }
}

/// The Ask AI bar above the editor (⌘K).
struct AIPromptBar: View {
    @Bindable var assistant: QueryAssistant
    let hasSelection: Bool
    let submit: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            bar
            if let error = assistant.error {
                Text(error).font(Layout.Font.small).foregroundStyle(.red).lineLimit(3).textSelection(.enabled)
                    .padding(.horizontal, Layout.barPadding).padding(.bottom, Layout.barPadding / 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .barBackground()
        .onAppear { focused = true }
        .onExitCommand { assistant.cancel(); assistant.showPrompt = false }
    }

    private var bar: some View {
        HStack(spacing: Layout.barPadding) {
            Image(systemName: "sparkles").foregroundStyle(.secondary)
            TextField(hasSelection ? "How should the selected SQL change?" : "Describe the query you want",
                      text: $assistant.prompt)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit(submit)
                .disabled(assistant.busy)
            if assistant.busy {
                ProgressView().controlSize(.small)
                Button("Stop") { assistant.cancel() }
            } else {
                Button(hasSelection ? "Edit" : "Write SQL", action: submit)
                    .disabled(assistant.prompt.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
            BarButton(symbol: "xmark", help: "Close (⎋)") { assistant.cancel(); assistant.showPrompt = false }
        }
        .controlSize(.small)
        .padding(.horizontal, Layout.barPadding)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: Layout.barHeight)
    }
}
