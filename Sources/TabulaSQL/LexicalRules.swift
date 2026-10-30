import Foundation
import TabulaFoundation

/// What starts a comment, a string or a quoted name in a query language. The lexer reads every language Tabula
/// highlights with these rules instead of asking which database it is for.
public struct LexicalRules: Sendable, Equatable {
    /// Whether `--` at `index` of `units` starts a comment under these rules.
    public func startsDashDashComment(_ units: [UInt16], at index: Int) -> Bool {
        let dash = UInt16(UInt8(ascii: "-"))
        guard dashDashComments, index + 1 < units.count, units[index] == dash, units[index + 1] == dash else {
            return false
        }
        guard dashDashNeedsSpace, index + 2 < units.count else {
            return true
        }
        // MySQL: a space, a tab, a line break or another control character.
        return units[index + 2] <= 0x20
    }

    /// `-- comment` to the end of the line.
    public var dashDashComments: Bool
    /// `--` starts a comment only before a space, tab or line break (MySQL; `a--b` is a minus minus b).
    public var dashDashNeedsSpace: Bool
    /// `# comment` to the end of the line (MySQL).
    public var hashComments: Bool
    /// `// comment` to the end of the line (the MongoDB shell).
    public var slashSlashComments: Bool
    /// A backslash escapes the next character inside strings (MySQL, the shell). Never inside a backtick
    /// quoted name of SQL, which ends at the next backtick.
    public var backslashEscapes: Bool
    /// `E'…'` strings, where a backslash escapes the next character although other strings don't (PostgreSQL).
    public var escapeStrings: Bool
    /// A doubled quote stands for one quote inside quotes (SQL).
    public var doubledQuotes: Bool
    /// `$tag$ … $tag$` bodies (PostgreSQL).
    public var dollarQuotes: Bool
    /// `"name"` and `` `name` `` are names rather than strings (SQL).
    public var quotedIdentifiers: Bool
    /// `[name]` is a name (SQLite, as in SQL Server).
    public var bracketIdentifiers: Bool

    public init(
        dashDashComments: Bool,
        hashComments: Bool,
        slashSlashComments: Bool,
        backslashEscapes: Bool,
        escapeStrings: Bool,
        doubledQuotes: Bool,
        dollarQuotes: Bool,
        quotedIdentifiers: Bool,
        bracketIdentifiers: Bool = false,
        dashDashNeedsSpace: Bool = false
    ) {
        self.dashDashComments = dashDashComments
        self.dashDashNeedsSpace = dashDashNeedsSpace
        self.hashComments = hashComments
        self.slashSlashComments = slashSlashComments
        self.backslashEscapes = backslashEscapes
        self.escapeStrings = escapeStrings
        self.doubledQuotes = doubledQuotes
        self.dollarQuotes = dollarQuotes
        self.quotedIdentifiers = quotedIdentifiers
        self.bracketIdentifiers = bracketIdentifiers
    }
}

/// The SQL variants Tabula reads and writes. They differ in quoting, comments and a few statements; everything
/// that depends on the variant asks the flavor rather than the database kind.
public enum SQLFlavor: Sendable, Equatable, CaseIterable {
    case postgres, mysql, sqlite

    public var lexicalRules: LexicalRules {
        LexicalRules(
            dashDashComments: true,
            hashComments: self == .mysql,
            slashSlashComments: false,
            backslashEscapes: self == .mysql,
            escapeStrings: self == .postgres,
            doubledQuotes: true,
            dollarQuotes: self == .postgres,
            quotedIdentifiers: true,
            bracketIdentifiers: self == .sqlite,
            dashDashNeedsSpace: self == .mysql
        )
    }

    /// The SQL flavor of a database kind, or nil for the document and key-value stores.
    public init?(_ kind: DatabaseKind) {
        switch kind {
        case .postgres: self = .postgres
        case .mysql: self = .mysql
        case .sqlite: self = .sqlite
        case .mongodb, .redis: return nil
        }
    }
}
