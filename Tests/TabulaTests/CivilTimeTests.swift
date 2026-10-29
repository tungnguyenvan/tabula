import XCTest

@testable import TabulaConnections
@testable import TabulaFoundation

final class CivilTimeTests: XCTestCase {
    private let reference: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    /// Matches Foundation from 1583 on. Before the 1582 reform Foundation switches to the Julian calendar, while
    /// PostgreSQL and MongoDB keep counting in Gregorian (proleptic), as these functions do.
    func testMatchesFoundationSinceTheGregorianReform() {
        var generator = SystemRandomNumberGenerator()
        let first: Int64 = -12_212_553_600
        let last: Int64 = 253_402_300_799  // 1583-01-01 to 9999-12-31
        var instants: [Int64] = [0, -1, 1, 86_399, 86_400, -86_401, 951_782_400, 4_107_542_400, first, last]
        for _ in 0..<20_000 { instants.append(Int64.random(in: first...last, using: &generator)) }
        for seconds in instants {
            XCTAssertEqual(
                CivilTime.dateTimeText(seconds: seconds),
                reference.string(from: Date(timeIntervalSince1970: Double(seconds))),
                "\(seconds)"
            )
        }
    }

    func testProlepticDatesMatchPostgres() {
        // Values from PostgreSQL: to_timestamp(-62135596800), to_timestamp(-14376665905).
        XCTAssertEqual(CivilTime.dateTimeText(seconds: -62_135_596_800), "0001-01-01 00:00:00")
        XCTAssertEqual(CivilTime.dateTimeText(seconds: -14_376_665_905), "1514-06-04 09:41:35")
        XCTAssertEqual(CivilTime.dateText(days: -265_232), "1243-10-27")
    }

    func testPostgresDriverWritesOldDatesLikePsql() async throws {
        guard let port = ProcessInfo.processInfo.environment["TABULA_TEST_PG_PORT"].flatMap(Int.init) else {
            throw XCTSkip("TABULA_TEST_PG_PORT not set")
        }
        let driver = try await DriverFactory.connect(
            ConnectionConfig(kind: .postgres, port: port, user: "tabula", database: "tabula"),
            password: "tabula"
        )
        let result = try await driver.execute(
            "SELECT date '1243-10-27' AS d, timestamp '1514-06-04 09:41:35.25' AS t, timestamptz '2024-02-29 23:59:59+00' AS z"
        )
        XCTAssertEqual(result.rows.first ?? [], ["1243-10-27", "1514-06-04 09:41:35.25", "2024-02-29 23:59:59+00"])
        await driver.close()
    }

    func testDaysRoundTrip() {
        for days in stride(from: Int64(-800_000), through: 3_000_000, by: 997) {
            XCTAssertEqual(CivilTime.days(from: CivilTime.civil(fromDays: days)), days)
        }
        XCTAssertEqual(CivilTime.civil(fromDays: 0), .init(year: 1970, month: 1, day: 1))
        XCTAssertEqual(CivilTime.civil(fromDays: 11_016), .init(year: 2000, month: 2, day: 29))
    }

    func testISOText() {
        XCTAssertEqual(CivilTime.isoText(milliseconds: 631_249_445_678), "1990-01-02T03:04:05.678Z")
        XCTAssertEqual(CivilTime.isoText(milliseconds: -1), "1969-12-31T23:59:59.999Z")
        XCTAssertNil(CivilTime.isoText(milliseconds: 253_402_300_800_000))  // year 10000
    }

    func testISOParsing() {
        XCTAssertEqual(CivilTime.milliseconds(iso: "1990-01-02T03:04:05.678Z"), 631_249_445_678)
        XCTAssertEqual(CivilTime.milliseconds(iso: "1990-01-02"), 631_238_400_000)
        XCTAssertEqual(CivilTime.milliseconds(iso: "1990-01-02 03:04"), 631_249_440_000)
        XCTAssertEqual(CivilTime.milliseconds(iso: "1990-01-02T10:04:05+07:00"), 631_249_445_000)
        XCTAssertEqual(CivilTime.milliseconds(iso: "1990-01-02T10:04:05+0700"), 631_249_445_000)
        XCTAssertEqual(CivilTime.milliseconds(iso: "1990-01-01T22:04:05-05"), 631_249_445_000)
        XCTAssertEqual(CivilTime.milliseconds(iso: "1990-01-02T03:04:05.6789123Z"), 631_249_445_678)
        XCTAssertEqual(CivilTime.milliseconds(iso: "1969-12-31T23:59:59.999Z"), -1)
        for invalid in [
            "2024-02-30", "2023-02-29", "2024-13-01", "2024-1-1", "2024-01-01T25:00", "2024-01-01Tx",
            "2024-01-01T10:00+7", "abc", "",
        ] {
            XCTAssertNil(CivilTime.milliseconds(iso: invalid), invalid)
        }
        XCTAssertEqual(CivilTime.milliseconds(iso: "2024-02-29"), 1_709_164_800_000)
    }
}
