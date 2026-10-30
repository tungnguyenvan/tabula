import Foundation
import TabulaFoundation

/// Edits made in a table's grid, waiting to be committed. Each dialect writes them its own way: SQL matches rows by
/// primary key, the MongoDB shell by each document's `_id`.
public struct TableChanges: Sendable {
    public var table: TableRef
    public var columns: [String]
    /// The rows as loaded, before any change.
    public var rows: [[String?]]
    /// MongoDB: each row's whole document as shell text.
    public var documents: DocumentTexts?
    /// Indices of the primary key's columns in `columns`.
    public var keyColumns: [Int]
    public var deleted: Set<Int>
    /// New values by row and column index; nil sets NULL.
    public var edited: [Int: [Int: String?]]
    public var inserted: [[Int: String?]]
    /// Columns whose values are bytes (`QueryResult.binaryColumns`), written as hex literals.
    public var binaryColumns: Set<Int>

    public init(
        table: TableRef,
        columns: [String],
        rows: [[String?]],
        documents: DocumentTexts?,
        keyColumns: [Int],
        deleted: Set<Int>,
        edited: [Int: [Int: String?]],
        inserted: [[Int: String?]],
        binaryColumns: Set<Int>
    ) {
        self.table = table
        self.columns = columns
        self.rows = rows
        self.documents = documents
        self.keyColumns = keyColumns
        self.deleted = deleted
        self.edited = edited
        self.binaryColumns = binaryColumns
        self.inserted = inserted
    }

    /// Edited rows that aren't also deleted, in row order, with their changes in column order.
    public var updates: [(row: Int, values: [(column: String, value: String?)])] {
        edited.keys.sorted().filter { !deleted.contains($0) }
            .map { row in
                (row, (edited[row] ?? [:]).sorted { $0.key < $1.key }.map { (columns[$0.key], $0.value) })
            }
    }

    public var insertions: [[(column: String, value: String?)]] {
        inserted.map { values in values.sorted { $0.key < $1.key }.map { (columns[$0.key], $0.value) } }
    }
}

/// One statement of a commit, with how to tell it reached exactly its row.
public struct PlannedStatement: Sendable, Equatable {
    public var sql: String
    /// The page row it changes or deletes, for the message when it doesn't find that row.
    public var row: Int?
    /// A count query that must answer 1 before the statement runs.
    public var check: String?
    /// The statement itself must report exactly one affected row.
    public var mustAffectOne: Bool

    public init(sql: String, row: Int? = nil, check: String? = nil, mustAffectOne: Bool = false) {
        self.sql = sql
        self.row = row
        self.check = check
        self.mustAffectOne = mustAffectOne
    }
}

/// How a highlighted word reads in a query language.
public enum WordRole: Sendable, Equatable {
    /// A keyword or a method of the language (`SELECT`, `find`).
    case keyword
    /// An operator written as a word (`$match`, `$gt`).
    case `operator`
}

/// One database's query language: how names and values are written, the statements Tabula generates to browse
/// and change tables, and how scripts are split, formatted and highlighted.
///
/// Every engine supplies its own (a strategy), and a driver hands out the one for its database, so code that works
/// with any database asks the dialect instead of branching on the database kind.
public protocol QueryDialect: Sendable {
    /// What starts comments, strings and quoted names, for the lexer.
    var lexicalRules: LexicalRules { get }

    /// The SQL dialect when the language is SQL: what writes rows by primary key, runs transactions and parses
    /// SQL. Nil for languages that work differently (the MongoDB shell).
    var sql: SQLDialect? { get }

    /// The statement that starts a transaction, or nil when changes can't be grouped into one.
    var beginTransaction: String? { get }

    func quoteIdentifier(_ name: String) -> String
    func qualified(_ table: TableRef) -> String
    /// A value as a literal; nil is the language's null.
    func literal(_ value: String?) -> String

    func selectPage(_ request: TablePageRequest) -> String
    func countRows(_ table: TableRef, filter: String?) -> String
    /// `binaryColumns` names the columns whose values are bytes, written as the language's hex literals.
    func insert(_ table: TableRef, values: [(column: String, value: String?)], binaryColumns: Set<String>) -> String
    /// What the sidebar's "open in a query tab" puts in the editor.
    func selectSample(_ table: TableRef, limit: Int) -> String
    func truncate(_ table: TableRef) -> String
    func drop(_ table: TableRef) -> String
    /// The filter bar's rules as a condition for `selectPage` / `countRows`. Rules missing a needed value are skipped.
    func condition(_ rules: [FilterRule]) -> String
    /// The statements that apply a grid's pending changes, in the order they run: deletes, updates, inserts.
    func statements(for changes: TableChanges) throws -> [String]

    func statements(in script: String) -> [ScriptStatement]
    func beautify(_ script: String) -> String
    /// Limits a reading statement that sets no limit of its own, so an accidental full read stays small.
    /// Anything else is returned unchanged.
    func applyingRowLimit(_ statement: String, limit: Int) -> String
    /// Why the assistant may not run `statement`, or nil when it only reads.
    func readOnlyViolation(_ statement: String) -> String?
    /// How a word token is highlighted, or nil for a plain name.
    func role(ofWord word: SQLToken) -> WordRole?

    /// Suggestions for the word at `caret` (a UTF-16 offset): the range they replace and the candidates, best first.
    @MainActor
    func completions(in text: String, caret: Int, catalog: any CompletionCatalog) -> (range: NSRange, items: [String])
    /// The tables a statement reads or writes, for focusing what the assistant is told.
    func referencedTables(in text: String) -> [SQLCompletion.TableName]
}

/// The names completion offers, as the workspace knows them so far. Read on the main actor, where the editor runs.
@MainActor
public protocol CompletionCatalog {
    var tableNames: [String] { get }
    var schemaNames: [String] { get }
    /// Columns of every table whose columns are loaded, for statements that name no table yet.
    var allColumnNames: [String] { get }
    /// A table's columns, or nil while they aren't loaded.
    func columnNames(of table: SQLCompletion.TableName) -> [String]?
    /// Another schema's tables, or nil while they aren't loaded.
    func tableNames(inSchema schema: String) -> [String]?
}

extension QueryDialect {
    public func split(_ script: String) -> [String] {
        statements(in: script).map(\.text)
    }

    /// The statement under `location` (a UTF-16 offset, such as the caret). A caret in the blank space or comment
    /// after a statement belongs to that statement, matching how people place the cursor.
    public func statement(at location: Int, in script: String) -> ScriptStatement? {
        let all = statements(in: script)
        if let containing = all.first(where: { location >= $0.range.location && location <= NSMaxRange($0.range) }) {
            return containing
        }
        return all.last(where: { $0.range.location <= location }) ?? all.first
    }

    public func tokens(_ text: String) -> [SQLToken] {
        SQLLexer.tokens(text, rules: lexicalRules)
    }
}
