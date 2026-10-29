import Foundation
import TabulaFoundation

/// What starts a comment, a string or a quoted name in a query language. The lexer reads every language Tabula
/// highlights with these rules instead of asking which database it is for.
public struct LexicalRules: Sendable, Equatable {
    /// `-- comment` to the end of the line.
    public var dashDashComments: Bool
    /// `# comment` to the end of the line (MySQL).
    public var hashComments: Bool
    /// `// comment` to the end of the line (the MongoDB shell).
    public var slashSlashComments: Bool
    /// A backslash escapes the next character inside quotes (MySQL, the shell).
    public var backslashEscapes: Bool
    /// A doubled quote stands for one quote inside quotes (SQL).
    public var doubledQuotes: Bool
    /// `$tag$ … $tag$` bodies (PostgreSQL).
    public var dollarQuotes: Bool
    /// `"name"` and `` `name` `` are names rather than strings (SQL).
    public var quotedIdentifiers: Bool

    public init(
        dashDashComments: Bool,
        hashComments: Bool,
        slashSlashComments: Bool,
        backslashEscapes: Bool,
        doubledQuotes: Bool,
        dollarQuotes: Bool,
        quotedIdentifiers: Bool
    ) {
        self.dashDashComments = dashDashComments
        self.hashComments = hashComments
        self.slashSlashComments = slashSlashComments
        self.backslashEscapes = backslashEscapes
        self.doubledQuotes = doubledQuotes
        self.dollarQuotes = dollarQuotes
        self.quotedIdentifiers = quotedIdentifiers
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
            doubledQuotes: true,
            dollarQuotes: self == .postgres,
            quotedIdentifiers: true
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
