import XCTest

@testable import TabulaFoundation
@testable import TabulaRedis

final class RedisStopTests: XCTestCase {
    private func bytes(_ words: String...) -> [[UInt8]] { words.map { Array($0.utf8) } }

    func testWhichCommandsCanBeStopped() {
        XCTAssertEqual(RedisStop(for: bytes("eval", "return 1", "0")), .script)
        XCTAssertEqual(RedisStop(for: bytes("EVALSHA_RO", "abc", "0")), .script)
        XCTAssertEqual(RedisStop(for: bytes("fcall", "f", "0")), .function)
        XCTAssertEqual(RedisStop(for: bytes("BLPOP", "q", "30")), .unblock)
        XCTAssertEqual(RedisStop(for: bytes("XREAD", "BLOCK", "0", "STREAMS", "s", "$")), .unblock)
        XCTAssertEqual(
            RedisStop(for: bytes("XREAD", "STREAMS", "s", "0")),
            .unsupported,
            "without BLOCK it doesn't wait"
        )
        XCTAssertEqual(RedisStop(for: bytes("KEYS", "*")), .unsupported)
        XCTAssertEqual(RedisStop(for: []), .unsupported)
    }
}

/// Against the test Redis (TABULA_TEST_REDIS_PORT, user and password "tabula").
final class RedisStopIntegrationTests: XCTestCase {
    private func config() throws -> ConnectionConfig {
        guard let port = ProcessInfo.processInfo.environment["TABULA_TEST_REDIS_PORT"].flatMap(Int.init) else {
            throw XCTSkip("TABULA_TEST_REDIS_PORT not set")
        }
        return ConnectionConfig(kind: .redis, port: port, user: "tabula", database: "9")
    }

    func testStopKillsARunningScript() async throws {
        let config = try config()
        let driver = try await RedisDriver.connect(config, password: "tabula")
        // Redis takes SCRIPT KILL once a script has run for busy-reply-threshold (5 s by default); this one runs
        // well past that, but ends on its own if the kill fails, so the test server isn't held for good.
        let script = "local i = 0 while i < 2000000000 do i = i + 1 end return i"
        let run = Task { try await driver.send("EVAL", script, "0") }
        try await Task.sleep(for: .milliseconds(300))
        let started = Date()
        let failure = await driver.stopRunningCommand(.script, config: config, password: "tabula")
        XCTAssertNil(failure)
        let reply = try await run.value
        guard case .error(let message) = reply else {
            return XCTFail("expected the script to be killed, got \(reply)")
        }
        XCTAssertTrue(message.localizedCaseInsensitiveContains("kill"), message)
        XCTAssertLessThan(Date().timeIntervalSince(started), 8)
        let ping = try await driver.send("PING")
        XCTAssertEqual(ping, .status("PONG"))
        await driver.close()
    }

    func testStopUnblocksABlockingCommand() async throws {
        let config = try config()
        let driver = try await RedisDriver.connect(config, password: "tabula")
        let key = "tabula:stop:" + UUID().uuidString
        let run = Task { try await driver.send("BLPOP", key, "20") }
        try await Task.sleep(for: .milliseconds(300))
        let started = Date()
        let failure = await driver.stopRunningCommand(.unblock, config: config, password: "tabula")
        XCTAssertNil(failure)
        let reply = try await run.value
        guard case .error(let message) = reply else {
            return XCTFail("expected the command to be unblocked, got \(reply)")
        }
        XCTAssertTrue(message.contains("UNBLOCKED"), message)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        // Nothing left to stop: the server says so.
        let again = await driver.stopRunningCommand(.unblock, config: config, password: "tabula")
        XCTAssertEqual(again, "The command had already finished.")
        let none = await driver.stopRunningCommand(.script, config: config, password: "tabula")
        XCTAssertTrue(none?.contains("NOTBUSY") == true, none ?? "")
        await driver.close()
    }
}
