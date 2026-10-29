import XCTest

@testable import TabulaConnections
@testable import TabulaDrivers
@testable import TabulaFoundation

/// MySQL result edits on keys that only differ in case, accents or trailing spaces under the default
/// case- and accent-insensitive collation: each edit reaches exactly its own row.
final class MySQLResultEditEdgeTests: XCTestCase {
    func testKeysThatTheCollationCallsEqualStayApart() async throws {
        guard let port = ProcessInfo.processInfo.environment["TABULA_TEST_MYSQL_PORT"].flatMap(Int.init) else {
            throw XCTSkip("TABULA_TEST_MYSQL_PORT not set")
        }
        let driver = try await DriverFactory.connect(
            ConnectionConfig(kind: .mysql, port: port, user: "tabula", database: "tabula"),
            password: "tabula"
        )
        let table = "edges_" + UUID().uuidString.prefix(8).lowercased()
        do {
            // A binary-collated key holds values the default collation would call equal.
            _ = try await driver.execute(
                """
                CREATE TABLE \(table) (k VARCHAR(20) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin PRIMARY KEY,
                  label VARCHAR(40), padded CHAR(6), big BIGINT, money DECIMAL(30,10))
                """
            )
            _ = try await driver.execute(
                """
                INSERT INTO \(table) VALUES ('ha', 'plain', 'x', 9007199254740993, 12345678901234567890.0123456789),
                  ('HA', 'upper', 'x', 9007199254740992, 1), ('hà', 'accent', 'x ', -1, 0)
                """
            )
            let result = try await driver.execute("SELECT k, label, padded, big, money FROM \(table) ORDER BY label")
            let resolved = try await driver.queryEditTarget(for: result)
            let target = try XCTUnwrap(resolved)
            let rows = result.rows
            let accent = try XCTUnwrap(rows.firstIndex { $0[0] == "hà" })
            let upper = try XCTUnwrap(rows.firstIndex { $0[0] == "HA" })
            _ = try await driver.commitQueryEdits(
                [
                    QueryRowEdit(row: accent, original: rows[accent], values: [1: "accent edited"]),
                    QueryRowEdit(row: upper, original: rows[upper], values: [1: "upper edited"]),
                ],
                target: target
            )
            let after = try await driver.execute("SELECT k, label FROM \(table) ORDER BY BINARY k")
            XCTAssertEqual(after.rows, [["HA", "upper edited"], ["ha", "plain"], ["hà", "accent edited"]])
            // An edit compares only the key and the columns it changes: a change made elsewhere to another column
            // (a BIGINT past 2^53, which doubles would round) is neither a conflict nor overwritten.
            _ = try await driver.execute("UPDATE \(table) SET big = 9007199254740992 WHERE BINARY k = 'ha'")
            let plain = try XCTUnwrap(rows.firstIndex { $0[0] == "ha" })
            _ = try await driver.commitQueryEdits(
                [QueryRowEdit(row: plain, original: rows[plain], values: [1: "plain edited"])],
                target: target
            )
            let kept = try await driver.execute(
                "SELECT label, big, CAST(money AS CHAR), padded FROM \(table) WHERE BINARY k = 'ha'"
            )
            XCTAssertEqual(kept.rows, [["plain edited", "9007199254740992", "12345678901234567890.0123456789", "x"]])
            // A changed label is a conflict, even when it differs only by a trailing space.
            _ = try await driver.execute("UPDATE \(table) SET label = 'plain edited ' WHERE BINARY k = 'ha'")
            let reread = try await driver.execute(
                "SELECT k, label, padded, big, money FROM \(table) WHERE BINARY k = 'ha'"
            )
            var stale = reread.rows[0]
            stale[1] = "plain edited"
            do {
                _ = try await driver.commitQueryEdits(
                    [QueryRowEdit(row: 0, original: stale, values: [1: "lost update"])],
                    target: target
                )
                XCTFail("a label changed by a trailing space must count as changed")
            } catch {}
            _ = try await driver.execute("DROP TABLE \(table)")
        } catch {
            _ = try? await driver.execute("DROP TABLE IF EXISTS \(table)")
            await driver.close()
            throw error
        }
        await driver.close()
    }
}
