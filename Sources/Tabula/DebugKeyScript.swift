#if DEBUG
import AppKit
import Foundation
import TabulaSQL

/// TABULA_DEBUG_KEYS: scripted key presses, clicks and menu commands, replayed through the normal event path.
extension DebugHooks {
    /// TABULA_DEBUG_KEYS: ";"-separated key presses replayed through the normal event path, e.g.
    /// "wait:2000;cmd+f;type:Nội;return;esc;down;right;return;type:x;tab". Also logs the menu bar once.
    private static let typingInterval = 0.05

    private static func firstView<T: NSView>(of type: T.Type, in view: NSView?) -> T? {
        guard let view, !view.isHidden else { return nil }
        if let match = view as? T {
            return match
        }
        for subview in view.subviews { if let match = firstView(of: type, in: subview) { return match } }
        return nil
    }

    static func startKeyScript() {
        dumpMenus()
        if let files = environment["TABULA_DEBUG_FILES"] {
            NSApp.delegate?.application?(
                NSApp,
                open: files.split(separator: ",").map { URL(fileURLWithPath: String($0)) }
            )
        }
        if environment["TABULA_DEBUG_TARGET"] == "connections" { resizeConnectionsWindow() }
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
                        if !window.isKeyWindow {
                            NSApp.activate(ignoringOtherApps: true)
                            window.makeKeyAndOrderFront(nil)
                        }
                        WorkspaceRegistry.makeActiveForTesting(window)
                        // A sheet takes the keys while it is open.
                        let receiver = window.attachedSheet ?? window
                        // Typing goes to the SQL editor when nothing that takes text has focus.
                        if !(receiver.firstResponder is NSTextView),
                            let editor = firstView(of: SQLTextView.self, in: receiver.contentView)
                        {
                            receiver.makeFirstResponder(editor)
                        }
                        for event in events(for: "type:\(character)", window: receiver) {
                            NSApp.postEvent(event, atStart: false)
                        }
                        logEvent(character == " " ? "space" : "key")
                    }
                }
                delay += Double(token.count - 5) * typingInterval + 0.3
                continue
            }
            // click:x,y / dclick:x,y / move:x,y: the mouse at a point of the window, given as fractions of its width and
            // height from the top left. The events go through the window as real ones would.
            if let kind = ["click", "dclick", "move"].first(where: { token.hasPrefix($0 + ":") }) {
                let numbers = token.dropFirst(kind.count + 1).split(separator: ",").compactMap { Double($0) }
                guard numbers.count == 2 else { continue }
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    guard let window = targetWindow else { return }
                    if !window.isKeyWindow {
                        NSApp.activate(ignoringOtherApps: true)
                        window.makeKeyAndOrderFront(nil)
                    }
                    WorkspaceRegistry.makeActiveForTesting(window)
                    // Fractions of the whole window, as recorded frames show it (title bar and toolbar included).
                    var point = NSPoint(x: numbers[0] * window.frame.width, y: (1 - numbers[1]) * window.frame.height)
                    // A point on a sheet goes to the sheet, in its own coordinates.
                    var receiver = window
                    if let sheet = window.attachedSheet {
                        let onScreen = NSPoint(x: window.frame.minX + point.x, y: window.frame.minY + point.y)
                        if sheet.frame.contains(onScreen) {
                            receiver = sheet
                            point = NSPoint(x: onScreen.x - sheet.frame.minX, y: onScreen.y - sheet.frame.minY)
                        }
                    }
                    func post(_ type: NSEvent.EventType, clicks: Int) {
                        guard
                            let event = NSEvent.mouseEvent(
                                with: type,
                                location: point,
                                modifierFlags: [],
                                timestamp: ProcessInfo.processInfo.systemUptime,
                                windowNumber: receiver.windowNumber,
                                context: nil,
                                eventNumber: 0,
                                clickCount: clicks,
                                pressure: type == .leftMouseDown ? 1 : 0
                            )
                        else { return }
                        NSApp.postEvent(event, atStart: false)
                    }
                    post(.mouseMoved, clicks: 0)
                    if kind != "move" {
                        post(.leftMouseDown, clicks: 1)
                        post(.leftMouseUp, clicks: 1)
                    }
                    if kind == "dclick" {
                        post(.leftMouseDown, clicks: 2)
                        post(.leftMouseUp, clicks: 2)
                    }
                    logEvent(kind, x: numbers[0], y: numbers[1])
                }
                delay += 0.6
                continue
            }
            // paste:<text> puts the text into the focused field at once, as Edit > Paste would (logged as a key, ⌘V).
            if token.hasPrefix("paste:") {
                let text = String(token.dropFirst(6))
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    guard let window = targetWindow else { return }
                    let receiver = window.attachedSheet ?? window
                    guard let field = receiver.firstResponder as? NSTextView else {
                        return print("PASTE no text field")
                    }
                    field.insertText(text, replacementRange: field.selectedRange())
                    logEvent("keycap")
                }
                delay += 0.6
                continue
            }
            // open:<path> hands a file over as Finder would; alert:<button> answers the alert on screen.
            if token.hasPrefix("open:") {
                let url = URL(fileURLWithPath: String(token.dropFirst(5)))
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    NSApp.delegate?.application?(NSApp, open: [url])
                }
                delay += 0.6
                continue
            }
            if token.hasPrefix("alert:") {
                let title = String(token.dropFirst(6))
                // A run-loop timer, since the main queue is held by the step that opened the alert.
                let timer = Timer(timeInterval: delay, repeats: false) { _ in
                    MainActor.assumeIsolated {
                        guard let alert = NSApp.modalWindow, let content = alert.contentView else {
                            return print("ALERT none")
                        }
                        func buttons(_ view: NSView) -> [NSButton] {
                            ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap(buttons)
                        }
                        let found = buttons(content)
                        print("ALERT", found.map(\.title).filter { !$0.isEmpty })
                        found.first { $0.title == title }?.performClick(nil)
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                delay += 0.6
                continue
            }
            // save / saveas / close / reopen / nextconn / closeconn / ai / sidebar: what File > Save, Save As…, Close Tab,
            // Reopen Closed Tab, Next Connection, Close Connection, AI Chat and View > Hide Sidebar do. SwiftUI doesn't
            // refresh the menus of an app that isn't active, as one launched from a terminal may not be.
            if token.hasPrefix("call:") {
                let name = token.dropFirst(5)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    print("CALL", name)
                    if let window = targetWindow {
                        WorkspaceRegistry.makeActiveForTesting(window)
                    }
                    // Connections switch in any workspace, Redis included.
                    if name == "closewindow" {
                        targetWindow?.performClose(nil)
                        return
                    }
                    if name == "quit" {
                        NSApp.terminate(nil)
                        return
                    }
                    if name == "nextconn" {
                        return ActiveWorkspace.shared.session?.selectAdjacent(1) ?? print("CALL no session")
                    }
                    if name == "closeconn", let session = ActiveWorkspace.shared.session, let id = session.active?.id {
                        return session.close(id)
                    }
                    if name == "sidebar" {
                        let toggled = NSApp.sendAction(
                            #selector(NSSplitViewController.toggleSidebar(_:)),
                            to: nil,
                            from: nil
                        )
                        if !toggled {
                            print("CALL no sidebar")
                        }
                        return
                    }
                    guard let workspace = WorkspaceRegistry.key else {
                        return print("CALL no workspace")
                    }
                    switch name {
                    case "ai": workspace.toggleRightPanel(.ai)
                    case "queries": workspace.toggleRightPanel(.queries)
                    case "resultundo":
                        workspace.selectedTab.flatMap { if case .query(let q) = $0 { q.resultEditor } else { nil } }?
                            .undoManager.undo()
                    case "resultredo":
                        workspace.selectedTab.flatMap { if case .query(let q) = $0 { q.resultEditor } else { nil } }?
                            .undoManager.redo()
                    case "resultpreview": if case .query(let q) = workspace.selectedTab { q.showResultPreview = true }
                    case "dump": workspace.startDump()
                    case "restore": Task { await workspace.startRestore() }
                    case "dumpstart": workspace.transfer?.start()
                    case "dumpstop": workspace.transfer?.cancel()
                    case let call where call.hasPrefix("dumptable-"):
                        if let table = workspace.tables.first(where: { $0.name == call.dropFirst("dumptable-".count) })
                        {
                            workspace.startDump(tables: [table])
                        }
                    case "dumpcustom": workspace.transfer?.dumpOptions.format = .custom
                    case "dumpdrop": workspace.transfer?.dumpOptions.addDrop = true
                    case "restoredrop": workspace.transfer?.restoreOptions.dropExisting = true
                    case "dumpdone": workspace.transfer = nil
                    case "save": workspace.saveSelectedTab(choosingLocation: false)
                    case "saveas": workspace.saveSelectedTab(choosingLocation: true)
                    case "close": if let id = workspace.selectedTabID { workspace.requestClose(id) }
                    case "reopen": workspace.reopenClosedTab()
                    default: print("CALL unknown", name)
                    }
                }
                delay += 0.6
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
                guard let window = targetWindow else {
                    print("KEY", token, "→ no window")
                    return
                }
                if !window.isKeyWindow {
                    NSApp.activate(ignoringOtherApps: true)
                    window.makeKeyAndOrderFront(nil)
                }
                // Launched from a terminal the app may not be allowed to become active, so its window never
                // turns key; route menu commands to it anyway.
                WorkspaceRegistry.makeActiveForTesting(window)
                print(
                    "KEY",
                    token,
                    "→ first responder:",
                    String(describing: window.firstResponder.map { type(of: $0) })
                )
                let receiver = window.attachedSheet ?? window
                // Keys go to the SQL editor when nothing that takes text has focus, as typing does.
                if !(receiver.firstResponder is NSTextView),
                    let editor = firstView(of: SQLTextView.self, in: receiver.contentView)
                {
                    receiver.makeFirstResponder(editor)
                }
                let events = events(for: token, window: receiver)
                if !token.hasPrefix("type:") { logEvent("keycap") }
                if let down = events.first, down.modifierFlags.contains(.command) {
                    // AppKit's key-equivalent order (window, then main menu), which an inactive app skips.
                    NSApp.mainMenu?.update()
                    let handled =
                        receiver.performKeyEquivalent(with: down)
                        || NSApp.mainMenu?.performKeyEquivalent(with: down) == true
                    print("KEY", token, handled ? "→ handled" : "→ not handled, sent as a key press")
                    // As in AppKit, a key equivalent nothing takes is a key press (⌘← and ⌘↑ in a text view).
                    if !handled { for event in events { NSApp.postEvent(event, atStart: false) } }
                } else {
                    for event in events {
                        NSApp.postEvent(event, atStart: false)
                    }
                }
            }
            delay += 0.6
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 1) {
            print("KEYS DONE")
            fflush(stdout)
        }
    }

    /// The window scripts drive and recordings capture: a workspace, or with TABULA_DEBUG_TARGET=connections the
    /// Connections window.
    static var targetWindow: NSWindow? {
        if environment["TABULA_DEBUG_TARGET"] == "connections" {
            return NSApp.windows.first {
                $0.isVisible && $0.identifier?.rawValue.hasPrefix(WindowID.connections) == true
            }
        }
        return NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue.hasPrefix("workspace") == true }
            ?? NSApp.windows.first {
                $0.isVisible && $0.title != "Tabula" && $0.title != "Keyboard Shortcuts" && $0.contentView != nil
                    && $0.frame.width > 900
            }
    }

    private static let namedKeys: [String: (UInt16, String)] = [
        "return": (36, "\r"), "tab": (48, "\t"), "space": (49, " "), "delete": (51, "\u{7F}"), "esc": (53, "\u{1B}"),
        "left": (123, "\u{F702}"), "right": (124, "\u{F703}"), "down": (125, "\u{F701}"), "up": (126, "\u{F700}"),
        "f2": (120, "\u{F705}"),
    ]

    private static let letterCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
        "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
        "]": 30, "o": 31,
        "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46, "/": 44, ".": 47,
    ]

    private static func events(for token: String, window: NSWindow) -> [NSEvent] {
        if token.hasPrefix("type:") {
            return token.dropFirst(5)
                .flatMap { character in
                    [true, false]
                        .compactMap { down in
                            key(
                                down: down,
                                code: letterCodes[Character(character.lowercased())] ?? 0,
                                characters: String(character),
                                ignoring: String(character).lowercased(),
                                flags: character.isUppercase ? [.shift] : [],
                                window: window
                            )
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
        return [true, false]
            .compactMap {
                key(down: $0, code: code, characters: typed, ignoring: characters, flags: flags, window: window)
            }
    }

    private static func key(
        down: Bool,
        code: UInt16,
        characters: String,
        ignoring: String,
        flags: NSEvent.ModifierFlags,
        window: NSWindow
    ) -> NSEvent? {
        NSEvent.keyEvent(
            with: down ? .keyDown : .keyUp,
            location: .zero,
            modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: ignoring,
            isARepeat: false,
            keyCode: code
        )
    }

    /// Logs every menu item with its shortcut, to spot conflicts.
    private static func dumpMenus() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            func walk(_ menu: NSMenu, _ path: String) {
                for item in menu.items where !item.isSeparatorItem {
                    let key =
                        item.keyEquivalent.isEmpty
                        ? ""
                        : " [\(item.keyEquivalentModifierMask.rawValue >> 17):\(item.keyEquivalent.debugDescription)]"
                    print("MENU", path + item.title + key)
                    if let submenu = item.submenu {
                        walk(submenu, path + item.title + " > ")
                    }
                }
            }
            if let main = NSApp.mainMenu {
                walk(main, "")
            }
            fflush(stdout)
        }
    }
}
#endif
