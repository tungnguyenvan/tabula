import Foundation

/// A token of SQL text. Ranges are in UTF-16 units, matching NSString / NSTextView.
public struct SQLToken: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case word, quotedIdentifier, string, number, comment, whitespace, punctuation
    }

    public var kind: Kind
    public var text: String
    public var range: NSRange

    /// Upper-cased text for words, for keyword checks.
    public var keyword: String { kind == .word ? text.uppercased() : "" }
}

/// Splits query text into tokens, treating quotes, comments and dollar-quoted bodies as single tokens, as the
/// language's `LexicalRules` define them. Shared by highlighting, the formatter, the row limit and completion so
/// they agree on what is code and what is text.
public enum SQLLexer {
    public static func tokens(_ sql: String, flavor: SQLFlavor) -> [SQLToken] {
        tokens(sql, rules: flavor.lexicalRules)
    }

    public static func tokens(_ sql: String, rules: LexicalRules) -> [SQLToken] {
        let chars = Array(sql.utf16)
        var tokens: [SQLToken] = []
        var i = 0

        func unit(_ c: Character) -> UInt16 { c.utf16.first! }
        func at(_ index: Int) -> UInt16? { index < chars.count ? chars[index] : nil }
        func isWordUnit(_ u: UInt16) -> Bool {
            guard let scalar = Unicode.Scalar(u) else { return true } // surrogate halves belong to words
            return CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "$"
        }
        func emit(_ kind: SQLToken.Kind, from start: Int) {
            let text = String(utf16CodeUnits: Array(chars[start..<i]), count: i - start)
            tokens.append(SQLToken(kind: kind, text: text, range: NSRange(location: start, length: i - start)))
        }

        while i < chars.count {
            let start = i
            let c = chars[i]
            let next = at(i + 1)
            if (c == unit("-") && next == unit("-") && rules.dashDashComments) || (c == unit("#") && rules.hashComments)
                || (c == unit("/") && next == unit("/") && rules.slashSlashComments) {
                while let u = at(i), u != unit("\n") { i += 1 }
                emit(.comment, from: start)
            } else if c == unit("/") && next == unit("*") {
                i += 2
                while i < chars.count && !(chars[i] == unit("*") && at(i + 1) == unit("/")) { i += 1 }
                i = min(chars.count, i + 2)
                emit(.comment, from: start)
            } else if c == unit("'") || c == unit("\"") || c == unit("`") {
                i += 1
                while i < chars.count {
                    if chars[i] == unit("\\") && rules.backslashEscapes { i += 2; continue }
                    if chars[i] == c {
                        if at(i + 1) == c && rules.doubledQuotes { i += 2; continue } // doubled quote
                        i += 1
                        break
                    }
                    i += 1
                }
                i = min(i, chars.count)
                // Without quoted identifiers (the shell) every quote is a string.
                emit(c == unit("'") || !rules.quotedIdentifiers ? .string : .quotedIdentifier, from: start)
            } else if c == unit("$") && rules.dollarQuotes, let tag = dollarTag(chars, at: i) {
                i += tag.count
                while i < chars.count && !(chars[i] == unit("$") && Array(chars[i..<min(chars.count, i + tag.count)]) == tag) { i += 1 }
                i = min(chars.count, i + tag.count)
                emit(.string, from: start)
            } else if let scalar = Unicode.Scalar(c), CharacterSet.whitespacesAndNewlines.contains(scalar) {
                while let u = at(i), let s = Unicode.Scalar(u), CharacterSet.whitespacesAndNewlines.contains(s) { i += 1 }
                emit(.whitespace, from: start)
            } else if let scalar = Unicode.Scalar(c), CharacterSet.decimalDigits.contains(scalar) {
                while let u = at(i), let s = Unicode.Scalar(u), CharacterSet.decimalDigits.contains(s) || s == "." { i += 1 }
                emit(.number, from: start)
            } else if isWordUnit(c) {
                while let u = at(i), isWordUnit(u) { i += 1 }
                emit(.word, from: start)
            } else {
                // Two-character operators stay together so the formatter keeps them intact.
                i += 1
                if let n = at(i), ["<=", ">=", "<>", "!=", "::", "||", "->"].contains(String(utf16CodeUnits: [c, n], count: 2)) { i += 1 }
                emit(.punctuation, from: start)
            }
        }
        return tokens
    }

    private static func dollarTag(_ chars: [UInt16], at start: Int) -> [UInt16]? {
        var j = start + 1
        while j < chars.count, let s = Unicode.Scalar(chars[j]), CharacterSet.alphanumerics.contains(s) || s == "_" { j += 1 }
        guard j < chars.count, chars[j] == "$".utf16.first! else { return nil }
        if j > start + 1, let s = Unicode.Scalar(chars[start + 1]), CharacterSet.decimalDigits.contains(s) { return nil } // $1 parameter
        return Array(chars[start...j])
    }
}
