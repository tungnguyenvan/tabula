import XCTest

@testable import TabulaFoundation
@testable import TabulaRedis

/// Editing elements in the key browser on the test Redis (database 13): renaming a field or member onto one that
/// exists is refused, as it would silently drop an element or overwrite its score.
final class RedisElementEditTests: XCTestCase {
    private func connect() async throws -> RedisDriver {
        guard let port = ProcessInfo.processInfo.environment["TABULA_TEST_REDIS_PORT"].flatMap(Int.init) else {
            throw XCTSkip("TABULA_TEST_REDIS_PORT not set")
        }
        let driver = try await RedisDriver.connect(
            ConnectionConfig(kind: .redis, port: port, user: "tabula", database: "13"),
            password: "tabula"
        )
        _ = try await driver.send("FLUSHDB")
        return driver
    }

    private func bytes(_ text: String) -> RedisBytes { RedisBytes(text) }

    func testRenamingOntoAnExistingMemberIsRefused() async throws {
        let driver = try await connect()
        _ = try await driver.send("SADD", "s", "a", "b")
        _ = try await driver.send("ZADD", "z", "1", "a", "2", "b")
        _ = try await driver.send("HSET", "h", "a", "1", "b", "2")

        for (key, type, row) in [
            ("s", RedisKeyType.set, [bytes("a")]), ("z", .zset, [bytes("a"), bytes("1")]),
            ("h", .hash, [bytes("a"), bytes("1")]),
        ] {
            do {
                try await driver.update(
                    bytes(key),
                    type: type,
                    element: bytes("a"),
                    column: 0,
                    to: bytes("b"),
                    row: row
                )
                XCTFail("renaming \(type) member a onto b must be refused")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("already exists"), error.localizedDescription)
            }
        }
        let set = try await driver.send("SCARD", "s")
        XCTAssertEqual(set, .integer(2), "no member was lost")
        let score = try await driver.send("ZSCORE", "z", "b")
        XCTAssertEqual(score.string, "2", "b keeps its score")

        // Renaming to a new name moves the element and keeps its value or score.
        try await driver.update(
            bytes("s"),
            type: .set,
            element: bytes("a"),
            column: 0,
            to: bytes("c"),
            row: [bytes("a")]
        )
        try await driver.update(
            bytes("z"),
            type: .zset,
            element: bytes("a"),
            column: 0,
            to: bytes("c"),
            row: [bytes("a"), bytes("1")]
        )
        let members = try await driver.send("SMEMBERS", "s")
        XCTAssertEqual(Set(members.array.compactMap(\.string)), ["b", "c"])
        let moved = try await driver.send("ZSCORE", "z", "c")
        XCTAssertEqual(moved.string, "1")
        _ = try await driver.send("FLUSHDB")
        await driver.close()
    }
}
