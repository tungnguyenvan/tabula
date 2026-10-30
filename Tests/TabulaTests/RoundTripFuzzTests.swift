import BSON
import XCTest

@testable import Tabula
@testable import TabulaConnections
@testable import TabulaDrivers
@testable import TabulaFoundation
@testable import TabulaMongo
@testable import TabulaRedis
@testable import TabulaSQLite

/// Seeded random round trips: what Tabula writes, it reads back as it was.
@MainActor
final class RoundTripFuzzTests: XCTestCase {
    /// A fixed sequence, so a failure repeats.
    private struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
    }

    /// Rows copied from one table and pasted into another come back cell for cell, through tabs, line breaks,
    /// quotes, NUL and Unicode. (The text "NULL" pastes as NULL, as Copy writes NULL, so it isn't generated.)
    func testCopiedRowsPasteBackAsTheyWere() async throws {
        let pieces = [
            "", " ", "\t", "\n", "\r\n", "\r", "\"", "\"\"", "'", "\\", "null", "a", "Hà Nội", "😀", "%", ",", ";",
            "\u{2028}", " x ", "\u{0}", "1e5", "0001",
        ]
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("tabula-paste-\(UUID()).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let setup = try SQLiteDriver(path: path)
        _ = try await setup.execute("CREATE TABLE src (id INTEGER PRIMARY KEY, a TEXT, b TEXT, c TEXT)")
        _ = try await setup.execute("CREATE TABLE dst (id INTEGER PRIMARY KEY, a TEXT, b TEXT, c TEXT)")
        var random = Seeded(state: 0x5EED)
        for index in 1...300 {
            var row: [String?] = [String(index)]
            for _ in 0..<3 {
                if Int.random(in: 0..<8, using: &random) == 0 {
                    row.append(nil)
                    continue
                }
                let length = Int.random(in: 0...4, using: &random)
                row.append((0..<length).map { _ in pieces.randomElement(using: &random)! }.joined())
            }
            let values = zip(["id", "a", "b", "c"], row).map { (column: $0, value: $1) }
            _ = try await setup.execute(
                setup.dialect.insert(TableRef(schema: "main", name: "src"), values: values, binaryColumns: [])
            )
        }
        await setup.close()

        let source = TableTabModel(
            table: TableRef(schema: "main", name: "src"),
            driver: try SQLiteDriver(path: path),
            connectionTag: .local
        )
        source.pageSize = 1000
        await source.reload()
        let copied = TabSeparated.text([source.resultColumns] + source.copyRows(IndexSet(0..<source.rows.count)))
        let target = TableTabModel(
            table: TableRef(schema: "main", name: "dst"),
            driver: try SQLiteDriver(path: path),
            connectionTag: .local
        )
        await target.reload()
        target.paste(copied, row: nil, column: nil)
        await target.commit()
        XCTAssertNil(target.error)
        let check = try SQLiteDriver(path: path)
        let original = try await check.execute("SELECT id, a, b, c FROM src ORDER BY id").rows
        let pasted = try await check.execute("SELECT id, a, b, c FROM dst ORDER BY id").rows
        XCTAssertEqual(pasted.count, 300)
        for (before, after) in zip(original, pasted) where before != after {
            XCTFail("\(before) came back as \(after)")
        }
        await check.close()
    }

    /// Every millisecond of a date survives being written and read, before 1970 too, where truncation used to
    /// move it one millisecond on (#289).
    func testDatesKeepTheirMillisecond() throws {
        for milliseconds in stride(from: Int64(-5_000_000_000), to: 5_000_000_000, by: 7_777_777) + [
            -1, -1001, 253_402_300_799_999,
        ] {
            for text in [
                "{ d: ISODate(\"\(try XCTUnwrap(CivilTime.isoText(milliseconds: milliseconds)))\") }",
                "{ d: new Date(\(milliseconds)) }",
            ] {
                let document = try MongoShell.parseDocument(text)
                guard case .some(let date as Date) = document["d"] else {
                    return XCTFail(text)
                }
                // What BSON stored: reading it back divides by 1000, so round to see the stored millisecond.
                XCTAssertEqual(Int64((date.timeIntervalSince1970 * 1000).rounded()), milliseconds, text)
                XCTAssertEqual(
                    try MongoShell.parseDocument(MongoShell.format(document)).makeData(),
                    document.makeData(),
                    text
                )
            }
        }
    }

    /// The same copy and paste on the servers: quotes, backslashes (MySQL's escapes), comment markers, dollar
    /// quotes and, on MySQL, NUL. PostgreSQL text can't hold NUL, so it isn't generated there.
    func testCopiedRowsPasteBackOnServers() async throws {
        let env = ProcessInfo.processInfo.environment
        var servers: [(ConnectionConfig, String, Bool)] = []
        if let port = env["TABULA_TEST_PG_PORT"].flatMap(Int.init) {
            servers.append(
                (ConnectionConfig(kind: .postgres, port: port, user: "tabula", database: "tabula"), "public", false)
            )
        }
        if let port = env["TABULA_TEST_MYSQL_PORT"].flatMap(Int.init) {
            servers.append(
                (ConnectionConfig(kind: .mysql, port: port, user: "tabula", database: "tabula"), "tabula", true)
            )
        }
        guard !servers.isEmpty else {
            throw XCTSkip("TABULA_TEST_PG_PORT / TABULA_TEST_MYSQL_PORT not set")
        }
        var random = Seeded(state: 0xC0FFEE)
        for (config, schema, nul) in servers {
            var pieces = [
                "", " ", "\t", "\n", "\r\n", "\r", "\"", "\"\"", "'", "\\", "\\'", "null", "Hà Nội", "😀", "%", "_", ";",
                "\u{2028}", "1e5", "0001", "$$", "--", "/*", "`",
            ]
            if nul {
                pieces.append("\u{0}")
            }
            let driver = try await DriverFactory.connect(config, password: "tabula")
            let d = driver.dialect
            let suffix = UUID().uuidString.prefix(8).lowercased()
            let source = TableRef(schema: schema, name: "paste_src_\(suffix)")
            let target = TableRef(schema: schema, name: "paste_dst_\(suffix)")
            try await runThenClean(
                driver,
                cleanup: ["DROP TABLE \(d.qualified(source))", "DROP TABLE \(d.qualified(target))"]
            ) {
                for table in [source, target] {
                    _ = try await driver.execute(
                        "CREATE TABLE \(d.qualified(table)) (id INT PRIMARY KEY, a TEXT, b TEXT)"
                    )
                }
                for index in 1...150 {
                    var row: [String?] = [String(index)]
                    for _ in 0..<2 {
                        let length = Int.random(in: 0...4, using: &random)
                        row.append(
                            Int.random(in: 0..<8, using: &random) == 0
                                ? nil : (0..<length).map { _ in pieces.randomElement(using: &random)! }.joined()
                        )
                    }
                    let values = zip(["id", "a", "b"], row).map { (column: $0, value: $1) }
                    _ = try await driver.execute(d.insert(source, values: values, binaryColumns: []))
                }
                let from = TableTabModel(table: source, driver: driver, connectionTag: .local)
                from.pageSize = 1000
                await from.reload()
                let copied = TabSeparated.text([from.resultColumns] + from.copyRows(IndexSet(0..<from.rows.count)))
                let into = TableTabModel(table: target, driver: driver, connectionTag: .local)
                await into.reload()
                into.paste(copied, row: nil, column: nil)
                await into.commit()
                XCTAssertNil(into.error, "\(config.kind)")
                let original = try await driver.execute("SELECT id, a, b FROM \(d.qualified(source)) ORDER BY id").rows
                let pasted = try await driver.execute("SELECT id, a, b FROM \(d.qualified(target)) ORDER BY id").rows
                XCTAssertEqual(pasted.count, 150, "\(config.kind)")
                for (before, after) in zip(original, pasted) where before != after {
                    XCTFail("\(config.kind): \(before) came back as \(after)")
                }
            }
        }
    }

    /// Redis values written through the browser's operations read back byte for byte: invalid UTF-8, NUL, CRLF
    /// and RESP-like text, in strings, hashes, lists and sets.
    func testRedisBytesReadBackAsWritten() async throws {
        guard let port = ProcessInfo.processInfo.environment["TABULA_TEST_REDIS_PORT"].flatMap(Int.init) else {
            throw XCTSkip("TABULA_TEST_REDIS_PORT not set")
        }
        let redis = try await RedisDriver.connect(
            ConnectionConfig(kind: .redis, port: port, user: "tabula", database: "11"),
            password: "tabula"
        )
        _ = try await redis.send("FLUSHDB")
        var random = Seeded(state: 0xBEEF)
        let pool: [[UInt8]] = [
            [], [0], [0xFF, 0xFE], [0x0D, 0x0A], [0x22], [0x5C], Array("Hà Nội".utf8), Array("😀".utf8), [0xC3], [0x20],
            Array("$-1\r\n".utf8),
        ]
        func bytes() -> RedisBytes {
            RedisBytes((0..<Int.random(in: 0...4, using: &random)).flatMap { _ in pool.randomElement(using: &random)! })
        }
        for index in 0..<150 {
            let value = bytes()
            try await redis.setString(RedisBytes("s\(index)"), to: value)
            let string = try await redis.string(RedisBytes("s\(index)")).value
            XCTAssertEqual(string, value)
            let field = RedisBytes(Array("f".utf8) + bytes().bytes)
            let fieldValue = bytes()
            try await redis.add(RedisBytes("h\(index)"), type: .hash, values: [field, fieldValue])
            let hash = try await redis.page(RedisBytes("h\(index)"), type: .hash, after: nil).rows
            XCTAssertEqual(hash, [[field, fieldValue]])
            let items = [bytes(), bytes()]
            for item in items {
                try await redis.add(RedisBytes("l\(index)"), type: .list, values: [item])
            }
            let list = try await redis.page(RedisBytes("l\(index)"), type: .list, after: nil).rows
            XCTAssertEqual(list.map { $0.last }, items)
            let member = RedisBytes(Array("m".utf8) + bytes().bytes)
            try await redis.add(RedisBytes("t\(index)"), type: .set, values: [member])
            let set = try await redis.page(RedisBytes("t\(index)"), type: .set, after: nil).rows
            XCTAssertEqual(set, [[member]])
        }
        _ = try await redis.send("FLUSHDB")
        await redis.close()
    }

    /// Random documents written as shell text read back byte for byte, compact and pretty.
    func testRandomDocumentsReadBackAsWritten() throws {
        var random = Seeded(state: 0xD0C)
        let keys = ["a", "a.b", "$p", "", "sp ace", "Tên", "_id", "x\"y"]
        func value(_ depth: Int) -> Primitive {
            switch Int.random(in: 0..<(depth > 3 ? 8 : 10), using: &random) {
            case 0: return Int32.random(in: Int32.min...Int32.max, using: &random)
            case 1: return Int.random(in: Int.min...Int.max, using: &random)
            case 2: return [0.1, -0.0, 1e300, 5e-324, Double.nan, -Double.infinity].randomElement(using: &random)!
            case 3: return ["", "a\"b", "\\", "\n\t", "😀", "\u{0}", "$x", "Hà Nội"].randomElement(using: &random)!
            case 4: return Bool.random(using: &random)
            case 5: return Null()
            case 6:
                return Date(
                    timeIntervalSince1970: Double(Int.random(in: -10_000_000_000...10_000_000_000, using: &random))
                        / 1000
                )
            case 7:
                return RegularExpression(
                    pattern: ["a/b", "", "\\/", "[/]"].randomElement(using: &random)!,
                    options: "i"
                )
            case 8: return MongoDriver.array((0..<Int.random(in: 0...3, using: &random)).map { _ in value(depth + 1) })
            default:
                var document = Document()
                for key in keys.shuffled(using: &random).prefix(Int.random(in: 0...3, using: &random)) {
                    document[key] = value(depth + 1)
                }
                return document
            }
        }
        for _ in 0..<500 {
            var document = Document()
            for key in keys.shuffled(using: &random).prefix(Int.random(in: 1...4, using: &random)) {
                document[key] = value(0)
            }
            for text in [MongoShell.format(document), MongoShell.format(document, pretty: true)] {
                XCTAssertEqual(try MongoShell.parseDocument(text).makeData(), document.makeData(), text)
            }
        }
    }
}
