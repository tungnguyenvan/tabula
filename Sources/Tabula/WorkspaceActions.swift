import AppKit
import TabulaCore

extension WorkspaceModel {
    /// Closes a tab, asking first if it holds uncommitted edits.
    func requestClose(_ id: UUID) {
        guard case .table(let table) = tabs.first(where: { $0.id == id }), table.hasChanges else {
            close(id)
            return
        }
        if table.confirmDiscard(action: "Discard and Close") { close(id) }
    }
}
