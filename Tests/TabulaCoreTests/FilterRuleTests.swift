import XCTest
@testable import TabulaCore

final class FilterRuleTests: XCTestCase {
    func testConditions() {
        let pg = SQLDialect(kind: .postgres)
        XCTAssertEqual(pg.condition(FilterRule(column: "price", op: .contains, value: "5_0%")),
                       "CAST(\"price\" AS TEXT) ILIKE '%5\\_0\\%%' ESCAPE '\\'")
        XCTAssertEqual(pg.condition([FilterRule(column: "a", op: .isNull), FilterRule(column: "b", op: .equals, value: ""),
                                     FilterRule(column: "c", op: .inList, value: "1, 2")]),
                       "\"a\" IS NULL AND \"c\" IN ('1', '2')")
        XCTAssertEqual(SQLDialect(kind: .mysql).condition(FilterRule(column: "n", op: .startsWith, value: "x")), "`n` LIKE 'x%'")
    }

    func testConjunctions() {
        let d = SQLDialect(kind: .sqlite)
        let a = FilterRule(column: "a", value: "1")
        let b = FilterRule(column: "b", value: "2", conjunction: .and)
        let c = FilterRule(column: "c", value: "3", conjunction: .or)
        XCTAssertEqual(d.condition([a, b, c]), "(\"a\" = '1' AND \"b\" = '2') OR \"c\" = '3'")
        XCTAssertEqual(d.condition([a, c]), "\"a\" = '1' OR \"c\" = '3'")
        // A skipped (empty) rule doesn't leave a dangling OR.
        XCTAssertEqual(d.condition([FilterRule(column: "x", value: ""), c]), "\"c\" = '3'")
        XCTAssertEqual(d.condition([FilterRule(column: "x", op: .inList, value: "a, ,b")]), "\"x\" IN ('a', 'b')")
    }

    func testConnectionURLs() {
        let pg = ConnectionConfig(kind: .postgres, host: "db.example.com", user: "ann", database: "shop", tls: .verifyFull)
        XCTAssertEqual(pg.url(), "postgresql://ann@db.example.com:5432/shop?sslmode=verify-full")
        XCTAssertEqual(pg.url(password: "p@ss/word"), "postgresql://ann:p%40ss%2Fword@db.example.com:5432/shop?sslmode=verify-full")
        XCTAssertEqual(ConnectionConfig(kind: .mysql, host: "", user: "root", tls: .require).url(),
                       "mysql://root@127.0.0.1:3306?ssl-mode=REQUIRED")
        XCTAssertEqual(ConnectionConfig(kind: .redis, host: "cache", database: "2", tls: .require).url(), "rediss://cache:6379/2?ssl_cert_reqs=none")
        XCTAssertEqual(ConnectionConfig(kind: .sqlite, filePath: "/tmp/a b.db").url(), "file:///tmp/a%20b.db")
    }

    func testFiltersAgainstSQLite() async throws {
        let driver = try SQLiteDriver(path: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).db").path)
        _ = try await driver.executeScript("CREATE TABLE t (id INTEGER PRIMARY KEY, name TEXT); INSERT INTO t (name) VALUES ('50%_off'), ('5000'), (NULL);")
        let d = driver.dialect
        let table = TableRef(schema: "main", name: "t")
        let contains = try await driver.countRows(table, filter: d.condition([FilterRule(column: "name", op: .contains, value: "0%_")]))
        XCTAssertEqual(contains, 1)
        let nulls = try await driver.countRows(table, filter: d.condition([FilterRule(column: "name", op: .isNull)]))
        XCTAssertEqual(nulls, 1)
    }
}
