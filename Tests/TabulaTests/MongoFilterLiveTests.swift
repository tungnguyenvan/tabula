import XCTest

@testable import TabulaConnections
@testable import TabulaDrivers
@testable import TabulaFoundation
@testable import TabulaMongo
@testable import TabulaSQL

/// The filter bar on MongoDB, where a value typed as text must find numbers, decimals, longs, dates, ObjectIds and
/// booleans stored with their own types, and text operators treat regex characters as plain.
final class MongoFilterLiveTests: XCTestCase {
    func testTypedValuesAreFound() async throws {
        guard let port = ProcessInfo.processInfo.environment["TABULA_TEST_MONGO_PORT"].flatMap(Int.init) else {
            throw XCTSkip("TABULA_TEST_MONGO_PORT not set")
        }
        let driver = try await DriverFactory.connect(
            ConnectionConfig(kind: .mongodb, port: port, user: "tabula", database: "tabula_filters"),
            password: "tabula"
        )
        try await runThenClean(driver, cleanup: ["db.dropDatabase()"]) {
            _ = try await driver.execute("db.items.drop()")
            _ = try await driver.execute(
                """
                db.items.insertMany([
                  { _id: 1, v: 5, s: "a.b*c", flag: true, dec: NumberDecimal("0.1000"), big: NumberLong("9007199254740993"), at: ISODate("2024-01-02T03:04:05Z"), oid: ObjectId("65f1a2b3c4d5e6f708091a2b") },
                  { _id: 2, v: "5", s: "abxc", flag: false, dec: NumberDecimal("2"), big: NumberLong("1"), at: ISODate("2024-05-06T00:00:00Z") },
                  { _id: 3, v: 50, s: "Hà Nội", flag: "true" }
                ])
                """
            )
            let table = TableRef(schema: "tabula_filters", name: "items")
            func ids(_ column: String, _ op: FilterRule.Operator, _ value: String) async throws -> [String] {
                let filter = driver.dialect.condition([FilterRule(column: column, op: op, value: value)])
                let page = try await driver.fetchPage(TablePageRequest(table: table, limit: 10, filter: filter))
                // A page without documents has no columns.
                guard let id = page.columns.firstIndex(of: "_id") else { return [] }
                return page.rows.compactMap { $0[id] }.sorted()
            }
            let five = try await ids("v", .equals, "5")
            XCTAssertEqual(five, ["1", "2"], "the number and the string 5")
            let regex = try await ids("s", .contains, "a.b*")
            XCTAssertEqual(regex, ["1"], ". and * are plain characters")
            let vietnamese = try await ids("s", .contains, "hà nội")
            XCTAssertEqual(vietnamese, ["3"])
            let flag = try await ids("flag", .equals, "true")
            XCTAssertEqual(flag, ["1", "3"], "the boolean and the string")
            let decimal = try await ids("dec", .equals, "0.1000")
            XCTAssertEqual(decimal, ["1"], "a decimal, as the grid shows it")
            let big = try await ids("big", .equals, "9007199254740993")
            XCTAssertEqual(big, ["1"], "a long past 2^53, not rounded")
            let date = try await ids("at", .greater, "2024-03-01")
            XCTAssertEqual(date, ["2"])
            let oid = try await ids("oid", .equals, "65f1a2b3c4d5e6f708091a2b")
            XCTAssertEqual(oid, ["1"])
            let missing = try await ids("oid", .isNull, "")
            XCTAssertEqual(missing, ["2", "3"], "a missing field counts as NULL, as in MongoDB")
            let list = try await ids("v", .inList, "50, 5")
            XCTAssertEqual(list, ["1", "2", "3"])
            let numberContains = try await ids("v", .contains, "0")
            XCTAssertEqual(numberContains, ["3"], "contains looks at numbers as text too")
        }
    }
}
