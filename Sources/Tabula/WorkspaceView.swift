import AppKit
import SwiftUI
import TabulaFoundation

struct WorkspaceWindow: View {
    /// The connection the window was opened for; nil for an empty window, which offers one to open.
    @Binding var connectionID: UUID?
    @Environment(AppState.self) private var appState
    @State private var session = ConnectionSession()
    @State private var openedInitial = false
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        HStack(spacing: 0) {
            // With one connection the rail would only repeat the toolbar; it appears once a second one opens.
            if session.connections.count > 1 {
                ConnectionRail(session: session)
            }
            activeConnection
        }
        .environment(session)
        .background(WindowAccessor { window in WorkspaceRegistry.register(session, window: window) })
        .task(id: connectionID) {
            guard !openedInitial, let id = connectionID, let config = appState.connection(id) else { return }
            openedInitial = true
            await session.open(config, appState: appState)
        }
        .onDisappear { session.closeAll() }
    }

    /// One split view for as long as the window shows connections; switching connections changes what is in its
    /// columns and toolbar. A split view per connection crashed AppKit: after a SQL, then a Redis, then a SQL one,
    /// a toolbar separator was left half-registered and removing it threw (#53).
    @ViewBuilder
    private var activeConnection: some View {
        if let active = session.active {
            NavigationSplitView(columnVisibility: $columnVisibility) {
                switch active {
                case .sql(let model):
                    SidebarView(model: model).id(model.config.id)
                        .navigationSplitViewColumnWidth(
                            min: Layout.Sidebar.minWidth,
                            ideal: Layout.Sidebar.idealWidth,
                            max: Layout.Sidebar.maxWidth
                        )
                case .redis(let model):
                    RedisSidebar(model: model).id(model.config.id)
                        .navigationSplitViewColumnWidth(
                            min: Layout.Sidebar.redisMinWidth,
                            ideal: Layout.Sidebar.redisIdealWidth,
                            max: Layout.Sidebar.redisMaxWidth
                        )
                }
            } detail: {
                switch active {
                case .sql(let model): WorkspaceView(model: model).id(model.config.id)
                case .redis(let model): RedisWorkspaceView(model: model).id(model.config.id)
                }
            }
            .overlay(alignment: .top) {
                if case .sql(let model) = active, model.showPalette {
                    ZStack(alignment: .top) {
                        Color.black.opacity(0.001).onTapGesture { model.showPalette = false }
                        CommandPaletteView(model: model).padding(.top, 60)
                    }
                }
            }
        } else {
            emptyWindow
        }
    }

    /// No connection open: the one the window was opened for is on its way, or a list to pick one from.
    @ViewBuilder
    private var emptyWindow: some View {
        if let connectionID, !openedInitial {
            if appState.connection(connectionID) == nil {
                ContentUnavailableView(
                    "Connection not found",
                    systemImage: "questionmark.circle",
                    description: Text("It may have been deleted.")
                )
            } else {
                ProgressView()
            }
        } else {
            ConnectionPicker { id in
                guard let config = appState.connection(id) else { return }
                Task { await session.open(config, appState: appState) }
            }
        }
    }
}

/// A SQL connection's detail column (tabs, inspector) and toolbar items, in its window's split view; its sidebar is
/// `SidebarView`.
struct WorkspaceView: View {
    @Bindable var model: WorkspaceModel

    private var recordingInspectorWidth: CGFloat? {
        #if DEBUG
        return DebugHooks.inspectorWidth.map { CGFloat($0) }
        #else
        return nil
        #endif
    }

    var body: some View {
        detail
            .inspector(isPresented: $model.showInspector) {
                VStack(spacing: 0) {
                    Picker("Panel", selection: $model.rightPanel) {
                        ForEach(WorkspaceModel.RightPanel.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(Layout.barPadding)
                    Divider()
                    switch model.rightPanel {
                    case .rowDetails: RowInspectorView(model: model)
                    case .queries: QueryLibraryView(workspace: model)
                    case .ai: AIChatView(workspace: model, chat: model.chat)
                    }
                }
                .inspectorColumnWidth(
                    min: recordingInspectorWidth ?? Layout.Inspector.minWidth,
                    ideal: recordingInspectorWidth ?? Layout.Inspector.idealWidth,
                    max: recordingInspectorWidth ?? Layout.Inspector.maxWidth
                )
            }
            .navigationTitle(model.config.displayName)
            .sheet(item: $model.transfer) { transfer in
                DatabaseTransferSheet(transfer: transfer) { model.transfer = nil }
            }
            .toolbar {
                ConnectionPillItem(
                    pill: ConnectionPill(
                        config: model.config,
                        status: model.status,
                        location: location,
                        serverVersion: model.serverVersion,
                        connectedAt: model.connectedAt,
                        onReconnect: { Task { await model.reconnect() } }
                    )
                )
                ToolbarItem(placement: .navigation) {
                    OpenConnectionMenu(current: model.config.id)
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        model.newQueryTab()
                    } label: {
                        Label("New Query", systemImage: "plus.square.on.square")
                    }
                    .help("New query tab (⌘T)")
                    .disabled(model.driver == nil)
                    if model.config.kind.supportsDiagram {
                        Button {
                            model.openDiagram()
                        } label: {
                            Label("Diagram", systemImage: "point.3.connected.trianglepath.dotted")
                        }
                        .help("Relationship diagram (⌥⌘3)")
                        .disabled(model.driver == nil)
                    }
                    Button {
                        model.openMetrics()
                    } label: {
                        Label("Metrics", systemImage: "gauge.with.dots.needle.33percent")
                    }
                    .help("Server metrics (⌥⌘4)")
                    .disabled(model.driver == nil)
                    Button {
                        Task { await model.refresh() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .help("Refresh (⌘R)")
                    .disabled(model.driver == nil)
                    Button {
                        model.showConsole.toggle()
                    } label: {
                        Label("Console", systemImage: "rectangle.bottomthird.inset.filled")
                    }
                    .help("Console log (⇧⌘C)")
                    Button {
                        model.toggleRightPanel(.ai)
                    } label: {
                        Label("AI Chat", systemImage: "bubble.left.and.text.bubble.right")
                    }
                    .help("AI chat (⌥⌘A)")
                    Button {
                        model.toggleRightPanel(.rowDetails)
                    } label: {
                        Label("Row Details", systemImage: "sidebar.right")
                    }
                    .help("Show row details (⌥⌘0)")
                    .keyboardShortcut("0", modifiers: [.command, .option])
                }
            }
    }

    @ViewBuilder
    private var detail: some View {
        switch model.status {
        case .connecting:
            ProgressView("Connecting…")
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 10) {
                Image(systemName: "bolt.horizontal.circle").font(.system(size: 34, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Could not connect to \(model.config.displayName)").font(.headline)
                Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .textSelection(.enabled).frame(maxWidth: 480)
                Button("Try Again") { Task { await model.connect() } }
                    .controlSize(.regular)
                    .buttonStyle(.borderedProminent)
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .connected:
            VStack(spacing: 0) {
                // The tab strip stays above the console's split view, which mustn't sit under the toolbar.
                if !model.tabs.isEmpty {
                    TabStrip(model: model)
                }
                if !model.showConsole {
                    tabContent
                } else if model.tabs.isEmpty {
                    tabContent
                    Divider()
                    console.frame(height: Layout.Console.idealHeight)
                } else {
                    VerticalSplit(
                        topMinimum: Layout.Console.contentMinHeight,
                        bottomMinimum: Layout.Console.minHeight,
                        bottomIdeal: Layout.Console.idealHeight,
                        growing: .top,
                        autosaveName: "ConsoleLog"
                    ) {
                        tabContent
                    } bottom: {
                        console
                    }
                }
            }
            // Content must not dictate a minimum width: split views take a child's ideal width as its
            // minimum, which would stop the window from getting narrower than the widest row.
            .frame(minWidth: 0, maxWidth: .infinity)
        }
    }

    /// "database.schema" on PostgreSQL, where both can change; the schema (or database) elsewhere.
    private var location: String? {
        let parts = [model.currentDatabase, model.selectedSchema].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ".")
    }

    private var console: some View {
        ConsoleLogView(log: model.log) { model.showConsole = false }
    }

    /// Its own view, so switching tabs updates only the tab area, not the toolbar, inspector and sidebar.
    private var tabContent: some View {
        TabContentArea(model: model)
    }
}

/// The selected tab's content. Reads the selection here rather than in `WorkspaceView`, whose body also builds the
/// toolbar and inspector.
private struct TabContentArea: View {
    let model: WorkspaceModel

    var body: some View {
        VStack(spacing: 0) {
            if model.selectedTab != nil {
                TabContentHost(tabs: model.tabs, selectedID: model.selectedTabID, transient: transientTabs) {
                    [model] tab in
                    Self.content(of: tab, workspace: model)
                }
            } else {
                EmptyWorkspaceView(model: model)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity)
    }

    private var transientTabs: Set<UUID> {
        Set(model.tabs.compactMap { if case .metrics(let metrics) = $0 { metrics.id } else { nil } })
    }

    private static func content(of tab: WorkspaceModel.Tab, workspace model: WorkspaceModel) -> AnyView {
        switch tab {
        case .table(let table): AnyView(TableTabView(model: table, workspace: model))
        case .query(let query): AnyView(QueryTabView(model: query, workspace: model))
        case .diagram(let diagram): AnyView(DiagramView(model: diagram) { model.open($0) })
        case .metrics(let metrics): AnyView(MetricsView(model: metrics))
        case .routine(let routine): AnyView(RoutineTabView(model: routine, workspace: model))
        }
    }
}

private struct EmptyWorkspaceView: View {
    let model: WorkspaceModel

    var body: some View {
        VStack(spacing: 14) {
            KindBadge(kind: model.config.kind, size: 44).opacity(0.85)
            Text(model.config.displayName).font(.title3.weight(.semibold))
            VStack(alignment: .leading, spacing: 6) {
                shortcut("⌘T", "New query")
                shortcut("⌘R", "Refresh")
                shortcut("⌘F", "Filter rows")
                shortcut("⌥⌘0", "Row details")
                shortcut("⇧⌘K", "Connections")
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func shortcut(_ keys: String, _ title: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 24)
            Text(keys).font(.system(.body, design: .rounded)).foregroundStyle(.tertiary)
        }
        .frame(width: 220)
    }
}

/// Hands the hosting NSWindow to SwiftUI code (for window-level registration).
struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { if let window = view.window { onWindow(window) } }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window {
            onWindow(window)
        }
    }
}
