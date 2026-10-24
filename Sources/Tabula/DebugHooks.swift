#if DEBUG
import AppKit
import Foundation
import TabulaCore

/// Debug-only automation for visual checks, driven by environment variables:
/// - TABULA_DEBUG_OPEN: connection UUID to open at launch
/// - TABULA_DEBUG_TABLE: table name to open once connected
/// - TABULA_DEBUG_QUERY: SQL to run in the first query tab
/// - TABULA_DEBUG_SNAPSHOT: directory that receives PNG snapshots of every window
@MainActor
enum DebugHooks {
    private static let environment = ProcessInfo.processInfo.environment

    static var showShortcuts: Bool { environment["TABULA_DEBUG_SHORTCUTS"] != nil }

    static var connectionToOpen: UUID? { environment["TABULA_DEBUG_OPEN"].flatMap(UUID.init(uuidString:)) }

    static func workspaceConnected(_ model: WorkspaceModel) {
        if environment["TABULA_DEBUG_PALETTE"] != nil { model.showPalette = true }
        if let sql = environment["TABULA_DEBUG_QUERY"], case .query(let query) = model.tabs.first {
            query.sql = sql
            Task { await query.run() }
        }
        if let name = environment["TABULA_DEBUG_TABLE"], let table = model.tables.first(where: { $0.name == name }) {
            model.open(table, mode: environment["TABULA_DEBUG_MODE"] == "structure" ? .structure : .data)
            if let tab = model.selectedTableTab, let filter = environment["TABULA_DEBUG_FILTER"] {
                // "column|operator|value", e.g. "city|contains|Nội"
                let parts = filter.components(separatedBy: "|")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    if parts.count == 3, let op = FilterRule.Operator(rawValue: parts[1]) {
                        tab.filterRules = [FilterRule(column: parts[0], op: op, value: parts[2])]
                        tab.showFilterBar = true
                        Task { await tab.applyFilter() }
                    }
                }
            }
            if let row = environment["TABULA_DEBUG_INSPECT"].flatMap(Int.init) {
                model.showInspector = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { model.inspectedRows = [row] }
            }
        }
    }

    /// TABULA_DEBUG_KEYS: ";"-separated key presses replayed through the normal event path, e.g.
    /// "wait:2000;cmd+f;type:Nội;return;esc;down;right;return;type:x;tab". Also logs the menu bar once.
    static func startKeyScript() {
        dumpMenus()
        guard let script = environment["TABULA_DEBUG_KEYS"] else { return }
        var delay = 3.0
        for token in script.components(separatedBy: ";") where !token.isEmpty {
            if token.hasPrefix("wait:") {
                delay += (Double(token.dropFirst(5)) ?? 0) / 1000
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
                print("KEY", token, "→ first responder:", String(describing: window.firstResponder.map { type(of: $0) }))
                for event in events(for: token, window: window) { NSApp.postEvent(event, atStart: false) }
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
        return [true, false].compactMap { key(down: $0, code: code, characters: characters, ignoring: characters, flags: flags, window: window) }
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
