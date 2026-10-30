import AppKit
import UniformTypeIdentifiers

/// Query tabs saved to and opened from .sql files.
enum SQLFile {
    /// Apps that edit SQL each declare their own type for .sql, so it is looked up by extension.
    static let type = UTType(filenameExtension: "sql", conformingTo: .plainText) ?? .plainText

    /// A file's text and the encoding it was read in: the one detected (a byte order mark, UTF-8), otherwise
    /// Windows-1252, as older dumps and Windows tools write, and Latin-1, which reads any bytes.
    static func read(_ url: URL) throws -> (text: String, encoding: String.Encoding) {
        var detected = String.Encoding.utf8
        if let text = try? String(contentsOf: url, usedEncoding: &detected) {
            // Foundation says .utf16 for either byte order; the byte order mark tells which, so saving keeps it.
            if detected == .utf16, let head = try? FileHandle(forReadingFrom: url).read(upToCount: 2) {
                if head == Data([0xFE, 0xFF]) {
                    return (text, .utf16BigEndian)
                }
                if head == Data([0xFF, 0xFE]) {
                    return (text, .utf16LittleEndian)
                }
            }
            return (text, detected)
        }
        let data = try Data(contentsOf: url)
        for encoding in [String.Encoding.windowsCP1252, .isoLatin1] {
            if let text = String(data: data, encoding: encoding) {
                return (text, encoding)
            }
        }
        throw CocoaError(.fileReadInapplicableStringEncoding)
    }

    /// The bytes to save: in the encoding the file was read in, or UTF-8 once the text holds characters that
    /// encoding can't.
    static func data(_ text: String, encoding: String.Encoding) -> Data {
        guard let encoded = text.data(using: encoding, allowLossyConversion: false) else {
            return Data(text.utf8)
        }
        // A file read with a byte order mark in a set byte order is written with the same mark.
        switch encoding {
        case .utf16BigEndian: return Data([0xFE, 0xFF]) + encoded
        case .utf16LittleEndian: return Data([0xFF, 0xFE]) + encoded
        default: return encoded
        }
    }
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
        let data = SQLFile.data(text, encoding: fileEncoding)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            Confirmation.report("Couldn’t save “\(url.lastPathComponent)”.", error: error)
            return false
        }
        let saved = String(data: data, encoding: fileEncoding) == text ? fileEncoding : .utf8
        attach(url, savedText: text, encoding: saved)
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
        let encoding: String.Encoding
        do {
            (text, encoding) = try SQLFile.read(url)
        } catch {
            Confirmation.report("Couldn’t open “\(url.lastPathComponent)”.", error: error)
            return
        }
        // The empty tab a connection opens with is used for the file rather than left behind it.
        if case .query(let current) = selectedTab, current.fileURL == nil,
            current.sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            current.sql = text
            current.attach(url, savedText: text, encoding: encoding)
        } else {
            newQueryTab(sql: text)
            if case .query(let model) = selectedTab {
                model.attach(url, savedText: text, encoding: encoding)
            }
        }
    }
}
