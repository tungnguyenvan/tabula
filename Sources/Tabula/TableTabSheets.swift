import AppKit
import SwiftUI
import TabulaFoundation
import TabulaMongo
import TabulaSQL
import TabulaTransfer

/// MongoDB: one document written out in full, to edit nested fields or insert a new document.
struct DocumentEditorSheet: View {
    struct Target: Identifiable {
        let id = UUID()
        /// The row being replaced; nil inserts a new document.
        var row: Int?
        var text: String
    }

    let target: Target
    let collection: String
    /// Saves and returns the error, or nil when it worked.
    let save: (String) async -> String?
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?
    @State private var saving = false
    @State private var handle = EditorHandle()
    @State private var undoManager = UndoManager()

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.barPadding) {
            Text(target.row == nil ? "Insert into \(collection)" : "Edit document in \(collection)").font(.headline)
            Text(
                "Shell syntax: ObjectId(\"…\"), ISODate(\"…\"), NumberLong(…) and NumberDecimal(\"…\") keep their types. "
                    + (target.row == nil
                        ? "Leave out _id to have one generated."
                        : "The document is replaced as a whole, matched by its _id.")
            )
            .font(.caption).foregroundStyle(.secondary)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
                    .lineLimit(4)
            }
            SQLEditorView(
                text: $text,
                handle: handle,
                dialect: MongoQueryDialect(),
                suggest: { _, caret in (NSRange(location: caret, length: 0), []) },
                undoManager: undoManager
            ) { _ in Task { await submit() } }
            .border(Color(nsColor: .separatorColor))
            HStack {
                Button("Format") { text = MongoShell.pretty(text) }
                    .help("Lay the document out over indented lines")
                Spacer()
                if saving {
                    ProgressView().controlSize(.small)
                }
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(target.row == nil ? "Insert" : "Save") { Task { await submit() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(saving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(Layout.Sheet.padding)
        .frame(width: Layout.Sheet.documentWidth, height: Layout.Sheet.documentHeight)
        .onAppear { text = target.text }
    }

    private func submit() async {
        guard !saving else { return }
        saving = true
        defer { saving = false }
        if let message = await save(text) {
            error = message
        } else {
            dismiss()
        }
    }
}

struct SQLPreviewSheet: View {
    let kind: DatabaseKind
    let dialect: any QueryDialect
    let pending: Result<[String], any Error>
    let onCommit: () -> Void
    let onCancel: () -> Void

    // When the statements can't be written, `pending` holds the error, which the sheet shows instead.
    private var statements: [String] { (try? pending.get()) ?? [] }
    private var script: String { statements.map { $0 + ";" }.joined(separator: "\n") }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pending changes").font(.headline)
            Text(
                dialect.beginTransaction == nil
                    ? "These commands run one after another. If one fails, the ones before it stay saved."
                    : "These statements run in a single transaction. If any fails, all are rolled back."
            )
            .font(.caption).foregroundStyle(.secondary)
            if case .failure(let error) = pending {
                Label(error.localizedDescription, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            ScrollView {
                Text(script).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Button("Copy \(kind.statementsNoun)") {
                    Clipboard.copy(script)
                }
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button("Commit", action: onCommit).keyboardShortcut(.defaultAction).disabled(statements.isEmpty)
            }
        }
        .padding(16)
        .frame(width: 640, height: 420)
    }
}
