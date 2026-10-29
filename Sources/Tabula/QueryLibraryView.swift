import AppKit
import SwiftUI
import TabulaFoundation
import TabulaStorage

/// The Queries panel: the saved query library, searched by keyword, folder and SQL (#94). Double-click inserts a
/// query at the caret; Open edits its file in a tab, where ⌘S saves it back to the library.
struct QueryLibraryView: View {
    let workspace: WorkspaceModel
    @State private var library = QueryLibraryModel.shared
    @State private var search = ""
    @State private var selection: SavedQuery.ID?
    @State private var problem: String?

    private var matches: [SavedQuery] {
        SavedQuery.search(library.queries, for: search)
    }

    /// Matches by folder, in the order search ranked them; the top level first.
    private var groups: [(name: String, queries: [SavedQuery])] {
        var order: [String] = []
        var byGroup: [String: [SavedQuery]] = [:]
        for query in matches {
            if byGroup[query.group] == nil {
                order.append(query.group)
            }
            byGroup[query.group, default: []].append(query)
        }
        order.sort { first, second in
            if first.isEmpty != second.isEmpty {
                return first.isEmpty
            }
            return first.localizedStandardCompare(second) == .orderedAscending
        }
        return order.map { (name: $0, queries: byGroup[$0] ?? []) }
    }

    private var queryTab: QueryTabModel? {
        if case .query(let model) = workspace.selectedTab {
            return model
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search keyword, folder or SQL", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(Layout.barPadding)
            Divider()
            if let error = library.loadError {
                ErrorBanner(message: error) { library.reload() }
            }
            if let problem {
                ErrorBanner(message: problem) { self.problem = nil }
            }
            if library.queries.isEmpty {
                empty
            } else if matches.isEmpty {
                placeholder("No saved query matches “\(search)”")
            } else {
                list
            }
            Divider()
            footer
        }
        .onAppear { library.reload() }
    }

    private var list: some View {
        List(selection: $selection) {
            ForEach(groups, id: \.name) { group in
                Section(group.name.isEmpty ? "Queries" : group.name) {
                    ForEach(group.queries) { query in
                        row(query)
                            .tag(query.id)
                            .contextMenu { menu(for: query) }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .contextMenu(forSelectionType: SavedQuery.ID.self) { _ in
        } primaryAction: { ids in
            if let id = ids.first, let query = library.queries.first(where: { $0.id == id }) {
                insert(query)
            }
        }
    }

    private func row(_ query: SavedQuery) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(query.keyword).font(.body.weight(.medium))
            Text(Self.preview(query.sql))
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.vertical, 2)
        .help(
            "Double-click to insert at the caret. Type “\(query.keyword)” in the editor and press ⌃Space to insert it there."
        )
    }

    @ViewBuilder
    private func menu(for query: SavedQuery) -> some View {
        Button("Insert at Caret") { insert(query) }
            .disabled(queryTab == nil)
        Button("Open") { workspace.openSQLFile(query.file) }
        Button("Copy SQL") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(query.sql, forType: .string)
        }
        Divider()
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([query.file]) }
        Button("Move to Trash") {
            do {
                try library.moveToTrash(query)
            } catch {
                problem = "Couldn't move \(query.keyword) to the Trash: \(error.localizedDescription)"
            }
        }
    }

    private var empty: some View {
        VStack(spacing: Layout.barPadding) {
            Text("No saved queries").font(.headline)
            Text(
                "Save the query you are editing with Query › Save to Library… (⌥⌘S), or put .sql files in the Queries folder. Folders inside it become groups."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            Text("\(library.queries.count) saved").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Show Folder") {
                do {
                    try library.showFolder()
                } catch {
                    problem = "Couldn't create the Queries folder: \(error.localizedDescription)"
                }
            }
            .controlSize(.small)
        }
        .padding(Layout.barPadding)
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.tertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Inserts at the caret of the selected query tab, or in a new query tab when another kind of tab is shown.
    private func insert(_ query: SavedQuery) {
        if let tab = queryTab {
            tab.insertRequest = (query.sql, UUID())
        } else {
            workspace.newQueryTab(sql: query.sql)
        }
    }

    /// The SQL on one line, comments and runs of spaces left out, for the list.
    static func preview(_ sql: String) -> String {
        let lines = sql.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("--") }
        return lines.joined(separator: " ")
    }
}

/// Asks for the keyword (and optionally the folder) to save a query under, then saves it to the library.
struct SaveToLibrarySheet: View {
    let sql: String
    let dismiss: () -> Void
    @State private var keyword = ""
    @State private var group = ""
    @State private var problem: String?

    private var trimmedKeyword: String { keyword.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save to Library").font(.headline)
            Form {
                TextField("Keyword", text: $keyword, prompt: Text("active_users"))
                TextField("Folder", text: $group, prompt: Text("Optional, e.g. reports"))
            }
            Text("Type the keyword in the editor and press ⌃Space to insert this query.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedKeyword.isEmpty)
            }
        }
        .padding(20)
        .frame(width: Layout.Inspector.maxWidth)
    }

    private func save() {
        let folder = group.trimmingCharacters(in: .whitespaces)
        do {
            try QueryLibraryModel.shared.save(sql, keyword: trimmedKeyword, group: folder)
            dismiss()
        } catch {
            problem = error.localizedDescription
        }
    }
}
