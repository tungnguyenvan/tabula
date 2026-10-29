import AppKit
import SwiftUI
import TabulaAI
import TabulaFoundation

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
