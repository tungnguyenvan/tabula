import AppKit
import SwiftUI
import TabulaFoundation

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
            if config.kind == .sqlite {
                return (config.filePath as NSString).abbreviatingWithTildeInPath
            }
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
            ConnectionInfoPopover(
                config: config,
                status: status,
                location: location,
                serverVersion: serverVersion,
                connectedAt: connectedAt,
                onReconnect: {
                    showingInfo = false
                    onReconnect()
                }
            )
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

/// Shown in a new, empty window tab: pick the connection to open there.
struct ConnectionPicker: View {
    let onPick: (UUID) -> Void
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @State private var search = ""

    private var matches: [ConnectionConfig] {
        search.isEmpty
            ? appState.connections
            : appState.connections.filter {
                SearchText.matches($0.displayName, search) || SearchText.matches($0.subtitle, search)
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
                        Button {
                            onPick(connection.id)
                        } label: {
                            HStack(spacing: 10) {
                                KindBadge(kind: connection.kind, size: 26)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(connection.displayName).font(.system(size: 13, weight: .medium))
                                    Text(connection.subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if let color = connection.tag.color {
                                    Circle().fill(color).frame(width: 7, height: 7)
                                }
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
        if let serverVersion {
            rows.append(("Server", serverVersion))
        }
        if config.kind == .sqlite {
            rows.append(("File", (config.filePath as NSString).abbreviatingWithTildeInPath))
        } else {
            rows.append(("Host", "\(config.host):\(config.port)"))
            if !config.user.isEmpty {
                rows.append(("User", config.user))
            }
            let databaseLabel = config.kind == .postgres ? "Database.Schema" : "Database"
            if let location {
                rows.append((databaseLabel, location))
            }
            rows.append(("TLS", config.tls.displayName))
        }
        if config.tag != .none {
            rows.append(("Tag", config.tag.displayName))
        }
        switch status {
        case .connected:
            rows.append(
                (
                    "Status",
                    connectedAt.map { "Connected \($0.formatted(.relative(presentation: .named)))" } ?? "Connected"
                )
            )
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
                    Text(config.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .truncationMode(.middle)
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
                            Button {
                                ConnectionRouter.open(other.id, appState: appState, openWindow: openWindow)
                            } label: {
                                HStack(spacing: 8) {
                                    KindBadge(kind: other.kind, size: 18)
                                    Text(other.displayName).lineLimit(1)
                                    if let color = other.tag.color {
                                        Circle().fill(color).frame(width: 6, height: 6)
                                    }
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
