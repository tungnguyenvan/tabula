import XCTest
@testable import TabulaCore

final class SQLFormatterTests: XCTestCase {
    func testClausesAndConditions() {
        let sql = "select id, name from users u left join orders o on o.user_id = u.id where u.active = true and o.total > 10 order by name limit 5"
        XCTAssertEqual(SQLFormatter.format(sql, kind: .postgres), """
            SELECT
              id,
              name
            FROM
              users u
            LEFT JOIN orders o ON o.user_id = u.id
            WHERE
              u.active = TRUE
              AND o.total > 10
            ORDER BY
              name
            LIMIT 5
            """)
    }

    func testKeepsLiteralsCommentsAndCalls() {
        let sql = "select count(*), 'from where' as \"select\" -- note\nfrom t where x between 1 and 2 and y in (1, 2)"
        XCTAssertEqual(SQLFormatter.format(sql, kind: .postgres), """
            SELECT
              COUNT(*),
              'from where' AS "select" -- note
            FROM
              t
            WHERE
              x BETWEEN 1 AND 2
              AND y IN (1, 2)
            """)
    }

    func testSubqueryAndStatements() {
        let sql = "select * from (select id from a) s; delete from a where id = 1"
        XCTAssertEqual(SQLFormatter.format(sql, kind: .mysql), """
            SELECT
              *
            FROM
              (
                SELECT
                  id
                FROM
                  a
              ) s;

            DELETE FROM a
            WHERE
              id = 1
            """)
    }
}

final class RowLimitTests: XCTestCase {
    let d = SQLDialect(kind: .postgres)

    func testAddsLimitToPlainSelect() {
        XCTAssertEqual(d.applyingRowLimit("SELECT * FROM t", limit: 300), "SELECT * FROM t LIMIT 300")
        XCTAssertEqual(d.applyingRowLimit("select * from t; -- end", limit: 10), "select * from t LIMIT 10; -- end")
        // A LIMIT inside a subquery doesn't count.
        XCTAssertEqual(d.applyingRowLimit("SELECT * FROM (SELECT 1 LIMIT 1) x", limit: 5), "SELECT * FROM (SELECT 1 LIMIT 1) x LIMIT 5")
    }

    func testLeavesOtherStatementsAlone() {
        for sql in ["SELECT * FROM t LIMIT 3", "UPDATE t SET a = 1", "SELECT * FROM t FOR UPDATE",
                    "SELECT 'limit' FROM t FETCH FIRST 2 ROWS ONLY", "WITH x AS (SELECT 1) DELETE FROM t", "SHOW TABLES"] {
            XCTAssertEqual(d.applyingRowLimit(sql, limit: 5), sql, sql)
        }
    }
}

final class SQLCompletionTests: XCTestCase {
    let tables = ["users", "orders", "order_items"]
    let columns: [String: [String]] = ["users": ["id", "name", "email"], "orders": ["id", "user_id", "total"]]

    private func suggest(_ sql: String) -> [String] {
        let caret = (sql as NSString).range(of: "|").location
        let text = sql.replacingOccurrences(of: "|", with: "")
        let context = SQLCompletion.context(in: text, caret: caret, kind: .postgres)
        return SQLCompletion.suggestions(for: context, tables: tables, columns: { self.columns[$0] })
    }

    func testTablesAfterFrom() {
        XCTAssertEqual(suggest("SELECT * FROM ord|"), ["orders", "order_items"])
        XCTAssertEqual(suggest("SELECT * FROM users JOIN |"), tables.sorted { ($0.count, $0) < ($1.count, $1) })
    }

    func testColumnsAfterAlias() {
        XCTAssertEqual(suggest("SELECT o.| FROM orders o"), ["id", "total", "user_id"])
        XCTAssertEqual(suggest("SELECT u.na| FROM users AS u"), ["name"])
        XCTAssertEqual(suggest("SELECT users.e| FROM users"), ["email"])
    }

    func testColumnsOfUsedTablesComeFirst() {
        XCTAssertEqual(suggest("SELECT na| FROM users").first, "name")
        // Keywords follow the case being typed.
        XCTAssertEqual(suggest("sel|"), ["select"])
        XCTAssertEqual(suggest("SEL|"), ["SELECT"])
    }

    func testNothingToCompleteWithoutAWord() {
        XCTAssertEqual(suggest("SELECT |"), [])
        XCTAssertEqual(suggest("SELECT 'na|"), [])
    }
}
