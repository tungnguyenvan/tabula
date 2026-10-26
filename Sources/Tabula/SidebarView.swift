import AppKit
import SwiftUI
import TabulaCore

struct SidebarView: View {
    @Bindable var model: WorkspaceModel
    @State private var pendingAction: PendingAction?
    @State private var actionError: String?
    /// A database to open once the user agrees to lose unsaved edits.
    @State private var pendingDatabase: String?
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
                get: { () -> SidebarItem? in
                    switch model.selectedTab {
                    case .table(let table): return .table(table.table)
                    case .routine(let routine): return routine.routine.map(SidebarItem.routine)
                    default: return nil
                    }
                },
                set: { item in
                    switch item {
                    case .table(let table): model.open(table, preview: true)
                    case .routine(let routine): model.openRoutine(routine)
                    case nil: break
                    }
                }
            )) {
                // Selection mirrors the active tab, so switching tabs moves the highlight too.
                let tables = model.filteredTables.filter { $0.kind == .table }
                let views = model.filteredTables.filter { $0.kind == .view }
                if !tables.isEmpty {
                    Section { ForEach(tables) { row($0) } } header: { sectionHeader(model.config.kind.tablesTitle, count: tables.count) }
                }
                if !views.isEmpty {
                    Section { ForEach(views) { row($0) } } header: { sectionHeader("Views", count: views.count) }
                }
                let functions = model.filteredRoutines.filter { $0.kind != .trigger }
                let triggers = model.filteredRoutines.filter { $0.kind == .trigger }
                if !functions.isEmpty {
                    Section { ForEach(functions) { routineRow($0) } } header: { sectionHeader("Functions", count: functions.count) }
                }
                if !triggers.isEmpty {
                    Section { ForEach(triggers) { routineRow($0) } } header: { sectionHeader("Triggers", count: triggers.count) }
                }
                if model.filteredTables.isEmpty && !model.loadingTables {
                    Text(model.tableSearch.isEmpty ? "No \(model.config.kind.tablesTitle.lowercased())" : "No matches")
                        .font(.callout).foregroundStyle(.tertiary)
                }
            }
            .listStyle(.sidebar)
            .environment(\.defaultMinListRowHeight, 22)
            .contextMenu(forSelectionType: SidebarItem.self) { items in
                if items.isEmpty, model.config.kind.supportsRoutines { newRoutineButtons() }
            } primaryAction: { items in
                switch items.first {
                case .table(let table): model.open(table)
                case .routine(let routine): model.openRoutine(routine)
                case nil: break
                }
            }
            footer
        }
        .onChange(of: model.sidebarFilterFocusRequest) { _, _ in filterFocused = true }
        .confirmationDialog(dialogTitle, isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }),
                            titleVisibility: .visible, presenting: pendingAction) { action in
            Button(action.kind == .drop ? "Drop" : model.config.kind.truncateTitle, role: .destructive) {
                Task { await run(action) }
            }
        } message: { action in
            Text(model.config.tag == .production
                 ? "This is a PRODUCTION connection. This cannot be undone."
                 : "This cannot be undone.")
        }
        .confirmationDialog("Open “\(pendingDatabase ?? "")”?", isPresented: Binding(
            get: { pendingDatabase != nil }, set: { if !$0 { pendingDatabase = nil } }
        ), titleVisibility: .visible, presenting: pendingDatabase) { name in
            Button("Discard Changes and Open") { Task { await model.openDatabase(name) } }
        } message: { _ in
            Text("Tabs with unsaved changes close when the window moves to another database.")
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
        VStack(spacing: Layout.Sidebar.pickerSpacing) {
            if !model.databases.isEmpty {
                picker(model.databases, selected: model.openingDatabase ?? model.currentDatabase ?? "", icon: "cylinder", help: "Database") { name in
                    if model.hasUnsavedChanges { pendingDatabase = name } else { Task { await model.openDatabase(name) } }
                }
                // One switch at a time: the window keeps the old database until the new one is open.
                .disabled(model.openingDatabase != nil)
            }
            if model.config.kind != .sqlite || model.schemas.count > 1 {
                picker(model.schemas, selected: model.selectedSchema,
                       icon: model.config.kind.schemaNoun == "Database" ? "cylinder" : "folder",
                       help: model.config.kind.schemaNoun) { schema in
                    Task { await model.selectSchema(schema) }
                }
            }
        }
        .padding(.vertical, Layout.Sidebar.pickerPadding)
    }

    private func picker(_ items: [String], selected: String, icon: String, help: String,
                        choose: @escaping (String) -> Void) -> some View {
        Menu {
            ForEach(items, id: \.self) { item in
                Button {
                    choose(item)
                } label: {
                    if item == selected { Label(item, systemImage: "checkmark") } else { Text(item) }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(selected.isEmpty ? "Select" : selected)
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
        .help(help)
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
        let kind = model.config.kind
        if action.kind == .truncate && kind.isDocument { return "Delete all documents in “\(action.table.name)”?" }
        let verb = action.kind == .drop ? "Drop" : kind.truncateTitle
        return "\(verb) \(action.table.kind == .view ? "view" : kind.tableNoun) “\(action.table.name)”?"
    }

    private func row(_ table: TableRef) -> some View {
        Label {
            Text(table.name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
        } icon: {
            Image(systemName: table.kind == .view ? "eye" : "tablecells")
                .font(.system(size: 11))
                .foregroundStyle(table.kind == .view ? Color.purple : Color.accentColor)
        }
        .tag(SidebarItem.table(table))
            .contextMenu {
                Button("Open Data") { model.open(table, mode: .data) }
                Button("Open Structure") { model.open(table, mode: .structure) }
                Button("New Query") {
                    model.newQueryTab(sql: model.driver?.dialect.selectSample(table, limit: Defaults.sampleQueryLimit) ?? "")
                }
                Divider()
                Button("Copy Name") {
                    Clipboard.copy(table.name)
                }
                Divider()
                if table.kind == .table {
                    Button("\(model.config.kind.truncateTitle)…", role: .destructive) { pendingAction = PendingAction(kind: .truncate, table: table) }
                }
                Button("Drop…", role: .destructive) { pendingAction = PendingAction(kind: .drop, table: table) }
                if table.kind == .table, model.config.kind.supportsRoutines {
                    Divider()
                    Button("New Trigger on \(table.name)…") { model.newRoutine(.trigger, table: table.name) }
                }
            }
    }

    private func routineRow(_ routine: RoutineInfo) -> some View {
        RoutineRow(routine: routine)
            .tag(SidebarItem.routine(routine))
            .contextMenu {
                Button("Open") { model.openRoutine(routine) }
                Button("Copy Name") { Clipboard.copy(routine.name) }
                Divider()
                newRoutineButtons()
            }
    }

    @ViewBuilder
    private func newRoutineButtons() -> some View {
        if model.driver?.supportsFunctions == true {
            Button("New Function…") { model.newRoutine(.function) }
            Button("New Procedure…") { model.newRoutine(.procedure) }
        }
        Button("New Trigger…") { model.newRoutine(.trigger) }
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
                    .help("Reload \(model.config.kind.tablesTitle.lowercased())")
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

/// What a sidebar row stands for.
enum SidebarItem: Hashable {
    case table(TableRef)
    case routine(RoutineInfo)
}
