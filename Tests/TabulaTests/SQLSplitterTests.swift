import XCTest

@testable import TabulaConnections
@testable import TabulaDrivers
@testable import TabulaFoundation
@testable import TabulaSQL

final class SQLSplitterTests: XCTestCase {
    func testSplitsOnTopLevelSemicolons() {
        let script = "SELECT 1; SELECT 'a;b'; -- c;d\nSELECT \"x;y\";"
        XCTAssertEqual(
            SQLSplitter.split(script, flavor: .postgres),
            ["SELECT 1", "SELECT 'a;b'", "-- c;d\nSELECT \"x;y\""]
        )
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
        XCTAssertEqual(
            d.update(table, set: [("name", "Ann")], key: [("id", "1"), ("org", nil)], binaryColumns: []),
            "UPDATE \"public\".\"users\" SET \"name\" = 'Ann' WHERE \"id\" = '1' AND \"org\" IS NULL"
        )
        XCTAssertEqual(
            d.insert(table, values: [], binaryColumns: []),
            "INSERT INTO \"public\".\"users\" DEFAULT VALUES"
        )
        XCTAssertEqual(
            SQLDialect(flavor: .mysql).insert(TableRef(schema: "db", name: "t"), values: [], binaryColumns: []),
            "INSERT INTO `db`.`t` () VALUES ()"
        )
        XCTAssertEqual(
            d.selectPage(
                TablePageRequest(
                    table: table,
                    limit: 10,
                    offset: 20,
                    orderBy: "id",
                    ascending: false,
                    filter: " age > 3 "
                )
            ),
            "SELECT * FROM \"public\".\"users\" WHERE age > 3 ORDER BY \"id\" DESC LIMIT 10 OFFSET 20"
        )
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
        XCTAssertEqual(
            SQLDialect(flavor: .postgres).statement(at: ns.range(of: "t;   ").location + 4, in: script)?.text,
            "-- note\nSELECT 'é;x' FROM t"
        )
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

    /// PostgreSQL 14's SQL-standard bodies hold their own semicolons, and CASE … END inside them.
    func testPostgresAtomicBodiesStayWhole() {
        let script = """
            CREATE FUNCTION f(n int) RETURNS text LANGUAGE sql
            BEGIN ATOMIC
                SELECT CASE WHEN n > 1 THEN 'big' ELSE 'small' END;
            END;
            CREATE OR REPLACE PROCEDURE p() LANGUAGE sql BEGIN ATOMIC INSERT INTO t VALUES (1); DELETE FROM u; END;
            BEGIN; SELECT 1; END;
            SELECT 3
            """
        let statements = SQLSplitter.split(script, flavor: .postgres)
        XCTAssertEqual(statements.count, 6, statements.joined(separator: "\n---\n"))
        XCTAssertTrue(statements[0].hasSuffix("END"))
        XCTAssertTrue(statements[1].hasSuffix("DELETE FROM u; END"))
        XCTAssertEqual(Array(statements[2...]), ["BEGIN", "SELECT 1", "END", "SELECT 3"])
    }

    func testAPostgresAtomicFunctionScriptRuns() async throws {
        guard let port = ProcessInfo.processInfo.environment["TABULA_TEST_PG_PORT"].flatMap(Int.init) else {
            throw XCTSkip("TABULA_TEST_PG_PORT not set")
        }
        let driver = try await DriverFactory.connect(
            ConnectionConfig(kind: .postgres, port: port, user: "tabula", database: "tabula"),
            password: "tabula"
        )
        let name = "f_" + UUID().uuidString.prefix(8).lowercased()
        try await runThenClean(driver, cleanup: ["DROP FUNCTION IF EXISTS \(name)(int)"]) {
            let results = try await driver.executeScript(
                """
                CREATE FUNCTION \(name)(n int) RETURNS text LANGUAGE sql
                BEGIN ATOMIC
                    SELECT CASE WHEN n > 1 THEN 'big' ELSE 'small' END;
                END;
                SELECT \(name)(5), \(name)(0);
                """
            )
            XCTAssertEqual(results.count, 2)
            XCTAssertEqual(results.last?.rows, [["big", "small"]])
        }
    }
}

final class MySQLDelimiterTests: XCTestCase {
    /// Scripts written for the mysql client change the delimiter around routine bodies.
    func testDelimiterLinesSplitAsTheMySQLClientDoes() {
        let script = """
            DELIMITER $$
            CREATE PROCEDURE p()
            BEGIN
              SELECT 'a;b';
              SELECT 2;
            END$$
            CREATE FUNCTION f() RETURNS INT DETERMINISTIC RETURN 1$$
            delimiter ;
            CALL p();
            SELECT f()
            """
        let statements = SQLSplitter.statements(in: script, flavor: .mysql)
        XCTAssertEqual(
            statements.map(\.text),
            [
                "CREATE PROCEDURE p()\nBEGIN\n  SELECT 'a;b';\n  SELECT 2;\nEND",
                "CREATE FUNCTION f() RETURNS INT DETERMINISTIC RETURN 1",
                "CALL p()",
                "SELECT f()",
            ]
        )
        // Ranges point at the statements in the editor, past the DELIMITER lines.
        let text = script as NSString
        for statement in statements {
            XCTAssertEqual(text.substring(with: statement.range), statement.text)
        }
    }

    func testDelimiterIsOnlyAMySQLClientCommand() {
        XCTAssertEqual(
            SQLSplitter.split("SELECT 1; SELECT 'DELIMITER $$'", flavor: .mysql),
            ["SELECT 1", "SELECT 'DELIMITER $$'"]
        )
        XCTAssertEqual(
            SQLSplitter.split("DELIMITER $$\nSELECT 1", flavor: .postgres).count,
            1,
            "PostgreSQL has no DELIMITER"
        )
    }
}

final class MySQLDelimiterLiveTests: XCTestCase {
    func testAProcedureScriptRuns() async throws {
        guard let port = ProcessInfo.processInfo.environment["TABULA_TEST_MYSQL_PORT"].flatMap(Int.init) else {
            throw XCTSkip("TABULA_TEST_MYSQL_PORT not set")
        }
        let driver = try await DriverFactory.connect(
            ConnectionConfig(kind: .mysql, port: port, user: "tabula", database: "tabula"),
            password: "tabula"
        )
        let name = "p_" + UUID().uuidString.prefix(8).lowercased()
        do {
            let results = try await driver.executeScript(
                """
                DELIMITER //
                CREATE PROCEDURE \(name)(IN n INT, OUT next INT)
                BEGIN
                  SET next = n + 1;
                END //
                DELIMITER ;
                CALL \(name)(41, @next);
                SELECT @next;
                DROP PROCEDURE \(name);
                """
            )
            // A procedure returning rows needs CLIENT_MULTI_RESULTS, which the MySQL driver doesn't ask for (#185);
            // this one answers through an OUT parameter.
            XCTAssertEqual(results.count, 4)
            XCTAssertEqual(results[2].rows, [["42"]])
        } catch {
            _ = try? await driver.execute("DROP PROCEDURE IF EXISTS \(name)")
            await driver.close()
            throw error
        }
        await driver.close()
    }
}
