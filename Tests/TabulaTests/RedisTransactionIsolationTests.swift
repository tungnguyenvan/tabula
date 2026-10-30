import XCTest

@testable import TabulaFoundation
@testable import TabulaRedis

/// The browser's own transactions (renames, list removals) never take in another command sent meanwhile on the
/// same connection, such as a key scan.
final class RedisTransactionIsolationTests: XCTestCase {
    func testCommandsSentDuringATransactionAreAnswered() async throws {
        guard let port = ProcessInfo.processInfo.environment["TABULA_TEST_REDIS_PORT"].flatMap(Int.init) else {
            throw XCTSkip("TABULA_TEST_REDIS_PORT not set")
        }
        let driver = try await RedisDriver.connect(
            ConnectionConfig(kind: .redis, port: port, user: "tabula", database: "13"),
            password: "tabula"
        )
        _ = try await driver.send("FLUSHDB")
        _ = try await driver.send("SET", "x", "value")
        _ = try await driver.send("SADD", "s", "m0")
        let reader = Task { () -> [RedisReply] in
            var replies: [RedisReply] = []
            for _ in 0..<300 {
                replies.append(try await driver.send("GET", "x"))
            }
            return replies
        }
        for index in 0..<100 {
            try await driver.update(
                RedisBytes("s"),
                type: .set,
                element: RedisBytes("m\(index)"),
                column: 0,
                to: RedisBytes("m\(index + 1)"),
                row: [RedisBytes("m\(index)")]
            )
        }
        let replies = try await reader.value
        XCTAssertEqual(Set(replies.map { "\($0)" }), ["\(RedisReply.bulk(Array("value".utf8)))"], "never QUEUED")
        let members = try await driver.send("SMEMBERS", "s")
        XCTAssertEqual(members.array.compactMap(\.string), ["m100"])
        // A transaction Redis refuses to queue reports why and changes nothing.
        do {
            try await driver.transaction([[.text("SET"), .text("y")], [.text("SET"), .text("z"), .text("1")]])
            XCTFail("a malformed command aborts the transaction")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("EXECABORT"), error.localizedDescription)
        }
        let z = try await driver.send("EXISTS", "z")
        XCTAssertEqual(z, .integer(0))
        _ = try await driver.send("FLUSHDB")
        await driver.close()
    }
}
