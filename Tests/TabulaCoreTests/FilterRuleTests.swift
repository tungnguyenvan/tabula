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
