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
    public func insert(_ table: TableRef, values: [(column: String, value: String?)]) -> String {
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
            text += ".sort({ \(MongoShell.key(orderBy)): \(request.ascending ? 1 : -1) })"
        }
        return text + ".skip(\(request.offset)).limit(\(request.limit))"
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
        var groups: [[Document]] = []
        for rule in rules where !rule.op.needsValue || !rule.value.isEmpty {
            if groups.isEmpty || rule.conjunction == .or {
                groups.append([])
            }
            groups[groups.count - 1].append(condition(rule))
        }
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
        func pattern(_ prefix: String, _ suffix: String) -> RegularExpression {
            RegularExpression(
                pattern: prefix + NSRegularExpression.escapedPattern(for: rule.value) + suffix,
                options: "i"
            )
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
        case .contains: return [field: pattern("", "")]
        case .notContains: return [field: ["$not": pattern("", "")] as Document]
        case .startsWith: return [field: pattern("^", "")]
        case .endsWith: return [field: pattern("", "$")]
        case .isNull: return [field: Null()]
        case .isNotNull: return [field: ["$ne": Null()] as Document]
        case .inList:
            let items = rule.value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return [field: ["$in": MongoDriver.array(items.flatMap { Self.candidates($0) })] as Document]
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
            case is Int32, is Int, is Double: return [value, trimmed]
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
        var set = Document()
        for (field, text) in row.changes.sorted(by: { $0.key < $1.key }) {
            set.appendValue(try value(text, original: document[field], field: field), forKey: field)
        }
        let update: Document = ["$set": set]
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
        guard let id = old["_id"] else { throw DatabaseError("This document has no _id, so it can't be replaced.") }
        return MongoDialect.collection(table)
            + ".replaceOne(\(MongoShell.format(["_id": id] as Document)), \(MongoShell.format(new)))"
    }

    /// Inserts a document written in the editor.
    public static func insertDocument(_ table: TableRef, text: String) throws -> String {
        MongoDialect.collection(table) + ".insertOne(\(MongoShell.format(try MongoShell.parseDocument(text))))"
    }

    /// Text typed into a cell, in the type the field had.
    static func value(_ text: String?, original: Primitive?, field: String) throws -> Primitive {
        guard let text else { return Null() }
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
            guard let parsed else { throw invalid("a number") }
            return parsed
        case is Int32, is Int, is Double:
            guard let parsed else { throw invalid("a number") }
            return coerce(parsed, like: original!)
        case is Date:
            if let date = MongoDates.parse(text) {
                return date
            }
            guard let parsed else { throw invalid("a date") }
            return parsed
        case is ObjectId:
            if let id = ObjectId(text.trimmingCharacters(in: .whitespaces)) {
                return id
            }
            guard let parsed else { throw invalid("an ObjectId") }
            return parsed
        default:
            guard let parsed else { throw invalid("a valid value") }
            return parsed
        }
    }

    /// A plain number typed over a number keeps the field's numeric type when it fits exactly.
    static func coerce(_ value: Primitive, like original: Primitive) -> Primitive {
        guard let number = MongoShellParser.double(value), !(value is String) else { return value }
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
    static func typed(_ text: String) -> Primitive {
        guard let value = try? MongoShell.parseValue(text) else { return text }
        if value is Int32 || value is Int || value is Double,
            MongoShell.cell(value) != text.trimmingCharacters(in: .whitespaces)
        {
            return text
        }
        return value
    }
}
