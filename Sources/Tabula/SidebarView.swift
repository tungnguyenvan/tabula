import AppKit
import SwiftUI
import TabulaCore

struct SidebarView: View {
    @Bindable var model: WorkspaceModel
    @State private var pendingAction: PendingAction?
    @State private var actionError: String?
    @FocusState private var filterFocused: Bool

    struct PendingAction: Identifiable {
        enum Kind { case truncate, drop }
        let id = UUID()
        let kind: Kind
        let table: TableRef
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            // Arrow keys / single click browse in a reusable preview tab; Return or double-click opens for good.
            List(selection: Binding(
                get: { model.selectedTableTab?.table },
                set: { table in if let table { model.open(table, preview: true) } }
            )) {
                // Selection mirrors the active tab, so switching tabs moves the highlight too.
                let tables = model.filteredTables.filter { $0.kind == .table }
                let views = model.filteredTables.filter { $0.kind == .view }
                if !tables.isEmpty {
                    Section { ForEach(tables) { row($0) } } header: { sectionHeader("Tables", count: tables.count) }
                }
                if !views.isEmpty {
                    Section { ForEach(views) { row($0) } } header: { sectionHeader("Views", count: views.count) }
                }
                if model.filteredTables.isEmpty && !model.loadingTables {
                    Text(model.tableSearch.isEmpty ? "No tables" : "No matches")
                        .font(.callout).foregroundStyle(.tertiary)
                }
            }
            .listStyle(.sidebar)
            .environment(\.defaultMinListRowHeight, 22)
            .contextMenu(forSelectionType: TableRef.self) { _ in } primaryAction: { tables in
                if let table = tables.first { model.open(table) }
            }
            footer
        }
        .onChange(of: model.sidebarFilterFocusRequest) { _, _ in filterFocused = true }
        .confirmationDialog(dialogTitle, isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }),
                            titleVisibility: .visible, presenting: pendingAction) { action in
            Button(action.kind == .drop ? "Drop" : "Truncate", role: .destructive) {
                Task { await run(action) }
            }
        } message: { action in
            Text(model.config.tag == .production
                 ? "This is a PRODUCTION connection. This cannot be undone."
                 : "This cannot be undone.")
        }
        .alert("Operation failed", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK") { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
    }

    @ViewBuilder
    private var header: some View {
        if let color = model.config.tag.color {
            Rectangle().fill(color).frame(height: 3)
        }
        if model.config.kind != .sqlite || model.schemas.count > 1 {
            Menu {
                ForEach(model.schemas, id: \.self) { schema in
                    Button {
                        Task { await model.selectSchema(schema) }
                    } label: {
                        if schema == model.selectedSchema { Label(schema, systemImage: "checkmark") } else { Text(schema) }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: model.config.kind == .mysql ? "cylinder" : "folder")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(model.selectedSchema.isEmpty ? "Select" : model.selectedSchema)
                        .font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .help(model.config.kind == .mysql ? "Database" : "Schema")
        }
    }

    private func sectionHeader(_ title: String, count: Int) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("\(count)").monospacedDigit().foregroundStyle(.tertiary)
        }
    }

    private var dialogTitle: String {
        guard let action = pendingAction else { return "" }
        let verb = action.kind == .drop ? "Drop" : "Truncate"
        return "\(verb) \(action.table.kind == .view ? "view" : "table") “\(action.table.name)”?"
    }

    private func row(_ table: TableRef) -> some View {
        Label {
            Text(table.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
        } icon: {
            Image(systemName: table.kind == .view ? "eye" : "tablecells")
                .font(.system(size: 11))
                .foregroundStyle(table.kind == .view ? Color.purple : Color.accentColor)
        }
        .tag(table)
            .contextMenu {
                Button("Open Data") { model.open(table, mode: .data) }
                Button("Open Structure") { model.open(table, mode: .structure) }
                Button("New Query") {
                    model.newQueryTab(sql: "SELECT * FROM \(model.driver?.dialect.qualified(table) ?? table.name) LIMIT 100;")
                }
                Divider()
                Button("Copy Name") {
                    Clipboard.copy(table.name)
                }
                Divider()
                if table.kind == .table {
                    Button("Truncate…", role: .destructive) { pendingAction = PendingAction(kind: .truncate, table: table) }
                }
                Button("Drop…", role: .destructive) { pendingAction = PendingAction(kind: .drop, table: table) }
            }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Filter  ⌥⌘F", text: $model.tableSearch)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($filterFocused)
                    .onExitCommand { model.tableSearch = ""; filterFocused = false }
                    .onSubmit {
                        // Return in the filter opens the first match.
                        if let first = model.filteredTables.first { model.open(first) }
                    }
                if model.loadingTables { ProgressView().controlSize(.mini) }
                if let error = model.tablesError {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.system(size: 11)).help(error)
                }
                Button { Task { await model.loadTables() } } label: { Image(systemName: "arrow.clockwise").font(.system(size: 11)) }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Reload tables")
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
        }
    }

    private func run(_ action: PendingAction) async {
        defer { pendingAction = nil }
        guard let dialect = model.driver?.dialect else {
            actionError = "Not connected. Reconnect and try again."
            return
        }
        let sql = action.kind == .drop ? dialect.drop(action.table) : dialect.truncate(action.table)
        do {
            try await model.perform(sql, on: action.table)
        } catch {
            actionError = error.localizedDescription
        }
    }
}
