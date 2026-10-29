import XCTest

@testable import TabulaSQL

final class SQLLexerTests: XCTestCase {
    private func tokens(_ sql: String, _ flavor: SQLFlavor) -> [String] {
        SQLLexer.tokens(sql, flavor: flavor).filter { $0.kind != .whitespace }.map { "\($0.kind):\($0.text)" }
    }

    func testKindsOfTokens() {
        XCTAssertEqual(
            tokens("SELECT \"Name\", 'it''s', 1.5 FROM t -- note", .postgres),
            [
                "word:SELECT", "quotedIdentifier:\"Name\"", "punctuation:,", "string:'it''s'", "punctuation:,",
                "number:1.5", "word:FROM", "word:t", "comment:-- note",
            ]
        )
        XCTAssertEqual(
            tokens("a <> b::int /* x */", .postgres),
            [
                "word:a", "punctuation:<>", "word:b", "punctuation:::", "word:int", "comment:/* x */",
            ]
        )
    }

    func testCommentsByFlavor() {
        XCTAssertEqual(tokens("SELECT 1 # note", .mysql), ["word:SELECT", "number:1", "comment:# note"])
        XCTAssertEqual(tokens("SELECT 1 # 2", .postgres), ["word:SELECT", "number:1", "punctuation:#", "number:2"])
        // An unclosed block comment runs to the end rather than past it.
        XCTAssertEqual(tokens("SELECT /* open", .sqlite), ["word:SELECT", "comment:/* open"])
    }

    func testDollarQuotesAndParameters() {
        XCTAssertEqual(
            tokens("SELECT $$ it's ; $$, $fn$ a $$ b $fn$, $1", .postgres),
            [
                "word:SELECT", "string:$$ it's ; $$", "punctuation:,", "string:$fn$ a $$ b $fn$", "punctuation:,",
                "word:$1",
            ]
        )
        XCTAssertEqual(tokens("SELECT $$x$$", .mysql), ["word:SELECT", "word:$$x$$"])
    }

    func testBackslashesInMySQLStrings() {
        XCTAssertEqual(
            tokens("SELECT 'a\\'b', \"c\\\"d\"", .mysql),
            [
                "word:SELECT", "string:'a\\'b'", "punctuation:,", "quotedIdentifier:\"c\\\"d\"",
            ]
        )
        // PostgreSQL's standard strings keep a backslash as it is.
        XCTAssertEqual(
            tokens("SELECT 'a\\', 2", .postgres),
            ["word:SELECT", "string:'a\\'", "punctuation:,", "number:2"]
        )
    }

    /// MySQL ends a backtick name at the next backtick, backslash or not.
    func testBacktickNamesHaveNoEscapes() {
        XCTAssertEqual(
            tokens("SELECT `dir\\`, 'x'", .mysql),
            [
                "word:SELECT", "quotedIdentifier:`dir\\`", "punctuation:,", "string:'x'",
            ]
        )
        XCTAssertEqual(SQLSplitter.split("SELECT `dir\\`; SELECT 2", flavor: .mysql), ["SELECT `dir\\`", "SELECT 2"])
    }

    func testPostgresEscapeStrings() {
        XCTAssertEqual(
            tokens("SELECT E'it\\'s', e'\\\\', 'plain\\'", .postgres),
            [
                "word:SELECT", "string:E'it\\'s'", "punctuation:,", "string:e'\\\\'", "punctuation:,",
                "string:'plain\\'",
            ]
        )
        // A word ending in E is a name, not a prefix.
        XCTAssertEqual(tokens("SELECT NAME'x'", .postgres), ["word:SELECT", "word:NAME", "string:'x'"])
        XCTAssertEqual(
            SQLSplitter.split("SELECT E'a\\'; b'; SELECT 2", flavor: .postgres),
            [
                "SELECT E'a\\'; b'", "SELECT 2",
            ]
        )
    }

    /// Ranges are UTF-16, as NSTextView counts them, including letters outside the BMP.
    func testRangesAreUTF16() {
        let sql = "SELECT 'Hà Nội 😀', tên"
        let all = SQLLexer.tokens(sql, flavor: .postgres)
        let text = sql as NSString
        for token in all {
            XCTAssertEqual(text.substring(with: token.range), token.text)
        }
        XCTAssertEqual(all.last?.text, "tên")
        XCTAssertEqual(all.last?.kind, .word)
    }

    func testUnclosedStringRunsToTheEnd() {
        XCTAssertEqual(tokens("SELECT 'open", .postgres), ["word:SELECT", "string:'open"])
        XCTAssertEqual(tokens("SELECT 'a\\", .mysql), ["word:SELECT", "string:'a\\"])
    }

    func testFlavorOfEachKind() {
        XCTAssertEqual(SQLFlavor(.postgres), .postgres)
        XCTAssertEqual(SQLFlavor(.mysql), .mysql)
        XCTAssertEqual(SQLFlavor(.sqlite), .sqlite)
        XCTAssertNil(SQLFlavor(.mongodb))
        XCTAssertNil(SQLFlavor(.redis))
    }
}
