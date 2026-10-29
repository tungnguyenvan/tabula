import AppKit

extension WorkspaceModel {
    /// Closes a tab, asking first if it holds uncommitted rows or unsaved edits to its file.
    func requestClose(_ id: UUID) {
        switch tabs.first(where: { $0.id == id }) {
        case .table(let table) where table.hasChanges:
            if table.confirmDiscard(action: "Discard and Close") { close(id) }
        case .query(let query):
            if query.confirmClose() { close(id) }
        default:
            close(id)
        }
    }

    /// ⌘S and ⇧⌘S follow the tab: a query saves its .sql file (Save As asks where), a table commits or previews
    /// its changes, a routine saves its definition.
    func saveSelectedTab(choosingLocation: Bool) {
        switch selectedTab {
        case .query(let query):
            if !choosingLocation, query.resultEditor?.hasChanges == true {
                Task { await query.commitResult() }
            } else {
                query.save(choosingLocation: choosingLocation)
            }
        case .table(let table): if choosingLocation { table.showPreviewRequest += 1 } else { commitSelectedTable() }
        case .routine(let routine) where !choosingLocation: Task { await routine.save() }
        default: NSSound.beep()
        }
    }

    func commitSelectedTable() {
        if case .query(let query) = selectedTab, query.resultEditor?.hasChanges == true {
            Task { await query.commitResult() }
            return
        }
        if let table = selectedTableTab, table.hasChanges { Task { await table.commit() } } else { NSSound.beep() }
    }
}
