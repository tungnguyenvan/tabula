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
            let contents = try library.contents()
            // Assigned only when something changed: every query tab reads the list, and Tabula reloads it each
            // time it comes to the front.
            if contents.queries != queries {
                queries = contents.queries
            }
            var problem: String?
            if !contents.unreadable.isEmpty {
                let names = contents.unreadable.map(\.lastPathComponent).joined(separator: ", ")
                problem =
                    "Couldn't read \(names), so they aren't listed. Check that each is text (UTF-8 is safest), "
                    + "that you may read it, and that a link leads to a file inside the Queries folder."
            }
            if problem != loadError {
                loadError = problem
            }
        } catch {
            let problem = "Couldn't read \(library.directory.path): \(error.localizedDescription)"
            if problem != loadError {
                loadError = problem
            }
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
