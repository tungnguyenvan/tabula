import XCTest

@testable import TabulaMongo

/// Decimal128 text reads back to the same text, on both sides of 2^64 where the significand needs both words.
final class MongoDecimalTests: XCTestCase {
    func testCanonicalTextRoundTrips() throws {
        for text in [
            "0", "-0", "1234.5600", "0.1000", "18446744073709551615", "18446744073709551616",
            "9999999999999999999999999999999999", "-9999999999999999999999999999999999",
            "1.000000000000000000000000000000000E+6144",
            "1E-6176", "0.000001", "1.23E-7", "1.23E+5", "NaN", "Infinity", "-Infinity",
        ] {
            let decimal = try XCTUnwrap(MongoDecimal.parse(text), text)
            XCTAssertEqual(MongoDecimal.string(decimal), text)
        }
        // The canonical form puts one digit before the point once there is an exponent.
        XCTAssertEqual(MongoDecimal.parse("123E+3").map(MongoDecimal.string), "1.23E+5")
    }
}
