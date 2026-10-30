import BSON
import Foundation
import TabulaDrivers
import TabulaFoundation
import TabulaSQL

/// The MongoDB shell as a query language: the statements Tabula writes where it writes SQL for the other
/// databases (paging, counting, filtering and editing a collection in the grid), and how shell scripts are split,
/// formatted and highlighted.
public struct MongoQueryDialect: QueryDialect {
    public init() {}

    /// `//` comments; every quote is a string with backslash escapes.
    public var lexicalRules: LexicalRules {
        LexicalRules(
            dashDashComments: false,
            hashComments: false,
            slashSlashComments: true,
            backslashEscapes: true,
            escapeStrings: false,
            doubledQuotes: false,
            dollarQuotes: false,
            quotedIdentifiers: false
        )
    }

    public var sql: SQLDialect? { nil }
    /// Multi-document transactions need a replica set, which Tabula can't assume.
    public var beginTransaction: String? { nil }

    public func quoteIdentifier(_ name: String) -> String { MongoShell.quoted(name) }
    public func qualified(_ table: TableRef) -> String { MongoDialect.collection(table) }
    public func literal(_ value: String?) -> String { value.map(MongoShell.quoted) ?? "null" }
    public func selectPage(_ request: TablePageRequest) -> String { MongoDialect.selectPage(request) }
    public func countRows(_ table: TableRef, filter: String?) -> String {
        MongoDialect.countRows(table, filter: filter)
    }
    /// The shell writes binary values as BinData itself; a document's fields need no column list.
    public func insert(
        _ table: TableRef,
        values: [(column: String, value: String?)],
        binaryColumns: Set<String>
    )
        -> String
    {
        MongoDialect.insert(table, values: values)
    }
    public func selectSample(_ table: TableRef, limit: Int) -> String { MongoDialect.sample(table, limit: limit) }
    public func truncate(_ table: TableRef) -> String { MongoDialect.truncate(table) }
    public func drop(_ table: TableRef) -> String { MongoDialect.drop(table) }
    public func condition(_ rules: [FilterRule]) -> String { MongoDialect.condition(rules) }

    /// Updates and deletes match each document's `_id`; edited text is read back in the field's type.
    public func statements(for changes: TableChanges) throws -> [String] {
        func document(_ row: Int) throws -> String {
            guard let documents = changes.documents, documents.indices.contains(row) else {
                throw DatabaseError("Reload the collection and try again.")
            }
            return documents[row]
        }
        return try changes.deleted.sorted().map { try MongoChanges.delete(changes.table, document: document($0)) }
            + changes.updates.map { update in
                try MongoChanges.update(
                    changes.table,
                    row: .init(
                        document: document(update.row),
                        changes: Dictionary(uniqueKeysWithValues: update.values)
                    )
                )
            }
            + changes.insertions.map { MongoChanges.insert(changes.table, values: $0) }
    }
    public func statements(in script: String) -> [ScriptStatement] { MongoSplitter.statements(in: script) }
    public func beautify(_ script: String) -> String { MongoStatement.beautify(script) }
    public func applyingRowLimit(_ statement: String, limit: Int) -> String {
        MongoStatement.applyingRowLimit(statement, limit: limit)
    }

    public func readOnlyViolation(_ statement: String) -> String? {
        MongoReadOnlyCheck.violation(statement)
    }

    public func role(ofWord word: SQLToken) -> WordRole? {
        if word.text.hasPrefix("$") { return .operator }
        return MongoVocabulary.highlighted.contains(word.text) ? .keyword : nil
    }

    @MainActor
    public func completions(
        in text: String,
        caret: Int,
        catalog: any CompletionCatalog
    ) -> (range: NSRange, items: [String]) {
        MongoCompletion.suggestions(
            in: text,
            caret: caret,
            collections: catalog.tableNames,
            fields: { catalog.columnNames(of: SQLCompletion.TableName(name: $0)) }
        )
    }

    /// Shell statements name their collection after `db.`, which the assistant's schema already lists in full.
    public func referencedTables(in text: String) -> [SQLCompletion.TableName] { [] }
}

/// The statements behind `MongoQueryDialect`.
enum MongoDialect {
    /// `db.getSiblingDB("shop").users`: generated statements name the database, since a tab can outlive
    /// the sidebar's current one.
    static func collection(_ table: TableRef) -> String {
        "db.getSiblingDB(\(MongoShell.quoted(table.schema)))" + MongoStatement.collectionAccessor(table.name)
    }

    static func filterText(_ filter: String?) -> String {
        let trimmed = filter?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "{}" : trimmed
    }

    static func selectPage(_ request: TablePageRequest) -> String {
        var text = collection(request.table) + ".find(\(filterText(request.filter)))"
        if let orderBy = request.orderBy {
            if readsAsPath(orderBy) {
                return sortedByName(request, field: orderBy)
            }
            text += ".sort({ \(MongoShell.key(orderBy)): \(request.ascending ? 1 : -1) })"
        }
        return text + ".skip(\(request.offset)).limit(\(request.limit))"
    }

    /// A field named "a.b" or "$p": as a query key or a "$…" path it would mean the path a → b, or an operator.
    static func readsAsPath(_ field: String) -> Bool {
        field.contains(".") || field.hasPrefix("$")
    }

    /// The field's value read by its name.
    static func fieldByName(_ field: String) -> Document {
        ["$getField": ["field": ["$literal": field] as Document, "input": "$$ROOT"] as Document]
    }

    /// find() can only sort by a path, so a page sorted by such a field is an aggregation with a sort key.
    private static func sortedByName(_ request: TablePageRequest, field: String) -> String {
        let key = "__tabula_sort"
        let stages: [Document] = [
            ["$set": [key: fieldByName(field)] as Document],
            ["$sort": [key: Int32(request.ascending ? 1 : -1)] as Document],
            ["$skip": Int32(clamping: request.offset)],
            ["$limit": Int32(clamping: request.limit)],
            ["$unset": key],
        ]
        let rest = stages.map { MongoShell.format($0) }.joined(separator: ", ")
        return collection(request.table) + ".aggregate([{ $match: \(filterText(request.filter)) }, \(rest)])"
    }

    static func countRows(_ table: TableRef, filter: String?) -> String {
        // Views have no count metadata, and a filter needs real counting.
        let empty = filter?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        if empty && table.kind == .table {
            return collection(table) + ".estimatedDocumentCount()"
        }
        return collection(table) + ".countDocuments(\(filterText(filter)))"
    }

    static func sample(_ table: TableRef, limit: Int) -> String {
        "db" + MongoStatement.collectionAccessor(table.name) + ".find({}).limit(\(limit))"
    }

    static func truncate(_ table: TableRef) -> String { collection(table) + ".deleteMany({})" }
    static func drop(_ table: TableRef) -> String { collection(table) + ".drop()" }

    /// Values typed in the grid, as a document (each read as shell text, falling back to a string).
    static func insert(_ table: TableRef, values: [(column: String, value: String?)]) -> String {
        var document = Document()
        for (column, value) in values {
            document.appendValue(value.map(MongoChanges.typed) ?? Null(), forKey: column)
        }
        return collection(table) + ".insertOne(\(MongoShell.format(document)))"
    }

    // MARK: Filter builder

    /// The visual filter's rules as a query document; AND binds tighter than OR, as in the SQL version.
    static func condition(_ rules: [FilterRule]) -> String {
        let groups = FilterRule.groups(rules).map { group in group.map(condition) }
        func and(_ parts: [Document]) -> Document {
            parts.count == 1 ? parts[0] : ["$and": MongoDriver.array(parts)]
        }
        switch groups.count {
        case 0: return ""
        case 1: return MongoShell.format(and(groups[0]))
        default: return MongoShell.format(["$or": MongoDriver.array(groups.map(and))] as Document)
        }
    }

    static func condition(_ rule: FilterRule) -> Document {
        let field = rule.column
        let candidates = self.candidates(rule.value)
        func operand(_ op: String) -> Document {
            // Ranges compare within one type, so use the value as typed (a number stays a number).
            [field: [op: candidates.first ?? rule.value] as Document]
        }
        func pattern(_ prefix: String, _ suffix: String) -> String {
            prefix + NSRegularExpression.escapedPattern(for: rule.value) + suffix
        }
        if readsAsPath(field) {
            return conditionByName(rule, candidates: candidates, pattern: pattern)
        }
        /// Text matching as the SQL engines do it: strings (and arrays of strings, element by element) by the regex
        /// itself, and numbers, dates or ids by their text, which a regex alone never matches.
        func textMatch(_ pattern: String) -> Document {
            let asText: Document = [
                "$convert": ["input": "$" + field, "to": "string", "onError": Null(), "onNull": Null()] as Document
            ]
            let converted: Document = [
                "$expr": [
                    "$regexMatch": [
                        "input": ["$ifNull": [asText, ""] as Document] as Document, "regex": pattern, "options": "i",
                    ]
                        as Document
                ] as Document
            ]
            return [
                "$or": MongoDriver.array([
                    [field: RegularExpression(pattern: pattern, options: "i")] as Document, converted,
                ])
            ]
        }
        switch rule.op {
        case .equals:
            return candidates.count == 1
                ? [field: candidates[0]] : [field: ["$in": MongoDriver.array(candidates)] as Document]
        case .notEquals:
            return [field: ["$nin": MongoDriver.array(candidates)] as Document]
        case .less: return operand("$lt")
        case .greater: return operand("$gt")
        case .lessOrEqual: return operand("$lte")
        case .greaterOrEqual: return operand("$gte")
        case .contains: return textMatch(pattern("", ""))
        case .notContains: return ["$nor": MongoDriver.array([textMatch(pattern("", ""))])]
        case .startsWith: return textMatch(pattern("^", ""))
        case .endsWith: return textMatch(pattern("", "$"))
        case .isNull: return [field: Null()]
        case .isNotNull: return [field: ["$ne": Null()] as Document]
        case .inList:
            let items = rule.value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return [field: ["$in": MongoDriver.array(items.flatMap { Self.candidates($0) })] as Document]
        }
    }

    /// The same rule in $expr, for a field `readsAsPath`: its value is read with $getField, and every value
    /// compared with it is a $literal, so a "$x" string isn't read as a path either.
    private static func conditionByName(
        _ rule: FilterRule,
        candidates: [Primitive],
        pattern: (String, String) -> String
    ) -> Document {
        let value = fieldByName(rule.column)
        func literal(_ item: Primitive) -> Document { ["$literal": item] }
        func expression(_ body: Document) -> Document { ["$expr": body] }
        func isAny(_ items: [Primitive]) -> Document {
            ["$in": MongoDriver.array([value, MongoDriver.array(items.map(literal))])]
        }
        // A query reads a missing field as null too.
        let orNull: Document = ["$ifNull": MongoDriver.array([value, Null()])]
        func compare(_ op: String) -> Document {
            let operand = candidates.first ?? rule.value
            // A query's range compares within one type (numbers of any type together); $expr compares across types.
            let isNumber = operand is Int32 || operand is Int || operand is Double || operand is Decimal128
            let sameType: Document =
                isNumber
                ? ["$isNumber": value]
                : ["$eq": MongoDriver.array([["$type": value] as Document, ["$type": literal(operand)] as Document])]
            let comparison: Document = [op: MongoDriver.array([value, literal(operand)])]
            return expression(["$and": MongoDriver.array([sameType, comparison])])
        }
        func textMatch(_ regex: String) -> Document {
            let asText: Document = [
                "$convert": ["input": value, "to": "string", "onError": Null(), "onNull": Null()] as Document
            ]
            let input: Document = ["$ifNull": MongoDriver.array([asText, ""])]
            return expression(["$regexMatch": ["input": input, "regex": regex, "options": "i"] as Document])
        }
        switch rule.op {
        case .equals: return expression(isAny(candidates))
        case .notEquals: return expression(["$not": MongoDriver.array([isAny(candidates)])])
        case .less: return compare("$lt")
        case .greater: return compare("$gt")
        case .lessOrEqual: return compare("$lte")
        case .greaterOrEqual: return compare("$gte")
        case .contains: return textMatch(pattern("", ""))
        case .notContains: return ["$nor": MongoDriver.array([textMatch(pattern("", ""))])]
        case .startsWith: return textMatch(pattern("^", ""))
        case .endsWith: return textMatch(pattern("", "$"))
        case .isNull: return expression(["$eq": MongoDriver.array([orNull, Null()])])
        case .isNotNull: return expression(["$ne": MongoDriver.array([orNull, Null()])])
        case .inList:
            let items = rule.value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return expression(isAny(items.flatMap { Self.candidates($0) }))
        }
    }

    /// What typed text may mean: `42` matches the number or the string "42", a 24-digit hex id the ObjectId
    /// or the string, an ISO date the date or the string. Quoted text and shell values mean exactly that.
    static func candidates(_ text: String) -> [Primitive] {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.first == "\"" || trimmed.first == "'", let string = try? MongoShell.parseValue(trimmed) as? String {
            return [string]
        }
        if trimmed.count == 24, let id = ObjectId(trimmed) {
            return [id, trimmed]
        }
        if trimmed.count >= 10, trimmed.first?.isNumber == true, trimmed.contains("-"),
            let date = MongoDates.parse(trimmed)
        {
            return [date, trimmed]
        }
        if let value = try? MongoShell.parseValue(trimmed), !(value is Document) {
            switch value {
            case is Int32, is Int:
                // Integers compare with decimals by value already.
                return [value, trimmed]
            case is Double:
                // A decimal field holds 0.1000 exactly, which no double equals; the decimal form finds it.
                guard let decimal = MongoDecimal.parse(trimmed) else {
                    return [value, trimmed]
                }
                return [value, decimal, trimmed]
            case is Bool: return [value, trimmed]
            case is String: return [value]
            default: return [value]
            }
        }
        return [trimmed]
    }
}

/// Grid edits on documents as update, delete and insert statements.
///
/// Cells show plain text; each row also carries its whole document, so an edited value is read back in the
/// field's existing type (a long stays a long, a date stays a date).
public enum MongoChanges {
    public struct Row: Sendable {
        /// The row's document as shell text (`QueryResult.documents`).
        public var document: String
        /// Column → new text (nil for null).
        public var changes: [String: String?]

        public init(document: String, changes: [String: String?]) {
            self.document = document
            self.changes = changes
        }
    }

    public static func update(_ table: TableRef, row: Row) throws -> String {
        let document = try MongoShell.parseDocument(row.document)
        guard let id = document["_id"] else {
            throw DatabaseError("This document has no _id, so it can't be edited here.")
        }
        let changes = row.changes.sorted(by: { $0.key < $1.key })
        var set = Document()
        // $set reads "a.b" as a path and refuses "$a": fields named like that are set by name, with $setField
        // (MongoDB 5), one pipeline stage each.
        var stages = Document(isArray: true)
        for (field, text) in changes {
            let value = try value(text, original: document[field], field: field)
            set.appendValue(value, forKey: field)
            // $literal, so neither a "$p" name nor a "$x" string value reads as a field path.
            let named: Document = [
                "field": ["$literal": field] as Document,
                "input": "$$ROOT",
                "value": ["$literal": value] as Document,
            ]
            stages.append(["$replaceWith": ["$setField": named] as Document] as Document)
        }
        let byName = changes.contains { $0.key.contains(".") || $0.key.hasPrefix("$") }
        let update: Document = byName ? stages : ["$set": set]
        return MongoDialect.collection(table)
            + ".updateOne(\(MongoShell.format(["_id": id] as Document)), \(MongoShell.format(update)))"
    }

    public static func delete(_ table: TableRef, document text: String) throws -> String {
        let document = try MongoShell.parseDocument(text)
        guard let id = document["_id"] else {
            throw DatabaseError("This document has no _id, so it can't be deleted here.")
        }
        return MongoDialect.collection(table) + ".deleteOne(\(MongoShell.format(["_id": id] as Document)))"
    }

    public static func insert(_ table: TableRef, values: [(column: String, value: String?)]) -> String {
        MongoDialect.insert(table, values: values)
    }

    /// Replaces a whole document (the document editor's Save), matched by its original `_id`.
    public static func replace(_ table: TableRef, original: String, with text: String) throws -> String {
        let old = try MongoShell.parseDocument(original)
        let new = try MongoShell.parseDocument(text)
        guard let id = old["_id"] else {
            throw DatabaseError("This document has no _id, so it can't be replaced.")
        }
        return MongoDialect.collection(table)
            + ".replaceOne(\(MongoShell.format(["_id": id] as Document)), \(MongoShell.format(new)))"
    }

    /// Inserts a document written in the editor.
    public static func insertDocument(_ table: TableRef, text: String) throws -> String {
        MongoDialect.collection(table) + ".insertOne(\(MongoShell.format(try MongoShell.parseDocument(text))))"
    }

    /// Text typed into a cell, in the type the field had.
    static func value(_ text: String?, original: Primitive?, field: String) throws -> Primitive {
        guard let text else {
            return Null()
        }
        func invalid(_ kind: String) -> DatabaseError {
            DatabaseError(
                "“\(text)” isn't \(kind) for \(field). Type a shell value such as \"text\" to change the field's type."
            )
        }
        let parsed = try? MongoShell.parseValue(text)
        switch original {
        case nil, is Null:
            return typed(text)
        case is String:
            return text
        case is Decimal128:
            // Read straight as a decimal, never through a double, so every digit is kept.
            if let decimal = MongoDecimal.parse(text) {
                return decimal
            }
            guard let parsed else {
                throw invalid("a number")
            }
            return parsed
        case is Int32, is Int, is Double:
            guard let parsed else {
                throw invalid("a number")
            }
            return coerce(parsed, like: original!)
        case is Date:
            if let date = MongoDates.parse(text) {
                return date
            }
            guard let parsed else {
                throw invalid("a date")
            }
            return parsed
        case is ObjectId:
            if let id = ObjectId(text.trimmingCharacters(in: .whitespaces)) {
                return id
            }
            guard let parsed else {
                throw invalid("an ObjectId")
            }
            return parsed
        default:
            guard let parsed else {
                throw invalid("a valid value")
            }
            return parsed
        }
    }

    /// A plain number typed over a number keeps the field's numeric type when it fits exactly.
    static func coerce(_ value: Primitive, like original: Primitive) -> Primitive {
        guard let number = MongoShellParser.double(value), !(value is String) else {
            return value
        }
        switch original {
        case is Int:
            if let int = value as? Int32 {
                return Int(int)
            }
            return value
        case is Double:
            return value is Int32 || value is Int ? number : value
        case is Decimal128:
            if value is Int32 || value is Int || value is Double,
                let decimal = MongoDecimal.parse(MongoShell.cell(value) ?? "")
            {
                return decimal
            }
            return value
        default:
            return value
        }
    }

    /// Text in a field with no type yet: a shell value when it reads as one, otherwise a string. A number counts
    /// only when it reads back the same, so "02134" or a 20-digit account number stays text.
    /// The fields of `document` as cells for a copy of it (Duplicate Row, INSERT export), keyed by their index in
    /// `columns`: a value's cell text where that reads back as the same value, otherwise the value as the shell
    /// writes it (NumberDecimal("0.1000"), ISODate(…), NumberLong(5), "5" for a string of digits), so the copy
    /// keeps every type. Fields the document lacks are left out.
    public static func cellsForCopy(of document: String, columns: [String]) throws -> [Int: String?] {
        let parsed = try MongoShell.parseDocument(document)
        var cells: [Int: String?] = [:]
        for (index, column) in columns.enumerated() {
            guard let value = parsed[column] else { continue }
            cells[index] = .some(cellForCopy(value))
        }
        return cells
    }

    /// Every document's cells for a copy (`cellsForCopy`), a missing field as null, for an INSERT export.
    public static func rowsForCopy(of documents: DocumentTexts, columns: [String]) throws -> [[String?]] {
        try documents.map { document in
            let cells = try cellsForCopy(of: document, columns: columns)
            return columns.indices.map { cells[$0] ?? nil }
        }
    }

    private static func cellForCopy(_ value: Primitive) -> String? {
        guard let plain = MongoShell.cell(value) else {
            return nil
        }
        // The same value back means the same text from the shell's own writer.
        return MongoShell.format(typed(plain)) == MongoShell.format(value) ? plain : MongoShell.format(value)
    }

    static func typed(_ text: String) -> Primitive {
        guard let value = try? MongoShell.parseValue(text) else {
            return text
        }
        if value is Int32 || value is Int || value is Double,
            MongoShell.cell(value) != text.trimmingCharacters(in: .whitespaces)
        {
            return text
        }
        return value
    }
}
