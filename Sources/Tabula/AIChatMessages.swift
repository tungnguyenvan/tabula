import AppKit
import SwiftUI
import TabulaAI
import TabulaFoundation

struct MessageView: View {
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
                    Label("Copy", systemImage: "doc.on.doc").labelStyle(.iconOnly)
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
