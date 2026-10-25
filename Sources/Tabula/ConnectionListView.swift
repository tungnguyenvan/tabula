import AppKit
import SwiftUI
import TabulaCore

struct ConnectionListView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var search = ""
    @State private var selection: UUID?
    @State private var editing: EditRequest?
    @State private var pendingDelete: ConnectionConfig?

    struct EditRequest: Identifiable {
        let id = UUID()
        var config: ConnectionConfig
        var isNew: Bool
        var password = ""
    }

    /// Opens the editor once the saved password has been read (off the main thread).
    private func edit(_ config: ConnectionConfig) {
        Task {
            let password = await appState.password(for: config.id) ?? ""
            // The connection may have been deleted while the Keychain was answering.
            guard let current = appState.connection(config.id) else { return }
            editing = EditRequest(config: current, isNew: false, password: password)
        }
    }

    private var filtered: [ConnectionConfig] {
        guard !search.isEmpty else { return appState.connections }
        return appState.connections.filter {
            $0.displayName.localizedCaseInsensitiveContains(search) || $0.subtitle.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            welcomePane
                .frame(width: Layout.Welcome.width)
                .background(WindowDragArea())
                .barBackground()
            Divider()
            listPane
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 680, minHeight: 420)
        .onAppear {
            #if DEBUG
            if let id = DebugHooks.connectionToEdit, let config = appState.connection(id) { edit(config) }
            #endif
        }
        .sheet(item: $editing) { request in
            ConnectionFormView(config: request.config, isNew: request.isNew, password: request.password) { saved, password, connect in
                appState.save(saved, password: password)
                editing = nil
                if connect { open(saved.id) }
            } onCancel: {
                editing = nil
            }
        }
        .confirmationDialog("Delete “\(pendingDelete?.displayName ?? "")”?", isPresented: Binding(
            get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }
        ), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let id = pendingDelete?.id { appState.delete(id) }
                pendingDelete = nil
            }
        } message: {
            Text("The saved connection and its Keychain password are removed. The database itself is not touched.")
        }
        .onAppear { Updater.shared.checkInBackgroundIfDue() }
        .onChange(of: Updater.shared.showWindow) { _, show in
            if show {
                WindowRequests.request(WindowID.update)
                openWindow(id: WindowID.update)
            }
        }
        #if DEBUG
        .onAppear {
            for (index, id) in DebugHooks.connectionsToOpen.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 1.5) { open(id) }
            }
            if DebugHooks.showShortcuts {
                WindowRequests.request(WindowID.shortcuts)
                openWindow(id: WindowID.shortcuts)
            }
            if DebugHooks.showAbout { AboutPanel.show() }
            if DebugHooks.showSettings {
                UserDefaults.standard.set(ProcessInfo.processInfo.environment["TABULA_DEBUG_SETTINGS"], forKey: "TabulaSettingsTab")
                openSettings()
            }
        }
        #endif
        .onDeleteCommand {
            if let id = selection { pendingDelete = appState.connection(id) }
        }
    }

    private var welcomePane: some View {
        VStack(spacing: 0) {
            Spacer()
            AppMark(size: 72)
            Text("Tabula").font(.system(size: 24, weight: .bold)).padding(.top, 12)
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            VStack(spacing: 8) {
                WelcomeAction(symbol: "plus.circle.fill", title: "New Connection", shortcut: "⌘N") {
                    editing = EditRequest(config: ConnectionConfig(), isNew: true)
                }
                .keyboardShortcut("n", modifiers: .command)
                WelcomeAction(symbol: "doc.badge.plus", title: "Open SQLite File…", shortcut: "⌘O") { openSQLiteFile() }
                    .keyboardShortcut("o", modifiers: .command)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
        }
    }

    private var listPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("Search connections", text: $search).textFieldStyle(.plain).font(.system(size: 13))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 6)

            if appState.connections.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "cylinder.split.1x2").font(.system(size: 30, weight: .light)).foregroundStyle(.tertiary)
                    Text("No connections yet").font(.headline)
                    Text("PostgreSQL · MySQL / MariaDB · SQLite · MongoDB · Redis").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(filtered) { config in
                        ConnectionRow(config: config)
                            .tag(config.id)
                            .contextMenu { menu(for: config) }
                    }
                    .onMove { appState.move(from: $0, to: $1) }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .contextMenu(forSelectionType: UUID.self) { _ in } primaryAction: { ids in
                    if let id = ids.first { open(id) }
                }
            }
            if let error = appState.lastError {
                Text(error).font(.caption).foregroundStyle(.red).padding(6)
            }
            Divider()
            HStack {
                Text("Double-click to connect · ⌫ to delete").font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                BarButton(symbol: "pencil", help: "Edit") {
                    if let config = appState.connection(selection) { edit(config) }
                }
                .disabled(selection == nil)
                BarButton(symbol: "plus", help: "New connection") { editing = EditRequest(config: ConnectionConfig(), isNew: true) }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
        }
    }

    @ViewBuilder
    private func menu(for config: ConnectionConfig) -> some View {
        Button("Connect") { open(config.id) }
        Button("Edit…") { edit(config) }
        Button("Duplicate") { appState.duplicate(config) }
        Divider()
        Button("Copy URL") { Clipboard.copy(config.url()) }
        Button("Copy URL with Password") {
            Task { Clipboard.copy(config.url(password: await appState.password(for: config.id))) }
        }
        Divider()
        Button("Delete…", role: .destructive) { pendingDelete = config }
    }

    private func open(_ id: UUID) {
        ConnectionRouter.open(id, appState: appState, openWindow: openWindow)
    }

    private func openSQLiteFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a SQLite database"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let existing = appState.connections.first(where: { $0.kind == .sqlite && $0.filePath == url.path }) {
            open(existing.id)
            return
        }
        let config = ConnectionConfig(name: url.lastPathComponent, kind: .sqlite, filePath: url.path)
        appState.save(config, password: nil)
        open(config.id)
    }
}

private struct ConnectionRow: View {
    let config: ConnectionConfig

    var body: some View {
        HStack(spacing: 10) {
            KindBadge(kind: config.kind, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(config.displayName).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    if let color = config.tag.color {
                        Text(config.tag.displayName.uppercased())
                            .font(.system(size: 8, weight: .heavy))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(color, in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(.white)
                    }
                }
                Text(config.subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Text(config.kind.displayName).font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

private struct WelcomeAction: View {
    let symbol: String
    let title: String
    let shortcut: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(Color.accentColor).frame(width: 20)
                Text(title).font(.system(size: 13, weight: .medium))
                Spacer()
                Text(shortcut).font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Color.primary.opacity(hovering ? 0.09 : 0.05), in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
