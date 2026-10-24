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
        DebugHooks.startKeyScript()
        #endif
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
        .defaultSize(width: 760, height: 480)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        WindowGroup("Workspace", id: WindowID.workspace, for: UUID.self) { $connectionID in
            WorkspaceWindow(connectionID: connectionID)
                .environment(appState)
        }
        .defaultSize(width: 1280, height: 800)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { WorkspaceCommands() }

        Window("Keyboard Shortcuts", id: WindowID.shortcuts) {
            ShortcutsView()
        }
        .defaultSize(width: 760, height: 620)
    }
}

enum WindowID {
    static let connections = "connections"
    static let workspace = "workspace"
    static let shortcuts = "shortcuts"
}

/// The workspace of the key window. Menu commands use this instead of SwiftUI's focused values,
/// which drop to nil whenever an AppKit view (grid cell editor, SQL editor) holds keyboard focus.
@MainActor @Observable
final class ActiveWorkspace {
    static let shared = ActiveWorkspace()
    private(set) weak var model: WorkspaceModel?

    fileprivate func update(_ model: WorkspaceModel?) {
        if self.model !== model { self.model = model }
    }
}

/// Maps windows to their workspace so menus and app-wide keys (⌃Tab) reach the right one.
@MainActor
enum WorkspaceRegistry {
    private static var models: [Int: WeakWorkspace] = [:]
    private static var observer: Any?

    private struct WeakWorkspace { weak var model: WorkspaceModel? }

    static func register(_ model: WorkspaceModel, window: NSWindow) {
        models = models.filter { $0.value.model != nil }
        models[window.windowNumber] = WeakWorkspace(model: model)
        if window.isKeyWindow { ActiveWorkspace.shared.update(model) }
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
                let number = (note.object as? NSWindow)?.windowNumber
                MainActor.assumeIsolated {
                    // Non-workspace windows (Connections, Shortcuts) clear it, so workspace commands disable.
                    ActiveWorkspace.shared.update(number.flatMap { models[$0]?.model })
                }
            }
        }
    }

    static var key: WorkspaceModel? { ActiveWorkspace.shared.model }

    #if DEBUG
    static func makeActiveForTesting(_ window: NSWindow) {
        ActiveWorkspace.shared.update(models[window.windowNumber]?.model)
    }
    #endif

    /// Shortcuts that menus can't express (⌃Tab / ⌃⇧Tab). Returns true when handled.
    static func handle(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard event.keyCode == 48, flags == [.control] || flags == [.control, .shift], let workspace = key else { return false }
        workspace.selectAdjacentTab(flags.contains(.shift) ? -1 : 1)
        return true
    }
}

struct WorkspaceCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    private var workspace: WorkspaceModel? { ActiveWorkspace.shared.model }

    private var table: TableTabModel? { workspace?.selectedTableTab }

    private var query: QueryTabModel? {
        if case .query(let model) = workspace?.selectedTab { return model }
        return nil
    }

    // SwiftUI doesn't re-evaluate menus when model state changes, so items only disable when there is
    // no workspace; each action checks its own preconditions when it runs.
    var body: some Commands {
        let noWorkspace = workspace == nil

        CommandGroup(after: .newItem) {
            Button("New Query Tab") { workspace?.newQueryTab() }
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
                if let table {
                    table.focusFilter()
                } else {
                    let sender = NSMenuItem()
                    sender.tag = NSTextFinder.Action.showFindInterface.rawValue
                    NSApp.sendAction(#selector(NSResponder.performTextFinderAction(_:)), to: nil, from: sender)
                }
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(noWorkspace)
            Button("Filter Tables") { workspace?.sidebarFilterFocusRequest += 1 }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(noWorkspace)
            Button("Row Details") { workspace?.showInspector.toggle() }
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
            Button("Refresh") { Task { await workspace?.refresh() } }
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
            Button("Reconnect") { Task { await workspace?.reconnect() } }
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
        }

        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") { openWindow(id: WindowID.shortcuts) }
                .keyboardShortcut("/", modifiers: [.command, .shift])
        }
    }
}

struct WorkspaceFocusKey: FocusedValueKey {
    typealias Value = WorkspaceModel
}

extension FocusedValues {
    var workspace: WorkspaceModel? {
        get { self[WorkspaceFocusKey.self] }
        set { self[WorkspaceFocusKey.self] = newValue }
    }
}
