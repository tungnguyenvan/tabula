import AppKit
import Foundation
import Observation
import TabulaFoundation
import TabulaStorage

/// The saved query library as every window sees it (#94). It reads the Queries folder when created, when Tabula
/// comes to the front (files may have changed in Finder) and after its own saves and deletions.
@MainActor @Observable
final class QueryLibraryModel {
    static let shared = QueryLibraryModel(library: AppState.queryLibrary)

    let library: QueryLibrary
    private(set) var queries: [SavedQuery] = []
    /// Why the folder couldn't be read, shown in the panel.
    private(set) var loadError: String?

    init(library: QueryLibrary) {
        self.library = library
        reload()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reload()
            }
        }
    }

    func reload() {
        do {
            queries = try library.load()
            loadError = nil
        } catch {
            loadError = "Couldn't read \(library.directory.path): \(error.localizedDescription)"
        }
    }

    /// Saves `sql` under `keyword` (and `group`), then reloads. Throws the reason it can't be saved.
    func save(_ sql: String, keyword: String, group: String) throws {
        try library.save(sql, keyword: keyword, group: group)
        reload()
    }

    func moveToTrash(_ query: SavedQuery) throws {
        try library.remove(query)
        reload()
    }

    /// Opens the Queries folder in Finder, creating it first so there is something to open.
    func showFolder() throws {
        try FileManager.default.createDirectory(at: library.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([library.directory])
    }
}
