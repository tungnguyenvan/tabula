import Foundation

/// A query saved in the library: one .sql file. Its keyword is the file's name, so `active_users.sql` comes up
/// when `active_users` is typed in the editor; its group is the folder it sits in, if any.
public struct SavedQuery: Identifiable, Hashable, Sendable {
    public let file: URL
    public let keyword: String
    /// The folder under the library it sits in ("reports", "reports/monthly"); empty at the top level.
    public let group: String
    public let sql: String

    public var id: URL { file }

    public init(file: URL, keyword: String, group: String, sql: String) {
        self.file = file
        self.keyword = keyword
        self.group = group
        self.sql = sql
    }
}

extension SavedQuery {
    /// The queries that match `text`, best first: keyword starting with it, then keyword or group containing it,
    /// then SQL containing it. Case and accents are ignored, "đ" matching "d" as well; empty text matches
    /// everything, in library order.
    public static func search(_ queries: [SavedQuery], for text: String) -> [SavedQuery] {
        let needle = searchable(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.isEmpty else {
            return queries
        }
        func rank(_ query: SavedQuery) -> Int? {
            let keyword = searchable(query.keyword)
            if keyword.hasPrefix(needle) {
                return 0
            }
            if keyword.contains(needle) || searchable(query.group).contains(needle) {
                return 1
            }
            if searchable(query.sql).contains(needle) {
                return 2
            }
            return nil
        }
        var ranked: [(rank: Int, index: Int, query: SavedQuery)] = []
        for (index, query) in queries.enumerated() {
            if let rank = rank(query) {
                ranked.append((rank, index, query))
            }
        }
        ranked.sort { ($0.rank, $0.index) < ($1.rank, $1.index) }
        return ranked.map(\.query)
    }

    /// Lowercased, without accents. Foundation keeps "đ" (a separate letter, not "d" with a mark), so it is
    /// mapped by hand, as Vietnamese readers expect.
    static func searchable(_ text: String) -> String {
        let plain = text.replacingOccurrences(of: "đ", with: "d").replacingOccurrences(of: "Đ", with: "D")
        return plain.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
