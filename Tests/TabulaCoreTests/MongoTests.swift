import BSON
import XCTest
@testable import TabulaCore

final class MongoShellTests: XCTestCase {
    func testRoundTripKeepsTypes() throws {
        let text = """
            { _id: ObjectId("65f1a2b3c4d5e6f708091a2b"), name: "Hà Nội \\"x\\"", age: 42, big: NumberLong(9007199254740993),
              price: 5.0, ratio: 0.25, amount: NumberDecimal("1234.5600"), born: ISODate("1990-01-02T03:04:05.678Z"),
              tags: ["a", 1, true, null], nested: { "with space": [ { deep: MinKey() } ] }, re: /ab\\/c/ig,
              uid: UUID("123e4567-e89b-12d3-a456-426614174000"), bin: BinData(0, "AQID"), ts: Timestamp({ t: 1700000000, i: 3 }),
              max: MaxKey() }
            """
        let document = try MongoShell.parseDocument(text)
        XCTAssertTrue(document["age"] is Int32)
        XCTAssertTrue(document["big"] is Int)
        XCTAssertTrue(document["price"] is Double)
        XCTAssertTrue(document["amount"] is Decimal128)
        XCTAssertEqual((document["born"] as? Date)?.timeIntervalSince1970 ?? 0, 631_249_445.678, accuracy: 0.0005)
        XCTAssertEqual((document["re"] as? RegularExpression)?.pattern, "ab/c")
        XCTAssertEqual((document["re"] as? RegularExpression)?.options, "gi")
        XCTAssertEqual(document["name"] as? String, "Hà Nội \"x\"")

        let written = MongoShell.format(document)
        XCTAssertTrue(written.contains("big: NumberLong(9007199254740993)"), written)
        XCTAssertTrue(written.contains("price: 5.0"), written)
        XCTAssertTrue(written.contains("amount: NumberDecimal(\"1234.5600\")"), written)
        XCTAssertTrue(written.contains("\"with space\": "), written)
        XCTAssertTrue(written.contains("uid: UUID(\"123e4567-e89b-12d3-a456-426614174000\")"), written)
        XCTAssertTrue(written.contains("ts: Timestamp({ t: 1700000000, i: 3 })"), written)
        // Reading the written text gives the same document, byte for byte.
        XCTAssertEqual(try MongoShell.parseDocument(written).makeData(), document.makeData())
        XCTAssertEqual(try MongoShell.parseDocument(MongoShell.format(document, pretty: true)).makeData(), document.makeData())
    }

    func testExtendedJSONAndJavaScriptLeniency() throws {
        let document = try MongoShell.parseDocument("""
            {"_id": {"$oid": "65f1a2b3c4d5e6f708091a2b"}, "n": {"$numberLong": "7"}, "d": {"$date": {"$numberLong": "1000"}},
             'single': 'quoted', trailing: [1, 2,], // comment
             /* block */ "op": {"$gt": 5}, "dec": {"$numberDecimal": "0.1"}, "bin": {"$binary": {"base64": "AQ==", "subType": "04"}}}
            """)
        XCTAssertTrue(document["_id"] is ObjectId)
        XCTAssertEqual(document["n"] as? Int, 7)
        XCTAssertEqual((document["d"] as? Date)?.timeIntervalSince1970, 1)
        XCTAssertEqual(document["single"] as? String, "quoted")
        XCTAssertEqual((document["trailing"] as? Document)?.count, 2)
        // Query operators aren't wrapped values.
        XCTAssertEqual((document["op"] as? Document)?["$gt"] as? Int32, 5)
        XCTAssertTrue(document["dec"] is Decimal128)
        XCTAssertTrue(document["bin"] is Binary)
    }

    func testParseErrorsSayWhere() {
        XCTAssertThrowsError(try MongoShell.parseDocument("{ a: 1,\n  b: }")) { error in
            XCTAssertTrue(error.localizedDescription.contains("line 2"), error.localizedDescription)
        }
        XCTAssertThrowsError(try MongoShell.parseValue("ObjectId(\"nothex\")"))
        XCTAssertThrowsError(try MongoShell.parseValue("{ a: someFunction() }"))
        XCTAssertThrowsError(try MongoShell.parseDocument("[1, 2]"))
    }

    func testCellsArePlainText() throws {
        let document = try MongoShell.parseDocument(#"{ s: "x", i: NumberLong(5), d: 2.0, f: 2.5, id: ObjectId("65f1a2b3c4d5e6f708091a2b"), when: ISODate("2024-05-06T07:08:09Z"), n: null }"#)
        XCTAssertEqual(MongoShell.cell(document["s"]!), "x")
        XCTAssertEqual(MongoShell.cell(document["i"]!), "5")
        XCTAssertEqual(MongoShell.cell(document["d"]!), "2")
        XCTAssertEqual(MongoShell.cell(document["f"]!), "2.5")
        XCTAssertEqual(MongoShell.cell(document["id"]!), "65f1a2b3c4d5e6f708091a2b")
        XCTAssertEqual(MongoShell.cell(document["when"]!), "2024-05-06T07:08:09.000Z")
        XCTAssertNil(MongoShell.cell(document["n"]!))
    }

    func testDecimal128() throws {
        for text in ["0", "1", "-1", "1234.5600", "0.000001", "1E-7", "1.5E+20", "-0.1", "9999999999999999999999999999999999", "NaN", "Infinity", "-Infinity"] {
            let decimal = try XCTUnwrap(MongoDecimal.parse(text), text)
            XCTAssertEqual(MongoDecimal.string(decimal), text)
        }
        XCTAssertEqual(MongoDecimal.string(try XCTUnwrap(MongoDecimal.parse("12e3"))), "1.2E+4")
        XCTAssertEqual(MongoDecimal.string(try XCTUnwrap(MongoDecimal.parse(".5"))), "0.5")
        XCTAssertNil(MongoDecimal.parse("12345678901234567890123456789012345")) // 35 digits needs rounding
        XCTAssertNil(MongoDecimal.parse("abc"))
    }
}

final class MongoStatementTests: XCTestCase {
    func testParsesShellStatements() throws {
        let find = try MongoStatement.parse("db.users.find({ age: { $gt: 30 } }, { name: 1 }).sort({ name: -1 }).limit(5);")
        XCTAssertEqual(find.collection, "users")
        XCTAssertEqual(find.calls.map(\.name), ["find", "sort", "limit"])
        XCTAssertEqual(find.modifier("limit")?.arguments.first as? Int32, 5)

        XCTAssertEqual(try MongoStatement.parse("db.getCollection('my orders').countDocuments()").collection, "my orders")
        XCTAssertEqual(try MongoStatement.parse("db[\"a-b\"].find()").collection, "a-b")
        XCTAssertEqual(try MongoStatement.parse("db.system.profile.find()").collection, "system.profile")
        let sibling = try MongoStatement.parse("db.getSiblingDB(\"shop\").orders.drop()")
        XCTAssertEqual(sibling.database, "shop")
        XCTAssertEqual(sibling.collection, "orders")
        XCTAssertEqual(try MongoStatement.parse("db.runCommand({ ping: 1 })").target, .database)
        XCTAssertEqual(try MongoStatement.parse("show dbs").target, .show("dbs"))
        XCTAssertEqual(try MongoStatement.parse("use shop // comment").target, .use("shop"))
        XCTAssertThrowsError(try MongoStatement.parse("SELECT * FROM users"))
        XCTAssertThrowsError(try MongoStatement.parse("db.users.find({}).forEach(printjson)"))
    }

    func testFormattingAndRowLimit() throws {
        let statement = try MongoStatement.parse("db.users.find({a:1,b:{$in:[1,2]}}).sort({a:1})")
        XCTAssertEqual(statement.formatted(pretty: false), "db.users.find({ a: 1, b: { $in: [1, 2] } }).sort({ a: 1 })")
        XCTAssertEqual(statement.formatted(), "db.users.find({ a: 1, b: { $in: [1, 2] } }).sort({ a: 1 })")
        let long = try MongoStatement.parse("db.orders.aggregate([{$match:{status:'paid',total:{$gte:100}}},{$group:{_id:'$customer',n:{$sum:1}}}])")
        XCTAssertEqual(long.formatted(), """
            db.orders.aggregate([
              { $match: { status: "paid", total: { $gte: 100 } } },
              { $group: { _id: "$customer", n: { $sum: 1 } } }
            ])
            """)
        XCTAssertEqual(SQLFormatter.format("db.a.find({x:1})\n// note\ndb.b.find( {} ) // why", kind: .mongodb),
                       "db.a.find({ x: 1 })\n// note\ndb.b.find( {} ) // why")
        XCTAssertEqual(MongoStatement.collectionAccessor("stats"), ".getCollection(\"stats\")")

        XCTAssertEqual(MongoStatement.applyingRowLimit("db.users.find({});", limit: 300), "db.users.find({}).limit(300)")
        XCTAssertEqual(MongoStatement.applyingRowLimit("db.users.find().limit(5)", limit: 300), "db.users.find().limit(5)")
        XCTAssertEqual(MongoStatement.applyingRowLimit("db.users.aggregate([])", limit: 10), "db.users.aggregate([]).limit(10)")
        XCTAssertEqual(MongoStatement.applyingRowLimit("db.users.find().count()", limit: 10), "db.users.find().count()")
        XCTAssertEqual(MongoStatement.applyingRowLimit("db.users.deleteMany({})", limit: 10), "db.users.deleteMany({})")
    }

    func testSplitting() {
        let script = """
            use shop
            db.orders.find({
              status: "paid; really"   // a ; in a string and a comment
            })
              .sort({ at: -1 })
            db.orders.countDocuments({ note: /a;b/ }); db.orders.drop()

            // just a comment
            """
        let statements = SQLSplitter.statements(in: script, kind: .mongodb)
        XCTAssertEqual(statements.map(\.text).count, 4, statements.map(\.text).description)
        XCTAssertEqual(statements[0].text, "use shop")
        XCTAssertTrue(statements[1].text.hasSuffix(".sort({ at: -1 })"), statements[1].text)
        XCTAssertEqual(statements[2].text, "db.orders.countDocuments({ note: /a;b/ })")
        XCTAssertEqual(statements[3].text, "db.orders.drop()")
        XCTAssertEqual((script as NSString).substring(with: statements[3].range), "db.orders.drop()")
    }
}

final class MongoDialectTests: XCTestCase {
    private let table = TableRef(schema: "shop", name: "users")
    private let dialect = SQLDialect(kind: .mongodb)

    func testPagingAndCounting() {
        let page = dialect.selectPage(TablePageRequest(table: table, limit: 50, offset: 100, orderBy: "created at", ascending: false, filter: "{ a: 1 }"))
        XCTAssertEqual(page, "db.getSiblingDB(\"shop\").users.find({ a: 1 }).sort({ \"created at\": -1 }).skip(100).limit(50)")
        XCTAssertNoThrow(try MongoStatement.parse(page))
        XCTAssertEqual(dialect.countRows(table, filter: ""), "db.getSiblingDB(\"shop\").users.estimatedDocumentCount()")
        XCTAssertEqual(dialect.countRows(TableRef(schema: "shop", name: "v", kind: .view), filter: nil),
                       "db.getSiblingDB(\"shop\").v.countDocuments({})")
        XCTAssertEqual(dialect.drop(table), "db.getSiblingDB(\"shop\").users.drop()")
        XCTAssertEqual(dialect.selectSample(table, limit: 100), "db.users.find({}).limit(100)")
    }

    func testFilterRules() throws {
        XCTAssertEqual(dialect.condition([FilterRule(column: "age", op: .equals, value: "30")]), "{ age: { $in: [30, \"30\"] } }")
        XCTAssertEqual(dialect.condition([FilterRule(column: "age", op: .greater, value: "30")]), "{ age: { $gt: 30 } }")
        XCTAssertEqual(dialect.condition([FilterRule(column: "_id", op: .equals, value: "65f1a2b3c4d5e6f708091a2b")]),
                       "{ _id: { $in: [ObjectId(\"65f1a2b3c4d5e6f708091a2b\"), \"65f1a2b3c4d5e6f708091a2b\"] } }")
        XCTAssertEqual(dialect.condition([FilterRule(column: "name", op: .contains, value: "a.b")]), "{ name: /a\\.b/i }")
        XCTAssertEqual(dialect.condition([FilterRule(column: "name", op: .equals, value: "\"30\"")]), "{ name: \"30\" }")
        let combined = dialect.condition([
            FilterRule(column: "a", op: .isNull), FilterRule(column: "b", op: .equals, value: "x"),
            FilterRule(column: "c", op: .isNotNull, conjunction: .or),
        ])
        XCTAssertEqual(combined, "{ $or: [{ $and: [{ a: null }, { b: \"x\" }] }, { c: { $ne: null } }] }")
        XCTAssertNoThrow(try MongoShell.parseDocument(combined))
    }

    func testEditsKeepFieldTypes() throws {
        let original = #"{ _id: ObjectId("65f1a2b3c4d5e6f708091a2b"), n: NumberLong(5), d: 1.5, s: "x", when: ISODate("2024-01-01T00:00:00Z") }"#
        let update = try MongoChanges.update(table, row: .init(document: original, changes: ["n": "6", "d": "2", "s": "42", "when": "2025-02-03"]))
        XCTAssertEqual(update, #"db.getSiblingDB("shop").users.updateOne({ _id: ObjectId("65f1a2b3c4d5e6f708091a2b") }, { $set: { d: 2.0, n: NumberLong(6), s: "42", when: ISODate("2025-02-03T00:00:00.000Z") } })"#)
        XCTAssertThrowsError(try MongoChanges.update(table, row: .init(document: original, changes: ["n": "six"])))
        XCTAssertEqual(try MongoChanges.update(table, row: .init(document: original, changes: ["s": nil])),
                       #"db.getSiblingDB("shop").users.updateOne({ _id: ObjectId("65f1a2b3c4d5e6f708091a2b") }, { $set: { s: null } })"#)
        XCTAssertEqual(try MongoChanges.delete(table, document: original),
                       #"db.getSiblingDB("shop").users.deleteOne({ _id: ObjectId("65f1a2b3c4d5e6f708091a2b") })"#)
        XCTAssertEqual(MongoChanges.insert(table, values: [("name", "Ann"), ("age", "31"), ("note", nil)]),
                       #"db.getSiblingDB("shop").users.insertOne({ name: "Ann", age: 31, note: null })"#)
    }

    func testConnectionURL() {
        var config = ConnectionConfig(kind: .mongodb, host: "db.example.com", user: "app", database: "shop", tls: .verifyFull, authSource: "admin")
        XCTAssertEqual(config.url(), "mongodb://app@db.example.com:27017/shop?tls=true&authSource=admin")
        config.srv = true
        config.host = "cluster0.abcde.mongodb.net"
        XCTAssertEqual(config.url(), "mongodb+srv://app@cluster0.abcde.mongodb.net/shop?authSource=admin")
        let replicaSet = ConnectionConfig(kind: .mongodb, host: "a:27017,b:27018")
        XCTAssertEqual(replicaSet.url(), "mongodb://a:27017,b:27018")
    }
}

/// Runs against real servers: TABULA_TEST_MONGO_PORT (replica set, user and password "tabula") and
/// TABULA_TEST_MONGO_PLAIN_PORT (standalone, no authentication).
final class MongoIntegrationTests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment

    private func connect(password: String = "tabula", database: String = "tabula_test") async throws -> any DatabaseDriver {
        guard let port = env["TABULA_TEST_MONGO_PORT"].flatMap(Int.init) else { throw XCTSkip("TABULA_TEST_MONGO_PORT not set") }
        return try await DriverFactory.connect(ConnectionConfig(kind: .mongodb, port: port, user: "tabula", database: database), password: password)
    }

    func testWrongPasswordFails() async throws {
        do {
            let driver = try await connect(password: "wrong")
            await driver.close()
            XCTFail("expected an authentication error")
        } catch is XCTSkip {
            throw XCTSkip("TABULA_TEST_MONGO_PORT not set")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    func testBrowseQueryAndEdit() async throws {
        let driver = try await connect()
        defer { Task { await driver.close() } }
        _ = try await driver.execute("db.people.drop()")
        let inserted = try await driver.execute("""
            db.people.insertMany([
              { name: "Ann", age: 31, joined: ISODate("2024-01-02T00:00:00Z"), tags: ["a"], balance: NumberDecimal("10.50") },
              { name: "Bình", age: NumberLong(45), address: { city: "Hà Nội" } },
              { name: "Chi" }
            ])
            """)
        XCTAssertEqual(inserted.affectedRows, 3)

        let value1 = try await driver.schemas().contains("tabula_test")
        XCTAssertTrue(value1)
        let tables = try await driver.tables(in: "tabula_test")
        let people = try XCTUnwrap(tables.first { $0.name == "people" })
        let columns = try await driver.columns(of: people)
        XCTAssertEqual(columns.first?.name, "_id")
        XCTAssertTrue(columns.first?.isPrimaryKey == true)
        XCTAssertEqual(columns.first { $0.name == "age" }?.dataType, "int | long")
        XCTAssertTrue(columns.first { $0.name == "address" }?.isNullable == true)

        // Paging, sorting, filtering and counting go through the dialect, as the table tab does.
        let dialect = driver.dialect
        let filter = dialect.condition([FilterRule(column: "age", op: .greaterOrEqual, value: "31")])
        let page = try await driver.fetchPage(TablePageRequest(table: people, limit: 10, orderBy: "age", ascending: false, filter: filter))
        XCTAssertEqual(page.rows.count, 2)
        XCTAssertEqual(page.rows.first?[page.columns.firstIndex(of: "name")!], "Bình")
        let value2 = try await driver.countRows(people, filter: filter)
        XCTAssertEqual(value2, 2)
        let value3 = try await driver.countRows(people, filter: nil)
        XCTAssertEqual(value3, 3)

        // Edit a cell: the long stays a long.
        let row = try XCTUnwrap(page.documents?.first)
        let update = try MongoChanges.update(people, row: .init(document: row, changes: ["age": "46", "name": "Bình B"]))
        try await driver.applyInTransaction([update])
        let after = try await driver.execute("db.people.find({ name: \"Bình B\" })")
        XCTAssertTrue(after.documents?.first?.contains("age: NumberLong(46)") == true, after.documents.map { Array($0).description } ?? "")

        // Replace and delete by _id.
        let replaced = try MongoChanges.replace(people, original: row, with: "{ name: \"Replaced\", n: 1 }")
        _ = try await driver.execute(replaced)
        let value4 = try await driver.execute("db.people.countDocuments({ name: \"Replaced\" })").rows.first?.first
        XCTAssertEqual(value4, "1")
        let found = try await driver.execute("db.people.findOne({ name: \"Replaced\" })")
        let document = try XCTUnwrap(found.documents?.first)
        _ = try await driver.execute(try MongoChanges.delete(people, document: document))
        let value5 = try await driver.countRows(people, filter: nil)
        XCTAssertEqual(value5, 2)

        // Shell statements.
        let aggregate = try await driver.execute("db.people.aggregate([{ $group: { _id: null, n: { $sum: 1 } } }])")
        XCTAssertEqual(aggregate.rows.first?[aggregate.columns.firstIndex(of: "n")!], "2")
        let distinct = try await driver.execute("db.people.distinct(\"name\")")
        XCTAssertEqual(Set(distinct.rows.compactMap { $0.first ?? nil }), ["Ann", "Chi"])
        let updated = try await driver.execute("db.people.updateMany({}, { $inc: { visits: 1 } })")
        XCTAssertEqual(updated.affectedRows, 2)
        _ = try await driver.execute("db.people.createIndex({ name: 1 }, { unique: true })")
        let indexes = try await driver.indexes(of: people)
        XCTAssertTrue(indexes.contains { $0.name == "name_1" && $0.isUnique })
        XCTAssertTrue(indexes.contains { $0.isPrimary })
        do {
            _ = try await driver.execute("db.people.insertOne({ name: \"Ann\" })")
            XCTFail("expected a duplicate key error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("duplicate key"), error.localizedDescription)
        }
        // More documents than one batch come back through getMore, capped by the limit.
        _ = try await driver.execute("db.many.drop()")
        let docs = (0..<1200).map { "{ i: \($0) }" }.joined(separator: ", ")
        _ = try await driver.execute("db.many.insertMany([\(docs)])")
        let value6 = try await driver.execute("db.many.find({})").rows.count
        XCTAssertEqual(value6, 1200)
        let value7 = try await driver.execute(driver.dialect.applyingRowLimit("db.many.find({})", limit: 700)).rows.count
        XCTAssertEqual(value7, 700)
        let value8 = try await driver.execute("db.many.find({ i: { $gte: 1000 } }).count()").rows.first?.first
        XCTAssertEqual(value8, "200")

        _ = try await driver.execute("db.removing.insertMany([{ k: 1 }, { k: 1 }, { k: 1 }])")
        _ = try await driver.execute("db.removing.remove({ k: 1 }, { justOne: true })")
        let leftAfterOne = try await driver.execute("db.removing.countDocuments({})").rows.first?.first
        XCTAssertEqual(leftAfterOne, "2")
        _ = try await driver.execute("db.removing.remove({ k: 1 })")
        let leftAfterAll = try await driver.execute("db.removing.countDocuments({})").rows.first?.first
        XCTAssertEqual(leftAfterAll, "0")
        _ = try await driver.execute("db.removing.drop()")

        let explain = try await driver.execute("db.people.find({ name: \"Ann\" }).explain()")
        XCTAssertTrue(explain.columns.contains("queryPlanner"))
        let value9 = try await driver.execute("show collections").rows.compactMap { $0.first ?? nil }.sorted()
        XCTAssertEqual(value9, ["many", "people"])
        _ = try await driver.execute("use other_db")
        let value10 = try await driver.execute("db.getName()").rows.first?.first
        XCTAssertEqual(value10, "other_db")
        let value11 = await driver.serverVersion()?.hasPrefix("MongoDB 8") == true
        XCTAssertTrue(value11)

        let metrics = try await driver.metrics(schema: "tabula_test")
        XCTAssertTrue(metrics.groups.contains { $0.title == "Server" })
        XCTAssertTrue(metrics.tables.contains { $0.name == "many" && $0.rows == 1200 })
        _ = try await driver.execute("db.getSiblingDB(\"tabula_test\").dropDatabase()")
    }

    func testStandaloneWithoutAuthentication() async throws {
        guard let port = env["TABULA_TEST_MONGO_PLAIN_PORT"].flatMap(Int.init) else { throw XCTSkip("TABULA_TEST_MONGO_PLAIN_PORT not set") }
        let driver = try await DriverFactory.connect(ConnectionConfig(kind: .mongodb, port: port), password: nil)
        _ = try await driver.execute("db.t.insertOne({ x: 1 })")
        let value12 = try await driver.defaultSchema()
        XCTAssertEqual(value12, "test")
        let value13 = try await driver.countRows(TableRef(schema: "test", name: "t"), filter: "{ x: 1 }")
        XCTAssertEqual(value13, 1)
        _ = try await driver.execute("db.dropDatabase()")
        await driver.close()
    }

    /// TABULA_TEST_MONGO_SRV_SEED: a seed list whose members run a server without authentication, e.g.
    /// test1.test.build.10gen.cc (MongoDB's test records, pointing at localhost:27017/27018).
    func testSeedListConnection() async throws {
        guard let seed = env["TABULA_TEST_MONGO_SRV_SEED"] else { throw XCTSkip("TABULA_TEST_MONGO_SRV_SEED not set") }
        let driver = try await DriverFactory.connect(ConnectionConfig(kind: .mongodb, host: seed, tls: .disable, srv: true), password: nil)
        let version = await driver.serverVersion()
        XCTAssertTrue(version?.hasPrefix("MongoDB") == true, version ?? "nil")
        await driver.close()
    }

    func testUnreachableMembersGiveAReadableError() async throws {
        do {
            _ = try await DriverFactory.connect(ConnectionConfig(kind: .mongodb, host: "127.0.0.1:1,127.0.0.1:2", connectTimeout: 5), password: nil)
            XCTFail("expected a connection error")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("127.0.0.1:1: Connection refused") && message.contains("127.0.0.1:2: Connection refused"), message)
        }
    }

    func testUnreachableServerTimesOut() async throws {
        let started = Date()
        do {
            _ = try await DriverFactory.connect(ConnectionConfig(kind: .mongodb, host: "127.0.0.1", port: 1, connectTimeout: 3), password: nil)
            XCTFail("expected a connection error")
        } catch {
            XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        }
    }
}

final class MongoCompletionTests: XCTestCase {
    private func items(_ text: String) -> [String] {
        let caret = (text as NSString).range(of: "|").location
        let clean = text.replacingOccurrences(of: "|", with: "")
        return MongoCompletion.suggestions(in: clean, caret: caret, collections: ["users", "orders"],
                                           fields: { $0 == "users" ? ["_id", "name", "nickname", "age"] : nil }).items
    }

    func testContexts() {
        XCTAssertEqual(Array(items("db.|").prefix(2)), ["users", "orders"].sorted { ($0.count, $0) < ($1.count, $1) })
        XCTAssertTrue(items("db.u|").contains("users"))
        XCTAssertTrue(items("db.users.f|").starts(with: ["find", "findOne"]))
        XCTAssertTrue(items("db.users.find({}).|").contains("sort"))
        XCTAssertTrue(items("db.getCollection(\"users\").|").contains("aggregate"))
        XCTAssertEqual(items("db.users.find({ na|"), ["name"])
        XCTAssertTrue(items("db.users.find({ n|").starts(with: ["name", "nickname"]))
        XCTAssertTrue(items("db.users.updateOne({}, { $s|").contains("$set"))
        XCTAssertEqual(items("db.users.find({ name: \"na|"), [])
        XCTAssertEqual(items("db.users.find()\nd|"), ["db"])
        XCTAssertEqual(items("show c|"), ["collections"])
        XCTAssertTrue(items("db.users.find({ _id: Obj|").contains("ObjectId"))
    }
}

final class MongoReviewFixTests: XCTestCase {
    private let table = TableRef(schema: "shop", name: "users")

    func testBeautifyKeepsValuesMadeAtRunTime() {
        let text = "db.logs.insertOne({_id:ObjectId(),at:new Date(),u:UUID()})"
        XCTAssertEqual(SQLFormatter.format(text, kind: .mongodb), text)
        XCTAssertEqual(SQLFormatter.format("db.logs.find({a:1})", kind: .mongodb), "db.logs.find({ a: 1 })")
    }

    func testDecimalAndUntypedValuesKeepEveryDigit() throws {
        let original = #"{ _id: 1, price: NumberDecimal("1.00") }"#
        let update = try MongoChanges.update(table, row: .init(document: original, changes: ["price": "12345678901234567.89"]))
        XCTAssertTrue(update.contains(#"NumberDecimal("12345678901234567.89")"#), update)
        XCTAssertEqual(MongoChanges.typed("02134") as? String, "02134")
        XCTAssertEqual(MongoChanges.typed("12345678901234567890") as? String, "12345678901234567890")
        XCTAssertEqual(MongoChanges.typed("42") as? Int32, 42)
        XCTAssertEqual(MongoChanges.typed("2.5") as? Double, 2.5)
    }

    func testSeedListHonorsTLSModeAndResolvedMembers() throws {
        let config = ConnectionConfig(kind: .mongodb, host: "cluster0.example.net", tls: .require, srv: true)
        let settings = try MongoDriver.settings(for: config, password: nil,
                                                members: [.init(hostname: "shard-00.example.net", port: 27017)])
        XCTAssertTrue(settings.useSSL)
        XCTAssertFalse(settings.verifySSLCertificates)
        XCTAssertFalse(settings.isSRV)
        XCTAssertEqual(settings.hosts.map(\.hostname), ["shard-00.example.net"])
    }

    func testSeedListTargetsMustShareTheParentDomain() throws {
        let good = [MongoSRV.Target(host: "cluster0-shard-00-00.abcde.mongodb.net.", port: 27017)]
        XCTAssertNoThrow(try MongoSRV.validate(good, seed: "cluster0.abcde.mongodb.net"))
        for bad in ["evil.attacker.com", "abcde.mongodb.net", "xabcde.mongodb.net", "mongodb.net"] {
            XCTAssertThrowsError(try MongoSRV.validate([.init(host: bad, port: 27017)], seed: "cluster0.abcde.mongodb.net"), bad)
        }
    }

    func testSRVRecordParsing() throws {
        // priority 0, weight 5, port 27017, target "a.example.net."
        var bytes: [UInt8] = [0, 0, 0, 5, 0x69, 0x89, 1, 97, 7]
        bytes += Array("example".utf8)
        bytes.append(3)
        bytes += Array("net".utf8)
        bytes.append(0)
        let target = bytes.withUnsafeBytes { MongoSRV.parse($0) }
        XCTAssertEqual(target, MongoSRV.Target(host: "a.example.net", port: 27017))
    }

    func testSystemResolverFindsSRVRecords() async throws {
        guard ProcessInfo.processInfo.environment["TABULA_TEST_NETWORK"] != nil else { throw XCTSkip("TABULA_TEST_NETWORK not set") }
        // MongoDB's public test records for the SRV specification.
        let members = try await MongoSRV.resolve("test1.test.build.10gen.cc", timeout: 10)
        XCTAssertEqual(Set(members.map(\.port)), [27017, 27018])
        XCTAssertTrue(members.allSatisfy { $0.host == "localhost.test.build.10gen.cc" }, "\(members)")
        // test19 includes a target in another domain (evil.build.10gen.cc), which must be refused.
        do {
            _ = try await MongoSRV.resolve("test19.test.build.10gen.cc", timeout: 10)
            XCTFail("expected the foreign target to be refused")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("evil.build.10gen.cc"), error.localizedDescription)
        }
        // A seed with no MongoDB records resolves to nothing, which is reported rather than hanging.
        do {
            _ = try await MongoSRV.resolve("nothing-here.example.com", timeout: 5)
            XCTFail("expected no records")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("no MongoDB servers") || error.localizedDescription.contains("DNS"),
                          error.localizedDescription)
        }
    }

    func testReplicaSetURLKeepsPorts() {
        XCTAssertEqual(ConnectionConfig(kind: .mongodb, host: "a,b:27019", port: 27018).url(), "mongodb://a:27018,b:27019")
    }
}

final class SplitterSecurityTests: XCTestCase {
    /// A name starting with a combining mark joins the opening quote into one grapheme; the splitter must still
    /// see the quote, so nothing inside the name can end the statement.
    func testCombiningMarkAfterQuoteDoesNotSplit() {
        let name = "\u{0301});db.adminCommand({createUser:'mallory',pwd:'pw',roles:['root']});//"
        let mongo = SQLDialect(kind: .mongodb).selectSample(TableRef(schema: "shop", name: name), limit: 100)
        let statements = SQLSplitter.statements(in: mongo, kind: .mongodb)
        XCTAssertEqual(statements.map(\.text), [mongo])
        XCTAssertEqual(SQLSplitter.statement(at: (mongo as NSString).length, in: mongo, kind: .mongodb)?.text, mongo)
        XCTAssertEqual(try MongoStatement.parse(mongo).collection, name)

        let sqlName = "\u{0301}\"; DROP TABLE users; --"
        let sql = SQLDialect(kind: .postgres).selectSample(TableRef(schema: "public", name: sqlName), limit: 100)
        XCTAssertEqual(SQLSplitter.split(sql, kind: .postgres), [String(sql.dropLast())])
    }
}
