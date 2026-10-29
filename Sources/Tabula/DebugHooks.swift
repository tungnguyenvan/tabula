#if DEBUG
import AppKit
import Foundation
import TabulaSQL

/// Debug-only automation for visual checks, driven by environment variables:
/// - TABULA_DEBUG_OPEN: connection UUID to open at launch
/// - TABULA_DEBUG_TABLE: table name to open once connected; TABULA_DEBUG_DOCUMENT: a row to open in the document editor (MongoDB);
///   TABULA_DEBUG_PAGE_SIZE: rows per page for that table
/// - TABULA_DEBUG_QUERY: SQL to run in the first query tab; TABULA_DEBUG_QUERY_THEN: more SQL to run a moment later
/// - TABULA_DEBUG_SNAPSHOT: directory that receives PNG snapshots of every window
/// - TABULA_DEBUG_KEYS: scripted input, e.g. "wait:500;slow:SELECT 1;cmd+return;click:0.2,0.12" (see startKeyScript;
///   also paste:<text>, open:<path>, alert:<button>, call:save|saveas|close|reopen|dump|restore|dumpstart, snap:<name>)
/// - TABULA_DEBUG_RECORD: directory that receives the workspace window as numbered JPEG frames
///   (TABULA_DEBUG_RECORD_FPS a second, default 30), e.g. for the demo video (scripts/render-demo.sh)
/// - TABULA_DEBUG_AI_PROVIDER: turn AI on with this provider; TABULA_DEBUG_ASK (+ _ASK_SUBMIT): fill the Ask AI bar
/// - TABULA_DEBUG_AI_ALLOW_PRODUCTION: allow AI on Production connections; TABULA_DEBUG_APPROVE: answer the chat's query approval
/// - TABULA_DEBUG_TARGET=connections: drive and record the Connections window instead of a workspace
/// - TABULA_DEBUG_FILES: .sql paths (comma-separated) handed over at launch, as Finder would open them
/// - TABULA_DEBUG_CHAT_DEMO (a question) / TABULA_DEBUG_ASK_DEMO: play a made-up streamed answer with reasoning
@MainActor
enum DebugHooks {
    static let environment = ProcessInfo.processInfo.environment

    static var showShortcuts: Bool { environment["TABULA_DEBUG_SHORTCUTS"] != nil }
    static var showSettings: Bool { environment["TABULA_DEBUG_SETTINGS"] != nil }
    static var showAbout: Bool { environment["TABULA_DEBUG_ABOUT"] != nil }

    static var connectionToOpen: UUID? { connectionsToOpen.first }
    /// TABULA_DEBUG_EDIT: a connection UUID whose editor opens on the welcome window.
    static var connectionToEdit: UUID? { environment["TABULA_DEBUG_EDIT"].flatMap(UUID.init(uuidString:)) }
    /// TABULA_DEBUG_FORM_HOST: text entered in that editor's Host field, as if pasted (e.g. a connection URL).
    static var formHost: String? { environment["TABULA_DEBUG_FORM_HOST"] }
    /// TABULA_DEBUG_CONNECTION_STRING: open New from Connection String with this text, as if pasted into the list;
    /// TABULA_DEBUG_CONNECTION_STRING_CONTINUE: then press Continue.
    static var connectionString: String? { environment["TABULA_DEBUG_CONNECTION_STRING"] }
    static var continuesConnectionString: Bool { environment["TABULA_DEBUG_CONNECTION_STRING_CONTINUE"] != nil }
    /// TABULA_DEBUG_VERSION: the version the Connections window shows (a debug build has none), e.g. for recordings.
    static var version: String? { environment["TABULA_DEBUG_VERSION"] }
    /// TABULA_DEBUG_INSPECTOR_WIDTH: fix the right panel width for recordings, without changing release defaults.
    static var inspectorWidth: Double? {
        environment["TABULA_DEBUG_INSPECTOR_WIDTH"].flatMap(Double.init)
            .flatMap {
                $0.isFinite && $0 >= Double(Layout.Inspector.minWidth) && $0 <= Double(Layout.Inspector.maxWidth)
                    ? $0 : nil
            }
    }

    /// TABULA_DEBUG_OPEN may list several ids separated by commas.
    static var connectionsToOpen: [UUID] {
        (environment["TABULA_DEBUG_OPEN"] ?? "").split(separator: ",").compactMap { UUID(uuidString: String($0)) }
    }

    private static var switchedDatabase = false

    static func workspaceConnected(_ model: WorkspaceModel) {
        if environment["TABULA_DEBUG_PALETTE"] != nil { model.showPalette = true }
        if environment["TABULA_DEBUG_CONSOLE"] != nil { model.showConsole = true }
        // TABULA_DEBUG_DATABASE: move the window to this database once connected (PostgreSQL).
        if let database = environment["TABULA_DEBUG_DATABASE"], !switchedDatabase {
            switchedDatabase = true
            Task { await model.openDatabase(database) }
        }
        checkMinimumWidth()
        if environment["TABULA_DEBUG_DIAGRAM"] != nil { model.openDiagram() }
        if environment["TABULA_DEBUG_METRICS"] != nil { model.openMetrics() }
        if let count = environment["TABULA_DEBUG_TABS"].flatMap(Int.init) {
            for table in model.tables {
                model.open(table)
            }
            for _ in 0..<count {
                model.newQueryTab()
            }
        }
        if let name = environment["TABULA_DEBUG_ROUTINE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if let routine = model.routines.first(where: { $0.name == name }) { model.openRoutine(routine) }
            }
        }
        if environment["TABULA_DEBUG_ASK_DEMO"] != nil, case .query(let query) = model.tabs.first {
            query.assistant.prompt = "top 5 customers by total order value"
            query.assistant.simulate(
                thinking: "Orders hold each order's total, so sum it per customer and join customers for the name.",
                answer:
                    "SELECT c.id, c.name, SUM(o.total) AS spent FROM public.customers c JOIN public.orders o ON o.customer_id = c.id GROUP BY c.id, c.name ORDER BY spent DESC LIMIT 5;",
                piece: .milliseconds(200)
            ) { query.insertRequest = ($0, UUID()) }
        }
        if let question = environment["TABULA_DEBUG_CHAT_DEMO"] {
            model.rightPanel = .ai
            model.showInspector = true
            model.chat.simulate(
                question: question,
                thinking:
                    "The user wants the customers who spent the most. Orders hold the total per order, so sum orders.total per customer, join customers for the name, sort descending and keep five.",
                answer:
                    "Sum each customer's orders and keep the top five:\n\n```sql\nSELECT c.id, c.name, SUM(o.total) AS spent\nFROM public.customers c\nJOIN public.orders o ON o.customer_id = c.id\nGROUP BY c.id, c.name\nORDER BY spent DESC\nLIMIT 5;\n```",
                piece: .milliseconds(150)
            )
        }
        if let question = environment["TABULA_DEBUG_CHAT"] {
            model.rightPanel = .ai
            model.showInspector = true
            model.chat.input = question
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let editor: String? = if case .query(let query) = model.selectedTab { query.sql } else { nil }
                model.chat.send(workspace: model, editorSQL: editor)
            }
            // TABULA_DEBUG_APPROVE=1 (or 0): answer the first Production query a few seconds after it asks,
            // so a snapshot can show the question.
            if let allow = environment["TABULA_DEBUG_APPROVE"] {
                Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { timer in
                    let answered = MainActor.assumeIsolated { () -> Bool in
                        guard let step = model.chat.messages.last(where: { $0.tool?.status == .awaitingApproval })
                        else { return false }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                            model.chat.answer(step.id, allow: allow == "1")
                        }
                        return true
                    }
                    if answered {
                        timer.invalidate()
                    }
                }
            }
        }
        if let prompt = environment["TABULA_DEBUG_ASK"], case .query(let query) = model.tabs.first {
            query.assistant.showPrompt = true
            query.assistant.prompt = prompt
            if environment["TABULA_DEBUG_ASK_SUBMIT"] != nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { query.assistant.submitRequest += 1 }
            }
        }
        if let sql = environment["TABULA_DEBUG_QUERY"], case .query(let query) = model.tabs.first {
            query.sql = sql
            Task { await query.run() }
            // A second query a moment later, e.g. to check how the grid moves to a different result.
            if let next = environment["TABULA_DEBUG_QUERY_THEN"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    query.sql = next
                    Task { await query.run() }
                }
            }
        }
        if let name = environment["TABULA_DEBUG_TABLE"], let table = model.tables.first(where: { $0.name == name }) {
            model.open(table, mode: environment["TABULA_DEBUG_MODE"] == "structure" ? .structure : .data)
            if let tab = model.selectedTableTab, let filter = environment["TABULA_DEBUG_FILTER"] {
                // "column|operator|value", e.g. "city|contains|Nội"; TABULA_DEBUG_FILTER_DELAY: seconds before it applies
                let parts = filter.components(separatedBy: "|")
                let delay = environment["TABULA_DEBUG_FILTER_DELAY"].flatMap(Double.init) ?? 1
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    if parts.count == 3, let op = FilterRule.Operator(rawValue: parts[1]) {
                        tab.filterRules = [FilterRule(column: parts[0], op: op, value: parts[2])]
                        tab.showFilterBar = true
                        Task { await tab.applyFilter() }
                    }
                }
            }
            if let size = environment["TABULA_DEBUG_PAGE_SIZE"].flatMap(Int.init) {
                // The tab exists once the open has gone through, as for the filter above.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    guard let tab = model.selectedTableTab else { return }
                    tab.pageSize = size
                    Task { await tab.reload() }
                }
            }
            if let row = environment["TABULA_DEBUG_DOCUMENT"].flatMap(Int.init), let tab = model.selectedTableTab {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { tab.documentEditRequest = row }
            }
            if let row = environment["TABULA_DEBUG_INSPECT"].flatMap(Int.init) {
                model.showInspector = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { model.inspectedRows = [row] }
            }
        }
    }

    static func redisConnected(_ model: RedisWorkspaceModel) {
        checkMinimumWidth()
        if let key = environment["TABULA_DEBUG_KEY"], let entry = model.keys.first(where: { $0.key.display == key }) {
            model.select(entry.key)
        }
        if environment["TABULA_DEBUG_METRICS"] != nil { model.mode = .metrics }
        if let commands = environment["TABULA_DEBUG_REDIS_CONSOLE"] {
            model.mode = .console
            Task {
                for command in commands.components(separatedBy: ";;") {
                    model.console.input = command
                    await model.console.run()
                }
            }
        }
    }

    /// TABULA_DEBUG_WIDTH (and optionally TABULA_DEBUG_HEIGHT): resize the window, e.g. to check that nothing
    /// forces a minimum width or to take screenshots at a set size; logs the result.
    /// TABULA_DEBUG_WIDTH / _HEIGHT for the Connections window (e.g. to show a whole connection form).
    static func resizeConnectionsWindow() {
        guard let width = environment["TABULA_DEBUG_WIDTH"].flatMap(Double.init) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.sheetParent == nil }) else { return }
            let height = environment["TABULA_DEBUG_HEIGHT"].flatMap(Double.init) ?? window.contentLayoutRect.height
            window.setContentSize(NSSize(width: width, height: height))
            moveToRetinaScreen(window)
        }
    }

    /// Screenshots for the README are taken at 2x: with a sized window, move it to a Retina screen if one is attached.
    private static func moveToRetinaScreen(_ window: NSWindow) {
        guard (window.screen?.backingScaleFactor ?? 1) < 2,
            let screen = NSScreen.screens.first(where: { $0.backingScaleFactor >= 2 })
        else { return }
        let visible = screen.visibleFrame
        window.setFrameTopLeftPoint(NSPoint(x: visible.minX, y: visible.maxY))
    }

    private static func checkMinimumWidth() {
        guard let width = environment["TABULA_DEBUG_WIDTH"].flatMap(Double.init) else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            guard let window = targetWindow else { return }
            let height = environment["TABULA_DEBUG_HEIGHT"].flatMap(Double.init) ?? window.contentLayoutRect.height
            window.setContentSize(NSSize(width: width, height: height))
            moveToRetinaScreen(window)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                print("WIDTH requested", width, "got", window.frame.width, "min", window.minSize.width)
                fflush(stdout)
            }
        }
    }

}
#endif
