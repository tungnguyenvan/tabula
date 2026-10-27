import AppKit
import SwiftUI
import TabulaCore

/// A connection open in a window: the SQL workspace or the Redis key browser.
@MainActor
enum OpenConnection: Identifiable {
    case sql(WorkspaceModel)
    case redis(RedisWorkspaceModel)

    nonisolated var id: UUID {
        switch self {
        case .sql(let model): model.connectionID
        case .redis(let model): model.config.id
        }
    }

    var config: ConnectionConfig {
        switch self {
        case .sql(let model): model.config
        case .redis(let model): model.config
        }
    }

    var status: WorkspaceModel.Status {
        switch self {
        case .sql(let model): model.status
        case .redis(let model): model.status
        }
    }

    var hasUnsavedChanges: Bool {
        guard case .sql(let model) = self else { return false }
        return model.tabs.contains { model.hasUnsavedChanges($0.id) }
    }

    func connect() async {
        switch self {
        case .sql(let model): await model.connect()
        case .redis(let model): await model.connect()
        }
    }

    /// Closes the connection, saving a SQL workspace's tabs first so they come back next time.
    func disconnect() async {
        switch self {
        case .sql(let model):
            model.saveState()
            await model.disconnect()
        case .redis(let model): await model.disconnect()
        }
    }
}

/// The connections open in one window, shown in the connection rail; one of them is on screen.
@MainActor @Observable
final class ConnectionSession {
    private(set) var connections: [OpenConnection] = []
    var activeID: UUID?

    var active: OpenConnection? { connections.first { $0.id == activeID } ?? connections.first }

    func contains(_ id: UUID) -> Bool { connections.contains { $0.id == id } }

    /// Shows the connection, connecting first if it isn't open in this window yet.
    func open(_ config: ConnectionConfig, appState: AppState) async {
        activeID = config.id
        guard !contains(config.id) else { return }
        let password = await appState.password(for: config.id)
        guard !contains(config.id) else { return }
        let connection: OpenConnection = config.kind == .redis
            ? .redis(RedisWorkspaceModel(config: config, password: password))
            : .sql(WorkspaceModel(config: config, password: password))
        connections.append(connection)
        await connection.connect()
    }

    /// Disconnects and removes a connection, asking first if it holds uncommitted edits.
    func close(_ id: UUID) {
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
        let connection = connections[index]
        // A result commit uses a short-lived writer and can't be interrupted by tearing down its workspace.
        if case .sql(let model) = connection,
           model.tabs.contains(where: { if case .query(let query) = $0 { query.committingResults } else { false } }) { return }
        if connection.hasUnsavedChanges, !Confirmation.ask(
            "Close “\(connection.config.displayName)” and discard unsaved changes?",
            detail: "Commit changed rows and save edited .sql files (⌘S) first if you want to keep them.",
            action: "Discard and Close") { return }
        connections.remove(at: index)
        if activeID == id { activeID = connections.isEmpty ? nil : connections[min(index, connections.count - 1)].id }
        Task { await connection.disconnect() }
    }

    func selectAdjacent(_ offset: Int) {
        guard let current = connections.firstIndex(where: { $0.id == active?.id }), !connections.isEmpty else { return }
        activeID = connections[(current + offset + connections.count) % connections.count].id
    }

    /// Window close and application quit must not silently drop staged result changes or interrupt a commit.
    func confirmCloseResults() -> Bool {
        let queries = connections.flatMap { connection -> [QueryTabModel] in
            guard case .sql(let workspace) = connection else { return [] }
            return workspace.tabs.compactMap { if case .query(let query) = $0 { query } else { nil } }
        }
        if queries.contains(where: \.committingResults) {
            NSSound.beep()
            return false
        }
        guard queries.contains(where: \.hasResultChanges) else { return true }
        return Confirmation.ask("Discard uncommitted query result changes?",
                                detail: "Commit the result changes before closing if you want to keep them.", action: "Discard and Close")
    }

    func closeAll() {
        let all = connections
        connections = []
        activeID = nil
        Task { for connection in all { await connection.disconnect() } }
    }
}

/// Opens connections the way TablePlus does: into the frontmost workspace window when there is one,
/// otherwise into a new window.
@MainActor
enum ConnectionRouter {
    static func open(_ id: UUID, appState: AppState, openWindow: OpenWindowAction) {
        guard let config = appState.connection(id) else { return }
        if let (session, window) = WorkspaceRegistry.frontmostSession {
            window.makeKeyAndOrderFront(nil)
            Task { await session.open(config, appState: appState) }
        } else {
            openWindow(id: WindowID.workspace, value: id)
        }
    }
}

/// The narrow column at the window's leading edge, left of the sidebar, listing this window's connections.
struct ConnectionRail: View {
    let session: ConnectionSession
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: Layout.Rail.spacing) {
            ForEach(session.connections) { connection in
                RailItem(connection: connection, selected: connection.id == session.active?.id,
                         select: { session.activeID = connection.id },
                         close: { session.close(connection.id) })
            }
            Menu {
                ForEach(appState.connections.filter { !session.contains($0.id) }) { config in
                    Button("\(config.displayName) — \(config.kind.displayName)") {
                        Task { await session.open(config, appState: appState) }
                    }
                }
                Divider()
                Button("Manage Connections…") { openWindow(id: WindowID.connections) }
            } label: {
                Image(systemName: "plus").font(Layout.Rail.addFont).frame(width: Layout.Rail.itemSize, height: Layout.Rail.itemSize)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Open another connection")
            Spacer()
        }
        .padding(.vertical, Layout.Rail.spacing)
        .frame(width: Layout.Rail.width)
        .barBackground()
        .overlay(alignment: .trailing) { Divider() }
    }
}

private struct RailItem: View {
    let connection: OpenConnection
    let selected: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        let config = connection.config
        KindBadge(kind: config.kind, size: Layout.Rail.badgeSize)
            .frame(width: Layout.Rail.itemSize, height: Layout.Rail.itemSize)
            .background(RoundedRectangle(cornerRadius: Layout.cornerRadius)
                .fill(selected ? Color.accentColor.opacity(0.22) : Color.primary.opacity(hovering ? 0.06 : 0)))
            .overlay(alignment: .leading) {
                // Environment colour, like the strip under the window controls.
                if let color = config.tag.color {
                    Capsule().fill(color).frame(width: Layout.Rail.tagWidth, height: Layout.Rail.badgeSize)
                        .offset(x: -Layout.Rail.tagWidth * 2)
                }
            }
            .overlay(alignment: .bottomTrailing) { statusDot }
            .contentShape(Rectangle())
            .onTapGesture(perform: select)
            .onHover { hovering = $0 }
            .help("\(config.displayName) — \(config.subtitle)")
            .contextMenu {
                Button("Close Connection", action: close)
            }
    }

    @ViewBuilder
    private var statusDot: some View {
        switch connection.status {
        case .connecting: ProgressView().controlSize(.mini)
        case .connected: EmptyView()
        case .failed: Circle().fill(.red).frame(width: Layout.statusDot, height: Layout.statusDot)
        }
    }
}
