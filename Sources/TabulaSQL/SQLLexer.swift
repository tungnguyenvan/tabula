import Foundation
import TabulaFoundation

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
            guard let scalar = Unicode.Scalar(u) else { return true }  // surrogate halves belong to words
            return CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "$"
        }
        func isOperatorUnit(_ u: UInt16) -> Bool {
            guard let scalar = Unicode.Scalar(u) else { return false }
            return "+-*/<>=~!@#%^&|?:".unicodeScalars.contains(scalar)
        }
        func startsComment(at index: Int) -> Bool {
            let c = chars[index]
            let next = at(index + 1)
            return rules.startsDashDashComment(chars, at: index)
                || (c == unit("/") && next == unit("*"))
                || (c == unit("#") && rules.hashComments)
                || (c == unit("/") && next == unit("/") && rules.slashSlashComments)
        }
        func emit(_ kind: SQLToken.Kind, from start: Int) {
            let text = String(utf16CodeUnits: Array(chars[start..<i]), count: i - start)
            tokens.append(SQLToken(kind: kind, text: text, range: NSRange(location: start, length: i - start)))
        }

        while i < chars.count {
            let start = i
            let c = chars[i]
            let next = at(i + 1)
            if rules.startsDashDashComment(chars, at: i) || (c == unit("#") && rules.hashComments)
                || (c == unit("/") && next == unit("/") && rules.slashSlashComments)
            {
                while let u = at(i), u != unit("\n") { i += 1 }
                emit(.comment, from: start)
            } else if c == unit("/") && next == unit("*") {
                i += 2
                while i < chars.count && !(chars[i] == unit("*") && at(i + 1) == unit("/")) { i += 1 }
                i = min(chars.count, i + 2)
                emit(.comment, from: start)
            } else if c == unit("'") || c == unit("\"") || c == unit("`") {
                var start = start
                var escapes = rules.backslashEscapes && !(c == unit("`") && rules.quotedIdentifiers)
                // E'…' (or e'…'): the E just read as a word belongs to the string.
                if c == unit("'"), rules.escapeStrings, let last = tokens.last, last.kind == .word,
                    last.text == "E" || last.text == "e", NSMaxRange(last.range) == i
                {
                    tokens.removeLast()
                    start = last.range.location
                    escapes = true
                }
                // U&'…' and U&"…" (PostgreSQL's Unicode escapes): the U& belongs to the string or name.
                if rules.escapeStrings, tokens.count >= 2, let amp = tokens.last, amp.text == "&",
                    NSMaxRange(amp.range) == i, case let u = tokens[tokens.count - 2], u.kind == .word,
                    u.text == "U" || u.text == "u", NSMaxRange(u.range) == amp.range.location
                {
                    tokens.removeLast(2)
                    start = u.range.location
                }
                i += 1
                while i < chars.count {
                    if chars[i] == unit("\\") && escapes {
                        i += 2
                        continue
                    }
                    if chars[i] == c {
                        if at(i + 1) == c && rules.doubledQuotes {
                            i += 2
                            continue
                        }  // doubled quote
                        i += 1
                        break
                    }
                    i += 1
                }
                i = min(i, chars.count)
                // Without quoted identifiers (the shell) every quote is a string.
                emit(c == unit("'") || !rules.quotedIdentifiers ? .string : .quotedIdentifier, from: start)
            } else if c == unit("[") && rules.bracketIdentifiers {
                // [name] runs to the next "]", spaces and all.
                i += 1
                while let u = at(i), u != unit("]") { i += 1 }
                i = min(chars.count, i + 1)
                emit(.quotedIdentifier, from: start)
            } else if c == unit("$") && rules.dollarQuotes, let tag = dollarTag(chars, at: i) {
                i += tag.count
                while i < chars.count
                    && !(chars[i] == unit("$") && Array(chars[i..<min(chars.count, i + tag.count)]) == tag)
                { i += 1 }
                i = min(chars.count, i + tag.count)
                emit(.string, from: start)
            } else if let scalar = Unicode.Scalar(c), CharacterSet.whitespacesAndNewlines.contains(scalar) {
                while let u = at(i), let s = Unicode.Scalar(u), CharacterSet.whitespacesAndNewlines.contains(s) {
                    i += 1
                }
                emit(.whitespace, from: start)
            } else if let scalar = Unicode.Scalar(c), CharacterSet.decimalDigits.contains(scalar) {
                while let u = at(i), let s = Unicode.Scalar(u), CharacterSet.decimalDigits.contains(s) || s == "." {
                    i += 1
                }
                // 0x1F, 0b101, 0o17 and 1_000: the letters and underscores belong to the number.
                if let u = at(i), let s = Unicode.Scalar(u),
                    s == "_" || (i - start == 1 && "xXbBoO".unicodeScalars.contains(s) && c == unit("0"))
                {
                    while let u = at(i), let s = Unicode.Scalar(u), CharacterSet.alphanumerics.contains(s) || s == "_" {
                        i += 1
                    }
                    emit(.number, from: start)
                    continue
                }
                // An exponent is part of the number: 1.5e-3, 2E10.
                if let e = at(i), e == unit("e") || e == unit("E") {
                    var j = i + 1
                    if let sign = at(j), sign == unit("+") || sign == unit("-") {
                        j += 1
                    }
                    if let d = at(j), let s = Unicode.Scalar(d), CharacterSet.decimalDigits.contains(s) {
                        i = j
                        while let u = at(i), let s = Unicode.Scalar(u), CharacterSet.decimalDigits.contains(s) {
                            i += 1
                        }
                    }
                }
                emit(.number, from: start)
            } else if isWordUnit(c) {
                while let u = at(i), isWordUnit(u) {
                    i += 1
                }
                emit(.word, from: start)
            } else {
                // A run of operator characters is one operator (<<, ->>, @>, !~*, :=, ::), as the servers read it,
                // up to a comment's start.
                i += 1
                if isOperatorUnit(c) {
                    while let u = at(i), isOperatorUnit(u), !startsComment(at: i) {
                        i += 1
                    }
                    // As PostgreSQL reads it: a trailing + or - is a sign of what follows (a=-1 is a = -1), unless
                    // the operator holds one of ~ ! @ # % ^ & | ? (@- stays one operator).
                    let run = String(utf16CodeUnits: Array(chars[start..<i]), count: i - start)
                    if !run.contains(where: { "~!@#%^&|?".contains($0) }) {
                        while i - start > 1, chars[i - 1] == unit("+") || chars[i - 1] == unit("-") {
                            i -= 1
                        }
                    }
                    // A prefix against a name after an operator starts that name: id=:id is "=" then ":id", and
                    // x=@@g is "=" then "@@g". Not "::", which casts.
                    if let last = Unicode.Scalar(chars[i - 1]), rules.prefixes.unicodeScalars.contains(last),
                        let next = at(i), isWordUnit(next) || next == unit("'") || next == unit("\"")
                    {
                        var prefixStart = i - 1
                        while prefixStart > start, chars[prefixStart - 1] == chars[i - 1] {
                            prefixStart -= 1
                        }
                        let isCast = last == ":" && i - prefixStart > 1
                        if prefixStart > start, !isCast {
                            i = prefixStart
                        }
                    }
                }
                emit(.punctuation, from: start)
            }
        }
        return tokens
    }

    private static func dollarTag(_ chars: [UInt16], at start: Int) -> [UInt16]? {
        var j = start + 1
        while j < chars.count, let s = Unicode.Scalar(chars[j]), CharacterSet.alphanumerics.contains(s) || s == "_" {
            j += 1
        }
        guard j < chars.count, chars[j] == "$".utf16.first! else { return nil }
        if j > start + 1, let s = Unicode.Scalar(chars[start + 1]), CharacterSet.decimalDigits.contains(s) {
            return nil
        }  // $1 parameter
        return Array(chars[start...j])
    }
}
