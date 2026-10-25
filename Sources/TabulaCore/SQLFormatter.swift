import Foundation

public enum SQLKeywords {
    public static let all: [String] = """
        SELECT FROM WHERE AND OR NOT IN IS NULL LIKE ILIKE BETWEEN EXISTS AS ON JOIN LEFT RIGHT INNER OUTER FULL CROSS
        GROUP BY ORDER HAVING LIMIT OFFSET UNION ALL DISTINCT INSERT INTO VALUES UPDATE SET DELETE CREATE TABLE VIEW INDEX
        DROP ALTER ADD COLUMN PRIMARY KEY FOREIGN REFERENCES UNIQUE DEFAULT CHECK CONSTRAINT IF CASE WHEN THEN ELSE END
        BEGIN COMMIT ROLLBACK TRANSACTION WITH RECURSIVE RETURNING ASC DESC TRUE FALSE CAST TRUNCATE SCHEMA DATABASE USE
        SHOW EXPLAIN ANALYZE GRANT REVOKE CASCADE COUNT SUM AVG MIN MAX COALESCE NULLIF LATERAL OVER PARTITION WINDOW
        INTERSECT EXCEPT FETCH FOR USING NATURAL INTERVAL CURRENT_DATE CURRENT_TIME CURRENT_TIMESTAMP EXTRACT ANY
        TRIGGER FUNCTION PROCEDURE REPLACE RETURNS RETURN LANGUAGE BEFORE AFTER INSTEAD EACH ROW EXECUTE DECLARE
        LOOP WHILE DO CALL DEFINER DETERMINISTIC
        """.split(whereSeparator: \.isWhitespace).map(String.init)

    public static let set = Set(all)
    /// Keywords written like functions: no space before their "(".
    static let functions: Set<String> = ["COUNT", "SUM", "AVG", "MIN", "MAX", "COALESCE", "NULLIF", "CAST", "EXISTS"]
}

/// Re-indents SQL: one clause per line, select items and AND/OR conditions on their own lines,
/// subqueries indented, keywords upper-cased. Strings, quoted names and comments are kept as written.
public enum SQLFormatter {
    public static let indentUnit = "  "

    /// Clauses whose contents go on the following lines, indented.
    private static let blockClauses: Set<String> = ["SELECT", "FROM", "WHERE", "GROUP BY", "ORDER BY", "HAVING", "SET", "VALUES", "RETURNING"]
    /// Clauses that start a line but keep their contents on it.
    private static let lineClauses: Set<String> = [
        "LIMIT", "OFFSET", "FETCH", "UNION", "UNION ALL", "INTERSECT", "EXCEPT", "INSERT INTO", "UPDATE", "DELETE FROM", "WITH",
        "JOIN", "INNER JOIN", "LEFT JOIN", "RIGHT JOIN", "FULL JOIN", "CROSS JOIN", "NATURAL JOIN",
        "LEFT OUTER JOIN", "RIGHT OUTER JOIN", "FULL OUTER JOIN",
    ]
    private static let compounds: [[String]] = [
        ["LEFT", "OUTER", "JOIN"], ["RIGHT", "OUTER", "JOIN"], ["FULL", "OUTER", "JOIN"],
        ["GROUP", "BY"], ["ORDER", "BY"], ["UNION", "ALL"], ["INSERT", "INTO"], ["DELETE", "FROM"],
        ["INNER", "JOIN"], ["LEFT", "JOIN"], ["RIGHT", "JOIN"], ["FULL", "JOIN"], ["CROSS", "JOIN"], ["NATURAL", "JOIN"],
    ]

    private struct Frame {
        /// Indent level of clause keywords in this (sub)query.
        var level: Int
        var isSubquery: Bool
        /// Open non-subquery parentheses (function calls, IN lists); commas inside them don't break lines.
        var parens = 0
        var clause = ""
    }

    public static func format(_ sql: String, kind: DatabaseKind) -> String {
        let tokens = SQLLexer.tokens(sql, kind: kind).filter { $0.kind != .whitespace }
        var out = ""
        var frames = [Frame(level: 0, isSubquery: false)]
        var lineHasContent = false
        var forceBreak = false
        var previous: SQLToken?
        var index = 0
        /// Set by BETWEEN so its AND isn't mistaken for a condition separator.
        var betweenPending = false

        func newline(_ level: Int) {
            while out.last == " " { out.removeLast() }
            if !out.isEmpty { out += "\n" }
            out += String(repeating: indentUnit, count: max(0, level))
            lineHasContent = false
            forceBreak = false
        }
        func write(_ text: String, spaced: Bool) {
            if forceBreak { newline(frames[frames.count - 1].level + 1) }
            if spaced && lineHasContent { out += " " }
            out += text
            lineHasContent = true
        }
        func needsSpace(before token: SQLToken) -> Bool {
            guard let previous else { return false }
            if [",", ")", ".", ";", "::"].contains(token.text) { return false }
            if ["(", ".", "::"].contains(previous.text) { return false }
            if token.text == "(" {
                // Function calls and table(column) lists hug their parenthesis; keywords like IN and VALUES don't.
                if previous.kind == .quotedIdentifier { return false }
                if previous.kind == .word { return SQLKeywords.set.contains(previous.keyword) && !SQLKeywords.functions.contains(previous.keyword) }
            }
            return true
        }
        /// The keyword (or multi-word keyword) starting at `index`, with the number of tokens it spans.
        func clause(at index: Int) -> (String, Int)? {
            guard tokens[index].kind == .word else { return nil }
            for words in compounds where index + words.count <= tokens.count {
                if zip(words, tokens[index..<index + words.count]).allSatisfy({ $0 == $1.keyword }) {
                    return (words.joined(separator: " "), words.count)
                }
            }
            let word = tokens[index].keyword
            return blockClauses.contains(word) || lineClauses.contains(word) ? (word, 1) : nil
        }

        while index < tokens.count {
            let token = tokens[index]
            var frame = frames[frames.count - 1]

            if token.text == ";" {
                // The next statement's first clause adds the second newline, leaving one blank line.
                out += ";\n"
                lineHasContent = false
                forceBreak = false
                frames = [Frame(level: 0, isSubquery: false)]
                previous = nil
                index += 1
                continue
            }
            if token.kind == .comment {
                write(token.text, spaced: true)
                if token.text.hasPrefix("--") || token.text.hasPrefix("#") { forceBreak = true }
                previous = token
                index += 1
                continue
            }
            if frame.parens == 0, let (name, length) = clause(at: index) {
                newline(frame.level)
                out += name
                lineHasContent = true
                frame.clause = name
                frames[frames.count - 1] = frame
                if blockClauses.contains(name) { forceBreak = true }
                previous = tokens[index + length - 1]
                index += length
                continue
            }
            if token.text == "(" {
                let nextKeyword = index + 1 < tokens.count ? tokens[index + 1].keyword : ""
                write("(", spaced: needsSpace(before: token))
                if nextKeyword == "SELECT" || nextKeyword == "WITH" {
                    frames.append(Frame(level: frame.level + 2, isSubquery: true))
                } else {
                    frame.parens += 1
                    frames[frames.count - 1] = frame
                }
                previous = token
                index += 1
                continue
            }
            if token.text == ")" {
                if frame.parens > 0 {
                    frame.parens -= 1
                    frames[frames.count - 1] = frame
                } else if frame.isSubquery, frames.count > 1 {
                    frames.removeLast()
                    newline(frames[frames.count - 1].level + 1)
                }
                write(")", spaced: false)
                previous = token
                index += 1
                continue
            }
            if frame.parens == 0 && token.text == "," && blockClauses.contains(frame.clause) {
                write(",", spaced: false)
                forceBreak = true
                previous = token
                index += 1
                continue
            }
            if frame.parens == 0 && (token.keyword == "AND" || token.keyword == "OR") && ["WHERE", "HAVING"].contains(frame.clause) {
                // BETWEEN x AND y keeps its AND.
                if token.keyword == "AND" && betweenPending {
                    betweenPending = false
                } else {
                    newline(frame.level + 1)
                    write(token.keyword, spaced: false)
                    previous = token
                    index += 1
                    continue
                }
            }
            if token.keyword == "BETWEEN" { betweenPending = true }
            let text = token.kind == .word && SQLKeywords.set.contains(token.keyword) && previous?.text != "." ? token.keyword : token.text
            write(text, spaced: needsSpace(before: token))
            previous = token
            index += 1
        }
        while out.last == " " || out.last == "\n" { out.removeLast() }
        return out
    }
}

extension SQLDialect {
    /// Adds `LIMIT n` to a plain SELECT that has no LIMIT of its own, so an accidental full-table query stays small.
    /// Anything else (writes, existing LIMIT/FETCH, locking clauses) is returned unchanged.
    public func applyingRowLimit(_ statement: String, limit: Int) -> String {
        let tokens = SQLLexer.tokens(statement, kind: kind)
        let significant = tokens.filter { $0.kind != .whitespace && $0.kind != .comment }
        guard let first = significant.first, first.keyword == "SELECT" || first.keyword == "WITH" else { return statement }
        var depth = 0
        for token in significant {
            if token.text == "(" { depth += 1 } else if token.text == ")" { depth -= 1 }
            guard depth == 0 else { continue }
            if ["LIMIT", "FETCH", "FOR", "INTO", "INSERT", "UPDATE", "DELETE", "TOP", "OFFSET"].contains(token.keyword) { return statement }
        }
        guard let last = significant.last(where: { $0.text != ";" }) else { return statement }
        let text = statement as NSString
        let end = NSMaxRange(last.range)
        return text.substring(to: end) + " LIMIT \(limit)" + text.substring(from: end)
    }
}
