#if DEBUG
import AppKit
import Foundation
import TabulaCore

/// Debug-only automation for visual checks, driven by environment variables:
/// - TABULA_DEBUG_OPEN: connection UUID to open at launch
/// - TABULA_DEBUG_TABLE: table name to open once connected; TABULA_DEBUG_DOCUMENT: a row to open in the document editor (MongoDB);
///   TABULA_DEBUG_PAGE_SIZE: rows per page for that table
/// - TABULA_DEBUG_QUERY: SQL to run in the first query tab; TABULA_DEBUG_QUERY_THEN: more SQL to run a moment later
/// - TABULA_DEBUG_SNAPSHOT: directory that receives PNG snapshots of every window
/// - TABULA_DEBUG_RECORD: directory that receives the workspace window as numbered JPEG frames
///   (TABULA_DEBUG_RECORD_FPS a second, default 10), e.g. for the demo video (scripts/render-demo.sh)
/// - TABULA_DEBUG_AI_PROVIDER: turn AI on with this provider; TABULA_DEBUG_ASK (+ _ASK_SUBMIT): fill the Ask AI bar
/// - TABULA_DEBUG_AI_ALLOW_PRODUCTION: allow AI on Production connections; TABULA_DEBUG_APPROVE: answer the chat's query approval
/// - TABULA_DEBUG_CHAT_DEMO (a question) / TABULA_DEBUG_ASK_DEMO: play a made-up streamed answer with reasoning
@MainActor
enum DebugHooks {
    private static let environment = ProcessInfo.processInfo.environment

    static var showShortcuts: Bool { environment["TABULA_DEBUG_SHORTCUTS"] != nil }
    static var showSettings: Bool { environment["TABULA_DEBUG_SETTINGS"] != nil }
    static var showAbout: Bool { environment["TABULA_DEBUG_ABOUT"] != nil }

    static var connectionToOpen: UUID? { connectionsToOpen.first }
    /// TABULA_DEBUG_EDIT: a connection UUID whose editor opens on the welcome window.
    static var connectionToEdit: UUID? { environment["TABULA_DEBUG_EDIT"].flatMap(UUID.init(uuidString:)) }
    /// TABULA_DEBUG_FORM_HOST: text entered in that editor's Host field, as if pasted (e.g. a connection URL).
    static var formHost: String? { environment["TABULA_DEBUG_FORM_HOST"] }

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
            for table in model.tables { model.open(table) }
            for _ in 0..<count { model.newQueryTab() }
        }
        if let name = environment["TABULA_DEBUG_ROUTINE"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                if let routine = model.routines.first(where: { $0.name == name }) { model.openRoutine(routine) }
            }
        }
        if environment["TABULA_DEBUG_ASK_DEMO"] != nil, case .query(let query) = model.tabs.first {
            query.assistant.prompt = "top 5 customers by total order value"
            query.assistant.simulate(thinking: "Orders hold each order's total, so sum it per customer and join customers for the name.",
                                     answer: "SELECT c.id, c.name, SUM(o.total) AS spent FROM public.customers c JOIN public.orders o ON o.customer_id = c.id GROUP BY c.id, c.name ORDER BY spent DESC LIMIT 5;",
                                     piece: .milliseconds(200)) { query.insertRequest = ($0, UUID()) }
        }
        if let question = environment["TABULA_DEBUG_CHAT_DEMO"] {
            model.rightPanel = .ai
            model.showInspector = true
            model.chat.simulate(question: question,
                                thinking: "The user wants the customers who spent the most. Orders hold the total per order, so sum orders.total per customer, join customers for the name, sort descending and keep five.",
                                answer: "Sum each customer's orders and keep the top five:\n\n```sql\nSELECT c.id, c.name, SUM(o.total) AS spent\nFROM public.customers c\nJOIN public.orders o ON o.customer_id = c.id\nGROUP BY c.id, c.name\nORDER BY spent DESC\nLIMIT 5;\n```",
                                piece: .milliseconds(150))
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
                    MainActor.assumeIsolated {
                        guard let step = model.chat.messages.last(where: { $0.tool?.status == .awaitingApproval }) else { return }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { model.chat.answer(step.id, allow: allow == "1") }
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

    /// TABULA_DEBUG_KEYS: ";"-separated key presses replayed through the normal event path, e.g.
    /// "wait:2000;cmd+f;type:Nội;return;esc;down;right;return;type:x;tab". Also logs the menu bar once.
    private static let typingInterval = 0.05

    static func startKeyScript() {
        dumpMenus()
        guard let script = environment["TABULA_DEBUG_KEYS"] else { return }
        var delay = 3.0
        for token in script.components(separatedBy: ";") where !token.isEmpty {
            if token.hasPrefix("wait:") {
                delay += (Double(token.dropFirst(5)) ?? 0) / 1000
                continue
            }
            // slow:<text> types one character at a time, as a person would (for recordings).
            if token.hasPrefix("slow:") {
                for (index, character) in token.dropFirst(5).enumerated() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay + Double(index) * typingInterval) {
                        guard let window = targetWindow else { return }
                        for event in events(for: "type:\(character)", window: window) { NSApp.postEvent(event, atStart: false) }
                    }
                }
                delay += Double(token.count - 5) * typingInterval + 0.3
                continue
            }
            if token.hasPrefix("snap:") {
                let name = String(token.dropFirst(5))
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { snapshotKeyWindow(name) }
                delay += 0.3
                continue
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                // Real dispatch path (NSApp → monitor → key equivalents → first responder) on the key window.
                guard let window = targetWindow else { print("KEY", token, "→ no window"); return }
                if !window.isKeyWindow {
                    NSApp.activate(ignoringOtherApps: true)
                    window.makeKeyAndOrderFront(nil)
                }
                // Launched from a terminal the app may not be allowed to become active, so its window never
                // turns key; route menu commands to it anyway.
                WorkspaceRegistry.makeActiveForTesting(window)
                print("KEY", token, "→ first responder:", String(describing: window.firstResponder.map { type(of: $0) }))
                let events = events(for: token, window: window)
                if let down = events.first, down.modifierFlags.contains(.command) {
                    // AppKit's key-equivalent order (window, then main menu), which an inactive app skips.
                    NSApp.mainMenu?.update()
                    let handled = window.performKeyEquivalent(with: down) || NSApp.mainMenu?.performKeyEquivalent(with: down) == true
                    print("KEY", token, handled ? "→ handled" : "→ not handled")
                } else {
                    for event in events { NSApp.postEvent(event, atStart: false) }
                }
            }
            delay += 0.6
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 1) {
            print("KEYS DONE")
            fflush(stdout)
        }
    }

    private static var targetWindow: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue.hasPrefix("workspace") == true }
            ?? NSApp.windows.first { $0.isVisible && $0.title != "Tabula" && $0.title != "Keyboard Shortcuts" && $0.contentView != nil && $0.frame.width > 900 }
    }

    private static let namedKeys: [String: (UInt16, String)] = [
        "return": (36, "\r"), "tab": (48, "\t"), "space": (49, " "), "delete": (51, "\u{7F}"), "esc": (53, "\u{1B}"),
        "left": (123, "\u{F702}"), "right": (124, "\u{F703}"), "down": (125, "\u{F701}"), "up": (126, "\u{F700}"), "f2": (120, "\u{F705}"),
    ]

    private static let letterCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29, "]": 30, "o": 31,
        "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, "/": 44,
    ]

    private static func events(for token: String, window: NSWindow) -> [NSEvent] {
        if token.hasPrefix("type:") {
            return token.dropFirst(5).flatMap { character in
                [true, false].compactMap { down in
                    key(down: down, code: letterCodes[Character(character.lowercased())] ?? 0, characters: String(character),
                        ignoring: String(character).lowercased(), flags: character.isUppercase ? [.shift] : [], window: window)
                }
            }
        }
        var parts = token.lowercased().components(separatedBy: "+")
        let name = parts.removeLast()
        var flags: NSEvent.ModifierFlags = []
        for part in parts {
            switch part {
            case "cmd": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "opt": flags.insert(.option)
            case "ctrl": flags.insert(.control)
            default: break
            }
        }
        let (code, characters): (UInt16, String) = namedKeys[name] ?? (letterCodes[Character(name)] ?? 0, name)
        // Like a real keyboard: Shift changes `characters` but not `charactersIgnoringModifiers`.
        let typed = flags.contains(.shift) ? characters.uppercased() : characters
        return [true, false].compactMap { key(down: $0, code: code, characters: typed, ignoring: characters, flags: flags, window: window) }
    }

    private static func key(down: Bool, code: UInt16, characters: String, ignoring: String, flags: NSEvent.ModifierFlags, window: NSWindow) -> NSEvent? {
        NSEvent.keyEvent(with: down ? .keyDown : .keyUp, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: window.windowNumber, context: nil, characters: characters,
                         charactersIgnoringModifiers: ignoring, isARepeat: false, keyCode: code)
    }

    /// Logs every menu item with its shortcut, to spot conflicts.
    private static func dumpMenus() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            func walk(_ menu: NSMenu, _ path: String) {
                for item in menu.items where !item.isSeparatorItem {
                    let key = item.keyEquivalent.isEmpty ? "" : " [\(item.keyEquivalentModifierMask.rawValue >> 17):\(item.keyEquivalent.debugDescription)]"
                    print("MENU", path + item.title + key)
                    if let submenu = item.submenu { walk(submenu, path + item.title + " > ") }
                }
            }
            if let main = NSApp.mainMenu { walk(main, "") }
            fflush(stdout)
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
              let screen = NSScreen.screens.first(where: { $0.backingScaleFactor >= 2 }) else { return }
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

    /// Records the workspace window as frame-00001.jpg, frame-00002.jpg… at a steady rate.
    static func startRecording() {
        guard let directory = environment["TABULA_DEBUG_RECORD"] else { return }
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let fps = environment["TABULA_DEBUG_RECORD_FPS"].flatMap(Double.init) ?? 10
        var frame = 0
        Timer.scheduledTimer(withTimeInterval: 1 / fps, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard let window = targetWindow, let rep = windowServerImage(window) ?? cachedImage(window),
                      let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85]) else { return }
                frame += 1
                let name = String(format: "frame-%05d.jpg", frame)
                try? data.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
            }
        }
    }

    static func startSnapshots() {
        guard let directory = environment["TABULA_DEBUG_SNAPSHOT"] else { return }
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        guard environment["TABULA_DEBUG_KEYS"] == nil else { return }
        Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in
            MainActor.assumeIsolated {
                for window in NSApp.windows where window.isVisible {
                    guard let rep = windowServerImage(window) ?? cachedImage(window) else { continue }
                    let name = window.title.isEmpty ? "window-\(window.windowNumber)" : window.title
                    let safe = name.replacingOccurrences(of: "/", with: "-")
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(safe).png"))
                }
            }
        }
    }

    private static func snapshotKeyWindow(_ name: String) {
        guard let directory = environment["TABULA_DEBUG_SNAPSHOT"], let window = targetWindow ?? NSApp.keyWindow,
              let rep = windowServerImage(window) ?? cachedImage(window) else { return }
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: directory).appendingPathComponent("step-\(name).png"))
        print("SNAP", name)
    }

    private typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?

    /// Window-server capture includes vibrancy; an app may capture its own windows without extra permission.
    /// The symbol is looked up at runtime because newer SDKs mark it unavailable.
    private static func windowServerImage(_ window: NSWindow) -> NSBitmapImageRep? {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let create = unsafeBitCast(symbol, to: CreateImage.self)
        // kCGWindowListOptionIncludingWindow = 1 << 3, kCGWindowImageBoundsIgnoreFraming = 1 << 0
        guard let image = create(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0)?.takeRetainedValue() else { return nil }
        return NSBitmapImageRep(cgImage: image)
    }

    private static func cachedImage(_ window: NSWindow) -> NSBitmapImageRep? {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }
}
#endif
