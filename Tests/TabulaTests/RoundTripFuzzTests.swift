import BSON
import XCTest

@testable import Tabula
@testable import TabulaDrivers
@testable import TabulaFoundation
@testable import TabulaMongo
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
