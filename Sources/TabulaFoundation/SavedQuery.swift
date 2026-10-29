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
    /// The queries that contain every word of `text`, best first: by the weakest place any word was found, keyword
    /// start, then inside the keyword or folder, then the SQL. "monthly revenue" finds `revenue_by_month`'s SQL
    /// mentioning both words. Case and accents are ignored, "đ" matching "d" as well; empty text matches
    /// everything, in library order.
    public static func search(_ queries: [SavedQuery], for text: String) -> [SavedQuery] {
        let words = searchable(text).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else {
            return queries
        }
        func rank(of word: String, in query: SavedQuery, keyword: String, group: String, sql: String) -> Int? {
            if keyword.hasPrefix(word) {
                return 0
            }
            if keyword.contains(word) || group.contains(word) {
                return 1
            }
            if sql.contains(word) {
                return 2
            }
            return nil
        }
        var ranked: [(rank: Int, index: Int, query: SavedQuery)] = []
        for (index, query) in queries.enumerated() {
            let keyword = searchable(query.keyword)
            let group = searchable(query.group)
            let sql = searchable(query.sql)
            var worst = 0
            var matchesAll = true
            for word in words {
                guard let found = rank(of: word, in: query, keyword: keyword, group: group, sql: sql) else {
                    matchesAll = false
                    break
                }
                worst = max(worst, found)
            }
            if matchesAll {
                ranked.append((worst, index, query))
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
