import NIOCore
import XCTest

@testable import TabulaConnections
@testable import TabulaDrivers
@testable import TabulaFoundation
@testable import TabulaPostgres

/// Values arrive in PostgreSQL's binary format and Tabula writes them as text itself. The server's own text output
/// (`::text`) is the reference: every cell must read as psql would show it.
final class PostgresValueFormatterTests: XCTestCase {
    private static let expressions: [String] = [
        "true", "false",
        "(-32768)::int2", "2147483647::int4", "(-9223372036854775808)::int8", "42::oid",
        "1.1::float4", "(-0.000123)::float4", "'NaN'::float4", "1e100::float8", "'-Infinity'::float8",
        "0.1::float8", "123456789.123456789::float8",
        "0::numeric", "(-0.000123)::numeric", "12345678901234567890.0987654321::numeric", "1e-20::numeric",
        "100::numeric(10,2)", "'NaN'::numeric", "'Infinity'::numeric", "1000000::numeric",
        "(-12.34)::money", "0.01::money",
        "'00000000-0000-0000-0000-000000000001'::uuid", "'\\xdeadbeef'::bytea", "''::bytea",
        "'{\"b\": [1, 2.5, null], \"a\": \"é\"}'::jsonb", "'{\"b\": 1,  \"a\": 2}'::json",
        "'2024-02-29'::date", "'0044-03-15 BC'::date", "'infinity'::date", "'1999-12-31'::date",
        "'23:59:59.999999'::time", "'24:00'::time", "'12:30:00+05:30'::timetz", "'00:00:01-03'::timetz",
        "'2024-01-02 03:04:05.06'::timestamp", "'1969-07-20 20:17:40'::timestamp", "'-infinity'::timestamp",
        "'0099-01-01 00:00 BC'::timestamp",
        "'1 year 2 mons 3 days 04:05:06.7'::interval", "'-1 day +02:00'::interval", "'-00:00:01.5'::interval",
        "'0'::interval", "'-3 years -1 mons'::interval",
        "'192.168.0.1'::inet", "'10.0.0.0/8'::cidr", "'::1'::inet", "'2001:db8::/32'::cidr",
        "'192.168.0.1/24'::inet", "'08:00:2b:01:02:03'::macaddr", "'08:00:2b:01:02:03:04:05'::macaddr8",
        "point(1.5, -2)", "'(1e20,0.1)'::point",
        "ARRAY[1, NULL, 3]", "ARRAY[[1, 2], [3, 4]]", "'{}'::int[]",
        "ARRAY['a,b', 'q\"uote', 'back\\slash', '', 'NULL', ' sp']",
        "'[0:1]={7,8}'::int[]", "ARRAY[true, false]", "ARRAY['2024-01-01'::date]", "ARRAY[1.5::numeric, NULL]",
        "ARRAY['{\"k\": 1}'::jsonb]", "ARRAY[ARRAY['x']]::text[]",
        "'hello'::text", "'é ü 😀'::varchar", "'  padded'::char(10)", "'name'::name",
        "'pg_class'::regclass::oid", "'abc'::bpchar", "B'1010'::bit(4)", "'(1,2)'::int4range",
        "'fat & rat'::tsquery", "'<a/>'::xml", "'a:1 b:2'::tsvector",
        "'a & (b | c:*AB) & !d'::tsquery", "'a <-> (b <2> c)'::tsquery", "'!(a | b)'::tsquery",
        "'(a <-> b) <-> c'::tsquery", "$$'it''s' & 'back\\\\slash'$$::tsquery", "''::tsquery", "'!a & b'::tsquery",
        "'a | b & c'::tsquery", "'(a | b) & c'::tsquery", "'!!a'::tsquery", "$$a:1A,2 b:3C 'it''s'$$::tsvector",
        "2::float8", "(-2)::float4", "123456789012345::float8", "1e15::float8", "1e16::float8", "0.0001::float8",
        "0.00001::float8", "(-0.0)::float8", "3.4028235e38::float4", "1234567::float4", "100000::float4",
        "'-0'::float8", "1e-300::float8", "(1/3.0)::float8", "(1/3.0)::float4",
        "'2024-01-02 03:04:05.5+00'::timestamptz", "'0010-01-01 BC'::timestamptz",
        "'[1,5)'::int4range", "'(,10]'::int8range", "'[1.5,)'::numrange", "'empty'::daterange",
        "'[2024-01-01,2024-02-01)'::daterange", "'[\"2024-01-01 10:00\",\"2024-01-01 11:00\"]'::tsrange",
        "'{[1,2), [5,6)}'::int4multirange",
        "'1 day'::interval * -1", "'-1 mons 2 days'::interval", "'1 mon -2 days -03:00'::interval",
        "'100 hours'::interval", "'1 year -1 mons'::interval", "'-1 year'::interval",
        "B'101'::varbit", "B''::varbit", "'line'::text", "'{1,2,3}'::line", "'[(0,0),(1,1)]'::lseg",
        "'((0,0),(1,1))'::box", "'((0,0),(1,1),(2,0))'::path", "'[(0,0),(1,1)]'::path",
        "'((0,0),(1,1),(2,0))'::polygon", "'<(1,2),3>'::circle",
        "ARRAY[1.5::float8, 2]", "ARRAY['NaN'::float8]", "'[1:1][3:4]={{a,b}}'::text[]",
        "'simple'::regconfig::oid", "'1/0'::pg_lsn", "'(1,2)'::tid", "'12'::xid8",
    ]

    /// Tabula writes booleans out in full; everything else matches.
    private static let deliberate: [String: String] = [
        "true": "true", "false": "false", "ARRAY[true, false]": "{true,false}",
    ]

    /// Each type's output function (`format('%s', …)`) is the reference, as psql shows it; `::text` differs for
    /// inet and char(n).
    func testEveryValueReadsAsTheServerWritesIt() async throws {
        guard let port = ProcessInfo.processInfo.environment["TABULA_TEST_PG_PORT"].flatMap(Int.init) else {
            throw XCTSkip("TABULA_TEST_PG_PORT not set")
        }
        let driver = try await DriverFactory.connect(
            ConnectionConfig(kind: .postgres, port: port, user: "tabula", database: "tabula"),
            password: "tabula"
        )
        defer { Task { await driver.close() } }
        var mismatches: [String] = []
        for expression in Self.expressions {
            let result = try await driver.execute("SELECT \(expression) AS v, format('%s', \(expression)) AS t")
            let row = try XCTUnwrap(result.rows.first)
            let expected = Self.deliberate[expression] ?? row[1]
            if row[0] != expected {
                mismatches.append("\(expression): Tabula \(row[0] ?? "NULL") | server \(row[1] ?? "NULL")")
            }
        }
        XCTAssertEqual(mismatches, [], mismatches.joined(separator: "\n"))
    }
}

/// The same layout rules without a server.
final class PostgresValueFormatterUnitTests: XCTestCase {
    func testFloatsAsPostgresWritesThem() {
        let cases: [(Double, String)] = [
            (2, "2"), (-2, "-2"), (0.1, "0.1"), (1e15, "1e+15"), (123_456_789_012_345, "123456789012345"),
            (0.0001, "0.0001"), (0.00001, "1e-05"), (1e100, "1e+100"), (-0.0, "-0"), (.nan, "NaN"),
            (.infinity, "Infinity"), (-.infinity, "-Infinity"), (1.5e-300, "1.5e-300"), (100, "100"),
        ]
        for (value, expected) in cases {
            XCTAssertEqual(PostgresValueFormatter.floatText(value, precision: 15), expected, "\(value)")
        }
        XCTAssertEqual(PostgresValueFormatter.floatText(Float(1_234_567), precision: 6), "1.234567e+06")
        XCTAssertEqual(PostgresValueFormatter.floatText(Float(100_000), precision: 6), "100000")
    }

    /// Bytes of a type without a decoder show as text when they are text, otherwise as hex.
    func testUnknownBinaryShowsAsHex() {
        let text = PostgresValueFormatter.string(ByteBuffer(string: "ready\tset\u{1F}go"), oid: 99_999)
        XCTAssertEqual(text, "ready\tset\u{1F}go")
        let binary = PostgresValueFormatter.string(ByteBuffer(bytes: [0x01, 0x00, 0xFF]), oid: 99_999)
        XCTAssertEqual(binary, "\\x0100ff")
        // Zeros that look like an array header with no element type aren't an empty array.
        let zeros = PostgresValueFormatter.string(ByteBuffer(bytes: Array(repeating: 0, count: 32)), oid: 99_999)
        XCTAssertEqual(zeros, "\\x" + String(repeating: "00", count: 32))
    }
}
