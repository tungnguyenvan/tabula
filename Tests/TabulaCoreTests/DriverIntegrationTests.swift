import XCTest
@testable import TabulaCore

/// Exercises each driver against a real database. Postgres and MySQL tests run only when
/// TABULA_TEST_PG_PORT / TABULA_TEST_MYSQL_PORT are set (user/password/database "tabula").
final class DriverIntegrationTests: XCTestCase {
    func testSQLite() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("tabula-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let driver = try SQLiteDriver(path: path)
        _ = try await driver.executeScript("""
            CREATE TABLE people (id INTEGER PRIMARY KEY, name TEXT NOT NULL, photo BLOB, score REAL DEFAULT 1.5);
            CREATE UNIQUE INDEX people_name ON people(name);
            CREATE VIEW names AS SELECT name FROM people;
            """)
        try await exerciseEditing(driver, table: TableRef(schema: "main", name: "people"))

        let blob = try await driver.execute("SELECT x'00ff', NULL, 3")
        XCTAssertEqual(blob.rows.first, ["x'00ff'", nil, "3"])
        let tables = try await driver.tables(in: "main")
        XCTAssertEqual(tables.map(\.name), ["names", "people"])
        XCTAssertEqual(tables.first?.kind, .view)
        let indexes = try await driver.indexes(of: TableRef(schema: "main", name: "people"))
        XCTAssertEqual(indexes.first(where: { $0.name == "people_name" })?.columns, ["name"])
        await driver.close()
    }

    func testPostgres() async throws {
        guard let port = ProcessInfo.processInfo.environment["TABULA_TEST_PG_PORT"].flatMap(Int.init) else {
            throw XCTSkip("TABULA_TEST_PG_PORT not set")
        }
        let config = ConnectionConfig(kind: .postgres, port: port, user: "tabula", database: "tabula")
        let driver = try await DriverFactory.connect(config, password: "tabula")
        _ = try await driver.executeScript("""
            DROP SCHEMA IF EXISTS tabula_test CASCADE;
            CREATE SCHEMA tabula_test;
            CREATE TYPE tabula_test.mood AS ENUM ('ok', 'happy');
            CREATE TABLE tabula_test.people (
                id serial PRIMARY KEY, name text NOT NULL UNIQUE, photo bytea, score real DEFAULT 1.5,
                amount numeric(12,3), tags text[], meta jsonb, born date, seen timestamptz, at time,
                took interval, uid uuid, ip inet, mood tabula_test.mood, flag boolean, big bigint, matrix int[][]
            );
            """)
        let table = TableRef(schema: "tabula_test", name: "people")
        try await exerciseEditing(driver, table: table)

        _ = try await driver.execute("""
            INSERT INTO tabula_test.people (name, photo, amount, tags, meta, born, seen, at, took, uid, ip, mood, flag, big, matrix)
            VALUES ('typed', '\\x00ff', -1234.5, ARRAY['a', 'b c', NULL], '{"k": [1, 2]}', '2024-02-29',
                    '2024-01-02 03:04:05.25+00', '13:14:15.5', '1 year 2 mons 3 days 04:05:06', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11',
                    '192.168.0.1/24', 'happy', true, 9007199254740993, '{{1,2},{3,4}}')
            """)
        let typed = try await driver.execute("""
            SELECT photo, amount, tags, meta, born, seen, at, took, uid, ip, mood, flag, big, matrix, 0.5::float8, 7::int2
            FROM tabula_test.people WHERE name = 'typed'
            """)
        XCTAssertEqual(typed.rows.first, [
            "\\x00ff", "-1234.500", "{a,\"b c\",NULL}", "{\"k\": [1, 2]}", "2024-02-29", "2024-01-02 03:04:05.25+00",
            "13:14:15.5", "1 year 2 mons 3 days 04:05:06", "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11", "192.168.0.1/24",
            "happy", "true", "9007199254740993", "{{1,2},{3,4}}", "0.5", "7",
        ])
        let empty = try await driver.execute("SELECT id, name FROM tabula_test.people WHERE false")
        XCTAssertEqual(empty.columns, ["id", "name"])

        let columns = try await driver.columns(of: table)
        XCTAssertEqual(columns.first?.isPrimaryKey, true)
        XCTAssertEqual(columns.first(where: { $0.name == "amount" })?.dataType, "numeric(12,3)")
        let indexes = try await driver.indexes(of: table)
        XCTAssertTrue(indexes.contains { $0.isPrimary && $0.columns == ["id"] })
        let schemas = try await driver.schemas()
        XCTAssertTrue(schemas.contains("tabula_test"))

        do {
            _ = try await driver.execute("SELECT nope FROM tabula_test.people")
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("nope"), "got: \(error.localizedDescription)")
        }
        _ = try await driver.execute("DROP SCHEMA tabula_test CASCADE")
        await driver.close()
    }

    func testMySQL() async throws {
        guard let port = ProcessInfo.processInfo.environment["TABULA_TEST_MYSQL_PORT"].flatMap(Int.init) else {
            throw XCTSkip("TABULA_TEST_MYSQL_PORT not set")
        }
        let config = ConnectionConfig(kind: .mysql, port: port, user: "tabula", database: "tabula", tls: .require)
        let driver = try await DriverFactory.connect(config, password: "tabula")
        _ = try await driver.executeScript("""
            DROP TABLE IF EXISTS people;
            CREATE TABLE people (
                id INT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(100) NOT NULL UNIQUE, photo BLOB,
                score DOUBLE DEFAULT 1.5, amount DECIMAL(12,3), born DATE, seen DATETIME(3), flag TINYINT(1)
            );
            """)
        let table = TableRef(schema: "tabula", name: "people")
        try await exerciseEditing(driver, table: table)

        _ = try await driver.execute("INSERT INTO people (name, amount, born, seen, flag) VALUES ('typed', -1234.5, '2024-02-29', '2024-01-02 03:04:05.250', 1)")
        let typed = try await driver.execute("SELECT amount, born, seen, flag FROM people WHERE name = 'typed'")
        XCTAssertEqual(typed.rows.first, ["-1234.500", "2024-02-29", "2024-01-02 03:04:05.250", "1"])

        let show = try await driver.execute("SHOW TABLES")
        XCTAssertTrue(show.rows.contains { $0.first == "people" })
        let lock = try await driver.execute("LOCK TABLES people READ")
        XCTAssertFalse(lock.hasResultSet)
        _ = try await driver.execute("UNLOCK TABLES")

        let columns = try await driver.columns(of: table)
        XCTAssertEqual(columns.first?.isPrimaryKey, true)
        let indexes = try await driver.indexes(of: table)
        XCTAssertEqual(indexes.first?.isPrimary, true)
        XCTAssertTrue(indexes.contains { $0.name == "name" && $0.isUnique })
        _ = try await driver.execute("DROP TABLE people")
        await driver.close()
    }

    /// Insert / update / delete through the generated SQL, then verify via paging and counting.
    private func exerciseEditing(_ driver: any DatabaseDriver, table: TableRef, file: StaticString = #filePath, line: UInt = #line) async throws {
        let d = driver.dialect
        try await driver.applyInTransaction([
            d.insert(table, values: [("name", "O'Brien \\ slash")]),
            d.insert(table, values: [("name", "Zed")]),
        ])
        let page = try await driver.fetchPage(TablePageRequest(table: table, orderBy: "name", ascending: true))
        let nameIndex = try XCTUnwrap(page.columns.firstIndex(of: "name"), file: file, line: line)
        let idIndex = try XCTUnwrap(page.columns.firstIndex(of: "id"), file: file, line: line)
        XCTAssertEqual(page.rows.map { $0[nameIndex] }, ["O'Brien \\ slash", "Zed"], file: file, line: line)

        let likeCount = try await driver.countRows(table, filter: d.condition([FilterRule(column: "name", op: .contains, value: "'brien \\")]))
        XCTAssertEqual(likeCount, 1, "case-insensitive contains with quote and backslash", file: file, line: line)

        let zedID = page.rows[1][idIndex]
        try await driver.applyInTransaction([d.update(table, set: [("name", "Zoe"), ("photo", nil)], key: [("id", zedID)])])
        let filtered = try await driver.fetchPage(TablePageRequest(table: table, filter: "\(d.quoteIdentifier("name")) = 'Zoe'"))
        XCTAssertEqual(filtered.rows.count, 1, file: file, line: line)

        // A failing batch must leave the table untouched.
        do {
            try await driver.applyInTransaction([d.delete(table, key: [("id", zedID)]), "INSERT INTO nowhere VALUES (1)"])
            XCTFail("expected failure", file: file, line: line)
        } catch {}
        let count = try await driver.countRows(table, filter: nil)
        XCTAssertEqual(count, 2, file: file, line: line)

        try await driver.applyInTransaction([d.delete(table, key: [("id", zedID)])])
        let after = try await driver.countRows(table, filter: nil)
        XCTAssertEqual(after, 1, file: file, line: line)
        let update = try await driver.execute("UPDATE \(d.qualified(table)) SET \(d.quoteIdentifier("score")) = 2")
        XCTAssertEqual(update.affectedRows, 1, file: file, line: line)
    }
}

/// Picking a schema in the sidebar makes unqualified names resolve there ("relation does not exist" otherwise).
final class UseSchemaTests: XCTestCase {
    func testPostgresSearchPath() async throws {
        guard let port = ProcessInfo.processInfo.environment["TABULA_TEST_PG_PORT"].flatMap(Int.init) else {
            throw XCTSkip("TABULA_TEST_PG_PORT not set")
        }
        let driver = try await DriverFactory.connect(ConnectionConfig(kind: .postgres, port: port, user: "tabula", database: "tabula"), password: "tabula")
        _ = try await driver.executeScript("""
            DROP SCHEMA IF EXISTS tabula_use CASCADE;
            CREATE SCHEMA tabula_use;
            CREATE TABLE tabula_use.transactions (id int);
            INSERT INTO tabula_use.transactions VALUES (7);
            """)
        do {
            _ = try await driver.execute("SELECT id FROM transactions")
            XCTFail("expected the table to be invisible before useSchema")
        } catch {}
        try await driver.useSchema("tabula_use")
        let rows = try await driver.execute("SELECT id FROM transactions").rows
        XCTAssertEqual(rows, [["7"]])
        // public stays on the path for extensions and shared tables.
        let path = try await driver.execute("SHOW search_path").rows.first?.first
        XCTAssertEqual(path, "tabula_use, public")
        _ = try await driver.execute("DROP SCHEMA tabula_use CASCADE")
        await driver.close()
    }

    func testMySQLUse() async throws {
        guard let port = ProcessInfo.processInfo.environment["TABULA_TEST_MYSQL_PORT"].flatMap(Int.init) else {
            throw XCTSkip("TABULA_TEST_MYSQL_PORT not set")
        }
        let config = ConnectionConfig(kind: .mysql, port: port, user: "root", database: "tabula", tls: .require)
        let driver = try await DriverFactory.connect(config, password: "tabula")
        _ = try await driver.executeScript("""
            DROP DATABASE IF EXISTS tabula_use;
            CREATE DATABASE tabula_use;
            CREATE TABLE tabula_use.transactions (id int);
            INSERT INTO tabula_use.transactions VALUES (8);
            """)
        try await driver.useSchema("tabula_use")
        let rows = try await driver.execute("SELECT id FROM transactions").rows
        XCTAssertEqual(rows, [["8"]])
        _ = try await driver.execute("DROP DATABASE tabula_use")
        await driver.close()
    }
}

/// Viewing and editing functions and triggers.
final class RoutineTests: XCTestCase {
    func testSQLiteTriggers() async throws {
        let driver = try SQLiteDriver(path: FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).db").path)
        _ = try await driver.executeScript("""
            CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT, updated TEXT);
            CREATE TRIGGER touch AFTER UPDATE ON items BEGIN UPDATE items SET updated = 'yes' WHERE id = NEW.id; END;
            """)
        let routines = try await driver.routines(in: "main")
        XCTAssertEqual(routines.map(\.name), ["touch"])
        let trigger = try XCTUnwrap(routines.first)
        XCTAssertEqual(trigger.table, "items")
        let original = try await driver.definition(of: trigger)
        XCTAssertTrue(original.hasPrefix("CREATE TRIGGER touch"), original)

        // A broken definition changes nothing.
        do {
            try await driver.replace(trigger, original: original, with: "CREATE TRIGGER touch AFTER UPDATE ON nowhere BEGIN SELECT 1; END;")
            XCTFail("expected an error")
        } catch {}
        let unchanged = try await driver.definition(of: trigger)
        XCTAssertEqual(unchanged, original)

        try await driver.replace(trigger, original: original, with: "CREATE TRIGGER touch AFTER UPDATE ON items BEGIN UPDATE items SET updated = 'v2' WHERE id = NEW.id; END;")
        _ = try await driver.execute("INSERT INTO items (id, name) VALUES (1, 'a')")
        _ = try await driver.execute("UPDATE items SET name = 'b' WHERE id = 1")
        let updated = try await driver.execute("SELECT updated FROM items").rows.first?.first
        XCTAssertEqual(updated, "v2")
        _ = try await driver.execute(driver.dropStatement(for: trigger))
        let after = try await driver.routines(in: "main")
        XCTAssertTrue(after.isEmpty)
    }

    func testPostgresFunctionsAndTriggers() async throws {
        guard let port = ProcessInfo.processInfo.environment["TABULA_TEST_PG_PORT"].flatMap(Int.init) else {
            throw XCTSkip("TABULA_TEST_PG_PORT not set")
        }
        let driver = try await DriverFactory.connect(ConnectionConfig(kind: .postgres, port: port, user: "tabula", database: "tabula"), password: "tabula")
        _ = try await driver.executeScript("""
            DROP SCHEMA IF EXISTS tabula_routines CASCADE;
            CREATE SCHEMA tabula_routines;
            CREATE TABLE tabula_routines.items (id int, touched text);
            CREATE FUNCTION tabula_routines.add_one(n integer) RETURNS integer LANGUAGE sql AS $$ SELECT n + 1 $$;
            CREATE FUNCTION tabula_routines.touch() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN NEW.touched := 'v1'; RETURN NEW; END $$;
            CREATE TRIGGER touch_items BEFORE INSERT ON tabula_routines.items FOR EACH ROW EXECUTE FUNCTION tabula_routines.touch();
            """)
        let routines = try await driver.routines(in: "tabula_routines")
        XCTAssertEqual(Set(routines.map(\.displayName)), ["add_one(n integer)", "touch()", "touch_items"])
        let addOne = try XCTUnwrap(routines.first { $0.name == "add_one" })
        let definition = try await driver.definition(of: addOne)
        XCTAssertTrue(definition.contains("CREATE OR REPLACE FUNCTION tabula_routines.add_one"), definition)
        try await driver.replace(addOne, original: definition, with: definition.replacingOccurrences(of: "n + 1", with: "n + 2"))
        let two = try await driver.execute("SELECT tabula_routines.add_one(1)").rows.first?.first
        XCTAssertEqual(two, "3")

        let trigger = try XCTUnwrap(routines.first { $0.kind == .trigger })
        XCTAssertEqual(trigger.detail, "BEFORE INSERT ON items")
        let triggerDefinition = try await driver.definition(of: trigger)
        XCTAssertTrue(triggerDefinition.hasPrefix("CREATE TRIGGER touch_items BEFORE INSERT"), triggerDefinition)
        try await driver.replace(trigger, original: triggerDefinition, with: triggerDefinition.replacingOccurrences(of: "BEFORE INSERT", with: "BEFORE INSERT OR UPDATE"))
        let changed = try await driver.routines(in: "tabula_routines").first { $0.kind == .trigger }
        XCTAssertEqual(changed?.detail, "BEFORE INSERT OR UPDATE ON items")
        _ = try await driver.execute("DROP SCHEMA tabula_routines CASCADE")
        await driver.close()
    }

    func testMySQLRestoresTheOriginalWhenANewDefinitionFails() async throws {
        guard let port = ProcessInfo.processInfo.environment["TABULA_TEST_MYSQL_PORT"].flatMap(Int.init) else {
            throw XCTSkip("TABULA_TEST_MYSQL_PORT not set")
        }
        let driver = try await DriverFactory.connect(ConnectionConfig(kind: .mysql, port: port, user: "root", database: "tabula", tls: .require), password: "tabula")
        _ = try await driver.execute("DROP FUNCTION IF EXISTS tabula_add_one")
        _ = try await driver.execute("CREATE FUNCTION tabula_add_one(n INT) RETURNS INT DETERMINISTIC RETURN n + 1")
        let all = try await driver.routines(in: "tabula")
        let routine = try XCTUnwrap(all.first { $0.name == "tabula_add_one" })
        let original = try await driver.definition(of: routine)
        do {
            try await driver.replace(routine, original: original, with: "CREATE FUNCTION tabula_add_one(n INT) RETURNS INT DETERMINISTIC RETURN nonsense(")
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("restored"), error.localizedDescription)
        }
        let still = try await driver.execute("SELECT tabula_add_one(1)").rows.first?.first
        XCTAssertEqual(still, "2")
        _ = try await driver.execute("DROP FUNCTION tabula_add_one")
        await driver.close()
    }
}
