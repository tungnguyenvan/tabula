import Foundation

/// Decides whether a PostgreSQL query's result rows can be edited in place: the query must provably read one
/// instance of one table and project its columns directly.
///
/// This is a whitelist of a small grammar, not a hunt for banned keywords:
///
///     SELECT item [, item ...]            item: * | ref.* | column [[AS] alias]   column: [ref.]name
///     FROM [schema.]table [[AS] alias]
///     [WHERE predicate]                   columns, literals, comparisons, arithmetic, parentheses,
///                                         AND / OR / NOT, IS [NOT] NULL|TRUE|FALSE,
///                                         [NOT] IN (literal, ...), [NOT] BETWEEN, [NOT] LIKE|ILIKE
///     [ORDER BY column [ASC|DESC] [NULLS FIRST|LAST], ...]
///     [LIMIT integer] [OFFSET integer]    in either order
///     [;]
///
/// Anything else — joins, subqueries, CTEs, function calls, casts, typed or escape-string literals, parameters,
/// block comments, set operations, locking clauses, a second statement — answers false. When in doubt the
/// answer is false, which only means the result stays read-only.
///
/// Passing does not check names against the catalog: a bare name may still be a whole-row reference
/// (`SELECT t FROM t`) or `ref.name` attribute notation for a function, so the caller should confirm through
/// result metadata (table OID and column number) that every result column really is a column of the table.
public struct EditableSelect: Sendable {
    public static func accepts(_ sql: String, flavor: SQLFlavor = .postgres) -> Bool { source(sql, flavor: flavor) != nil }

    /// The FROM relation of an accepted query, decoded to the names PostgreSQL resolves (unquoted folded to lower
    /// case, quoted taken verbatim): `[table]` or `[schema, table]`. Nil whenever `accepts` is false. The caller
    /// should still resolve it (e.g. via regclass) and confirm it is a plain table matching the result metadata.
    public static func source(_ sql: String, flavor: SQLFlavor = .postgres) -> [String]? {
        relation(sql, flavor: flavor)?.names
    }

    public struct Relation: Sendable {
        public let names: [String]
        public let reference: String
    }

    public static func relation(_ sql: String, flavor: SQLFlavor = .postgres) -> Relation? {
        guard flavor == .postgres || flavor == .mysql, let tokens = significantTokens(sql, flavor: flavor) else { return nil }
        var parser = Parser(tokens: tokens, flavor: flavor)
        do {
            try parser.statement()
        } catch {
            return nil
        }
        return Relation(names: parser.relation, reference: parser.reference ?? "")
    }

    // MARK: - Lexical checks

    /// The tokens that matter, or nil when the text holds anything whose meaning to PostgreSQL is uncertain,
    /// including places where `SQLLexer` and the server's lexer could disagree.
    static func significantTokens(_ sql: String, flavor: SQLFlavor = .postgres) -> [SQLToken]? {
        let all = SQLLexer.tokens(sql, flavor: flavor)
        for (index, token) in all.enumerated() {
            guard isLexicallySafe(token, flavor: flavor) else { return nil }
            if index + 1 < all.count, !canAdjoin(token, all[index + 1]) { return nil }
        }
        return all.filter { $0.kind != .whitespace && $0.kind != .comment }
    }

    private static let whitespace: Set<Unicode.Scalar> = [" ", "\t", "\n", "\r", "\u{0C}"]
    private static let punctuation: Set<String> = [",", ".", ";", "(", ")", "*", "=", "<", ">", "<=", ">=", "<>", "!=",
                                                   "+", "-", "/", "%"]
    /// Tokens made of PostgreSQL operator characters; adjacent ones would lex as one longer operator.
    private static let operators: Set<String> = ["*", "=", "<", ">", "<=", ">=", "<>", "!=", "+", "-", "/", "%"]
    static let comparisons: Set<String> = ["=", "<", ">", "<=", ">=", "<>", "!="]

    private static func isLexicallySafe(_ token: SQLToken, flavor: SQLFlavor) -> Bool {
        let scalars = token.text.unicodeScalars
        guard !scalars.contains("\0") else { return false }
        switch token.kind {
        case .whitespace:
            // The lexer also counts Unicode spaces (e.g. NBSP) as whitespace; PostgreSQL does not.
            return scalars.allSatisfy { whitespace.contains($0) }
        case .comment:
            // Block comments nest in PostgreSQL but not in SQLLexer, so refuse them outright. A line comment
            // ends at \r for the server but only at \n for the lexer.
            guard !scalars.contains("\r") else { return false }
            if flavor == .mysql {
                // MySQL requires whitespace after --; # comments are unambiguous. Never executable /*! */.
                return token.text.hasPrefix("#") || (token.text.hasPrefix("--") && token.text.dropFirst(2).first.map { $0 == " " || $0 == "\t" || $0 == "\n" } == true)
            }
            return token.text.hasPrefix("--")
        case .string:
            // Plain '...' only: no dollar quoting, and no backslash, whose meaning depends on
            // standard_conforming_strings.
            return token.text.hasPrefix("'") && !scalars.contains("\\") && quotedBody(token.text) != nil
        case .quotedIdentifier:
            return quotedName(token.text, flavor: flavor) != nil
        case .number:
            return isDecimal(token.text)
        case .word:
            return isPlainWord(token.text)
        case .punctuation:
            return punctuation.contains(token.text)
        }
    }

    private static func canAdjoin(_ left: SQLToken, _ right: SQLToken) -> Bool {
        let atoms: [SQLToken.Kind] = [.word, .number, .string, .quotedIdentifier]
        // E'..', B'..', X'..', N'..', date'..', 1e5, 0x1F, 1_000, ident"x": prefixes and suffixes PostgreSQL
        // reads differently from the lexer.
        if atoms.contains(left.kind) && atoms.contains(right.kind) { return false }
        if left.kind == .punctuation && right.kind == .punctuation
            && operators.contains(left.text) && operators.contains(right.text) {
            // PostgreSQL reads a run of operator characters as one operator, trimming a trailing + or - only
            // when the run has none of ~ ! @ # % ^ & | ` ?. So `a=-1` is `=` then `-1`, but `a!=-1` is `!=-`.
            return ["=", "<", ">", "<=", ">=", "<>"].contains(left.text) && (right.text == "-" || right.text == "+")
        }
        return true
    }

    private static func isDecimal(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, let whole = parts.first, !whole.isEmpty, whole.allSatisfy(\.isASCIIDigit) else { return false }
        return parts.count == 1 || parts[1].allSatisfy(\.isASCIIDigit)
    }

    private static func isPlainWord(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.first, first.isASCIILetter || first == "_" else { return false }
        return text.unicodeScalars.allSatisfy { $0.isASCIILetter || $0.isASCIIDigit || $0 == "_" || $0 == "$" }
    }

    /// The text between the outer quotes with doubled quotes collapsed, or nil when unterminated or malformed.
    static func quotedBody(_ text: String) -> String? {
        let scalars = Array(text.unicodeScalars)
        guard let quote = scalars.first, scalars.count >= 2 else { return nil }
        var body = String.UnicodeScalarView()
        var j = 1
        while j < scalars.count {
            if scalars[j] == quote {
                if j + 1 < scalars.count && scalars[j + 1] == quote {
                    body.append(quote)
                    j += 2
                    continue
                }
                return j == scalars.count - 1 ? String(body) : nil
            }
            body.append(scalars[j])
            j += 1
        }
        return nil
    }

    /// A PostgreSQL "..." identifier's name. Backticks are MySQL's and refused.
    private static func quotedName(_ text: String, flavor: SQLFlavor = .postgres) -> String? {
        guard text.hasPrefix(flavor == .mysql ? "`" : "\""),
              flavor != .mysql || !text.contains("\\"),
              let name = quotedBody(text), !name.isEmpty, fitsNameLength(name, flavor: flavor) else { return nil }
        return name
    }

    /// Longer names are silently truncated by the server, so the name it resolves is not the one written.
    private static func fitsNameLength(_ name: String, flavor: SQLFlavor = .postgres) -> Bool {
        flavor == .mysql ? name.count <= 64 : name.utf8.count <= 63
    }

    /// The name PostgreSQL resolves an identifier token to, or nil when the token isn't a safe identifier.
    static func identifierName(_ token: SQLToken, flavor: SQLFlavor = .postgres) -> String? {
        switch token.kind {
        case .quotedIdentifier:
            return quotedName(token.text, flavor: flavor)
        case .word:
            guard isPlainWord(token.text), !reservedWords.contains(token.keyword), !mysqlReservedWords.contains(flavor == .mysql ? token.keyword : ""), fitsNameLength(token.text, flavor: flavor) else { return nil }
            return flavor == .mysql ? token.text : token.text.lowercased()
        default:
            return nil
        }
    }

    /// Words never taken as a bare identifier: PostgreSQL's reserved, type/function-name and column-name keywords
    /// (some of which are functions without parentheses, like CURRENT_USER), plus clause words this grammar
    /// steers by. A column with one of these names must be written quoted.
    private static let mysqlReservedWords: Set<String> = ["STRAIGHT_JOIN", "SQL_CALC_FOUND_ROWS", "SQL_NO_CACHE", "SQL_CACHE", "HIGH_PRIORITY", "DELAYED", "DISTINCTROW", "PARTITION", "FORCE", "USE", "IGNORE", "INDEX", "KEY", "DIV", "MOD", "XOR", "REGEXP", "RLIKE", "SOUNDS", "MATCH", "AGAINST", "DATABASE", "SCHEMA", "CURRENT_USER", "CURRENT_ROLE", "SYSTEM_USER", "SESSION_USER", "CURRENT_DATE", "CURRENT_TIME", "CURRENT_TIMESTAMP", "LOCALTIME", "LOCALTIMESTAMP", "UTC_DATE", "UTC_TIME", "UTC_TIMESTAMP"]

    static let reservedWords: Set<String> = [
        // Reserved
        "ALL", "ANALYSE", "ANALYZE", "AND", "ANY", "ARRAY", "AS", "ASC", "ASYMMETRIC", "BOTH", "CASE", "CAST", "CHECK",
        "COLLATE", "COLUMN", "CONSTRAINT", "CREATE", "CURRENT_CATALOG", "CURRENT_DATE", "CURRENT_ROLE",
        "CURRENT_TIME", "CURRENT_TIMESTAMP", "CURRENT_USER", "DEFAULT", "DEFERRABLE", "DESC", "DISTINCT", "DO",
        "ELSE", "END", "EXCEPT", "FALSE", "FETCH", "FOR", "FOREIGN", "FROM", "GRANT", "GROUP", "HAVING", "IN",
        "INITIALLY", "INTERSECT", "INTO", "LATERAL", "LEADING", "LIMIT", "LOCALTIME", "LOCALTIMESTAMP", "NOT", "NULL",
        "OFFSET", "ON", "ONLY", "OR", "ORDER", "PLACING", "PRIMARY", "REFERENCES", "RETURNING", "SELECT",
        "SESSION_USER", "SOME", "SYMMETRIC", "SYSTEM_USER", "TABLE", "THEN", "TO", "TRAILING", "TRUE", "UNION",
        "UNIQUE", "USER", "USING", "VARIADIC", "WHEN", "WHERE", "WINDOW", "WITH",
        // Reserved, can be a function or type name
        "AUTHORIZATION", "BINARY", "COLLATION", "CONCURRENTLY", "CROSS", "CURRENT_SCHEMA", "FREEZE", "FULL", "ILIKE",
        "INNER", "IS", "ISNULL", "JOIN", "LEFT", "LIKE", "NATURAL", "NOTNULL", "OUTER", "OVERLAPS", "RIGHT",
        "SIMILAR", "TABLESAMPLE", "VERBOSE",
        // Column-name keywords
        "BETWEEN", "BIGINT", "BIT", "BOOLEAN", "CHAR", "CHARACTER", "COALESCE", "DEC", "DECIMAL", "EXISTS", "EXTRACT",
        "FLOAT", "GREATEST", "GROUPING", "INOUT", "INT", "INTEGER", "INTERVAL", "JSON", "JSON_ARRAY",
        "JSON_ARRAYAGG", "JSON_EXISTS", "JSON_OBJECT", "JSON_OBJECTAGG", "JSON_QUERY", "JSON_SCALAR",
        "JSON_SERIALIZE", "JSON_TABLE", "JSON_VALUE", "LEAST", "MERGE_ACTION", "NATIONAL", "NCHAR", "NONE",
        "NORMALIZE", "NULLIF", "NUMERIC", "OUT", "OVERLAY", "POSITION", "PRECISION", "REAL", "ROW", "SETOF",
        "SMALLINT", "SUBSTRING", "TIME", "TIMESTAMP", "TREAT", "TRIM", "VALUES", "VARCHAR", "XMLATTRIBUTES",
        "XMLCONCAT", "XMLELEMENT", "XMLEXISTS", "XMLFOREST", "XMLNAMESPACES", "XMLPARSE", "XMLPI", "XMLROOT",
        "XMLSERIALIZE", "XMLTABLE",
        // Clause and operator words
        "BY", "NULLS", "ESCAPE", "UNKNOWN", "OPERATOR", "UESCAPE", "AT", "ROWS", "ORDINALITY", "REPEATABLE", "OVER",
        "FILTER", "WITHIN", "DOCUMENT",
    ]
}

private struct Rejected: Error {}

/// Recursive-descent check of the grammar documented on `EditableSelect`. Every method throws on the first token
/// that falls outside it.
private struct Parser {
    let tokens: [SQLToken]
    let flavor: SQLFlavor
    var index = 0
    var depth = 0
    /// The name columns may be qualified with: the alias, or the bare table name when there is none.
    var reference: String?
    /// The FROM table as written: `[table]` or `[schema, table]`.
    var relation: [String] = []

    var current: SQLToken? { index < tokens.count ? tokens[index] : nil }

    func isKeyword(_ word: String) -> Bool { current?.kind == .word && current?.keyword == word }

    mutating func accept(_ word: String) -> Bool {
        guard isKeyword(word) else { return false }
        index += 1
        return true
    }

    mutating func expect(_ word: String) throws { guard accept(word) else { throw Rejected() } }

    mutating func acceptPunctuation(_ text: String) -> Bool {
        guard let token = current, token.kind == .punctuation, token.text == text else { return false }
        index += 1
        return true
    }

    mutating func expectPunctuation(_ text: String) throws { guard acceptPunctuation(text) else { throw Rejected() } }

    var atIdentifier: Bool { current.map { EditableSelect.identifierName($0, flavor: flavor) != nil } ?? false }

    mutating func identifier() throws -> String {
        guard let token = current, let name = EditableSelect.identifierName(token, flavor: flavor) else { throw Rejected() }
        index += 1
        return name
    }

    // MARK: Statement

    mutating func statement() throws {
        try expect("SELECT")
        var qualifiers: [String] = []
        repeat { try selectItem(&qualifiers) } while acceptPunctuation(",")
        try expect("FROM")
        try tableReference()
        guard qualifiers.allSatisfy({ $0 == reference }) else { throw Rejected() }
        if accept("WHERE") { try orExpression() }
        if accept("ORDER") {
            try expect("BY")
            repeat { try orderItem() } while acceptPunctuation(",")
        }
        var sawLimit = false, sawOffset = false
        while true {
            if !sawLimit && accept("LIMIT") {
                try integer()
                sawLimit = true
            } else if !sawOffset && accept("OFFSET") {
                try integer()
                sawOffset = true
            } else {
                break
            }
        }
        _ = acceptPunctuation(";")
        guard current == nil else { throw Rejected() }
    }

    /// `*`, `ref.*`, or a column with an optional alias. Qualifiers are checked once FROM names the table.
    mutating func selectItem(_ qualifiers: inout [String]) throws {
        if acceptPunctuation("*") { return }
        let first = try identifier()
        if acceptPunctuation(".") {
            qualifiers.append(first)
            if acceptPunctuation("*") { return }
            _ = try identifier()
        }
        if accept("AS") {
            _ = try identifier()
        } else if atIdentifier {
            index += 1
        }
    }

    mutating func tableReference() throws {
        relation = [try identifier()]
        if acceptPunctuation(".") { relation.append(try identifier()) }
        reference = relation.last
        if accept("AS") {
            reference = try identifier()
        } else if atIdentifier {
            reference = try identifier()
        }
    }

    /// `name` or `ref.name`, where ref must be the FROM item's reference name.
    mutating func columnReference() throws {
        let first = try identifier()
        if acceptPunctuation(".") {
            guard first == reference else { throw Rejected() }
            _ = try identifier()
        }
    }

    mutating func orderItem() throws {
        try columnReference()
        if !accept("ASC") { _ = accept("DESC") }
        if flavor == .postgres && accept("NULLS") {
            guard accept("FIRST") || accept("LAST") else { throw Rejected() }
        }
    }

    mutating func integer() throws {
        guard let token = current, token.kind == .number, token.text.count <= 18,
              token.text.allSatisfy(\.isASCIIDigit) else { throw Rejected() }
        index += 1
    }

    // MARK: WHERE

    mutating func orExpression() throws {
        depth += 1
        defer { depth -= 1 }
        guard depth <= 64 else { throw Rejected() }
        try andExpression()
        while accept("OR") { try andExpression() }
    }

    mutating func andExpression() throws {
        try notExpression()
        while accept("AND") { try notExpression() }
    }

    mutating func notExpression() throws {
        var negations = 0
        while accept("NOT") {
            negations += 1
            guard negations <= 64 else { throw Rejected() }
        }
        try predicate()
    }

    mutating func predicate() throws {
        try arithmetic()
        if let token = current, token.kind == .punctuation, EditableSelect.comparisons.contains(token.text) {
            index += 1
            try arithmetic()
            return
        }
        if accept("IS") {
            _ = accept("NOT")
            guard accept("NULL") || accept("TRUE") || accept("FALSE") else { throw Rejected() }
            return
        }
        let negated = accept("NOT")
        if accept("IN") {
            try expectPunctuation("(")
            repeat { try literal(signed: true) } while acceptPunctuation(",")
            try expectPunctuation(")")
        } else if accept("BETWEEN") {
            try arithmetic()
            try expect("AND")
            try arithmetic()
        } else if accept("LIKE") || (flavor == .postgres && accept("ILIKE")) {
            try arithmetic()
        } else if negated {
            throw Rejected()
        }
    }

    mutating func arithmetic() throws {
        try unary()
        while let token = current, token.kind == .punctuation, ["+", "-", "*", "/", "%"].contains(token.text) {
            index += 1
            try unary()
        }
    }

    mutating func unary() throws {
        if !acceptPunctuation("-") { _ = acceptPunctuation("+") }
        if acceptPunctuation("(") {
            try orExpression()
            try expectPunctuation(")")
        } else if isLiteral {
            index += 1
        } else {
            try columnReference()
        }
    }

    var isLiteral: Bool {
        guard let token = current else { return false }
        return token.kind == .number || token.kind == .string || ["TRUE", "FALSE", "NULL"].contains(token.keyword)
    }

    mutating func literal(signed: Bool) throws {
        if signed && (acceptPunctuation("-") || acceptPunctuation("+")) {
            guard current?.kind == .number else { throw Rejected() }
        }
        guard isLiteral else { throw Rejected() }
        index += 1
    }
}

private extension Character {
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}

private extension Unicode.Scalar {
    var isASCIILetter: Bool { ("a"..."z").contains(self) || ("A"..."Z").contains(self) }
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}
