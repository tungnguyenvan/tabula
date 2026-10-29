import XCTest

@testable import Tabula
@testable import TabulaFoundation
@testable import TabulaRedis

/// The Redis browser and console against the test Redis, in database 12, which nothing else uses.
@MainActor
final class RedisModelTests: XCTestCase {
    private func workspace() async throws -> RedisWorkspaceModel {
        guard let port = ProcessInfo.processInfo.environment["TABULA_TEST_REDIS_PORT"].flatMap(Int.init) else {
            throw XCTSkip("TABULA_TEST_REDIS_PORT not set")
        }
        let config = ConnectionConfig(kind: .redis, port: port, user: "tabula", database: "12")
        let seed = try await RedisDriver.connect(config, password: "tabula")
        _ = try await seed.send("FLUSHDB")
        for index in [1, 2, 10] {
            _ = try await seed.send("SET", "item:\(index)", "value \(index)")
        }
        _ = try await seed.send("HSET", "user:1", "name", "Ann", "city", "Huế")
        _ = try await seed.send("RPUSH", "queue", "a", "b", "c")
        await seed.close()
        let model = RedisWorkspaceModel(config: config, password: "tabula")
        await model.connect()
        guard case .connected = model.status else {
            XCTFail("not connected: \(model.status)")
            throw XCTSkip("no connection")
        }
        return model
    }

    private func names(_ model: RedisWorkspaceModel) -> [String] { model.keys.map(\.key.display) }

    func testKeysInNaturalOrderAndFilters() async throws {
        let model = try await workspace()
        XCTAssertEqual(names(model), ["item:1", "item:2", "item:10", "queue", "user:1"])
        XCTAssertEqual(model.database, 12)
        model.pattern = "item:*"
        await model.reloadKeys()
        XCTAssertEqual(names(model), ["item:1", "item:2", "item:10"])
        model.pattern = "*"
        model.typeFilter = .hash
        await model.reloadKeys()
        XCTAssertEqual(names(model), ["user:1"])
        await model.disconnect()
    }

    func testInlineEditsRenameAndTTL() async throws {
        let model = try await workspace()
        let row = try XCTUnwrap(model.keys.firstIndex { $0.key.display == "item:2" })
        XCTAssertTrue(model.isEditable(row: row, column: RedisWorkspaceModel.KeyColumn.value.rawValue))
        XCTAssertFalse(model.isEditable(row: row, column: RedisWorkspaceModel.KeyColumn.type.rawValue))
        await model.edit(row: row, column: RedisWorkspaceModel.KeyColumn.value.rawValue, value: "changed")
        XCTAssertNil(model.keysError)
        XCTAssertEqual(model.keys[row].preview, "changed")

        await model.edit(row: row, column: RedisWorkspaceModel.KeyColumn.ttl.rawValue, value: "100")
        let ttl = try XCTUnwrap(model.keys.first { $0.key.display == "item:2" }?.ttlMilliseconds)
        XCTAssertGreaterThan(ttl, 90_000)

        await model.edit(row: row, column: RedisWorkspaceModel.KeyColumn.key.rawValue, value: "item:3")
        XCTAssertEqual(names(model), ["item:1", "item:3", "item:10", "queue", "user:1"])
        XCTAssertEqual(model.selectedKey?.display, "item:3")
        await model.disconnect()
    }

    func testCreateRefusesAnExistingKeyAndDeleteRemoves() async throws {
        let model = try await workspace()
        do {
            try await model.create(key: RedisBytes("queue"), type: .list, values: [RedisBytes("x")], ttl: nil)
            XCTFail("expected an existing key to be refused")
        } catch {
            XCTAssertEqual(error.localizedDescription, "A key named “queue” already exists.")
        }
        try await model.create(key: RedisBytes("tags"), type: .set, values: [RedisBytes("red")], ttl: 60)
        XCTAssertEqual(model.selectedKey?.display, "tags")
        await model.delete([RedisBytes("tags"), RedisBytes("item:1")])
        XCTAssertEqual(names(model), ["item:2", "item:10", "queue", "user:1"])
        await model.disconnect()
    }

    func testKeyDetailEditsAHash() async throws {
        let model = try await workspace()
        let driver = try XCTUnwrap(model.driver)
        let key = RedisKeyModel(key: RedisBytes("user:1"), driver: driver, workspace: model)
        await key.reload()
        XCTAssertEqual(key.type, .hash)
        XCTAssertTrue(key.canEditCells)
        let city = try XCTUnwrap(key.rows.firstIndex { $0[0].display == "city" })
        await key.update(row: city, column: 1, to: "Đà Nẵng")
        XCTAssertNil(key.error)
        XCTAssertEqual(key.rows.first { $0[0].display == "city" }?[1].display, "Đà Nẵng")
        await key.add(["email", "ann@example.com"])
        XCTAssertEqual(key.rows.count, 3)
        let name = try XCTUnwrap(key.rows.firstIndex { $0[0].display == "name" })
        await key.remove(rows: IndexSet(integer: name))
        XCTAssertEqual(key.rows.map { $0[0].display }.sorted(), ["city", "email"])
        await model.disconnect()
    }

    func testListIndexesAreNotEditable() async throws {
        let model = try await workspace()
        let key = RedisKeyModel(key: RedisBytes("queue"), driver: try XCTUnwrap(model.driver), workspace: model)
        await key.reload()
        XCTAssertFalse(key.isEditable(row: 0, column: 0))
        XCTAssertTrue(key.isEditable(row: 0, column: 1))
        await key.update(row: 0, column: 0, to: "5")
        XCTAssertEqual(key.error, "List indexes can't be edited.")
        await model.disconnect()
    }

    func testConsoleRunsRefusesAndFollowsSelect() async throws {
        let model = try await workspace()
        let console = model.console
        console.input = "GET item:1"
        await console.run()
        XCTAssertEqual(console.entries.last?.output, "\"value 1\"")
        console.input = "BLPOP queue 0"
        await console.run()
        XCTAssertEqual(console.entries.last?.isError, true)
        XCTAssertTrue(console.entries.last?.output.contains("block forever") == true)
        console.input = "\"unclosed"
        await console.run()
        XCTAssertTrue(console.entries.last?.output.hasPrefix("Invalid argument(s)") == true)

        console.input = "SELECT 11"
        await console.run()
        XCTAssertEqual(model.database, 11, "the browser follows the console's SELECT")
        XCTAssertTrue(console.prompt.hasSuffix("[11]>"))
        console.input = "clear"
        await console.run()
        XCTAssertTrue(console.entries.isEmpty)
        await model.disconnect()
    }
}
