import Foundation

/// Splits a script into statements on top-level semicolons, ignoring semicolons inside
/// quotes, comments and (for Postgres) dollar-quoted bodies.
public enum SQLSplitter {
    /// A statement and where it sits in the script, in UTF-16 units (NSString / NSTextView coordinates).
    public struct Statement: Equatable, Sendable {
        public var text: String
        public var range: NSRange
    }

    public static func split(_ script: String, kind: DatabaseKind) -> [String] {
        statements(in: script, kind: kind).map(\.text)
    }

    /// The statement under `location` (a UTF-16 offset, e.g. the caret). A caret in the blank space or
    /// comment after a statement belongs to that statement, matching how people place the cursor.
    public static func statement(at location: Int, in script: String, kind: DatabaseKind) -> Statement? {
        let all = statements(in: script, kind: kind)
        if let containing = all.first(where: { location >= $0.range.location && location <= NSMaxRange($0.range) }) {
            return containing
        }
        return all.last(where: { $0.range.location <= location }) ?? all.first
    }

    public static func statements(in script: String, kind: DatabaseKind) -> [Statement] {
        if kind == .mongodb { return MongoSplitter.statements(in: script) }
        let chars = Array(script)
        // UTF-16 offset of each character, so ranges can be reported in NSString units.
        var utf16Offsets: [Int] = []
        utf16Offsets.reserveCapacity(chars.count + 1)
        var running = 0
        for character in chars {
            utf16Offsets.append(running)
            running += character.utf16.count
        }
        utf16Offsets.append(running)

        var statements: [Statement] = []
        var current = ""
        var segmentStart = 0
        var i = 0
        // Bodies of MySQL routines and SQLite / MySQL triggers are BEGIN ... END blocks with their own
        // semicolons; inside one, a ';' doesn't end the statement.
        var blockDepth = 0
        var words: [String] = []

        func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }

        /// Tracks BEGIN / CASE ... END nesting, only inside CREATE TRIGGER / PROCEDURE / FUNCTION / EVENT.
        func note(_ word: String) {
            let word = word.uppercased()
            words.append(word)
            guard kind != .postgres, words.first == "CREATE",
                  words.contains(where: { ["TRIGGER", "PROCEDURE", "FUNCTION", "EVENT"].contains($0) }) else { return }
            let afterEnd = words.dropLast().last == "END"
            switch word {
            case "BEGIN", "CASE":
                // "END CASE" closes a CASE that was already counted when it opened.
                if !afterEnd { blockDepth += 1 }
            case "IF", "LOOP", "WHILE", "REPEAT":
                // END IF / END LOOP / ... close constructs that weren't counted, so undo that END's step.
                if afterEnd { blockDepth += 1 }
            case "END":
                blockDepth = max(0, blockDepth - 1)
            default:
                break
            }
        }

        func flush() {
            defer { current = ""; segmentStart = i + 1; words = []; blockDepth = 0 }
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty && !isOnlyComments(trimmed, kind: kind) else { return }
            let leading = current.prefix(while: { $0.isWhitespace || $0.isNewline }).count
            let trailing = current.reversed().prefix(while: { $0.isWhitespace || $0.isNewline }).count
            let start = segmentStart + leading
            let end = segmentStart + current.count - trailing
            statements.append(Statement(text: trimmed, range: NSRange(location: utf16Offsets[start], length: utf16Offsets[end] - utf16Offsets[start])))
        }

        while i < chars.count {
            let c = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil

            if c == "-" && next == "-" || (c == "#" && kind == .mysql) {
                while i < chars.count && chars[i] != "\n" { current.append(chars[i]); i += 1 }
                continue
            }
            if c == "/" && next == "*" {
                current.append("/*"); i += 2
                while i < chars.count && !(chars[i] == "*" && i + 1 < chars.count && chars[i + 1] == "/") {
                    current.append(chars[i]); i += 1
                }
                if i < chars.count { current.append("*/"); i += 2 }
                continue
            }
            if c == "'" || c == "\"" || c == "`" {
                current.append(c); i += 1
                while i < chars.count {
                    let q = chars[i]
                    current.append(q); i += 1
                    if q == "\\" && kind == .mysql && i < chars.count {
                        current.append(chars[i]); i += 1
                        continue
                    }
                    if q == c {
                        // Doubled quote is an escaped quote.
                        if i < chars.count && chars[i] == c { current.append(c); i += 1; continue }
                        break
                    }
                }
                continue
            }
            if c == "$" && kind == .postgres, let tag = dollarTag(chars, at: i) {
                current.append(contentsOf: tag); i += tag.count
                while i < chars.count {
                    if chars[i] == "$", matches(chars, at: i, tag: tag) {
                        current.append(contentsOf: tag); i += tag.count
                        break
                    }
                    current.append(chars[i]); i += 1
                }
                continue
            }
            if c == ";" && blockDepth == 0 {
                flush(); i += 1
                continue
            }
            if isWordCharacter(c) {
                var word = ""
                while i < chars.count, isWordCharacter(chars[i]) { word.append(chars[i]); current.append(chars[i]); i += 1 }
                note(word)
                continue
            }
            current.append(c); i += 1
        }
        flush()
        return statements
    }

    private static func dollarTag(_ chars: [Character], at start: Int) -> [Character]? {
        var j = start + 1
        while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" {
            j += 1
        }
        guard j < chars.count, chars[j] == "$" else { return nil }
        // "$1" is a parameter placeholder, not a tag.
        if j > start + 1, chars[start + 1].isNumber { return nil }
        return Array(chars[start...j])
    }

    private static func matches(_ chars: [Character], at start: Int, tag: [Character]) -> Bool {
        guard start + tag.count <= chars.count else { return false }
        return Array(chars[start..<start + tag.count]) == tag
    }

    private static func isOnlyComments(_ text: String, kind: DatabaseKind) -> Bool {
        var stripped = text
        // An unterminated block comment runs to the end, as in the scanner above.
        while let range = stripped.range(of: "/\\*(?:[\\s\\S]*?\\*/|[\\s\\S]*)", options: .regularExpression) {
            stripped.removeSubrange(range)
        }
        let lines = stripped.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.allSatisfy { $0.isEmpty || $0.hasPrefix("--") || (kind == .mysql && $0.hasPrefix("#")) }
    }

    /// Whether a statement produces a result set, judged by its leading keyword.
    public static func returnsRows(_ statement: String) -> Bool {
        let keyword = leadingKeyword(statement)
        return ["SELECT", "WITH", "SHOW", "VALUES", "TABLE", "EXPLAIN", "DESCRIBE", "DESC", "PRAGMA"].contains(keyword)
    }

    public static func leadingKeyword(_ statement: String) -> String {
        var text = Substring(statement)
        while true {
            text = text.drop(while: { $0.isWhitespace || $0 == "(" })
            if text.hasPrefix("--") || text.hasPrefix("#") {
                text = text.drop(while: { $0 != "\n" })
            } else if text.hasPrefix("/*"), let end = text.range(of: "*/") {
                text = text[end.upperBound...]
            } else {
                break
            }
        }
        return String(text.prefix(while: { $0.isLetter })).uppercased()
    }
}
