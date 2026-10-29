import Foundation
import TabulaDrivers
import TabulaFoundation
import TabulaSQL

/// Completion for shell statements: collections after `db.`, methods after a collection or call,
/// field names and `$` operators inside documents.
public enum MongoCompletion {
    /// The range the chosen item replaces (UTF-16, like NSTextView) and the candidates, best first.
    public static func suggestions(
        in text: String,
        caret: Int,
        collections: [String],
        fields: (String) -> [String]?
    ) -> (range: NSRange, items: [String]) {
        let string = text as NSString
        let caret = min(max(0, caret), string.length)
        var start = caret
        while start > 0, isWordUnit(string.character(at: start - 1)) { start -= 1 }
        let range = NSRange(location: start, length: caret - start)
        let partial = string.substring(with: range)
        let before = string.substring(to: start)
        let statement = currentStatement(before)
        if isInsideString(statement) { return (range, []) }

        // Groups in priority order; each is sorted shortest first.
        let candidates: [[String]]
        if before.hasSuffix(".") {
            candidates =
                members(after: String(before.dropLast())).map { [$0] } ?? [
                    collections, MongoVocabulary.databaseMethods,
                ]
        } else if partial.hasPrefix("$") {
            candidates = [MongoVocabulary.operators]
        } else if statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            candidates = [MongoVocabulary.statementStarts]
        } else if statement.trimmingCharacters(in: .whitespaces) == "show" || statement.hasSuffix("show ") {
            candidates = [MongoVocabulary.showTargets]
        } else if partial.isEmpty {
            return (range, [])
        } else {
            let known = collection(in: statement).flatMap(fields) ?? []
            // At a key position (after `{` or `,`) fields matter most; elsewhere values come first.
            let atKey =
                statement.trimmingCharacters(in: .whitespacesAndNewlines).last.map { "{,".contains($0) } ?? false
            candidates =
                atKey
                ? [known, MongoVocabulary.constructors]
                : [MongoVocabulary.constructors + MongoVocabulary.literals, known]
        }
        return (range, rank(candidates, partial: partial))
    }

    /// What may follow `text.`: database methods and collections after `db`, collection methods after a
    /// collection, cursor methods after a call. Nil means "after db".
    private static func members(after text: String) -> [String]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix(")") {
            // After db.getCollection("x") or db.getSiblingDB("x") comes a collection's or a database's members.
            if let call = lastCall(trimmed) {
                if call == "getCollection" { return MongoVocabulary.collectionMethods }
                if call == "getSiblingDB" { return nil }
            }
            return MongoVocabulary.cursorMethods
        }
        var end = trimmed.endIndex
        while end > trimmed.startIndex, isWordCharacter(trimmed[trimmed.index(before: end)]) {
            end = trimmed.index(before: end)
        }
        let word = String(trimmed[end...])
        if word == "db" { return nil }
        // `db.users.` (or `db.system.profile.`): a collection.
        let head = trimmed[..<end]
        if head.hasSuffix("."), head.dropLast().hasSuffix("db") || head.contains("db.") {
            return MongoVocabulary.collectionMethods
        }
        return []
    }

    private static func lastCall(_ text: String) -> String? {
        var depth = 0
        var index = text.endIndex
        while index > text.startIndex {
            index = text.index(before: index)
            if text[index] == ")" {
                depth += 1
            } else if text[index] == "(" {
                depth -= 1
                if depth == 0 {
                    var start = index
                    while start > text.startIndex, isWordCharacter(text[text.index(before: start)]) {
                        start = text.index(before: start)
                    }
                    return String(text[start..<index])
                }
            }
        }
        return nil
    }

    /// The collection the statement works on: `db.name.` or `db.getCollection("name").`.
    private static let collectionPatterns: [NSRegularExpression] = [
        #"db\s*\.\s*getCollection\(\s*["']([^"']+)["']\s*\)"#,
        #"db\s*\.\s*([A-Za-z_$][\w$.]*?)\s*\.\s*[A-Za-z_$]\w*\s*\("#,
    ]
    .compactMap { try? NSRegularExpression(pattern: $0) }

    static func collection(in statement: String) -> String? {
        for regex in collectionPatterns {
            guard
                let match = regex.firstMatch(
                    in: statement,
                    range: NSRange(location: 0, length: (statement as NSString).length)
                ),
                match.numberOfRanges > 1
            else { continue }
            let name = (statement as NSString).substring(with: match.range(at: 1))
            if !MongoStatement.databaseMethods.contains(name) { return name }
        }
        return nil
    }

    /// The text of the statement the caret is in, up to the caret.
    private static func currentStatement(_ before: String) -> String {
        // A marker at the caret lets the splitter decide whether the caret continues a statement or starts one.
        let marker = "\u{1}"
        guard let last = MongoSplitter.statements(in: before + marker).last?.text, last.hasSuffix(marker) else {
            return ""
        }
        return String(last.dropLast())
    }

    private static func isInsideString(_ text: String) -> Bool {
        var quote: Character?
        var escaped = false
        for character in text {
            if escaped {
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            if let open = quote {
                if character == open { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            }
        }
        return quote != nil
    }

    private static func rank(_ groups: [[String]], partial: String) -> [String] {
        let lowered = partial.lowercased()
        var seen = Set<String>()
        return
            groups.flatMap { group in
                group.filter { $0.lowercased().hasPrefix(lowered) && $0.count > partial.count }
                    .sorted { ($0.count, $0) < ($1.count, $1) }
            }
            .filter { seen.insert($0).inserted }
    }

    private static func isWordUnit(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return true }
        return CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "$"
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_" || character == "$"
    }
}
