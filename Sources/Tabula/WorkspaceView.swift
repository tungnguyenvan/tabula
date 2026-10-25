import AppKit
import SwiftUI
import TabulaCore

struct WorkspaceWindow: View {
    /// The connection the window was opened for; nil for an empty window, which offers one to open.
    @Binding var connectionID: UUID?
    @Environment(AppState.self) private var appState
    @State private var session = ConnectionSession()
    @State private var openedInitial = false

    var body: some View {
        HStack(spacing: 0) {
            // With one connection the rail would only repeat the toolbar; it appears once a second one opens.
            if session.connections.count > 1 { ConnectionRail(session: session) }
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

    @ViewBuilder
    private var activeConnection: some View {
        switch session.active {
        case .sql(let model):
            WorkspaceView(model: model).id(model.config.id)
        case .redis(let model):
            RedisWorkspaceView(model: model).id(model.config.id)
        case nil:
            if let connectionID, !openedInitial {
                if appState.connection(connectionID) == nil {
                    ContentUnavailableView("Connection not found", systemImage: "questionmark.circle",
                                           description: Text("It may have been deleted."))
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
}

struct WorkspaceView: View {
    @Bindable var model: WorkspaceModel
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: Layout.Sidebar.minWidth, ideal: Layout.Sidebar.idealWidth, max: Layout.Sidebar.maxWidth)
        } detail: {
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
                        case .ai: AIChatView(workspace: model, chat: model.chat)
                        }
                    }
                    .inspectorColumnWidth(min: Layout.Inspector.minWidth, ideal: Layout.Inspector.idealWidth, max: Layout.Inspector.maxWidth)
                }
        }
        .navigationTitle(model.config.displayName)
        .overlay(alignment: .top) {
            if model.showPalette {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.001).onTapGesture { model.showPalette = false }
                    CommandPaletteView(model: model).padding(.top, 60)
                }
            }
        }
        .toolbar {
            ConnectionPillItem(pill: ConnectionPill(config: model.config, status: model.status,
                                                    location: model.selectedSchema.isEmpty ? nil : model.selectedSchema,
                                                    serverVersion: model.serverVersion, connectedAt: model.connectedAt,
                                                    onReconnect: { Task { await model.reconnect() } }))
            ToolbarItem(placement: .navigation) {
                OpenConnectionMenu(current: model.config.id)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.newQueryTab() } label: { Label("New Query", systemImage: "plus.square.on.square") }
                    .help("New query tab (⌘T)")
                    .disabled(model.driver == nil)
                Button { model.openDiagram() } label: { Label("Diagram", systemImage: "point.3.connected.trianglepath.dotted") }
                    .help("Relationship diagram (⌥⌘3)")
                    .disabled(model.driver == nil || model.config.kind == .redis)
                Button { model.openMetrics() } label: { Label("Metrics", systemImage: "gauge.with.dots.needle.33percent") }
                    .help("Server metrics (⌥⌘4)")
                    .disabled(model.driver == nil)
                Button { Task { await model.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Refresh (⌘R)")
                    .disabled(model.driver == nil)
                Button { model.showConsole.toggle() } label: { Label("Console", systemImage: "rectangle.bottomthird.inset.filled") }
                    .help("Console log (⇧⌘C)")
                Button { model.toggleRightPanel(.ai) } label: { Label("AI Chat", systemImage: "bubble.left.and.text.bubble.right") }
                    .help("AI chat (⌥⌘A)")
                Button { model.toggleRightPanel(.rowDetails) } label: { Label("Row Details", systemImage: "sidebar.right") }
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
                Image(systemName: "bolt.horizontal.circle").font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
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
            if model.showConsole {
                VSplitView {
                    tabContent
                    ConsoleLogView(log: model.log) { model.showConsole = false }
                        .frame(minWidth: 0, maxWidth: .infinity, minHeight: Layout.Console.minHeight, idealHeight: Layout.Console.idealHeight)
                }
            } else {
                tabContent
            }
        }
    }

    private var tabContent: some View {
        VStack(spacing: 0) {
            if !model.tabs.isEmpty {
                TabStrip(model: model)
            }
            if let tab = model.selectedTab {
                switch tab {
                case .table(let table): TableTabView(model: table, workspace: model).id(table.id)
                case .query(let query): QueryTabView(model: query, workspace: model).id(query.id)
                case .diagram(let diagram): DiagramView(model: diagram) { model.open($0) }.id(diagram.id)
                case .metrics(let metrics): MetricsView(model: metrics).id(metrics.id)
                case .routine(let routine): RoutineTabView(model: routine, workspace: model).id(routine.id)
                }
            } else {
                EmptyWorkspaceView(model: model)
            }
        }
        // Content must not dictate a minimum width: split views take a child's ideal width as its
        // minimum, which would stop the window from getting narrower than the widest row.
        .frame(minWidth: 0, maxWidth: .infinity)
    }
}

/// The centered toolbar capsule: database kind, environment, connection name, server and status.
/// Clicking it shows the connection details and lets you open other connections.
struct ConnectionPill: View {
    let config: ConnectionConfig
    let status: WorkspaceModel.Status
    /// Schema, database or Redis db index shown after the server address.
    var location: String?
    var serverVersion: String?
    var connectedAt: Date?
    var onReconnect: () -> Void = {}
    @State private var showingInfo = false

    private var tint: Color { config.tag.color ?? .secondary }

    private var statusText: String {
        switch status {
        case .connecting: return "Connecting…"
        case .failed: return "Disconnected"
        case .connected:
            if config.kind == .sqlite { return (config.filePath as NSString).abbreviatingWithTildeInPath }
            return "\(config.host):\(config.port)" + (location.map { " : \($0)" } ?? "")
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            KindBadge(kind: config.kind, size: 18)
            if config.tag != .none {
                Text(config.tag.displayName.uppercased())
                    .font(Layout.Font.tag)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(tint, in: RoundedRectangle(cornerRadius: 3))
            }
            Text(config.displayName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Text(statusText).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            statusDot
        }
        .padding(.horizontal, 10)
        .frame(minWidth: 320, maxWidth: 560, minHeight: 26)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(config.tag.color.map { $0.opacity(0.14) } ?? Color.primary.opacity(0.05))
        )
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.08)))
        .contentShape(Rectangle())
        .onTapGesture { showingInfo.toggle() }
        .help("Connection details")
        .popover(isPresented: $showingInfo, arrowEdge: .bottom) {
            ConnectionInfoPopover(config: config, status: status, location: location, serverVersion: serverVersion,
                                  connectedAt: connectedAt, onReconnect: { showingInfo = false; onReconnect() })
        }
    }

    @ViewBuilder
    private var statusDot: some View {
        switch status {
        case .connecting: ProgressView().controlSize(.mini)
        case .connected: Circle().fill(.green).frame(width: 7, height: 7).help("Connected")
        case .failed(let message): Circle().fill(.red).frame(width: 7, height: 7).help(message)
        }
    }
}

/// Tabs share the bar between 120 and 220 points each, left-aligned; when they don't fit, the bar scrolls
/// and keeps the selected tab in view.
private struct TabStrip: View {
    let model: WorkspaceModel

    var body: some View {
        HStack(spacing: 0) {
            GeometryReader { geometry in
                let width = min(220, max(120, geometry.size.width / CGFloat(max(model.tabs.count, 1))))
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 0) {
                            ForEach(model.tabs) { tab in
                                TabButton(tab: tab, selected: tab.id == model.selectedTabID, isPreview: model.isPreview(tab.id),
                                          select: { model.selectedTabID = tab.id },
                                          pin: { model.pin(tab.id) },
                                          close: { model.requestClose(tab.id) },
                                          closeOthers: { for other in model.tabs where other.id != tab.id { model.requestClose(other.id) } })
                                    .frame(width: width)
                                    .id(tab.id)
                                Divider().frame(height: 14)
                            }
                        }
                        .frame(height: geometry.size.height)
                    }
                    .onChange(of: model.selectedTabID) { _, id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(id) }
                    }
                    .onAppear {
                        if let id = model.selectedTabID { DispatchQueue.main.async { proxy.scrollTo(id) } }
                    }
                }
            }
            Button { model.newQueryTab() } label: {
                Image(systemName: "plus").font(.system(size: 11, weight: .medium)).frame(width: 28, height: 26)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("New query tab (⌘T)")
        }
        .frame(height: 28)
        .barBackground()
        .overlay(alignment: .bottom) { Divider() }
        .clipped()
    }
}

private struct TabButton: View {
    let tab: WorkspaceModel.Tab
    let selected: Bool
    let isPreview: Bool
    let select: () -> Void
    let pin: () -> Void
    let close: () -> Void
    let closeOthers: () -> Void
    @State private var hovering = false

    private var icon: String {
        switch tab {
        case .table(let model): model.table.kind == .view ? "eye" : "tablecells"
        case .query: "chevron.left.forwardslash.chevron.right"
        case .diagram: "point.3.connected.trianglepath.dotted"
        case .metrics: "gauge.with.dots.needle.33percent"
        case .routine(let model): RoutineRow.symbol(model.routine?.kind ?? model.newKind)
        }
    }

    private var hasChanges: Bool {
        if case .table(let model) = tab { return model.hasChanges }
        return false
    }

    var body: some View {
        ZStack {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10)).foregroundStyle(selected ? Color.accentColor : .secondary)
                Text(tab.title).font(.system(size: 12, weight: selected ? .medium : .regular)).italic(isPreview).lineLimit(1)
                if hasChanges { Circle().fill(.orange).frame(width: 6, height: 6) }
            }
            .padding(.horizontal, 22)
            HStack {
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).frame(width: 16, height: 16)
                        .background(Color.primary.opacity(hovering ? 0.08 : 0), in: RoundedRectangle(cornerRadius: 3))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(hovering ? 1 : 0)
                Spacer()
            }
            .padding(.leading, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(selected ? Color(nsColor: .windowBackgroundColor) : (hovering ? Color.primary.opacity(0.04) : .clear),
                    ignoresSafeAreaEdges: [])
        .overlay(alignment: .top) {
            if selected { Rectangle().fill(Color.accentColor).frame(height: 2) }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: pin)
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .help(isPreview ? "Preview tab — double-click to keep it open" : "")
        .contextMenu {
            if isPreview { Button("Keep Open", action: pin) }
            Button("Close Tab", action: close)
            Button("Close Other Tabs", action: closeOthers)
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

/// Shown in a new, empty window tab: pick the connection to open there.
private struct ConnectionPicker: View {
    let onPick: (UUID) -> Void
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @State private var search = ""

    private var matches: [ConnectionConfig] {
        search.isEmpty ? appState.connections : appState.connections.filter {
            $0.displayName.localizedCaseInsensitiveContains(search) || $0.subtitle.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            Text("Open a connection in this tab").font(.title3.weight(.semibold))
            TextField("Search connections", text: $search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 360)
                .onSubmit { if let first = matches.first { onPick(first.id) } }
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(matches) { connection in
                        Button { onPick(connection.id) } label: {
                            HStack(spacing: 10) {
                                KindBadge(kind: connection.kind, size: 26)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(connection.displayName).font(.system(size: 13, weight: .medium))
                                    Text(connection.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                if let color = connection.tag.color { Circle().fill(color).frame(width: 7, height: 7) }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(width: 420, height: 300)
            Button("Manage Connections…") { openWindow(id: WindowID.connections) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The connection pill in the toolbar's center. On macOS 26 the pill draws its own capsule,
/// so the toolbar's glass background around it is turned off.
struct ConnectionPillItem: ToolbarContent {
    let pill: ConnectionPill

    var body: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .principal) { pill }.sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .principal) { pill }
        }
    }
}

/// Details of the current connection, plus quick access to the others.
struct ConnectionInfoPopover: View {
    let config: ConnectionConfig
    let status: WorkspaceModel.Status
    var location: String?
    var serverVersion: String?
    var connectedAt: Date?
    let onReconnect: () -> Void
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    private var rows: [(String, String)] {
        var rows: [(String, String)] = [("Type", config.kind.displayName)]
        if let serverVersion { rows.append(("Server", serverVersion)) }
        if config.kind == .sqlite {
            rows.append(("File", (config.filePath as NSString).abbreviatingWithTildeInPath))
        } else {
            rows.append(("Host", "\(config.host):\(config.port)"))
            if !config.user.isEmpty { rows.append(("User", config.user)) }
            let databaseLabel = config.kind == .postgres ? "Schema" : "Database"
            if let location { rows.append((databaseLabel, location)) }
            rows.append(("TLS", config.tls.displayName))
        }
        if config.tag != .none { rows.append(("Tag", config.tag.displayName)) }
        switch status {
        case .connected: rows.append(("Status", connectedAt.map { "Connected \($0.formatted(.relative(presentation: .named)))" } ?? "Connected"))
        case .connecting: rows.append(("Status", "Connecting…"))
        case .failed(let message): rows.append(("Status", message))
        }
        return rows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                KindBadge(kind: config.kind, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(config.displayName).font(.headline)
                    Text(config.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 5) {
                ForEach(rows, id: \.0) { row in
                    GridRow {
                        Text(row.0).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        Text(row.1).textSelection(.enabled).lineLimit(3)
                    }
                }
            }
            .font(.system(size: 12))
            HStack {
                Button("Reconnect", action: onReconnect)
                Button("Edit Connection…") { openWindow(id: WindowID.connections) }
                Spacer()
            }
            .controlSize(.small)
            let others = appState.connections.filter { $0.id != config.id }
            if !others.isEmpty {
                Divider()
                Text("Open another connection").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(others) { other in
                            Button { ConnectionRouter.open(other.id, appState: appState, openWindow: openWindow) } label: {
                                HStack(spacing: 8) {
                                    KindBadge(kind: other.kind, size: 18)
                                    Text(other.displayName).lineLimit(1)
                                    if let color = other.tag.color { Circle().fill(color).frame(width: 6, height: 6) }
                                    Spacer()
                                    Text(other.kind.displayName).font(.caption).foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 6).padding(.vertical, 4)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 180)
            }
        }
        .padding(14)
        .frame(width: 380)
    }
}

/// Toolbar menu that opens any saved connection in a new window tab.
struct OpenConnectionMenu: View {
    let current: UUID
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Menu {
            ForEach(appState.connections) { connection in
                Button {
                    ConnectionRouter.open(connection.id, appState: appState, openWindow: openWindow)
                } label: {
                    if connection.id == current {
                        Label(connection.displayName, systemImage: "checkmark")
                    } else {
                        Text("\(connection.displayName) — \(connection.kind.displayName)")
                    }
                }
            }
            Divider()
            Button("Manage Connections…") { openWindow(id: WindowID.connections) }
        } label: {
            Label("Connections", systemImage: "cylinder.split.1x2")
        }
        .help("Open another connection (⇧⌘K for all)")
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
        if let window = nsView.window { onWindow(window) }
    }
}
