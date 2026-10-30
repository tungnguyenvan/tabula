import XCTest

@testable import TabulaSQL

/// Beautify moves whitespace only: what was written together stays together (#244).
final class BeautifyTokensTests: XCTestCase {
    func testWhatIsWrittenTogetherStaysTogether() {
        let cases: [(SQLFlavor, String, String)] = [
            (
                .postgres, "select 1.5e-3, 2E10, 3e+2, 0x1F, 1_000 from t",
                "SELECT\n  1.5e-3,\n  2E10,\n  3e+2,\n  0x1F,\n  1_000\nFROM\n  t"
            ),
            (
                .postgres, "select b'01', x'ff', n'x', U&'a', U&\"b\" from t",
                "SELECT\n  b'01',\n  x'ff',\n  n'x',\n  U&'a',\n  U&\"b\"\nFROM\n  t"
            ),
            (.mysql, "select _utf8mb4'a', _binary x'00' from t", "SELECT\n  _utf8mb4'a',\n  _binary x'00'\nFROM\n  t"),
            (
                .postgres, "select a<<2, a->>'k', a @> b, a <-> b, a #>> '{x}', a !~* 'r', a=-1 from t",
                "SELECT\n  a << 2,\n  a ->> 'k',\n  a @> b,\n  a <-> b,\n  a #>> '{x}',\n  a !~* 'r',\n  a = - 1\nFROM\n  t"
            ),
            (
                .postgres, "select :name, :'v', a[1], a[1:2] from t",
                "SELECT\n  :name,\n  :'v',\n  a[1],\n  a[1 : 2]\nFROM\n  t"
            ),
            (
                .mysql, "select @a := 1, @@session.sql_mode, a--b from t",
                "SELECT\n  @a := 1,\n  @@session.sql_mode,\n  a - - b\nFROM\n  t"
            ),
            (.sqlite, "select ?1, [my col] from [t x]", "SELECT\n  ?1,\n  [my col]\nFROM\n  [t x]"),
            // The ";" stays out of the comment before it.
            (.postgres, "select 1 -- c\n; select 2", "SELECT\n  1 -- c\n;\n\nSELECT\n  2"),
        ]
        for (flavor, sql, expected) in cases {
            XCTAssertEqual(SQLDialect(flavor: flavor).beautify(sql), expected, "\(flavor): \(sql)")
        }
    }

    /// Random scripts from pieces that each mean something only as written; a seeded generator keeps runs equal.
    func testRandomScriptsKeepEveryToken() {
        let pieces = [
            "SELECT", "FROM", "WHERE", "AND", "OR", "JOIN", "LEFT", "ON", "GROUP", "BY", "ORDER", "HAVING", "LIMIT",
            "UNION",
            "CASE", "WHEN", "THEN", "END", "INSERT", "INTO", "VALUES", "UPDATE", "SET", "WITH", "AS", "(", ")", ",",
            ";",
            "=", "<>", "::", "->>", "||", "-", "*", ".", "a", "\"Q x\"", "`bt`", "'s;t'", "'it''s'", "$$x;y$$", "1",
            "1.5e-3", "-- c\n", "/* b */", "# h\n", "?", "$1", ":name", "@v", "[x]", "IN", "BETWEEN", "IS", "NULL",
            "\n", "Tên", "n'x'", "x'ff'", "b'01'", "U&\"a\"", "~", "<<", "@@g", ":=", "a[1]", "0x1F", "@>", "#>>", "?1",
            ":'v'", "x=-1",
        ]
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
        for flavor in SQLFlavor.allCases {
            let dialect = SQLDialect(flavor: flavor)
            for _ in 0..<1500 {
                let script = (0...next(20)).map { _ in pieces[next(pieces.count)] }.joined(separator: " ")
                let once = dialect.beautify(script)
                XCTAssertEqual(
                    Self.meaning(once, flavor),
                    Self.meaning(script, flavor),
                    "\(flavor): \(script)\n→\n\(once)"
                )
                XCTAssertEqual(dialect.beautify(once), once, "\(flavor): beautifying twice changes nothing:\n\(once)")
                XCTAssertEqual(dialect.split(once).count, dialect.split(script).count, "\(flavor): \(script)")
            }
        }
    }

    /// The tokens, with "⁀" before one written against the token before it where that matters to the server.
    static func meaning(_ text: String, _ flavor: SQLFlavor) -> [String] {
        let tokens = SQLLexer.tokens(text, flavor: flavor).filter { $0.kind != .whitespace }
        return tokens.indices.map { index in
            let token = tokens[index]
            var item =
                switch token.kind {
                case .comment: token.text.trimmingCharacters(in: .whitespaces)
                case .word: token.text.uppercased()
                default: token.text
                }
            if index > 0 {
                let previous = tokens[index - 1]
                let touching = NSMaxRange(previous.range) == token.range.location
                let joined =
                    ((previous.kind == .word || previous.kind == .number) && token.kind == .string)
                    || (previous.kind == .number && token.kind == .word)
                    || (SQLFormatter.isPrefix(at: index - 1, in: tokens) && token.kind != .punctuation)
                if touching && joined {
                    item = "⁀" + item
                }
            }
            return item
        }
    }
}
