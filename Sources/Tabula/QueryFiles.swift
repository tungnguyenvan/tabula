import AppKit
import UniformTypeIdentifiers

/// Query tabs saved to and opened from .sql files.
enum SQLFile {
    /// Apps that edit SQL each declare their own type for .sql, so it is looked up by extension.
    static let type = UTType(filenameExtension: "sql", conformingTo: .plainText) ?? .plainText
}

/// Files opened from Finder before any connection was ready; the next one to connect opens them.
@MainActor
enum PendingSQLFiles {
    private static var urls: [URL] = []

    static func add(_ new: [URL]) { urls += new }

    static func take() -> [URL] {
        defer { urls = [] }
        return urls
    }
}

extension QueryTabModel {
    /// Writes the tab to its file, asking where first when it has none or when `choosingLocation` (Save As).
    /// Returns whether it saved.
    @discardableResult
    func save(choosingLocation: Bool = false) -> Bool {
        if !choosingLocation, let fileURL {
            return write(to: fileURL)
        }
        guard let url = chooseLocation() else { return false }
        return write(to: url)
    }

    private func chooseLocation() -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [SQLFile.type]
        panel.nameFieldStringValue = fileURL?.lastPathComponent ?? title
        panel.directoryURL = fileURL?.deletingLastPathComponent()
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func write(to url: URL) -> Bool {
        let text = sql
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Confirmation.report("Couldn’t save “\(url.lastPathComponent)”.", error: error)
            return false
        }
        attach(url, savedText: text)
        return true
    }

    /// Before closing a tab with unsaved edits: Save, Don't Save or Cancel. Returns false when the tab should stay.
    func confirmClose() -> Bool {
        guard confirmDiscardResults() else { return false }
        guard isEdited else { return true }
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes made to “\(title)”?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let discard = alert.addButton(withTitle: "Don’t Save")
        discard.hasDestructiveAction = true
        discard.keyEquivalent = "d"
        discard.keyEquivalentModifierMask = .command
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save()
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }
}

extension WorkspaceModel {
    /// Asks for .sql files (⌘O) and opens each in a query tab.
    func chooseSQLFiles() {
        guard driver != nil else {
            return NSSound.beep()
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [SQLFile.type, .plainText]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(openSQLFile)
    }

    /// Opens a file in a query tab, or selects the tab that already has it.
    func openSQLFile(_ url: URL) {
        let url = url.standardizedFileURL
        if let open = tabs.first(where: { if case .query(let model) = $0 { model.fileURL == url } else { false } }) {
            selectedTabID = open.id
            return
        }
        let text: String
        do {
            var encoding = String.Encoding.utf8
            text = try String(contentsOf: url, usedEncoding: &encoding)
        } catch {
            Confirmation.report("Couldn’t open “\(url.lastPathComponent)”.", error: error)
            return
        }
        // The empty tab a connection opens with is used for the file rather than left behind it.
        if case .query(let current) = selectedTab, current.fileURL == nil,
            current.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            current.sql = text
            current.attach(url, savedText: text)
        } else {
            newQueryTab(sql: text)
            if case .query(let model) = selectedTab {
                model.attach(url, savedText: text)
            }
        }
    }
}
