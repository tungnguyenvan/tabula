import XCTest

@testable import TabulaFoundation
@testable import TabulaRedis

final class RedisCommandLineTests: XCTestCase {
    private func parse(_ line: String) throws -> [String] {
        try RedisCommandLine.parse(line).map { String(decoding: $0, as: UTF8.self) }
    }

    func testParsingLikeRedisCli() throws {
        XCTAssertEqual(try parse("SET  key   value"), ["SET", "key", "value"])
        XCTAssertEqual(try parse(#"SET "my key" "a\"b\nc""#), ["SET", "my key", "a\"b\nc"])
        XCTAssertEqual(try parse(#"SET k 'it\'s \n raw'"#), ["SET", "k", #"it's \n raw"#])
        XCTAssertEqual(try RedisCommandLine.parse(#"SET k "\x00\xff""#)[2], [0x00, 0xFF])
        XCTAssertEqual(try parse(#"SET k """#), ["SET", "k", ""])
        XCTAssertEqual(try parse("GET Hà_Nội"), ["GET", "Hà_Nội"])
        XCTAssertThrowsError(try parse(#"SET k "open"#))
        XCTAssertThrowsError(try parse(#"SET k "a"b"#))
    }

    func testReplyFormatting() {
        XCTAssertEqual(RedisReply.status("OK").formatted(), "OK")
        XCTAssertEqual(RedisReply.integer(3).formatted(), "(integer) 3")
        XCTAssertEqual(RedisReply.null.formatted(), "(nil)")
        XCTAssertEqual(RedisReply.bulk(Array("Nội\n\u{1}".utf8)).formatted(), "\"Nội\\n\\x01\"")
        let nested = RedisReply.array([.bulk(Array("a".utf8)), .array([.integer(1), .null])])
        XCTAssertEqual(nested.formatted(), "1) \"a\"\n2) 1) (integer) 1\n   2) (nil)")
        XCTAssertEqual(RedisReply.array([]).formatted(), "(empty array)")
    }

    /// The console shares its connection with the key browser, so commands that would hold it are refused.
    func testCommandsThatWouldHoldTheConnectionAreRefused() throws {
        for line in ["multi", "WATCH k", "SUBSCRIBE news", "MONITOR"] {
            XCTAssertNotNil(RedisCommandLine.refusal(for: try RedisCommandLine.parse(line)), line)
        }
        for line in ["EXEC", "GET k", "EVAL \"return 1\" 0"] {
            XCTAssertNil(RedisCommandLine.refusal(for: try RedisCommandLine.parse(line)), line)
        }
    }

    func testReadOnlyCommands() throws {
        func readOnly(_ line: String) throws -> Bool { RedisCommandLine.isReadOnly(try RedisCommandLine.parse(line)) }
        XCTAssertTrue(try readOnly("get user:1"))
        XCTAssertTrue(try readOnly("HGETALL h"))
        XCTAssertTrue(try readOnly("config get maxmemory"))
        XCTAssertFalse(try readOnly("config set maxmemory 1"))
        // Writes missing from any list still count as writes.
        XCTAssertFalse(try readOnly("SETEX k 10 v"))
        XCTAssertFalse(try readOnly("HINCRBY h f 1"))
        XCTAssertFalse(try readOnly("SOMEFUTURECOMMAND x"))
        // WAIT numreplicas timeout: only the second argument is the timeout.
        XCTAssertNotNil(RedisCommandLine.refusal(for: try RedisCommandLine.parse("WAIT 1 0")))
        XCTAssertNil(RedisCommandLine.refusal(for: try RedisCommandLine.parse("WAIT 0 100")))
    }

    func testTTLParsing() throws {
        XCTAssertEqual(try RedisTTL.parse("3600"), 3600)
        XCTAssertEqual(try RedisTTL.parse("1h 30m"), 5400)
        XCTAssertEqual(try RedisTTL.parse("2d"), 172_800)
        XCTAssertEqual(try RedisTTL.parse("90S"), 90)
        XCTAssertNil(try RedisTTL.parse(""))
        XCTAssertNil(try RedisTTL.parse("none"))
        XCTAssertThrowsError(try RedisTTL.parse("0"))
        XCTAssertThrowsError(try RedisTTL.parse("soon"))
        XCTAssertThrowsError(try RedisTTL.parse("5x"))
        XCTAssertThrowsError(try RedisTTL.parse("1h 5"))
        XCTAssertEqual(RedisTTL.format(milliseconds: 5_400_000), "1h 30m")
        XCTAssertEqual(try RedisTTL.parse(RedisTTL.format(milliseconds: 93_784_000)), 93_600)  // shown as "1d 2h"
        XCTAssertEqual(RedisTTL.format(milliseconds: nil), "")
    }

    func testSafetyChecks() throws {
        XCTAssertNotNil(RedisCommandLine.refusal(for: try RedisCommandLine.parse("subscribe news")))
        XCTAssertNotNil(RedisCommandLine.refusal(for: try RedisCommandLine.parse("BLPOP q 0")))
        XCTAssertNil(RedisCommandLine.refusal(for: try RedisCommandLine.parse("BLPOP q 2")))
        XCTAssertNotNil(RedisCommandLine.refusal(for: try RedisCommandLine.parse("XREAD BLOCK 0 STREAMS s $")))
        XCTAssertTrue(RedisCommandLine.isDestructive(try RedisCommandLine.parse("flushall")))
        XCTAssertTrue(RedisCommandLine.isDestructive(try RedisCommandLine.parse("CONFIG set maxmemory 1")))
        XCTAssertFalse(RedisCommandLine.isDestructive(try RedisCommandLine.parse("CONFIG GET maxmemory")))
    }
}

/// Runs against a real Redis when TABULA_TEST_REDIS_PORT is set (user "tabula", password "tabula").
/// TABULA_TEST_REDIS_TLS_PORT adds a TLS server with a self-signed certificate.
final class RedisIntegrationTests: XCTestCase {
    private var port: Int?

    override func setUp() {
        port = ProcessInfo.processInfo.environment["TABULA_TEST_REDIS_PORT"].flatMap(Int.init)
    }

    private func connect(
        user: String = "tabula",
        password: String? = "tabula",
        database: String = "9"
    ) async throws -> RedisDriver {
        guard let port else { throw XCTSkip("TABULA_TEST_REDIS_PORT not set") }
        return try await RedisDriver.connect(
            ConnectionConfig(kind: .redis, port: port, user: user, database: database),
            password: password
        )
    }

    func testAuthentication() async throws {
        guard port != nil else { throw XCTSkip("TABULA_TEST_REDIS_PORT not set") }
        do {
            _ = try await connect(password: "wrong")
            XCTFail("expected an auth error")
        } catch {
            XCTAssertTrue(
                error.localizedDescription.localizedCaseInsensitiveContains("WRONGPASS"),
                error.localizedDescription
            )
        }
        // Password-only AUTH uses the default user, whose password is also "tabula" (requirepass).
        let legacy = try await connect(user: "", password: "tabula")
        XCTAssertTrue(legacy.serverDescription.hasPrefix("Redis 7"), legacy.serverDescription)
        await legacy.close()
    }

    func testTypesEditingAndTTL() async throws {
        let redis = try await connect()
        _ = try await redis.send("FLUSHDB")
        let database = await redis.database
        XCTAssertEqual(database, 9)

        // string, including binary and non-ASCII
        let user = RedisBytes("user:1:name")
        try await redis.setString(user, to: RedisBytes("Nguyễn"), keepTTL: false)
        let read = try await redis.string(user)
        XCTAssertEqual(read.value.text, "Nguyễn")
        let binaryKey = RedisBytes([0x62, 0x69, 0x6E, 0xFF])
        try await redis.setString(binaryKey, to: RedisBytes([0x00, 0xFE]), keepTTL: false)
        let awaited1 = try await redis.string(binaryKey).value.bytes
        XCTAssertEqual(awaited1, [0x00, 0xFE])
        XCTAssertEqual(binaryKey.display, "bin\\xff")

        // TTL is kept when the value is edited, and can be removed
        try await redis.setTTL(user, seconds: 100)
        try await redis.setString(user, to: RedisBytes("Tùng"))
        let ttl = try await redis.info(user).ttlMilliseconds ?? 0
        XCTAssertGreaterThan(ttl, 90_000)
        try await redis.setTTL(user, seconds: nil)
        let awaited2 = try await redis.info(user).ttlMilliseconds
        XCTAssertNil(awaited2)

        // hash: add, edit value, rename field (refuses to overwrite), delete
        let hash = RedisBytes("user:1")
        for (field, value) in [("name", "An"), ("city", "Huế"), ("age", "30")] {
            try await redis.add(hash, type: .hash, values: [RedisBytes(field), RedisBytes(value)])
        }
        var page = try await redis.page(hash, type: .hash, after: nil)
        XCTAssertEqual(page.columns, ["field", "value"])
        XCTAssertEqual(Set(page.rows.map { $0[0].display }), ["name", "city", "age"])
        try await redis.update(
            hash,
            type: .hash,
            element: RedisBytes("city"),
            column: 1,
            to: RedisBytes("Đà Lạt"),
            row: [RedisBytes("city"), RedisBytes("Huế")]
        )
        try await redis.update(
            hash,
            type: .hash,
            element: RedisBytes("age"),
            column: 0,
            to: RedisBytes("years"),
            row: [RedisBytes("age"), RedisBytes("30")]
        )
        do {
            try await redis.update(
                hash,
                type: .hash,
                element: RedisBytes("years"),
                column: 0,
                to: RedisBytes("name"),
                row: [RedisBytes("years"), RedisBytes("30")]
            )
            XCTFail("renaming onto an existing field must fail")
        } catch {}
        try await redis.remove(hash, type: .hash, elements: [RedisBytes("name")])
        page = try await redis.page(hash, type: .hash, after: nil)
        let fields = Dictionary(uniqueKeysWithValues: page.rows.map { ($0[0].display, $0[1].display) })
        XCTAssertEqual(fields, ["city": "Đà Lạt", "years": "30"])

        // list: paging, LSET, delete by index (including duplicate values)
        let list = RedisBytes("queue")
        for value in ["a", "b", "a", "c"] { try await redis.add(list, type: .list, values: [RedisBytes(value)]) }
        try await redis.update(list, type: .list, element: RedisBytes("3"), column: 1, to: RedisBytes("z"), row: [])
        try await redis.remove(list, type: .list, elements: [RedisBytes("0")])
        let listPage = try await redis.page(list, type: .list, after: nil, count: 2)
        XCTAssertEqual(listPage.rows.map { $0[1].display }, ["b", "a"])
        XCTAssertEqual(listPage.next, "2")
        let listRest = try await redis.page(list, type: .list, after: listPage.next, count: 2)
        XCTAssertEqual(listRest.rows.map { $0[1].display }, ["z"])
        XCTAssertNil(listRest.next)

        // set and sorted set
        let set = RedisBytes("tags")
        for member in ["x", "y"] { try await redis.add(set, type: .set, values: [RedisBytes(member)]) }
        try await redis.update(
            set,
            type: .set,
            element: RedisBytes("y"),
            column: 0,
            to: RedisBytes("w"),
            row: [RedisBytes("y")]
        )
        let awaited3 = try await redis.page(set, type: .set, after: nil).rows.map { $0[0].display }
        XCTAssertEqual(Set(awaited3), ["x", "w"])

        let zset = RedisBytes("scores")
        try await redis.add(zset, type: .zset, values: [RedisBytes("an"), RedisBytes("10")])
        try await redis.add(zset, type: .zset, values: [RedisBytes("binh"), RedisBytes("2.5")])
        try await redis.update(
            zset,
            type: .zset,
            element: RedisBytes("an"),
            column: 1,
            to: RedisBytes("1"),
            row: [RedisBytes("an"), RedisBytes("10")]
        )
        do {
            try await redis.add(zset, type: .zset, values: [RedisBytes("c"), RedisBytes("not-a-number")])
            XCTFail("non-numeric score must fail")
        } catch {}
        let zrows = try await redis.page(zset, type: .zset, after: nil).rows.map { [$0[0].display, $0[1].display] }
        XCTAssertEqual(zrows, [["an", "1"], ["binh", "2.5"]])

        // stream: add entries, page with exclusive start, delete
        let stream = RedisBytes("events")
        for index in 0..<3 {
            try await redis.add(
                stream,
                type: .stream,
                values: [RedisBytes("n"), RedisBytes(String(index)), RedisBytes("kind"), RedisBytes("click")]
            )
        }
        let first = try await redis.page(stream, type: .stream, after: nil, count: 2)
        XCTAssertEqual(first.columns, ["id", "n", "kind"])
        XCTAssertEqual(first.rows.map { $0[1].display }, ["0", "1"])
        let second = try await redis.page(stream, type: .stream, after: first.next, count: 2)
        XCTAssertEqual(second.rows.map { $0[1].display }, ["2"])
        try await redis.remove(stream, type: .stream, elements: [first.rows[0][0]])
        let awaited4 = try await redis.info(stream).length
        XCTAssertEqual(awaited4, 2)

        // keys: scan with pattern and type filter, pipelined TYPE, rename (no overwrite), delete
        let all = try await redis.scanKeys(match: "*", type: nil)
        XCTAssertEqual(all.cursor, "0")
        XCTAssertEqual(all.keys.count, 7)
        let users = try await redis.scanKeys(match: "user:*", type: nil)
        XCTAssertEqual(Set(users.keys.map(\.display)), ["user:1", "user:1:name"])
        let hashes = try await redis.scanKeys(match: "*", type: .hash)
        XCTAssertEqual(hashes.keys.map(\.display), ["user:1"])
        let types = try await redis.types(of: [hash, list, set, zset, stream, user])
        XCTAssertEqual(types, [.hash, .list, .set, .zset, .stream, .string])
        do {
            try await redis.rename(set, to: zset)
            XCTFail("rename must not overwrite")
        } catch {}
        try await redis.rename(set, to: RedisBytes("labels"))
        let awaited5 = try await redis.exists(set)
        XCTAssertFalse(awaited5)
        let awaited6 = try await redis.delete([RedisBytes("labels"), list])
        XCTAssertEqual(awaited6, 2)

        // summaries for the keys table: type, TTL, length and previews; deleted keys are dropped
        try await redis.setTTL(hash, seconds: 500)
        let summaries = try await redis.summaries(of: [user, hash, zset, stream, RedisBytes("missing"), binaryKey])
        XCTAssertEqual(summaries.map(\.key), [user, hash, zset, stream, binaryKey])
        XCTAssertEqual(summaries.map(\.type), [.string, .hash, .zset, .stream, .string])
        XCTAssertEqual(summaries[0].preview, "Tùng")
        XCTAssertEqual(summaries[0].length, "Tùng".utf8.count)
        XCTAssertNil(summaries[0].ttlMilliseconds)
        XCTAssertGreaterThan(summaries[1].ttlMilliseconds ?? 0, 490_000)
        XCTAssertEqual(summaries[1].length, 2)
        XCTAssertTrue(
            summaries[1].preview.hasPrefix("{") && summaries[1].preview.contains("city: Đà Lạt"),
            summaries[1].preview
        )
        XCTAssertEqual(summaries[2].preview, "[an (1), binh (2.5)]")
        XCTAssertTrue(
            summaries[3].preview.hasPrefix("latest ") && summaries[3].preview.contains("n=2"),
            summaries[3].preview
        )
        XCTAssertEqual(summaries[4].preview, "\\x00\\xfe")

        // databases list includes this one, with its key count
        let databases = try await redis.databases()
        XCTAssertEqual(databases.first(where: { $0.index == 9 })?.keys, 5)
        XCTAssertGreaterThanOrEqual(databases.count, 16)

        // console: errors are replies, SELECT tracks the database
        if case .error(let message) = try await redis.send(try RedisCommandLine.parse("HGET user:1:name x")) {
            XCTAssertTrue(message.contains("WRONGTYPE"), message)
        } else {
            XCTFail("expected WRONGTYPE")
        }
        _ = try await redis.send(try RedisCommandLine.parse("SELECT 8"))
        let selected = await redis.database
        XCTAssertEqual(selected, 8)

        _ = try await redis.send("SELECT", "9")
        _ = try await redis.send("FLUSHDB")
        await redis.close()
    }

    func testLargeCollectionsPage() async throws {
        let redis = try await connect(database: "10")
        _ = try await redis.send("FLUSHDB")
        let key = RedisBytes("big")
        let members = (0..<1500).flatMap { ["field\($0)", "v\($0)"] }
        _ = try await redis.send((["HSET", "big"] + members).map { Array($0.utf8) })
        var seen = Set<String>()
        var next: String?
        var pages = 0
        repeat {
            let page = try await redis.page(key, type: .hash, after: next)
            seen.formUnion(page.rows.map { $0[0].display })
            next = page.next
            pages += 1
        } while next != nil && pages < 100
        XCTAssertEqual(seen.count, 1500)
        XCTAssertGreaterThan(pages, 1)

        let big = String(repeating: "x", count: RedisDriver.maxEditableStringBytes + 10)
        _ = try await redis.send("SET", "huge", big)
        let read = try await redis.string(RedisBytes("huge"))
        XCTAssertTrue(read.truncated)
        XCTAssertEqual(read.value.bytes.count, RedisDriver.maxEditableStringBytes)
        _ = try await redis.send("FLUSHDB")
        await redis.close()
    }

    func testTLS() async throws {
        guard let tlsPort = ProcessInfo.processInfo.environment["TABULA_TEST_REDIS_TLS_PORT"].flatMap(Int.init) else {
            throw XCTSkip("TABULA_TEST_REDIS_TLS_PORT not set")
        }
        let config = ConnectionConfig(kind: .redis, port: tlsPort, user: "", tls: .require)
        let redis = try await RedisDriver.connect(config, password: "tabula")
        let awaited7 = try await redis.send("PING")
        XCTAssertEqual(awaited7, .status("PONG"))
        await redis.close()

        // A self-signed certificate must fail verification.
        var verified = config
        verified.tls = .verifyFull
        do {
            _ = try await RedisDriver.connect(verified, password: "tabula")
            XCTFail("expected certificate verification to fail")
        } catch {}

        // Plain TCP to a TLS port must fail rather than hang.
        var plain = config
        plain.tls = .disable
        do {
            _ = try await RedisDriver.connect(plain, password: "tabula")
            XCTFail("expected plain connection to a TLS port to fail")
        } catch {}
    }
}
