import XCTest
@testable import TabulaCore

final class EditableSelectTests: XCTestCase {
    func testDirectColumnsFromOneTable() {
        accepts([
            "SELECT * FROM t",
            "select id, name from users",
            "SELECT t.* FROM t",
            "SELECT t.id, t.name FROM public.t",
            "SELECT a.id, a.name AS display_name FROM public.t AS a",
            "SELECT a.id identifier, a.name display_name FROM public.t a",
            "SELECT a.*, a.id AS duplicate_id FROM t a",
            "SELECT \"a\".\"id\" AS \"Display Name\" FROM \"public\".\"t\" AS \"a\"",
            "SELECT \"A\".id FROM t \"A\"",
            "SELECT ID FROM PUBLIC.Users U WHERE U.ID = 1",
            "SELECT * FROM t WHERE id=1 ORDER BY id DESC LIMIT 300",
        ])
    }

    func testConservativePredicates() {
        accepts([
            "SELECT * FROM t WHERE id = 1",
            "SELECT * FROM t WHERE id=-1 AND amount >= +2.5",
            "SELECT * FROM t WHERE a <> 2 OR b != 3 AND c <= 4 AND d > 0",
            "SELECT * FROM t WHERE active AND NOT deleted",
            "SELECT * FROM t WHERE NOT (id = 1 OR (name = 'two' AND deleted IS NULL))",
            "SELECT * FROM t WHERE deleted IS NOT NULL AND active IS TRUE AND hidden IS NOT FALSE",
            "SELECT * FROM t WHERE id IN (1, 2, -3, +4) AND name NOT IN ('a', 'b', NULL)",
            "SELECT * FROM t WHERE id BETWEEN 1 AND 9 AND amount NOT BETWEEN -1 AND 2.5",
            "SELECT * FROM t WHERE name LIKE 'a%' OR name NOT ILIKE '_b'",
            "SELECT * FROM t WHERE t.id = t.other_id",
            "SELECT * FROM t a WHERE a.id = 1 AND a.x + 1 > a.y * 2",
            "SELECT * FROM t WHERE (a + 1) > 2 AND a / 2 >= 1 AND a % 2 = 0",
        ])
    }

    func testOrderingAndPagination() {
        accepts([
            "SELECT * FROM t ORDER BY id",
            "SELECT id FROM t ORDER BY id ASC NULLS FIRST, t.name DESC NULLS LAST",
            "SELECT a.id AS result_id FROM t a ORDER BY a.id DESC LIMIT 300 OFFSET 10",
            "SELECT * FROM t OFFSET 10 LIMIT 300",
            "SELECT * FROM t LIMIT 0",
            "SELECT * FROM t OFFSET 0",
            "SELECT * FROM t;",
            " \t\r\n SELECT * FROM t \u{0C}; \n",
        ])
        rejects([
            "SELECT * FROM t ORDER BY 1",
            "SELECT * FROM t ORDER BY id + 1",
            "SELECT * FROM t ORDER BY lower(name)",
            "SELECT * FROM t ORDER BY id USING >",
            "SELECT * FROM t ORDER BY id NULLS",
            "SELECT * FROM t ORDER BY id DESC ASC",
            "SELECT * FROM t LIMIT ALL",
            "SELECT * FROM t LIMIT -1",
            "SELECT * FROM t LIMIT 1.0",
            "SELECT * FROM t LIMIT 1e2",
            "SELECT * FROM t LIMIT 1, 2",
            "SELECT * FROM t LIMIT 1 LIMIT 2",
            "SELECT * FROM t OFFSET 1 OFFSET 2",
            "SELECT * FROM t LIMIT 9223372036854775808",
            "SELECT * FROM t FETCH FIRST 1 ROW ONLY",
            "SELECT * FROM t LIMIT 1 WHERE id = 1",
        ])
    }

    func testKeywordsInsideDataAreNotClauses() {
        accepts([
            "SELECT \"join\", \"select\", \"count(*)\", \"from\" FROM \"with\"",
            "SELECT * FROM t WHERE name = 'JOIN t b; SELECT * FROM x'",
            "SELECT * FROM t WHERE name = 'it''s a UNION SELECT count(*)'",
            "SELECT \"a\"\"b\" FROM \"sch\"\"ema\".\"ta.ble\"",
            "SELECT * FROM t WHERE name = '/* nested /* comment */ */ --'",
            "-- WITH ignored AS (SELECT 1)\nSELECT * -- JOIN x\nFROM t -- UNION SELECT * FROM y\n; -- done",
        ])
    }

    func testRejectsMoreThanOneRelationInstance() {
        rejects([
            "SELECT a.id,b.name FROM t a JOIN t b ON a.id = b.id",
            "SELECT a.id,b.name FROM t a JOIN t b",
            "SELECT * FROM t, t",
            "SELECT a.id FROM t a, t b WHERE a.id = b.id",
            "SELECT * FROM t CROSS JOIN t b",
            "SELECT * FROM t NATURAL JOIN t b",
            "SELECT * FROM t LEFT JOIN u ON t.id = u.id",
            "SELECT * FROM t INNER JOIN u USING (id)",
            "SELECT * FROM t JOIN LATERAL (SELECT * FROM u) u ON TRUE",
            "SELECT * FROM (t)",
            "SELECT * FROM ONLY t",
            "SELECT * FROM ONLY (t)",
            "SELECT * FROM t *",
            "SELECT * FROM t TABLESAMPLE SYSTEM (10)",
            "SELECT * FROM t TABLESAMPLE BERNOULLI (10) REPEATABLE (1)",
            "SELECT * FROM t WITH ORDINALITY",
            "SELECT * FROM database.public.t",
            "SELECT public.t.* FROM public.t",
            "SELECT public.t.id FROM public.t",
            "SELECT wrong.id FROM t",
            "SELECT t.id FROM t a",
            "SELECT a.id FROM t \"A\"",
            "SELECT * FROM t WHERE other.id = 1",
            "SELECT * FROM t ORDER BY other.id",
        ])
    }

    func testRejectsComputedOrNonColumnProjections() {
        rejects([
            "SELECT 1 FROM t",
            "SELECT 'literal' FROM t",
            "SELECT NULL FROM t",
            "SELECT TRUE FROM t",
            "SELECT id + 1 FROM t",
            "SELECT id || name FROM t",
            "SELECT (id) FROM t",
            "SELECT id::text FROM t",
            "SELECT CAST(id AS text) FROM t",
            "SELECT lower(name) FROM t",
            "SELECT count(*) FROM t",
            "SELECT t.count(*) FROM t",
            "SELECT CASE WHEN active THEN id ELSE 0 END FROM t",
            "SELECT current_user FROM t",
            "SELECT current_date FROM t",
            "SELECT current_schema FROM t",
            "SELECT session_user FROM t",
            "SELECT system_user FROM t",
            "SELECT ARRAY[id] FROM t",
            "SELECT row_number() OVER () FROM t",
            "SELECT * AS columns FROM t",
            "SELECT t.* columns FROM t",
        ])
    }

    func testRejectsFunctionsSubqueriesAndCTEs() {
        rejects([
            "WITH x AS (SELECT * FROM t) SELECT * FROM x",
            "WITH RECURSIVE x AS (SELECT * FROM t) SELECT * FROM x",
            "SELECT * FROM (SELECT * FROM t) a",
            "SELECT (SELECT id FROM u) FROM t",
            "SELECT * FROM generate_series(1, 2)",
            "SELECT * FROM public.table_function()",
            "SELECT * FROM t WHERE id IN (SELECT id FROM u)",
            "SELECT * FROM t WHERE id = (SELECT max(id) FROM u)",
            "SELECT * FROM t WHERE EXISTS (SELECT 1 FROM u)",
            "SELECT * FROM t WHERE lower(name) = 'a'",
            "SELECT * FROM t WHERE name = upper('a')",
            "SELECT * FROM t WHERE f()",
            "SELECT * FROM t WHERE id = ANY(ARRAY[1, 2])",
            "SELECT * FROM t WHERE id::text = '1'",
            "SELECT * FROM t WHERE name = DATE '2026-01-01'",
            "SELECT * FROM t WHERE now = current_timestamp",
            "SELECT * FROM t WHERE id IN ()",
            "SELECT * FROM t WHERE id IN (other_id)",
            "SELECT * FROM t WHERE name LIKE 'x' ESCAPE '!'",
            "SELECT * FROM t WHERE id OPERATOR(public.=) 1",
        ])
    }

    func testRejectsNonWhitelistClausesAndMultipleStatements() {
        rejects([
            "", "-- comment only", "SELECT", "SELECT FROM t", "SELECT *", "SELECT * FROM", "SELECT *, FROM t",
            "SELECT id id_alias extra FROM t", "SELECT * FROM t AS", "SELECT * FROM t WHERE", "SELECT * FROM t WHERE ()",
            "SELECT DISTINCT id FROM t",
            "SELECT ALL id FROM t",
            "SELECT DISTINCT ON (id) id FROM t",
            "SELECT id INTO copy FROM t",
            "SELECT * FROM t GROUP BY id",
            "SELECT * FROM t HAVING id > 1",
            "SELECT * FROM t WINDOW w AS ()",
            "SELECT * FROM t UNION SELECT * FROM t",
            "SELECT * FROM t INTERSECT SELECT * FROM t",
            "SELECT * FROM t EXCEPT SELECT * FROM t",
            "SELECT * FROM t RETURNING id",
            "SELECT * FROM t FOR UPDATE",
            "SELECT * FROM t FOR NO KEY UPDATE",
            "SELECT * FROM t FOR SHARE",
            "SELECT * FROM t; SELECT * FROM t",
            "SELECT * FROM t;;",
            "SELECT * FROM t; DELETE FROM t",
            "UPDATE t SET id = 1 RETURNING id",
            "TABLE t",
        ])
    }

    func testRejectsLexerAmbiguities() {
        rejects([
            "SELECT * FROM t /* comment */",
            "SELECT * FROM t /* nested /* */ JOIN t b */",
            "SELECT * FROM t /* unterminated",
            "SELECT * FROM t -- ignored\r JOIN t b ON TRUE",
            "SELECT * FROM t\u{00A0}JOIN t b ON TRUE",
            "SELECT * FROM t\u{000B}",
            "SELECT * FROM t WHERE name = E'escape'",
            "SELECT * FROM t WHERE name = e 'escape'",
            "SELECT * FROM t WHERE name = U&'unicode'",
            "SELECT * FROM U&\"table\"",
            "SELECT * FROM t WHERE name = B'101'",
            "SELECT * FROM t WHERE name = X'FF'",
            "SELECT * FROM t WHERE name = N'national'",
            "SELECT * FROM t WHERE name = $$dollar$$",
            "SELECT * FROM t WHERE name = $tag$dollar$tag$",
            "SELECT * FROM t WHERE name = 'back\\slash'",
            "SELECT `id` FROM t",
            "SELECT [id] FROM t",
            "SELECT * FROM t WHERE name = 'unterminated",
            "SELECT * FROM \"unterminated",
            "SELECT * FROM \"unterminated\"\"",
            "SELECT * FROM t WHERE name = 'unterminated''",
            "SELECT * FROM \"\"",
            "SELECT * FROM t WHERE id = $1",
            "SELECT * FROM t WHERE id = ?",
            "SELECT * FROM t WHERE id = 0xFF",
            "SELECT * FROM t WHERE id = 1_000",
            "SELECT * FROM t WHERE id = 1..2",
            "SELECT * FROM t WHERE id !=-1",
            "SELECT * FROM t WHERE id === 1",
            "SELECT * FROM t WHERE id = 'one' 'two'",
            "SELECT * FROM t WHERE id = 'one'\n 'two'",
            "SELECT * FROM t WHERE id = 'one'; -- x\r DELETE FROM t",
            "SELECT * FROM t WHERE id = ١",
            "SELECT * FROM \"t\u{0}x\"",
        ])
    }

    func testSourceIsDecodedOnlyForAcceptedGrammar() {
        XCTAssertEqual(EditableSelect.source("SELECT * FROM Users"), ["users"])
        XCTAssertEqual(EditableSelect.source("SELECT u.id FROM Public.Users AS u WHERE u.id = 1"), ["public", "users"])
        XCTAssertEqual(EditableSelect.source("SELECT * FROM \"A.B\".\"T\"\"able\" x"), ["A.B", "T\"able"])
        XCTAssertEqual(EditableSelect.source("SELECT \"A\".id FROM \"Table\" AS \"A\""), ["Table"])
        XCTAssertNil(EditableSelect.source("SELECT * FROM t JOIN t b ON TRUE"))
        XCTAssertNil(EditableSelect.source("SELECT count(*) FROM t"))
        rejects(["SELECT * FROM \"" + String(repeating: "a", count: 64) + "\"",
                 "SELECT * FROM " + String(repeating: "a", count: 64)])
    }

    func testDeepPredicatesRemainReadOnlyRatherThanOverflowingStack() {
        let sql = "SELECT * FROM t WHERE " + String(repeating: "(", count: 1000) + "id = 1" + String(repeating: ")", count: 1000)
        XCTAssertFalse(EditableSelect.accepts(sql))
        XCTAssertFalse(EditableSelect.accepts("SELECT * FROM t WHERE " + String(repeating: "NOT ", count: 1000) + "active"))
    }

    private func accepts(_ queries: [String], file: StaticString = #filePath, line: UInt = #line) {
        for sql in queries { XCTAssertTrue(EditableSelect.accepts(sql), sql, file: file, line: line) }
    }

    private func rejects(_ queries: [String], file: StaticString = #filePath, line: UInt = #line) {
        for sql in queries {
            XCTAssertFalse(EditableSelect.accepts(sql), sql, file: file, line: line)
            XCTAssertNil(EditableSelect.source(sql), sql, file: file, line: line)
        }
    }
}
