import XCTest

@testable import TabulaConnections
@testable import TabulaDrivers
@testable import TabulaFoundation
@testable import TabulaRedis
@testable import TabulaSQLite

/// Foreign keys and metrics against real databases (Postgres/MySQL/Redis need the TABULA_TEST_* ports).
final class SchemaInsightsTests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment

    private let schemaSQL = """
        CREATE TABLE authors (id INTEGER PRIMARY KEY, name TEXT);
        CREATE TABLE books (id INTEGER PRIMARY KEY, author_id INTEGER, title TEXT, FOREIGN KEY (author_id) REFERENCES authors(id));
        CREATE TABLE editions (book_id INTEGER, number INTEGER, PRIMARY KEY (book_id, number));
        CREATE TABLE copies (id INTEGER PRIMARY KEY, book_id INTEGER, edition INTEGER,
                             FOREIGN KEY (book_id, edition) REFERENCES editions(book_id, number));
        """

    private func check(_ keys: [ForeignKeyInfo], file: StaticString = #filePath, line: UInt = #line) {
        let simple = keys.first { $0.table.name == "books" }
        XCTAssertEqual(simple?.columns, ["author_id"], file: file, line: line)
        XCTAssertEqual(simple?.referencedTable.name, "authors", file: file, line: line)
        let composite = keys.first { $0.table.name == "copies" }
        XCTAssertEqual(composite?.columns, ["book_id", "edition"], file: file, line: line)
        XCTAssertEqual(composite?.referencedColumns, ["book_id", "number"], file: file, line: line)
        XCTAssertEqual(keys.count, 2, file: file, line: line)
    }

    func testSQLite() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let driver = try SQLiteDriver(path: path)
        _ = try await driver.executeScript(schemaSQL + "INSERT INTO authors VALUES (1, 'An'), (2, 'Bình');")
        check(try await driver.foreignKeys(in: "main"))
        let metrics = try await driver.metrics(schema: "main")
        XCTAssertEqual(metrics.groups.first?.items.first?.label, "SQLite")
        XCTAssertEqual(metrics.tables.first { $0.name == "authors" }?.rows, 2)
    }

    func testPostgres() async throws {
        guard let port = env["TABULA_TEST_PG_PORT"].flatMap(Int.init) else {
            throw XCTSkip("TABULA_TEST_PG_PORT not set")
        }
        let driver = try await DriverFactory.connect(
            ConnectionConfig(kind: .postgres, port: port, user: "tabula", database: "tabula"),
            password: "tabula"
        )
        _ = try await driver.executeScript(
            "DROP SCHEMA IF EXISTS fk_test CASCADE; CREATE SCHEMA fk_test; SET search_path = fk_test;" + schemaSQL
        )
        check(try await driver.foreignKeys(in: "fk_test"))
        let first = try await driver.metrics(schema: "fk_test")
        _ = try await driver.execute("SELECT 1")
        let second = try await driver.metrics(schema: "fk_test")
        XCTAssertTrue(first.groups.flatMap(\.items).contains { $0.label == "Cache hit ratio" })
        XCTAssertGreaterThan(first.gauges["Connections"] ?? 0, 0)
        XCTAssertGreaterThanOrEqual(second.counters["Transactions/s"] ?? 0, first.counters["Transactions/s"] ?? 0)
        XCTAssertTrue(first.tables.contains { $0.name == "fk_test.books" })
        let version = try await driver.serverVersion()
        XCTAssertTrue(version.hasPrefix("PostgreSQL"), version)
        _ = try await driver.execute("DROP SCHEMA fk_test CASCADE")
        await driver.close()
    }

    func testMySQL() async throws {
        guard let port = env["TABULA_TEST_MYSQL_PORT"].flatMap(Int.init) else {
            throw XCTSkip("TABULA_TEST_MYSQL_PORT not set")
        }
        let driver = try await DriverFactory.connect(
            ConnectionConfig(kind: .mysql, port: port, user: "tabula", database: "tabula", tls: .require),
            password: "tabula"
        )
        _ = try await driver.executeScript("DROP TABLE IF EXISTS copies, editions, books, authors;" + schemaSQL)
        check(try await driver.foreignKeys(in: "tabula"))
        let metrics = try await driver.metrics(schema: "tabula")
        XCTAssertTrue(metrics.groups.flatMap(\.items).contains { $0.label == "Buffer pool hit ratio" })
        XCTAssertGreaterThan(metrics.counters["Queries/s"] ?? 0, 0)
        XCTAssertTrue(metrics.tables.contains { $0.name == "books" })
        let version = try await driver.serverVersion()
        XCTAssertTrue(version.hasPrefix("MySQL 8"), version)
        _ = try await driver.executeScript("DROP TABLE copies, editions, books, authors;")
        await driver.close()
    }

    func testRedis() async throws {
        guard let port = env["TABULA_TEST_REDIS_PORT"].flatMap(Int.init) else {
            throw XCTSkip("TABULA_TEST_REDIS_PORT not set")
        }
        let redis = try await RedisDriver.connect(
            ConnectionConfig(kind: .redis, port: port, user: "tabula"),
            password: "tabula"
        )
        let metrics = try await redis.metrics()
        let items = Dictionary(
            metrics.groups.flatMap(\.items).map { ($0.label, $0.value) },
            uniquingKeysWith: { a, _ in a }
        )
        XCTAssertTrue(items["Version"]?.hasPrefix("Redis 7") == true)
        XCTAssertNotNil(items["Used"])
        XCTAssertGreaterThan(metrics.gauges["Clients"] ?? 0, 0)
        XCTAssertGreaterThan(metrics.counters["Commands/s"] ?? 0, 0)
        await redis.close()
    }
}
