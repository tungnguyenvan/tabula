import XCTest

@testable import Tabula
@testable import TabulaConnections
@testable import TabulaDrivers
@testable import TabulaFoundation
@testable import TabulaSQLite

/// A table tab's commit must reach every row it edits or deletes: a row deleted meanwhile, or a key that can't be
/// matched exactly, fails the whole commit instead of reporting success with nothing saved.
@MainActor
final class TableCommitChecksTests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment

    private func model(_ driver: any DatabaseDriver, _ table: TableRef) async -> TableTabModel {
        let model = TableTabModel(table: table, driver: driver, connectionTag: .local)
        await model.reload()
        return model
    }

    /// Edits row 1 and 2; row 2 is deleted elsewhere first. Nothing must be saved.
    private func checkDeletedRow(
        _ driver: any DatabaseDriver,
        _ other: any DatabaseDriver,
        table: TableRef
    ) async throws {
        let d = try XCTUnwrap(driver.dialect.sql)
        let model = await model(driver, table)
        XCTAssertEqual(model.rows.count, 2)
        let v = try XCTUnwrap(model.resultColumns.firstIndex(of: "v"))
        model.setValue("edited 1", row: 0, column: v)
        model.setValue("edited 2", row: 1, column: v)
        _ = try await other.execute("DELETE FROM \(d.qualified(table)) WHERE id = 2")
        await model.commit()
        let error = try XCTUnwrap(model.error, "the commit must fail")
        XCTAssertTrue(error.contains("Row 2 wasn't found"), error)
        let saved = try await other.execute("SELECT v FROM \(d.qualified(table)) ORDER BY id").rows
        XCTAssertEqual(saved, [["one"]], "the edit of row 1 was rolled back too")
        // A commit that reaches every row still saves.
        let fresh = await self.model(driver, table)
        fresh.setValue("edited 1", row: 0, column: v)
        await fresh.commit()
        XCTAssertNil(fresh.error)
        let after = try await other.execute("SELECT v FROM \(d.qualified(table)) ORDER BY id").rows
        XCTAssertEqual(after, [["edited 1"]])
    }

    func testSQLite() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("tabula-commit-\(UUID()).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let setup = try SQLiteDriver(path: path)
        _ = try await setup.executeScript(
            "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT); INSERT INTO t VALUES (1, 'one'), (2, 'two');"
        )
        try await checkDeletedRow(try SQLiteDriver(path: path), setup, table: TableRef(schema: "main", name: "t"))
        await setup.close()
    }

    func testPostgres() async throws {
        guard let port = env["TABULA_TEST_PG_PORT"].flatMap(Int.init) else {
            throw XCTSkip("TABULA_TEST_PG_PORT not set")
        }
        let config = ConnectionConfig(kind: .postgres, port: port, user: "tabula", database: "tabula")
        let driver = try await DriverFactory.connect(config, password: "tabula")
        let other = try await DriverFactory.connect(config, password: "tabula")
        let name = "commit_" + UUID().uuidString.prefix(8).lowercased()
        _ = try await other.executeScript(
            "CREATE TABLE \(name) (id int PRIMARY KEY, v text); INSERT INTO \(name) VALUES (1, 'one'), (2, 'two');"
        )
        do {
            try await checkDeletedRow(driver, other, table: TableRef(schema: "public", name: name))
        } catch {
            _ = try? await other.execute("DROP TABLE \(name)")
            throw error
        }
        _ = try await other.execute("DROP TABLE \(name)")
        await driver.close()
        await other.close()
    }

    func testMySQLIncludingAFloatKey() async throws {
        guard let port = env["TABULA_TEST_MYSQL_PORT"].flatMap(Int.init) else {
            throw XCTSkip("TABULA_TEST_MYSQL_PORT not set")
        }
        let config = ConnectionConfig(kind: .mysql, port: port, user: "tabula", database: "tabula")
        let driver = try await DriverFactory.connect(config, password: "tabula")
        let other = try await DriverFactory.connect(config, password: "tabula")
        let name = "commit_" + UUID().uuidString.prefix(8).lowercased()
        do {
            _ = try await other.executeScript(
                "CREATE TABLE \(name) (id INT PRIMARY KEY, v VARCHAR(20)); INSERT INTO \(name) VALUES (1, 'one'), (2, 'two');"
            )
            try await checkDeletedRow(driver, other, table: TableRef(schema: "tabula", name: name))
            // A FLOAT key shown as 1.1 holds a value no '1.1' equals: the edit would match nothing.
            _ = try await other.executeScript(
                "CREATE TABLE \(name)_f (k FLOAT PRIMARY KEY, v VARCHAR(20)); INSERT INTO \(name)_f VALUES (1.1, 'a');"
            )
            let floats = await model(driver, TableRef(schema: "tabula", name: "\(name)_f"))
            floats.setValue("b", row: 0, column: try XCTUnwrap(floats.resultColumns.firstIndex(of: "v")))
            await floats.commit()
            XCTAssertTrue(floats.error?.contains("wasn't found") == true, floats.error ?? "no error")
            // Rewriting a value as it is (MySQL counts no changed row) is still fine.
            let same = await model(driver, TableRef(schema: "tabula", name: name))
            same.setValue("edited 1 ", row: 0, column: try XCTUnwrap(same.resultColumns.firstIndex(of: "v")))
            same.setValue("edited 1", row: 0, column: try XCTUnwrap(same.resultColumns.firstIndex(of: "v")))
            XCTAssertFalse(same.hasChanges, "setting the shown value back is no change")
        } catch {
            _ = try? await other.execute("DROP TABLE IF EXISTS \(name)")
            _ = try? await other.execute("DROP TABLE IF EXISTS \(name)_f")
            await driver.close()
            await other.close()
            throw error
        }
        _ = try await other.execute("DROP TABLE \(name)")
        _ = try await other.execute("DROP TABLE \(name)_f")
        await driver.close()
        await other.close()
    }
}
