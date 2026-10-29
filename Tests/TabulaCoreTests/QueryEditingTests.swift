import XCTest
@testable import TabulaCore

final class QueryEditingTests: XCTestCase {
    private var target: QueryEditTarget {
        QueryEditTarget(table: TableRef(schema: "public", name: "a\"b"), tableOID: 1, columns: [
            .init(name: "id", attribute: 1, typeOID: 23, typeName: "integer", isKey: true, editable: false),
            .init(name: "label", attribute: 2, typeOID: 25, typeName: "text", isKey: false, editable: true),
        ], kind: .postgres, writer: PostgresResultEditWriter())
    }

    func testUpdateEscapesValuesAndMatchesOriginals() throws {
        let edit = QueryRowEdit(row: 0, original: ["1", "old"], values: [1: "a'\\b"])
        let sql = try target.statement(for: edit)
        XCTAssertTrue(sql.hasPrefix("UPDATE ONLY \"public\".\"a\"\"b\" SET \"label\" = E'a''\\\\b'::pg_catalog.text"))
        XCTAssertTrue(sql.contains("\"id\" IS NOT DISTINCT FROM E'1'::pg_catalog.int4"))
        XCTAssertTrue(sql.contains("\"label\" IS NOT DISTINCT FROM E'old'::pg_catalog.text"))
        XCTAssertTrue(sql.hasSuffix("RETURNING \"id\", \"label\""))
        XCTAssertTrue(try target.statement(for: .init(row: 0, original: ["1", nil], values: [1: nil])).contains("SET \"label\" = NULL"))
    }

    func testRejectsKeyChangesAndNul() {
        XCTAssertThrowsError(try target.statement(for: .init(row: 0, original: ["1", "a"], values: [0: "2"])))
        XCTAssertThrowsError(try target.statement(for: .init(row: 0, original: [nil, "a"], values: [1: "b"])))
        XCTAssertThrowsError(try target.statement(for: .init(row: 0, original: ["1", "a"], values: [1: "\0"])))
    }

    func testRejectsAmbiguousRows() {
        XCTAssertFalse(target.editableRow(0, in: [["1", "a"], ["1", "b"]]))
        XCTAssertFalse(target.editableRow(0, in: [[nil, "a"]]))
        XCTAssertTrue(target.editableRow(0, in: [["1", "a"], ["2", nil]]))
    }

    func testPostgresResultEditing() async throws {
        guard let port = ProcessInfo.processInfo.environment["TABULA_TEST_PG_PORT"].flatMap(Int.init) else { throw XCTSkip("TABULA_TEST_PG_PORT not set") }
        let config = ConnectionConfig(kind: .postgres, port: port, user: "tabula", database: "tabula")
        let driver = try await DriverFactory.connect(config, password: "tabula")
        let schema = "edit_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        do {
            _ = try await driver.executeScript("""
                CREATE SCHEMA \(schema);
                CREATE TABLE \(schema).items (tenant int, id int, label text NOT NULL, amount numeric(12,2),
                    calc int GENERATED ALWAYS AS (id+1) STORED, born date, PRIMARY KEY(tenant,id));
                INSERT INTO \(schema).items VALUES (1,1,'first',12.30),(1,2,'second',45.60);
                CREATE VIEW \(schema).v AS SELECT * FROM \(schema).items;
                """)
            let result = try await driver.execute("SELECT i.tenant AS t, i.id, i.label AS renamed, i.amount, i.calc, i.born FROM \(schema).items AS i ORDER BY i.id LIMIT 300")
            let resolved = try await driver.queryEditTarget(for: result)
            let target = try XCTUnwrap(resolved)
            XCTAssertEqual(target.columns.map(\.name), ["tenant", "id", "label", "amount", "calc", "born"])
            XCTAssertEqual(target.columns.map(\.editable), [false, false, true, true, false, false])
            var edits: [Int: String?] = [2: "quote'\\value", 3: "23.45"]
            let returned = try await driver.commitQueryEdits([.init(row: 0, original: result.rows[0], values: edits)], target: target)
            XCTAssertEqual(returned[0]?[2], "quote'\\value")
            XCTAssertEqual(returned[0]?[3], "23.45")
            for sql in [
                "SELECT id, label FROM \(schema).items", // incomplete composite key
                "SELECT * FROM \(schema).v", // view
                "SELECT a.tenant,a.id,b.label FROM \(schema).items a JOIN \(schema).items b ON a.id=b.id",
                "SELECT tenant,id,max(label) FROM \(schema).items GROUP BY tenant,id",
                "SELECT tenant,id,label||'x' FROM \(schema).items",
                "WITH x AS (SELECT * FROM \(schema).items) SELECT * FROM x",
            ] {
                let result = try await driver.execute(sql)
                let target = try await driver.queryEditTarget(for: result)
                XCTAssertNil(target, sql)
            }
            // A conflict on row two rolls back the earlier change to row one.
            let fresh = try await driver.execute("SELECT * FROM \(schema).items ORDER BY id")
            _ = try await driver.execute("UPDATE \(schema).items SET label='concurrent' WHERE id=2")
            do {
                _ = try await driver.commitQueryEdits([
                    .init(row: 0, original: fresh.rows[0], values: [2: "must roll back"]),
                    .init(row: 1, original: fresh.rows[1], values: [2: "stale"]),
                ], target: target)
                XCTFail("Stale row must reject the whole batch")
            } catch { }
            let after = try await driver.execute("SELECT label FROM \(schema).items ORDER BY id")
            XCTAssertEqual(after.rows, [["quote'\\value"], ["concurrent"]])
            // A constraint failure doesn't drop or partially apply the batch either.
            edits[2] = .some(nil)
            do {
                _ = try await driver.commitQueryEdits([.init(row: 0, original: fresh.rows[0], values: edits)], target: target)
                XCTFail("NOT NULL must reject the update")
            } catch { }
            _ = try await driver.execute("CREATE TABLE \(schema).included (id int, label text, note text, PRIMARY KEY(id) INCLUDE(label))")
            _ = try await driver.execute("INSERT INTO \(schema).included VALUES (1,'included','note')")
            let omitIncluded = try await driver.execute("SELECT id,note FROM \(schema).included")
            let omitTarget = try await driver.queryEditTarget(for: omitIncluded)
            XCTAssertNotNil(omitTarget, "INCLUDE attributes are not primary key columns")
            let withIncluded = try await driver.execute("SELECT * FROM \(schema).included")
            let withTarget = try await driver.queryEditTarget(for: withIncluded)
            let includedTarget = try XCTUnwrap(withTarget)
            XCTAssertTrue(includedTarget.columns[1].editable)
            _ = try await driver.commitQueryEdits([.init(row: 0, original: withIncluded.rows[0], values: [1: "updated"])], target: includedTarget)
            _ = try await driver.execute("CREATE TABLE \(schema).replacement (id int PRIMARY KEY, label text)")
            _ = try await driver.execute("INSERT INTO \(schema).replacement VALUES (1,'old')")
            let old = try await driver.execute("SELECT * FROM \(schema).replacement")
            let oldResolved = try await driver.queryEditTarget(for: old)
            let oldTarget = try XCTUnwrap(oldResolved)
            _ = try await driver.execute("DROP TABLE \(schema).replacement")
            _ = try await driver.execute("CREATE TABLE \(schema).replacement (id int PRIMARY KEY, label text)")
            _ = try await driver.execute("INSERT INTO \(schema).replacement VALUES (1,'replacement')")
            do {
                _ = try await driver.commitQueryEdits([.init(row: 0, original: old.rows[0], values: [1: "must not write"])], target: oldTarget)
                XCTFail("Dropped/recreated tables must not accept stale result edits")
            } catch { }
            let untouched = try await driver.execute("SELECT label FROM \(schema).replacement")
            XCTAssertEqual(untouched.rows, [["replacement"]])
            _ = try await driver.execute("CREATE TABLE \(schema).parent (id int PRIMARY KEY, label text)")
            _ = try await driver.execute("CREATE TABLE \(schema).child () INHERITS (\(schema).parent)")
            let inherited = try await driver.execute("SELECT * FROM \(schema).parent")
            let inheritedTarget = try await driver.queryEditTarget(for: inherited)
            XCTAssertNil(inheritedTarget)
            _ = try await driver.execute("DROP SCHEMA \(schema) CASCADE")
            await driver.close()
        } catch {
            _ = try? await driver.execute("DROP SCHEMA \(schema) CASCADE")
            await driver.close()
            throw error
        }
    }
}
