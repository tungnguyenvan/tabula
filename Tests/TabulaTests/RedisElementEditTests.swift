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

/// List edits address elements by position; deleting rows must remove exactly those positions, duplicates
/// included, and the longest TTL the parser accepts must be one Redis accepts.
final class RedisListAndTTLTests: XCTestCase {
    func testDeletingListRowsRemovesThosePositions() async throws {
        guard let port = ProcessInfo.processInfo.environment["TABULA_TEST_REDIS_PORT"].flatMap(Int.init) else {
            throw XCTSkip("TABULA_TEST_REDIS_PORT not set")
        }
        let driver = try await RedisDriver.connect(
            ConnectionConfig(kind: .redis, port: port, user: "tabula", database: "13"),
            password: "tabula"
        )
        _ = try await driver.send("FLUSHDB")
        _ = try await driver.send("RPUSH", "l", "a", "dup", "b", "dup", "c", "dup")
        // Rows 1 and 5 hold "dup", as does row 3, which stays.
        try await driver.remove(
            RedisBytes("l"),
            type: .list,
            elements: [RedisBytes("1"), RedisBytes("5"), RedisBytes("0")]
        )
        let left = try await driver.send("LRANGE", "l", "0", "-1")
        XCTAssertEqual(left.array.compactMap(\.string), ["b", "dup", "c"])
        try await driver.update(
            RedisBytes("l"),
            type: .list,
            element: RedisBytes("2"),
            column: 1,
            to: RedisBytes("C"),
            row: [RedisBytes("2"), RedisBytes("c")]
        )
        let edited = try await driver.send("LRANGE", "l", "0", "-1")
        XCTAssertEqual(edited.array.compactMap(\.string), ["b", "dup", "C"])

        _ = try await driver.send("SET", "k", "v")
        try await driver.setTTL(RedisBytes("k"), seconds: RedisTTL.maxSeconds)
        let ttl = try await driver.send("TTL", "k")
        guard case .integer(let seconds) = ttl else { return XCTFail("TTL: \(ttl)") }
        XCTAssertGreaterThan(seconds, 0, "Redis took the longest TTL the parser accepts")
        _ = try await driver.send("FLUSHDB")
        await driver.close()
    }
}

/// Streams in the key browser: entries page in order by id, entries with different fields share columns, adding
/// and deleting work, and a stream's id column can't be edited.
final class RedisStreamTests: XCTestCase {
    func testStreamPagesAddsAndDeletes() async throws {
        guard let port = ProcessInfo.processInfo.environment["TABULA_TEST_REDIS_PORT"].flatMap(Int.init) else {
            throw XCTSkip("TABULA_TEST_REDIS_PORT not set")
        }
        let driver = try await RedisDriver.connect(
            ConnectionConfig(kind: .redis, port: port, user: "tabula", database: "13"),
            password: "tabula"
        )
        _ = try await driver.send("FLUSHDB")
        let key = RedisBytes("events")
        for index in 0..<(Defaults.Redis.pageSize + 5) {
            _ = try await driver.send("XADD", "events", "\(index + 1)-0", "n", String(index))
        }
        _ = try await driver.send("XADD", "events", "9999999999999-0", "other", "é", "n", "last")

        var page = try await driver.page(key, type: .stream, after: nil)
        var ids = page.rows.map { $0[0].display }
        while let next = page.next {
            page = try await driver.page(key, type: .stream, after: next)
            ids += page.rows.map { $0[0].display }
        }
        XCTAssertEqual(ids.count, Defaults.Redis.pageSize + 6, "every entry once")
        XCTAssertEqual(ids.first, "1-0")
        XCTAssertEqual(ids.last, "9999999999999-0")
        XCTAssertEqual(Set(ids).count, ids.count, "no entry repeated across pages")

        try await driver.add(
            key,
            type: .stream,
            values: [RedisBytes("a"), RedisBytes("1"), RedisBytes("b"), RedisBytes("2")]
        )
        do {
            try await driver.add(key, type: .stream, values: [RedisBytes("odd")])
            XCTFail("an entry needs field/value pairs")
        } catch {}
        try await driver.remove(key, type: .stream, elements: [RedisBytes("1-0"), RedisBytes("9999999999999-0")])
        let length = try await driver.send("XLEN", "events")
        XCTAssertEqual(length, .integer(Int(Defaults.Redis.pageSize) + 5))
        do {
            try await driver.update(
                key,
                type: .stream,
                element: RedisBytes("2-0"),
                column: 1,
                to: RedisBytes("x"),
                row: []
            )
            XCTFail("stream entries can't be edited in place")
        } catch {
            XCTAssertEqual(error.localizedDescription, "This value can't be edited in place.")
        }
        _ = try await driver.send("FLUSHDB")
        await driver.close()
    }
}
