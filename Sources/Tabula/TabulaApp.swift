import AppKit
import SwiftUI
import TabulaCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var keyMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched as a bare executable (swift run) rather than from the .app bundle.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Local monitors run on the main thread.
            nonisolated(unsafe) let event = event
            let handled = MainActor.assumeIsolated { WorkspaceRegistry.handle(event) }
            return handled ? nil : event
        }
        #if DEBUG
        DebugHooks.startSnapshots()
        DebugHooks.startRecording()
        DebugHooks.startKeyScript()
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        // llama.cpp aborts at exit if a model is still loaded on the GPU.
        LocalModelRunner.shared.unload()
    }
}

@main
struct TabulaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()

    init() {
        // Don't reopen workspace windows (and silently reconnect, possibly to production) on launch.
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    }

    var body: some Scene {
        Window("Tabula", id: WindowID.connections) {
            ConnectionListView()
                .environment(appState)
        }
        .defaultSize(Layout.Window.connections)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        WindowGroup("Workspace", id: WindowID.workspace, for: UUID.self) { $connectionID in
            WorkspaceWindow(connectionID: $connectionID)
                .environment(appState)
        }
        .defaultSize(Layout.Window.workspace)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { WorkspaceCommands() }

        Window("Keyboard Shortcuts", id: WindowID.shortcuts) {
            ShortcutsView().closesUnlessRequested(WindowID.shortcuts)
        }
        .defaultSize(Layout.Window.shortcuts)

        Window("Software Update", id: WindowID.update) {
            UpdateView(updater: Updater.shared).closesUnlessRequested(WindowID.update)
        }
        .windowResizability(.contentSize)

        Settings {
            SettingsView()
        }
    }
}

/// Auxiliary windows open only when asked for. macOS can bring them back by itself (e.g. after the app was
/// force-quit with one open); a window that appears without a request closes itself.
@MainActor
enum WindowRequests {
    private static var pending: Set<String> = []

    static func request(_ id: String) { pending.insert(id) }

    /// True once per request.
    static func consume(_ id: String) -> Bool { pending.remove(id) != nil }
}

/// Virtual key codes for keys that menus can't bind.
enum KeyCode {
    static let tab: UInt16 = 48
    static let `return`: UInt16 = 36
    static let enter: UInt16 = 76
    static let space: UInt16 = 49
}

enum WindowID {
    static let connections = "connections"
    static let workspace = "workspace"
    static let shortcuts = "shortcuts"
    static let update = "update"
}

/// The workspace of the key window. Menu commands use this instead of SwiftUI's focused values,
/// which drop to nil whenever an AppKit view (grid cell editor, SQL editor) holds keyboard focus.
@MainActor @Observable
final class ActiveWorkspace {
    static let shared = ActiveWorkspace()
    private(set) weak var session: ConnectionSession?

    var model: WorkspaceModel? {
        if case .sql(let model) = session?.active { return model }
        return nil
    }

    var redis: RedisWorkspaceModel? {
        if case .redis(let model) = session?.active { return model }
        return nil
    }

    fileprivate func update(_ session: ConnectionSession?) {
        if self.session !== session { self.session = session }
    }
}

/// Maps windows to their connection session so menus and app-wide keys (⌃Tab) reach the right one.
@MainActor
enum WorkspaceRegistry {
    private static var sessions: [Int: WeakSession] = [:]
    private static var observer: Any?

    private struct WeakSession {
        weak var session: ConnectionSession?
    }

    static func register(_ session: ConnectionSession, window: NSWindow) {
        window.title = session.active?.config.displayName ?? window.title
        guard sessions[window.windowNumber]?.session !== session else { return }
        sessions = sessions.filter { $0.value.session != nil }
        sessions[window.windowNumber] = WeakSession(session: session)
        // The window often becomes key before SwiftUI hands it to us, so the notification below has
        // already gone by; check now and once more after this layout pass.
        let number = window.windowNumber
        let refresh = { if NSApp.keyWindow?.windowNumber == number { ActiveWorkspace.shared.update(session) } }
        refresh()
        DispatchQueue.main.async(execute: refresh)
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
                let number = (note.object as? NSWindow)?.windowNumber
                MainActor.assumeIsolated {
                    // Non-workspace windows (Connections, Shortcuts) clear it, so workspace commands disable.
                    ActiveWorkspace.shared.update(number.flatMap { sessions[$0]?.session })
                }
            }
        }
    }

    /// The workspace window nearest the front, where newly opened connections go.
    static var frontmostSession: (ConnectionSession, NSWindow)? {
        for window in NSApp.orderedWindows where window.isVisible {
            if let session = sessions[window.windowNumber]?.session { return (session, window) }
        }
        return nil
    }

    static var key: WorkspaceModel? { ActiveWorkspace.shared.model }

    #if DEBUG
    static func makeActiveForTesting(_ window: NSWindow) {
        ActiveWorkspace.shared.update(sessions[window.windowNumber]?.session)
    }
    #endif

    /// Shortcuts that menus can't express (⌃Tab / ⌃⇧Tab). Returns true when handled.
    static func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard event.keyCode == KeyCode.tab, flags == [.control] || flags == [.control, .shift], let workspace = key else { return false }
        workspace.selectAdjacentTab(flags.contains(.shift) ? -1 : 1)
        return true
    }
}

struct WorkspaceCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    private var workspace: WorkspaceModel? { ActiveWorkspace.shared.model }
    private var redis: RedisWorkspaceModel? { ActiveWorkspace.shared.redis }

    private var table: TableTabModel? { workspace?.selectedTableTab }

    private var query: QueryTabModel? {
        if case .query(let model) = workspace?.selectedTab { return model }
        return nil
    }

    // SwiftUI doesn't re-evaluate menus when model state changes, so items only disable when there is
    // no workspace; each action checks its own preconditions when it runs.
    var body: some Commands {
        let noWorkspace = workspace == nil && redis == nil

        CommandGroup(after: .newItem) {
            Button(redis != nil ? "Console" : "New Query Tab") {
                if let redis { redis.mode = .console } else { workspace?.newQueryTab() }
            }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(noWorkspace)
            Button("Reopen Closed Tab") { workspace?.reopenClosedTab() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(noWorkspace)
            Button("Open Anything…") { workspace?.showPalette = true }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(noWorkspace)
            Divider()
            // Closes the current tab; with no tabs (or outside a workspace) closes the window.
            Button("Close Tab") {
                if let workspace, let id = workspace.selectedTabID {
                    workspace.requestClose(id)
                } else {
                    NSApp.keyWindow?.performClose(nil)
                }
            }
            .keyboardShortcut("w", modifiers: .command)
            Divider()
            Button("Connections…") { openWindow(id: WindowID.connections) }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            Button("Next Connection") { ActiveWorkspace.shared.session?.selectAdjacent(1) }
                .keyboardShortcut("]", modifiers: [.command, .control])
                .disabled(noWorkspace)
            Button("Previous Connection") { ActiveWorkspace.shared.session?.selectAdjacent(-1) }
                .keyboardShortcut("[", modifiers: [.command, .control])
                .disabled(noWorkspace)
            Button("Close Connection") {
                if let session = ActiveWorkspace.shared.session, let id = session.active?.id { session.close(id) }
            }
            .disabled(noWorkspace)
        }

        CommandGroup(after: .sidebar) {
            Divider()
            Button("Data") { table?.mode = .data }
                .keyboardShortcut("1", modifiers: [.command, .option])
                .disabled(noWorkspace)
            Button("Structure") { table?.mode = .structure }
                .keyboardShortcut("2", modifiers: [.command, .option])
                .disabled(noWorkspace)
            // ⌘F filters rows in a table tab and opens the find bar in the SQL editor.
            Button("Find / Filter Rows") {
                if let redis {
                    redis.patternFocusRequest += 1
                } else if let table {
                    table.focusFilter()
                } else {
                    let sender = NSMenuItem()
                    sender.tag = NSTextFinder.Action.showFindInterface.rawValue
                    NSApp.sendAction(#selector(NSResponder.performTextFinderAction(_:)), to: nil, from: sender)
                }
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(noWorkspace)
            Button("Relationship Diagram") { workspace?.openDiagram() }
                .keyboardShortcut("3", modifiers: [.command, .option])
                .disabled(noWorkspace || workspace?.config.kind.supportsDiagram == false)
            Button("Server Metrics") {
                if let redis { redis.mode = .metrics } else { workspace?.openMetrics() }
            }
            .keyboardShortcut("4", modifiers: [.command, .option])
            .disabled(noWorkspace)
            Button("Filter Tables") { workspace?.sidebarFilterFocusRequest += 1 }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(noWorkspace)
            Button("Console Log") { workspace?.showConsole.toggle() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(noWorkspace)
            Button("AI Chat") { workspace?.toggleRightPanel(.ai) }
                .keyboardShortcut("a", modifiers: [.command, .option])
                .disabled(noWorkspace)
            Button("Row Details") { workspace?.toggleRightPanel(.rowDetails) }
                .keyboardShortcut("0", modifiers: [.command, .option])
                .disabled(noWorkspace)
            Divider()
            Button("Show Next Tab") { workspace?.selectAdjacentTab(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(noWorkspace)
            Button("Show Previous Tab") { workspace?.selectAdjacentTab(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(noWorkspace)
            Menu("Go to Tab") {
                ForEach(1...9, id: \.self) { number in
                    Button(number == 9 ? "Last Tab" : "Tab \(number)") { workspace?.selectTab(number: number) }
                        .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
                }
            }
            .disabled(noWorkspace)
        }

        CommandMenu("Database") {
            Button("Refresh") {
                Task {
                    await workspace?.refresh()
                    await redis?.refresh()
                }
            }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(noWorkspace)
            Divider()
            Button("Commit Changes") {
                if let table, table.hasChanges { Task { await table.commit() } } else { NSSound.beep() }
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(noWorkspace)
            Button("Preview Changes…") { table?.showPreviewRequest += 1 }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(noWorkspace)
            Button("Discard Changes") { table?.discardChanges() }
                .keyboardShortcut("z", modifiers: [.command, .option])
                .disabled(noWorkspace)
            Divider()
            Button("Add Row") { table?.mode = .data; table?.addRow() }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(noWorkspace)
            Button("Duplicate Row") {
                if let rows = workspace?.inspectedRows, !rows.isEmpty { table?.duplicateRows(rows) }
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(noWorkspace)
            Divider()
            Button("Previous Page") {
                if let table, !table.hasChanges { Task { await table.previousPage() } }
            }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(noWorkspace)
            Button("Next Page") {
                if let table, !table.hasChanges { Task { await table.nextPage() } }
            }
            .keyboardShortcut("]", modifiers: .command)
            .disabled(noWorkspace)
            Divider()
            Button("Reconnect") {
                Task {
                    await workspace?.reconnect()
                    await redis?.reconnect()
                }
            }
                .disabled(noWorkspace)
        }

        CommandMenu("Query") {
            Button("Run Current Statement") {
                if let query, !query.running { query.runRequest = (false, query.runRequest.id + 1) }
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(noWorkspace)
            Button("Run All") {
                if let query, !query.running { query.runRequest = (true, query.runRequest.id + 1) }
            }
            .keyboardShortcut(.return, modifiers: [.command, .shift])
            .disabled(noWorkspace)
            Divider()
            Button("Beautify SQL") { query?.beautifyRequest += 1 }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(noWorkspace)
            Button("Ask AI…") { query?.askAIRequest += 1 }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(noWorkspace)
        }

        CommandGroup(replacing: .appInfo) {
            Button("About Tabula") { AboutPanel.show() }
            Button("Check for Updates…") {
                WindowRequests.request(WindowID.update)
                openWindow(id: WindowID.update)
                Task { await Updater.shared.check(userInitiated: true) }
            }
        }

        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") {
                WindowRequests.request(WindowID.shortcuts)
                openWindow(id: WindowID.shortcuts)
            }
                .keyboardShortcut("/", modifiers: [.command, .shift])
        }
    }
}

private struct ClosesUnlessRequested: ViewModifier {
    let id: String
    @Environment(\.dismissWindow) private var dismissWindow

    func body(content: Content) -> some View {
        content.onAppear {
            if !WindowRequests.consume(id) { DispatchQueue.main.async { dismissWindow(id: id) } }
        }
    }
}

extension View {
    func closesUnlessRequested(_ id: String) -> some View { modifier(ClosesUnlessRequested(id: id)) }
}
