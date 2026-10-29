import XCTest
@testable import TabulaCore

final class MySQLQueryEditingTests: XCTestCase {
    private var target: QueryEditTarget {
        QueryEditTarget(table: TableRef(schema: "db`name", name: "items`physical"), tableOID: 0, columns: [
            .init(name: "tenant", attribute: 1, typeOID: 0, typeName: "bigint unsigned", isKey: true, editable: false, mysqlType: "bigint"),
            .init(name: "id", attribute: 2, typeOID: 0, typeName: "varchar(30)", isKey: true, editable: false, mysqlType: "varchar"),
            .init(name: "physical`label", attribute: 3, typeOID: 0, typeName: "text", isKey: false, editable: true, mysqlType: "text"),
            .init(name: "amount", attribute: 4, typeOID: 0, typeName: "decimal(12,2)", isKey: false, editable: true, mysqlType: "decimal"),
            .init(name: "born", attribute: 5, typeOID: 0, typeName: "date", isKey: false, editable: false, mysqlType: "date"),
        ], kind: .mysql, mysqlTableIdentity: "123")
    }

    func testMySQLSelectGrammarAndSourceNames() {
        for sql in [
            "SELECT * FROM Items", "SELECT `a`.`id`, a.label AS renamed FROM `db`.`Items` AS a WHERE a.id = 1 ORDER BY a.id LIMIT 300",
            "SELECT id,label FROM items WHERE label='it''s fine' AND id IN (1,2) LIMIT 10 OFFSET 1;",
            "SELECT i.* FROM `a``b`.`t``x` i # safe comment\nWHERE i.id >= 1",
            "SELECT * FROM items -- safe comment\nWHERE id = 1",
        ] { XCTAssertTrue(EditableSelect.accepts(sql, flavor: .mysql), sql) }
        XCTAssertEqual(EditableSelect.source("SELECT * FROM Items", flavor: .mysql), ["Items"])
        XCTAssertEqual(EditableSelect.source("SELECT a.* FROM `a``b`.`t``x` a", flavor: .mysql), ["a`b", "t`x"])
        XCTAssertEqual(EditableSelect.relation("SELECT x.id FROM items x", flavor: .mysql)?.reference, "x")
        for sql in [
            "SELECT a.id,a.label FROM items a JOIN items b ON a.id=b.id", "SELECT * FROM items a, items b",
            "SELECT * FROM (SELECT * FROM items) a", "WITH a AS (SELECT * FROM items) SELECT * FROM a",
            "SELECT id,upper(label) FROM items", "SELECT id,label+1 FROM items", "SELECT DISTINCT id,label FROM items",
            "SELECT id,count(*) FROM items GROUP BY id", "SELECT id,label FROM items UNION SELECT id,label FROM items",
            "SELECT * FROM items FOR UPDATE", "SELECT * FROM items; SELECT * FROM items",
            "SELECT * FROM items /*!50000 JOIN other */", "SELECT * FROM items --not-a-comment",
            "SELECT * FROM items # comment\rJOIN other", "SELECT * FROM \"items\"",
            "SELECT * FROM `it\\ems`", "SELECT * FROM items WHERE label='a\\b'",
            "SELECT * FROM items WHERE label=\"text\"", "SELECT * FROM items WHERE id=0x01",
            "SELECT * FROM items WHERE id=@key", "SELECT * FROM items WHERE id=?",
            "SELECT * FROM items WHERE id=fn()", "SELECT * FROM items WHERE label ILIKE 'a'",
            "SELECT * FROM items ORDER BY id NULLS FIRST", "SELECT * FROM items LIMIT 1,2",
            "SELECT SQL_CALC_FOUND_ROWS id FROM items", "SELECT UTC_TIMESTAMP FROM items",
        ] { XCTAssertFalse(EditableSelect.accepts(sql, flavor: .mysql), sql) }
        XCTAssertFalse(EditableSelect.accepts("SELECT * FROM `items`"), "PostgreSQL still refuses backticks")
        XCTAssertEqual(EditableSelect.source("SELECT * FROM Items"), ["items"])
    }

    func testMySQLUpdateUsesPhysicalNamesAndModeIndependentLiterals() throws {
        let original: [String?] = ["18446744073709551615", "one", "old", "12.30", "2024-01-01"]
        let edit = QueryRowEdit(row: 0, original: original, values: [2: "quote'\\\0🙂", 3: nil])
        let sql = try target.statement(for: edit)
        XCTAssertTrue(sql.hasPrefix("UPDATE `db``name`.`items``physical` SET `physical``label` = _utf8mb4 X'"))
        XCTAssertTrue(sql.contains("', `amount` = NULL WHERE `tenant` = 18446744073709551615 AND"))
        XCTAssertTrue(sql.contains("`id` = _utf8mb4 X'6f6e65' AND"))
        XCTAssertTrue(sql.contains("CAST(`tenant` AS CHAR CHARACTER SET utf8mb4)"))
        XCTAssertTrue(sql.contains("CONVERT(`id` USING utf8mb4)"))
        XCTAssertTrue(sql.contains("CONVERT(`physical``label` USING utf8mb4)"))
        XCTAssertTrue(sql.contains("CAST(`amount` AS CHAR CHARACTER SET utf8mb4)"))
        XCTAssertFalse(sql.contains("born"), "Unedited unsupported columns never enter the optimistic predicate")
        XCTAssertFalse(sql.contains("RETURNING"))
        XCTAssertFalse(sql.contains("quote"))
        XCTAssertFalse(sql.contains("\\"))
        XCTAssertFalse(sql.contains("\0"))
        XCTAssertEqual(QueryEditTarget.mysqlLiteral(""), "_utf8mb4 X''")
        XCTAssertEqual(QueryEditTarget.mysqlLiteral(nil), "NULL")
        XCTAssertEqual(QueryEditTarget.mysqlLiteral("a'\\\0"), "_utf8mb4 X'61275c00'")
        XCTAssertThrowsError(try target.statement(for: .init(row: 0, original: ["1e3", "one", "old", "1.00", nil], values: [2: "new"])))
    }

    func testMySQLRejectsUnsafeEdits() {
        let original: [String?] = ["1", "key", "old", "1.00", nil]
        for edit in [
            QueryRowEdit(row: 0, original: original, values: [0: "2"]),
            .init(row: 0, original: original, values: [4: "2024-01-02"]),
            .init(row: 0, original: original, values: [9: "bad"]),
            .init(row: 0, original: original, values: [:]),
            .init(row: 0, original: ["1", nil, "old", "1.00", nil], values: [2: "new"]),
            .init(row: 0, original: ["1", "key"], values: [2: "new"]),
            .init(row: -1, original: original, values: [2: "new"]),
        ] { XCTAssertThrowsError(try target.statement(for: edit)) }
        var unsafeKey = target
        unsafeKey.columns[0].mysqlType = "binary"
        XCTAssertThrowsError(try unsafeKey.statement(for: .init(row: 0, original: original, values: [2: "new"])))
        XCTAssertFalse(target.editableRow(0, in: [original, original]))
        XCTAssertFalse(target.editableRow(0, in: [["1", nil, "old", "1.00", nil]]))
    }

    /// Only the parent's explicitly enabled disposable local MySQL container is used.
    func testMySQLResultEditing() async throws {
        guard let port = ProcessInfo.processInfo.environment["TABULA_TEST_MYSQL_PORT"].flatMap(Int.init) else {
            throw XCTSkip("TABULA_TEST_MYSQL_PORT not set")
        }
        let config = ConnectionConfig(kind: .mysql, port: port, user: "tabula", database: "tabula")
        let driver = try await DriverFactory.connect(config, password: "tabula")
        let writer = try await DriverFactory.connect(config, password: "tabula")
        let name = "qe_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let d = SQLDialect(flavor: .mysql)
        let table = "`tabula`." + d.quoteIdentifier(name)
        let view = "`tabula`." + d.quoteIdentifier(name + "_v")
        do {
            _ = try await driver.execute("""
                CREATE TABLE \(table) (tenant BIGINT UNSIGNED, id INT, label TEXT NOT NULL, amount DECIMAL(12,2),
                    calc INT GENERATED ALWAYS AS (id+1) STORED, born DATE, photo BLOB, seen TIMESTAMP NULL,
                    PRIMARY KEY(tenant,id)) ENGINE=InnoDB
                """)
            _ = try await driver.execute("INSERT INTO \(table) (tenant,id,label,amount) VALUES (18446744073709551615,1,'first',12.30),(18446744073709551615,2,'second',45.60)")
            _ = try await driver.execute("CREATE VIEW \(view) AS SELECT * FROM \(table)")
            let result = try await driver.execute("SELECT i.tenant AS t, i.id, i.label AS renamed, i.amount, i.calc, i.born, i.photo, i.seen FROM \(table) AS i ORDER BY i.id LIMIT 300")
            let resolved = try await driver.queryEditTarget(for: result)
            let target = try XCTUnwrap(resolved)
            XCTAssertEqual(target.kind, .mysql)
            XCTAssertEqual(target.columns.map(\.name), ["tenant", "id", "label", "amount", "calc", "born", "photo", "seen"])
            XCTAssertEqual(target.columns.map(\.editable), [false, false, true, true, false, false, false, false])
            XCTAssertEqual(result.rows[0][0], "18446744073709551615")
            XCTAssertEqual(result.mysqlOrigins?[2].originalName, "label")
            XCTAssertEqual(result.mysqlOrigins?[2].table, "i")
            XCTAssertEqual(result.mysqlOrigins?[2].originalTable, name)
            let special = "quote'\\\0🙂"
            let returned = try await writer.commitQueryEdits([.init(row: 0, original: result.rows[0], values: [2: special, 3: "23.45"])], target: target)
            XCTAssertEqual(returned[0]?[2], special)
            XCTAssertEqual(returned[0]?[3], "23.45")
            // User transaction remains open: committing through another connection must not commit this insert.
            _ = try await driver.execute("START TRANSACTION")
            _ = try await driver.execute("INSERT INTO \(table) (tenant,id,label,amount) VALUES (5,5,'uncommitted',1.00)")
            let updatedOriginal = try XCTUnwrap(returned[0])
            let noOp = try await writer.commitQueryEdits([.init(row: 0, original: updatedOriginal, values: [3: "23.450"])], target: target)
            XCTAssertEqual(noOp[0]?[3], "23.45", "Zero changed rows is valid after proving one matched row")
            _ = try await driver.execute("ROLLBACK")
            let absent = try await driver.execute("SELECT id FROM \(table) WHERE tenant=5")
            XCTAssertTrue(absent.rows.isEmpty)
            for sql in [
                "SELECT id,label FROM \(table)", "SELECT * FROM \(view)",
                "SELECT a.tenant,a.id,b.label FROM \(table) a JOIN \(table) b ON a.id=b.id",
                "SELECT tenant,id,UPPER(label) FROM \(table)",
                "SELECT tenant,id,MAX(label) FROM \(table) GROUP BY tenant,id",
                "WITH x AS (SELECT * FROM \(table)) SELECT * FROM x",
            ] {
                let result = try await driver.execute(sql)
                let eligibility = try await driver.queryEditTarget(for: result)
                XCTAssertNil(eligibility, sql)
            }
            // Temporary tables shadow permanent names only on the reading session; the writer must not edit
            // the permanent lookalike even if keys, values and wire origins are identical.
            _ = try await driver.execute("CREATE TEMPORARY TABLE \(table) (tenant BIGINT UNSIGNED, id INT, label TEXT, amount DECIMAL(12,2), PRIMARY KEY(tenant,id)) ENGINE=InnoDB")
            _ = try await driver.execute("INSERT INTO \(table) (tenant,id,label,amount) VALUES (18446744073709551615,1,'first',12.30)")
            let temporary = try await driver.execute("SELECT * FROM \(table)")
            let temporaryTarget = try await driver.queryEditTarget(for: temporary)
            XCTAssertNil(temporaryTarget)
            _ = try await driver.execute("DROP TEMPORARY TABLE \(table)")
            // Metadata must agree on one alias as well as one physical table and schema.
            var mixedAlias = result
            mixedAlias.mysqlOrigins?[2].table = "other"
            let mixedAliasTarget = try await driver.queryEditTarget(for: mixedAlias)
            XCTAssertNil(mixedAliasTarget)
            var mixedSchema = result
            mixedSchema.mysqlOrigins?[2].schema = "other"
            let mixedSchemaTarget = try await driver.queryEditTarget(for: mixedSchema)
            XCTAssertNil(mixedSchemaTarget)
            var wrongSource = result
            wrongSource.statement = "SELECT * FROM `other`." + d.quoteIdentifier(name)
            let wrongSourceTarget = try await driver.queryEditTarget(for: wrongSource)
            XCTAssertNil(wrongSourceTarget)
            var repeated = result
            repeated.mysqlOrigins?[2].originalName = "id"
            let repeatedTarget = try await driver.queryEditTarget(for: repeated)
            XCTAssertNil(repeatedTarget)
            let fresh = try await driver.execute("SELECT * FROM \(table) ORDER BY id")
            let freshResolved = try await driver.queryEditTarget(for: fresh)
            let freshTarget = try XCTUnwrap(freshResolved)
            _ = try await driver.execute("UPDATE \(table) SET label='concurrent' WHERE id=2")
            do {
                _ = try await writer.commitQueryEdits([
                    .init(row: 0, original: fresh.rows[0], values: [2: "must roll back"]),
                    .init(row: 1, original: fresh.rows[1], values: [2: "stale"]),
                ], target: freshTarget)
                XCTFail("Conflict must roll back the entire batch")
            } catch { }
            let afterConflict = try await driver.execute("SELECT label FROM \(table) ORDER BY id")
            XCTAssertEqual(afterConflict.rows, [[special], ["concurrent"]])
            // Text predicates are exact even under case-insensitive/padded collations.
            let staleCase = try await driver.execute("SELECT * FROM \(table) ORDER BY id")
            _ = try await driver.execute("UPDATE \(table) SET label='CONCURRENT ' WHERE id=2")
            do {
                _ = try await writer.commitQueryEdits([.init(row: 1, original: staleCase.rows[1], values: [2: "must not overwrite"])], target: freshTarget)
                XCTFail("Case/trailing-space-only concurrent changes must conflict")
            } catch { }
            do {
                _ = try await writer.commitQueryEdits([
                    .init(row: 0, original: fresh.rows[0], values: [2: "must roll back"]),
                    .init(row: 1, original: ["18446744073709551615", "2", "CONCURRENT ", "45.60", "3", nil, nil, nil], values: [2: nil]),
                ], target: freshTarget)
                XCTFail("NOT NULL must reject the whole batch")
            } catch { }
            let afterConstraint = try await driver.execute("SELECT label FROM \(table) ORDER BY id")
            XCTAssertEqual(afterConstraint.rows, [[special], ["CONCURRENT "]])
            // The dictionary ID must detect DROP/CREATE even when columns and values are identical.
            _ = try await driver.execute("DROP VIEW \(view)")
            let old = try await driver.execute("SELECT * FROM \(table) ORDER BY id")
            let oldResolved = try await driver.queryEditTarget(for: old)
            let oldTarget = try XCTUnwrap(oldResolved)
            _ = try await driver.execute("DROP TABLE \(table)")
            _ = try await driver.execute("""
                CREATE TABLE \(table) (tenant BIGINT UNSIGNED, id INT, label TEXT NOT NULL, amount DECIMAL(12,2),
                    calc INT GENERATED ALWAYS AS (id+1) STORED, born DATE, photo BLOB, seen TIMESTAMP NULL,
                    PRIMARY KEY(tenant,id)) ENGINE=InnoDB
                """)
            _ = try await driver.execute("INSERT INTO \(table) (tenant,id,label,amount) VALUES (18446744073709551615,1,\(QueryEditTarget.mysqlLiteral(special)),23.45)")
            do {
                _ = try await writer.commitQueryEdits([.init(row: 0, original: old.rows[0], values: [2: "must not write"])], target: oldTarget)
                XCTFail("A replaced table must reject stale edits")
            } catch { }
            let untouched = try await driver.execute("SELECT label FROM \(table)")
            XCTAssertEqual(untouched.rows, [[special]])
            _ = try await driver.execute("DROP TABLE \(table)")
            for keyType in ["BINARY(4)", "DATE", "TIMESTAMP", "DOUBLE", "BIT(8)"] {
                _ = try await driver.execute("CREATE TABLE \(table) (id \(keyType) PRIMARY KEY, label TEXT) ENGINE=InnoDB")
                // No input conversion is needed: one empty-table result can be furnished with plausible wire
                // metadata to exercise the catalog safety gate for each unsupported key type.
                var unsafe = QueryResult(columns: ["id", "label"], statement: "SELECT id,label FROM \(table)")
                unsafe.mysqlOrigins = [
                    .init(schema: "tabula", table: name, originalTable: name, originalName: "id", dataType: 254, characterSet: 63),
                    .init(schema: "tabula", table: name, originalTable: name, originalName: "label", dataType: 252, characterSet: 45),
                ]
                let unsafeTarget = try await driver.queryEditTarget(for: unsafe)
                XCTAssertNil(unsafeTarget, keyType)
                _ = try await driver.execute("DROP TABLE \(table)")
            }
            _ = try await driver.execute("CREATE TABLE \(table) (id INT PRIMARY KEY, label TEXT) ENGINE=MyISAM")
            _ = try await driver.execute("INSERT INTO \(table) VALUES (1,'not transactional')")
            let myisam = try await driver.execute("SELECT * FROM \(table)")
            let myisamTarget = try await driver.queryEditTarget(for: myisam)
            XCTAssertNil(myisamTarget)
            _ = try await driver.execute("DROP TABLE \(table)")
            await driver.close()
            await writer.close()
        } catch {
            _ = try? await driver.execute("ROLLBACK")
            _ = try? await driver.execute("DROP VIEW IF EXISTS \(view)")
            _ = try? await driver.execute("DROP TABLE IF EXISTS \(table)")
            await driver.close()
            await writer.close()
            throw error
        }
    }
}
