import XCTest
@testable import TabulaCore

final class SQLSplitterTests: XCTestCase {
    func testSplitsOnTopLevelSemicolons() {
        let script = "SELECT 1; SELECT 'a;b'; -- c;d\nSELECT \"x;y\";"
        XCTAssertEqual(SQLSplitter.split(script, kind: .postgres), ["SELECT 1", "SELECT 'a;b'", "-- c;d\nSELECT \"x;y\""])
    }

    func testDollarQuotedBodiesStayIntact() {
        let script = "CREATE FUNCTION f() RETURNS int AS $body$ BEGIN RETURN 1; END; $body$ LANGUAGE plpgsql; SELECT $1"
        let parts = SQLSplitter.split(script, kind: .postgres)
        XCTAssertEqual(parts.count, 2)
        XCTAssertTrue(parts[0].hasSuffix("LANGUAGE plpgsql"))
    }

    func testMySQLBackslashEscapesAndHashComments() {
        let script = "SELECT 'it\\'s;'; # trailing; comment\nSELECT `a;b`"
        XCTAssertEqual(SQLSplitter.split(script, kind: .mysql).count, 2)
    }

    func testCommentOnlyChunksAreDropped() {
        XCTAssertEqual(SQLSplitter.split("SELECT 1; -- done\n", kind: .sqlite), ["SELECT 1"])
    }

    func testLeadingKeywordSkipsCommentsAndParens() {
        XCTAssertEqual(SQLSplitter.leadingKeyword("/* hi */ -- x\n (select 1)"), "SELECT")
        XCTAssertTrue(SQLSplitter.returnsRows("with t as (select 1) select * from t"))
        XCTAssertFalse(SQLSplitter.returnsRows("update t set a = 1"))
    }
}

final class SQLDialectTests: XCTestCase {
    func testQuotingPerDialect() {
        XCTAssertEqual(SQLDialect(kind: .mysql).quoteIdentifier("a`b"), "`a``b`")
        XCTAssertEqual(SQLDialect(kind: .postgres).quoteIdentifier("a\"b"), "\"a\"\"b\"")
        XCTAssertEqual(SQLDialect(kind: .mysql).literal("it's \\ ok"), "'it''s \\\\ ok'")
        XCTAssertEqual(SQLDialect(kind: .postgres).literal("it's \\ ok"), "'it''s \\ ok'")
        XCTAssertEqual(SQLDialect(kind: .sqlite).literal(nil), "NULL")
    }

    func testGeneratedStatements() {
        let d = SQLDialect(kind: .postgres)
        let table = TableRef(schema: "public", name: "users")
        XCTAssertEqual(d.update(table, set: [("name", "Ann")], key: [("id", "1"), ("org", nil)]),
                       "UPDATE \"public\".\"users\" SET \"name\" = 'Ann' WHERE \"id\" = '1' AND \"org\" IS NULL")
        XCTAssertEqual(d.insert(table, values: []), "INSERT INTO \"public\".\"users\" DEFAULT VALUES")
        XCTAssertEqual(SQLDialect(kind: .mysql).insert(TableRef(schema: "db", name: "t"), values: []), "INSERT INTO `db`.`t` () VALUES ()")
        XCTAssertEqual(d.selectPage(TablePageRequest(table: table, limit: 10, offset: 20, orderBy: "id", ascending: false, filter: " age > 3 ")),
                       "SELECT * FROM \"public\".\"users\" WHERE age > 3 ORDER BY \"id\" DESC LIMIT 10 OFFSET 20")
        XCTAssertEqual(SQLDialect(kind: .sqlite).qualified(TableRef(schema: "main", name: "t")), "\"t\"")
    }
}

final class StatementAtCursorTests: XCTestCase {
    private let script = "SELECT 1;\n\n-- note\nSELECT 'é;x' FROM t;   \nUPDATE t SET a = 2"

    func testRangesMapBackToText() {
        let all = SQLSplitter.statements(in: script, kind: .postgres)
        XCTAssertEqual(all.count, 3)
        for statement in all {
            XCTAssertEqual((script as NSString).substring(with: statement.range), statement.text)
        }
    }

    func testCaretPicksTheStatementPeopleExpect() {
        let ns = script as NSString
        XCTAssertEqual(SQLSplitter.statement(at: 3, in: script, kind: .postgres)?.text, "SELECT 1")
        // Right after the semicolon / in trailing spaces: still the statement just written.
        XCTAssertEqual(SQLSplitter.statement(at: ns.range(of: "t;   ").location + 4, in: script, kind: .postgres)?.text,
                       "-- note\nSELECT 'é;x' FROM t")
        XCTAssertEqual(SQLSplitter.statement(at: ns.length, in: script, kind: .postgres)?.text, "UPDATE t SET a = 2")
        XCTAssertEqual(SQLSplitter.statement(at: 0, in: "  ", kind: .postgres), nil)
    }
}
