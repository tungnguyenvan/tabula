import Foundation
import TabulaFoundation

/// The saved query library: a folder of .sql files in Application Support/Tabula/Queries, which you can also fill
/// and arrange in Finder. Subfolders are groups.
public struct QueryLibrary: Sendable {
    public let directory: URL

    /// `base` is the folder that holds connections.json (nil: Application Support/Tabula).
    public init(base: URL? = nil) {
        let root =
            base
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tabula", isDirectory: true)
        directory = root.appendingPathComponent("Queries", isDirectory: true)
    }

    public enum LibraryError: LocalizedError, Equatable {
        case invalidKeyword(String)
        case keywordTaken(String)
        case invalidFolder(String)

        public var errorDescription: String? {
            switch self {
            case .invalidKeyword(let keyword):
                return "“\(keyword)” can't be a keyword. Use letters, digits and “_”, starting with a letter."
            case .keywordTaken(let keyword):
                return "A saved query is already called “\(keyword)”."
            case .invalidFolder(let folder):
                return "“\(folder)” can't be a folder: use names separated by “/”, without “.” or “..”."
            }
        }
    }

    /// Keywords are typed in the editor, so they are words as SQL reads them: letters, digits and “_”, starting
    /// with a letter.
    public static func isValidKeyword(_ keyword: String) -> Bool {
        guard let first = keyword.unicodeScalars.first, CharacterSet.letters.contains(first) else {
            return false
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        return keyword.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    public struct Contents: Equatable, Sendable {
        /// Sorted by group and keyword.
        public var queries: [SavedQuery]
        /// .sql files that couldn't be read (an unknown text encoding, no permission, a link to somewhere outside
        /// the library), to tell the user. Their keywords are still taken.
        public var unreadable: [URL]
    }

    /// Every .sql file in the library, its subfolders included. A missing library is empty.
    public func contents() throws -> Contents {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return Contents(queries: [], unreadable: [])
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            )
        else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: directory.path])
        }
        var queries: [SavedQuery] = []
        var unreadable: [URL] = []
        let rootComponents = directory.standardizedFileURL.pathComponents
        for case let file as URL in enumerator where file.pathExtension.lowercased() == "sql" {
            let values = try file.resourceValues(forKeys: Set(keys))
            var source = file
            if values.isSymbolicLink == true {
                // A link is read when it leads to a file inside the library, and reported otherwise.
                source = file.resolvingSymlinksInPath()
                let target = try? source.resourceValues(forKeys: [.isRegularFileKey])
                guard source.standardizedFileURL.path.hasPrefix(root), target?.isRegularFile == true else {
                    unreadable.append(file)
                    continue
                }
            } else if values.isRegularFile != true {
                continue
            }
            var encoding = String.Encoding.utf8
            let sql: String
            do {
                sql = try String(contentsOf: source, usedEncoding: &encoding)
            } catch {
                unreadable.append(file)
                continue
            }
            let folder = file.deletingLastPathComponent().standardizedFileURL.pathComponents
            let group = folder.dropFirst(rootComponents.count).joined(separator: "/")
            let keyword = file.deletingPathExtension().lastPathComponent
            queries.append(SavedQuery(file: file, keyword: keyword, group: group, sql: sql))
        }
        queries.sort { first, second in
            let firstKey = (first.group.lowercased(), first.keyword.lowercased())
            let secondKey = (second.group.lowercased(), second.keyword.lowercased())
            return firstKey < secondKey
        }
        return Contents(queries: queries, unreadable: unreadable)
    }

    /// The queries alone, for callers that report unreadable files elsewhere.
    public func load() throws -> [SavedQuery] {
        try contents().queries
    }

    /// Saves `sql` as `<keyword>.sql`, in `group` when one is given. A keyword already used anywhere in the
    /// library is refused, so typing it always means one query.
    @discardableResult
    public func save(_ sql: String, keyword: String, group: String = "") throws -> SavedQuery {
        guard Self.isValidKeyword(keyword) else {
            throw LibraryError.invalidKeyword(keyword)
        }
        let folders = group.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        // Each folder stays inside the library: no "." or "..", nor a hidden folder.
        guard folders.allSatisfy({ !$0.hasPrefix(".") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            throw LibraryError.invalidFolder(group)
        }
        // Files that couldn't be read count too: saving must never replace one of them.
        let existing = try contents()
        let taken =
            existing.queries.map(\.keyword) + existing.unreadable.map { $0.deletingPathExtension().lastPathComponent }
        if taken.contains(where: { $0.caseInsensitiveCompare(keyword) == .orderedSame }) {
            throw LibraryError.keywordTaken(keyword)
        }
        var folder = directory
        for part in folders {
            folder.appendPathComponent(part, isDirectory: true)
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A folder that is a link to elsewhere would take the query out of the library.
        let root = directory.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedFolder = folder.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedFolder == root || resolvedFolder.hasPrefix(root + "/") else {
            throw LibraryError.invalidFolder(group)
        }
        let file = folder.appendingPathComponent(keyword).appendingPathExtension("sql")
        guard !FileManager.default.fileExists(atPath: file.path) else {
            throw LibraryError.keywordTaken(keyword)
        }
        try sql.write(to: file, atomically: true, encoding: .utf8)
        return SavedQuery(file: file, keyword: keyword, group: folders.joined(separator: "/"), sql: sql)
    }

    /// Moves a saved query to the Trash, so a mistaken delete can be undone in Finder.
    public func remove(_ query: SavedQuery) throws {
        try FileManager.default.trashItem(at: query.file, resultingItemURL: nil)
    }
}
