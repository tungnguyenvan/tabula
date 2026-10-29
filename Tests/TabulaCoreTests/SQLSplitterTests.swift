import XCTest
@testable import TabulaCore

final class SQLSplitterTests: XCTestCase {
    func testSplitsOnTopLevelSemicolons() {
        let script = "SELECT 1; SELECT 'a;b'; -- c;d\nSELECT \"x;y\";"
        XCTAssertEqual(SQLSplitter.split(script, flavor: .postgres), ["SELECT 1", "SELECT 'a;b'", "-- c;d\nSELECT \"x;y\""])
    }

    func testDollarQuotedBodiesStayIntact() {
        let script = "CREATE FUNCTION f() RETURNS int AS $body$ BEGIN RETURN 1; END; $body$ LANGUAGE plpgsql; SELECT $1"
        let parts = SQLSplitter.split(script, flavor: .postgres)
        XCTAssertEqual(parts.count, 2)
        XCTAssertTrue(parts[0].hasSuffix("LANGUAGE plpgsql"))
    }

    func testMySQLBackslashEscapesAndHashComments() {
        let script = "SELECT 'it\\'s;'; # trailing; comment\nSELECT `a;b`"
        XCTAssertEqual(SQLSplitter.split(script, flavor: .mysql).count, 2)
    }

    func testCommentOnlyChunksAreDropped() {
        XCTAssertEqual(SQLSplitter.split("SELECT 1; -- done\n", flavor: .sqlite), ["SELECT 1"])
    }

    func testLeadingKeywordSkipsCommentsAndParens() {
        XCTAssertEqual(SQLSplitter.leadingKeyword("/* hi */ -- x\n (select 1)"), "SELECT")
        XCTAssertTrue(SQLSplitter.returnsRows("with t as (select 1) select * from t"))
        XCTAssertFalse(SQLSplitter.returnsRows("update t set a = 1"))
    }
}

final class SQLDialectTests: XCTestCase {
    func testQuotingPerDialect() {
        XCTAssertEqual(SQLDialect(flavor: .mysql).quoteIdentifier("a`b"), "`a``b`")
        XCTAssertEqual(SQLDialect(flavor: .postgres).quoteIdentifier("a\"b"), "\"a\"\"b\"")
        XCTAssertEqual(SQLDialect(flavor: .mysql).literal("it's \\ ok"), "'it''s \\\\ ok'")
        XCTAssertEqual(SQLDialect(flavor: .postgres).literal("it's \\ ok"), "'it''s \\ ok'")
        XCTAssertEqual(SQLDialect(flavor: .sqlite).literal(nil), "NULL")
    }

    func testGeneratedStatements() {
        let d = SQLDialect(flavor: .postgres)
        let table = TableRef(schema: "public", name: "users")
        XCTAssertEqual(d.update(table, set: [("name", "Ann")], key: [("id", "1"), ("org", nil)]),
                       "UPDATE \"public\".\"users\" SET \"name\" = 'Ann' WHERE \"id\" = '1' AND \"org\" IS NULL")
        XCTAssertEqual(d.insert(table, values: []), "INSERT INTO \"public\".\"users\" DEFAULT VALUES")
        XCTAssertEqual(SQLDialect(flavor: .mysql).insert(TableRef(schema: "db", name: "t"), values: []), "INSERT INTO `db`.`t` () VALUES ()")
        XCTAssertEqual(d.selectPage(TablePageRequest(table: table, limit: 10, offset: 20, orderBy: "id", ascending: false, filter: " age > 3 ")),
                       "SELECT * FROM \"public\".\"users\" WHERE age > 3 ORDER BY \"id\" DESC LIMIT 10 OFFSET 20")
        XCTAssertEqual(SQLDialect(flavor: .sqlite).qualified(TableRef(schema: "main", name: "t")), "\"t\"")
    }
}

final class StatementAtCursorTests: XCTestCase {
    private let script = "SELECT 1;\n\n-- note\nSELECT 'é;x' FROM t;   \nUPDATE t SET a = 2"

    func testRangesMapBackToText() {
        let all = SQLSplitter.statements(in: script, flavor: .postgres)
        XCTAssertEqual(all.count, 3)
        for statement in all {
            XCTAssertEqual((script as NSString).substring(with: statement.range), statement.text)
        }
    }

    func testCaretPicksTheStatementPeopleExpect() {
        let ns = script as NSString
        XCTAssertEqual(SQLDialect(flavor: .postgres).statement(at: 3, in: script)?.text, "SELECT 1")
        // Right after the semicolon / in trailing spaces: still the statement just written.
        XCTAssertEqual(SQLDialect(flavor: .postgres).statement(at: ns.range(of: "t;   ").location + 4, in: script)?.text,
                       "-- note\nSELECT 'é;x' FROM t")
        XCTAssertEqual(SQLDialect(flavor: .postgres).statement(at: ns.length, in: script)?.text, "UPDATE t SET a = 2")
        XCTAssertEqual(SQLDialect(flavor: .postgres).statement(at: 0, in: "  "), nil)
    }
}

final class RoutineSplittingTests: XCTestCase {
    func testTriggerAndProcedureBodiesStayWhole() {
        let sqlite = """
            CREATE TABLE t (id INTEGER, v TEXT);
            CREATE TRIGGER touch AFTER UPDATE ON t BEGIN UPDATE t SET v = 'x' WHERE id = NEW.id; SELECT 1; END;
            SELECT * FROM t;
            """
        XCTAssertEqual(SQLSplitter.split(sqlite, flavor: .sqlite).count, 3)
        let mysql = """
            CREATE PROCEDURE p(IN n INT)
            BEGIN
                IF n > 0 THEN
                    SELECT CASE WHEN n > 10 THEN 'big' ELSE 'small' END;
                END IF;
                WHILE n > 0 DO SET n = n - 1; END WHILE;
            END;
            CALL p(3);
            """
        let statements = SQLSplitter.split(mysql, flavor: .mysql)
        XCTAssertEqual(statements.count, 2, statements.joined(separator: "\n---\n"))
        XCTAssertTrue(statements[0].hasSuffix("END"))
        // Ordinary BEGIN (a transaction) still ends at its semicolon.
        XCTAssertEqual(SQLSplitter.split("BEGIN; UPDATE t SET v = 1; COMMIT;", flavor: .sqlite).count, 3)
    }
}
