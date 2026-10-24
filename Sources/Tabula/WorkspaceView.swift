import AppKit
import SwiftUI
import TabulaCore

struct WorkspaceWindow: View {
    let connectionID: UUID?
    @Environment(AppState.self) private var appState
    @State private var model: WorkspaceModel?

    var body: some View {
        Group {
            if let model {
                WorkspaceView(model: model)
            } else if appState.connection(connectionID) == nil {
                ContentUnavailableView("Connection not found", systemImage: "questionmark.circle",
                                       description: Text("It may have been deleted."))
            } else {
                ProgressView()
            }
        }
        .task(id: connectionID) {
            guard model == nil, let id = connectionID, let config = appState.connection(id) else { return }
            let workspace = WorkspaceModel(config: config, password: await appState.password(for: id))
            model = workspace
            await workspace.connect()
        }
        .onDisappear {
            let workspace = model
            Task { await workspace?.disconnect() }
        }
    }
}

struct WorkspaceView: View {
    @Bindable var model: WorkspaceModel
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 180, ideal: 230, max: 400)
        } detail: {
            detail
                .inspector(isPresented: $model.showInspector) {
                    RowInspectorView(model: model)
                        .inspectorColumnWidth(min: 240, ideal: 300, max: 520)
                }
        }
        .navigationTitle(model.config.displayName)
        .focusedSceneValue(\.workspace, model)
        .background(WindowAccessor { window in WorkspaceRegistry.register(model, window: window) })
        .overlay(alignment: .top) {
            if model.showPalette {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.001).onTapGesture { model.showPalette = false }
                    CommandPaletteView(model: model).padding(.top, 60)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                ConnectionPill(model: model)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.newQueryTab() } label: { Label("New Query", systemImage: "plus.square.on.square") }
                    .help("New query tab (⌘T)")
                    .disabled(model.driver == nil)
                Button { Task { await model.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Refresh (⌘R)")
                    .disabled(model.driver == nil)
                Button { model.showInspector.toggle() } label: { Label("Row Details", systemImage: "sidebar.right") }
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
            VStack(spacing: 0) {
                if !model.tabs.isEmpty {
                    TabStrip(model: model)
                }
                if let tab = model.selectedTab {
                    switch tab {
                    case .table(let table): TableTabView(model: table, workspace: model).id(table.id)
                    case .query(let query): QueryTabView(model: query, workspace: model).id(query.id)
                    }
                } else {
                    EmptyWorkspaceView(model: model)
                }
            }
        }
    }
}

/// The centered toolbar capsule: database kind, connection name, server and environment.
private struct ConnectionPill: View {
    let model: WorkspaceModel

    private var tint: Color { model.config.tag.color ?? .secondary }

    private var statusText: String {
        switch model.status {
        case .connecting: return "Connecting…"
        case .failed: return "Disconnected"
        case .connected:
            let config = model.config
            if config.kind == .sqlite { return (config.filePath as NSString).abbreviatingWithTildeInPath }
            let schema = model.selectedSchema.isEmpty ? "" : " : \(model.selectedSchema)"
            return "\(config.host):\(config.port)\(schema)"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            KindBadge(kind: model.config.kind, size: 18)
            if model.config.tag != .none {
                Text(model.config.tag.displayName.uppercased())
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(tint, in: RoundedRectangle(cornerRadius: 3))
            }
            Text(model.config.displayName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Text(statusText).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            statusDot
        }
        .padding(.horizontal, 10)
        .frame(minWidth: 320, maxWidth: 560, minHeight: 26)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(model.config.tag.color.map { $0.opacity(0.14) } ?? Color.primary.opacity(0.05))
        )
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.08)))
    }

    @ViewBuilder
    private var statusDot: some View {
        switch model.status {
        case .connecting: ProgressView().controlSize(.mini)
        case .connected: Circle().fill(.green).frame(width: 7, height: 7).help("Connected")
        case .failed(let message): Circle().fill(.red).frame(width: 7, height: 7).help(message)
        }
    }
}

/// Equal-width tabs that fill the bar, Safari-style.
private struct TabStrip: View {
    let model: WorkspaceModel

    var body: some View {
        HStack(spacing: 0) {
            ForEach(model.tabs) { tab in
                TabButton(tab: tab, selected: tab.id == model.selectedTabID, isPreview: model.isPreview(tab.id),
                          select: { model.selectedTabID = tab.id },
                          pin: { model.pin(tab.id) },
                          close: { model.requestClose(tab.id) },
                          closeOthers: { for other in model.tabs where other.id != tab.id { model.requestClose(other.id) } })
                if tab.id != model.tabs.last?.id { Divider().frame(height: 14) }
            }
            Button { model.newQueryTab() } label: {
                Image(systemName: "plus").font(.system(size: 11, weight: .medium)).frame(width: 28, height: 26)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("New query tab")
        }
        .frame(height: 28)
        .background(Color(nsColor: .underPageBackgroundColor))
        .overlay(alignment: .bottom) { Divider() }
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
        .frame(minWidth: 90, maxWidth: .infinity, maxHeight: .infinity)
        .background(selected ? Color(nsColor: .windowBackgroundColor) : (hovering ? Color.primary.opacity(0.04) : .clear))
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
