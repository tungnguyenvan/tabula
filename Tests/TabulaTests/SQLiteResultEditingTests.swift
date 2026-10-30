import XCTest

@testable import TabulaDrivers
@testable import TabulaFoundation
@testable import TabulaSQLite

/// Editing a SQLite query's result: which results can be edited, what each edit writes, and that a row changed
/// meanwhile is reported instead of overwritten.
final class SQLiteResultEditingTests: XCTestCase {
    private var path = ""

    override func setUp() async throws {
        path = FileManager.default.temporaryDirectory.appendingPathComponent("tabula-redit-\(UUID()).sqlite").path
        let setup = try SQLiteDriver(path: path)
        _ = try await setup.executeScript(
            """
            CREATE TABLE items (id INTEGER PRIMARY KEY, label TEXT NOT NULL, amount REAL, qty INTEGER, data BLOB,
              total REAL GENERATED ALWAYS AS (amount * qty) VIRTUAL, loose);
            INSERT INTO items (label, amount, qty, data, loose) VALUES ('first', 12.5, 2, x'00ff', 'x'), ('second', 0.1, 3, NULL, 7);
            CREATE TABLE pairs (a INTEGER, b TEXT, note TEXT, PRIMARY KEY (a, b));
            INSERT INTO pairs VALUES (1, 'x', 'one'), (1, 'y', 'two');
            CREATE TABLE nokey (v TEXT);
            CREATE VIEW items_view AS SELECT * FROM items;
            """
        )
        await setup.close()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: path)
    }

    private func target(_ sql: String, on driver: SQLiteDriver) async throws -> (QueryResult, QueryEditTarget?) {
        let result = try await driver.execute(sql)
        return (result, try await driver.queryEditTarget(for: result))
    }

    func testWhichResultsCanBeEdited() async throws {
        let driver = try SQLiteDriver(path: path)
        let (_, items) = try await target(
            "SELECT i.id, i.label AS name, amount, qty, data, total, loose FROM items AS i ORDER BY id",
            on: driver
        )
        let editable = try XCTUnwrap(items)
        XCTAssertEqual(editable.columns.map(\.name), ["id", "label", "amount", "qty", "data", "total", "loose"])
        XCTAssertEqual(
            editable.columns.map(\.editable),
            [false, true, true, true, false, false, false],
            "key, bytes, generated and untyped columns stay read-only"
        )
        for sql in [
            "SELECT label FROM items",  // no key
            "SELECT * FROM items_view",  // view
            "SELECT id, label || '!' FROM items",  // expression
            "SELECT a, note FROM pairs",  // half the key
            "SELECT * FROM nokey",  // no primary key
            "SELECT i.id, j.label FROM items i JOIN items j ON i.id = j.id",
            "SELECT id, label FROM items WHERE id IN (SELECT id FROM items)",
        ] {
            let (_, none) = try await target(sql, on: driver)
            XCTAssertNil(none, sql)
        }
        let (_, pairs) = try await target("SELECT * FROM pairs", on: driver)
        XCTAssertNotNil(pairs, "a composite key in full")
        await driver.close()
    }

    /// The app calls through `any DatabaseDriver`, wrapped for the console log.
    func testTheAppsDriverWrapperReachesSQLite() async throws {
        let driver: any DatabaseDriver = LoggingDriver(try SQLiteDriver(path: path)) { _ in }
        let result = try await driver.execute("SELECT id, label FROM items")
        let resolved = try await driver.queryEditTarget(for: result)
        XCTAssertNotNil(resolved)
        await driver.close()
    }

    func testEditsKeepTypesAndReturnTheRow() async throws {
        let reader = try SQLiteDriver(path: path)
        let (result, resolved) = try await target("SELECT id, label, amount, qty FROM items ORDER BY id", on: reader)
        let target = try XCTUnwrap(resolved)
        let writer = try SQLiteDriver(path: path)
        let returned = try await writer.commitQueryEdits(
            [
                QueryRowEdit(row: 0, original: result.rows[0], values: [1: "it's \"é\"", 2: "99.25", 3: "7"]),
                QueryRowEdit(row: 1, original: result.rows[1], values: [2: nil]),
            ],
            target: target
        )
        XCTAssertEqual(returned[0], ["1", "it's \"é\"", "99.25", "7"])
        XCTAssertEqual(returned[1], ["2", "second", nil, "3"])
        let types = try await reader.execute("SELECT typeof(amount), typeof(qty) FROM items WHERE id = 1").rows
        XCTAssertEqual(types, [["real", "integer"]], "typed text takes the column's type")
        await writer.close()
        await reader.close()
    }

    func testAChangedRowIsAConflictAndNothingIsSaved() async throws {
        let reader = try SQLiteDriver(path: path)
        let (result, resolved) = try await target("SELECT id, label, amount FROM items ORDER BY id", on: reader)
        let target = try XCTUnwrap(resolved)
        _ = try await reader.execute("UPDATE items SET label = 'changed elsewhere' WHERE id = 2")
        let writer = try SQLiteDriver(path: path)
        do {
            _ = try await writer.commitQueryEdits(
                [
                    QueryRowEdit(row: 0, original: result.rows[0], values: [1: "must roll back"]),
                    QueryRowEdit(row: 1, original: result.rows[1], values: [1: "stale"]),
                ],
                target: target
            )
            XCTFail("the second row changed since the query ran")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("changed or was removed"), error.localizedDescription)
        }
        let labels = try await reader.execute("SELECT label FROM items ORDER BY id").rows
        XCTAssertEqual(labels, [["first"], ["changed elsewhere"]], "the first edit was rolled back too")
        // An edit of another column than the one changed elsewhere still goes through.
        let fresh = try await reader.execute("SELECT id, label, amount FROM items ORDER BY id")
        let saved = try await writer.commitQueryEdits(
            [QueryRowEdit(row: 1, original: fresh.rows[1], values: [2: "0.2"])],
            target: target
        )
        XCTAssertEqual(saved[1], ["2", "changed elsewhere", "0.2"])
        await writer.close()
        await reader.close()
    }
}
