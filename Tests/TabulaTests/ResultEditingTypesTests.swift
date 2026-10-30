import XCTest

@testable import TabulaConnections
@testable import TabulaDrivers
@testable import TabulaFoundation

/// Editing one cell of a query result matches the row by every value it showed; a type whose shown text doesn't
/// compare equal to the stored value would make the edit fail as if the row had changed. One edit per type here.
final class ResultEditingTypesTests: XCTestCase {
    func testPostgresRowsWithEveryTypeCanBeEdited() async throws {
        guard let port = ProcessInfo.processInfo.environment["TABULA_TEST_PG_PORT"].flatMap(Int.init) else {
            throw XCTSkip("TABULA_TEST_PG_PORT not set")
        }
        let driver = try await DriverFactory.connect(
            ConnectionConfig(kind: .postgres, port: port, user: "tabula", database: "tabula"),
            password: "tabula"
        )
        let table = "edit_types_" + UUID().uuidString.prefix(8).lowercased()
        try await runThenClean(driver, cleanup: ["DROP TABLE IF EXISTS \(table)"]) {
            let columns: [(type: String, value: String)] = [
                ("float8", "0.1"), ("float4", "1.1"), ("float8", "'NaN'"), ("numeric", "1e-20"), ("money", "-12.34"),
                ("timestamptz", "'2024-01-02 03:04:05.678+07'"), ("timestamp", "'0044-03-15 10:00 BC'"),
                ("date", "'infinity'"), ("time", "'24:00'"), ("timetz", "'12:30+05:30'"),
                ("interval", "'-1 day +02:00:00.5'"), ("jsonb", #"'{"b": [1, 2.50], "a": "é"}'"#),
                ("json", #"'{"b": 1,  "a": 2}'"#), ("bytea", #"'\xdead00'"#), ("int[]", "'[0:1]={7,8}'"),
                ("text[]", #"ARRAY['a,b', NULL, '']"#), ("inet", "'10.0.0.1/8'"),
                ("macaddr8", "'08:00:2b:01:02:03:04:05'"),
                ("bit(4)", "B'1010'"), ("int4range", "'[1,5)'"), ("point", "point(1.5, -2)"),
                ("tsvector", "'a:1 b:2'"), ("uuid", "'00000000-0000-0000-0000-000000000001'"), ("boolean", "true"),
                ("char(5)", "'ab'"), ("xml", "'<a/>'"),
            ]
            let definitions = columns.enumerated().map { "c\($0.offset) \($0.element.type)" }.joined(separator: ", ")
            _ = try await driver.execute("CREATE TABLE \(table) (id int PRIMARY KEY, note text, \(definitions))")
            let values = columns.map(\.value).joined(separator: ", ")
            _ = try await driver.execute("INSERT INTO \(table) VALUES (1, 'before', \(values))")

            let result = try await driver.execute("SELECT * FROM \(table)")
            let resolved = try await driver.queryEditTarget(for: result)
            let target = try XCTUnwrap(resolved)
            let note = try XCTUnwrap(result.columns.firstIndex(of: "note"))
            let returned = try await driver.commitQueryEdits(
                [QueryRowEdit(row: 0, original: result.rows[0], values: [note: "after"])],
                target: target
            )
            XCTAssertEqual(returned[0]?[note], "after")
            let reread = try await driver.execute("SELECT * FROM \(table)")
            var expected = result.rows[0]
            expected[note] = "after"
            XCTAssertEqual(reread.rows.first, expected, "every other value stays as it was")
        }
    }
}
