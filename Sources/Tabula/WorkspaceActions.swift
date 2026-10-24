import AppKit
import TabulaCore

extension WorkspaceModel {
    /// Closes a tab, asking first if it holds uncommitted edits.
    func requestClose(_ id: UUID) {
        guard hasUnsavedChanges(id), case .table(let table) = tabs.first(where: { $0.id == id }) else {
            close(id)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Discard \(table.changeCount) uncommitted change\(table.changeCount == 1 ? "" : "s") in “\(table.table.name)”?"
        alert.informativeText = "Commit them (⌘S) first if you want to keep them."
        alert.addButton(withTitle: "Discard and Close")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn { close(id) }
    }
}
