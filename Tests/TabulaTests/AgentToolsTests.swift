import XCTest

@testable import TabulaAI
@testable import TabulaConnections
@testable import TabulaDrivers
@testable import TabulaFoundation
@testable import TabulaMongo
@testable import TabulaPostgres
@testable import TabulaSQL
@testable import TabulaSQLite

final class AgentProtocolTests: XCTestCase {
    func testParsesToolCalls() {
        let reply = """
            Let me check the columns first.
            ```tool
            {"tool": "describe_table", "table": "public.orders"}
            ```
            """
        XCTAssertEqual(AgentProtocol.call(in: reply), AgentToolCall(tool: .describeTable, table: "public.orders"))
        XCTAssertEqual(AgentProtocol.visibleText(reply), "Let me check the columns first.")

        // Nested arguments, "name" for "tool" and "sql" for "query", as some models write them.
        let nested = "```tool\n{\"name\": \"run_query\", \"arguments\": {\"sql\": \"SELECT 1\"}}\n```"
        XCTAssertEqual(AgentProtocol.call(in: nested), AgentToolCall(tool: .runQuery, query: "SELECT 1"))

        XCTAssertNil(AgentProtocol.call(in: "Here it is:\n```sql\nSELECT 1;\n```"))
        XCTAssertNil(AgentProtocol.call(in: "```tool\n{\"tool\": \"drop_everything\"}\n```"))
        XCTAssertNil(AgentProtocol.call(in: "```tool\nnot json\n```"))
    }

    /// A query may hold ``` itself; a block Tabula can't read stays visible; the fence's case doesn't matter (#252).
    func testFencesInsideAndAroundTheRequest() {
        let inside = "Here:\n```tool\n{\"tool\": \"run_query\", \"query\": \"SELECT '```' AS x\"}\n```"
        XCTAssertEqual(AgentProtocol.call(in: inside), AgentToolCall(tool: .runQuery, query: "SELECT '```' AS x"))
        XCTAssertEqual(AgentProtocol.visibleText(inside), "Here:")
        let unreadable = "Let me look.\n```tool\n{tool: \"list_tables\"}\n```"
        XCTAssertNil(AgentProtocol.call(in: unreadable))
        XCTAssertEqual(AgentProtocol.visibleText(unreadable), unreadable, "nothing ran, so nothing is hidden")
        let upper = "```TOOL\n{\"tool\": \"list_tables\"}\n```"
        XCTAssertEqual(AgentProtocol.call(in: upper), AgentToolCall(tool: .listTables))
        XCTAssertEqual(AgentProtocol.visibleText(upper), "")
        XCTAssertEqual(AgentProtocol.streamingText("Checking\n```To"), "Checking\n")
        // Unclosed, as when the reply stops at the token limit.
        XCTAssertEqual(
            AgentProtocol.call(in: "```tool\n{\"tool\": \"list_tables\"}"),
            AgentToolCall(tool: .listTables)
        )
    }

    func testStreamingTextHoldsBackAToolFence() {
        XCTAssertEqual(AgentProtocol.streamingText("Checking`"), "Checking")
        XCTAssertEqual(AgentProtocol.streamingText("Checking\n```to"), "Checking\n")
        XCTAssertEqual(AgentProtocol.streamingText("Checking\n```tool\n{\"tool\""), "Checking")
        // Another fence shows once it is clearly not a tool request.
        XCTAssertEqual(AgentProtocol.streamingText("Query:\n```sql\nSELECT"), "Query:\n```sql\nSELECT")
    }

    func testChatPromptCarriesToolsAndSteps() {
        let schema = SQLPrompts.Schema(tables: [], foreignKeys: [], defaultSchema: "public")
        let step = (
            call: AgentToolCall(tool: .runQuery, query: "SELECT count(*) FROM orders"), result: "1 row:\ncount\n42"
        )
        let request = SQLPrompts.chat(
            question: "How many orders?",
            history: [],
            editorSQL: nil,
            schema: schema,
            kind: .postgres,
            tools: AgentProtocol.instructions(kind: .postgres, canQuery: true),
            steps: [step]
        )
        XCTAssertTrue(request.instructions.contains("run_query"))
        XCTAssertTrue(request.prompt.contains("Result:\n1 row:\ncount\n42"))
        XCTAssertTrue(request.prompt.contains("use another tool, or answer"))

        let last = SQLPrompts.chat(
            question: "How many orders?",
            history: [],
            editorSQL: nil,
            schema: schema,
            kind: .postgres,
            steps: [step]
        )
        XCTAssertFalse(last.instructions.contains("run_query"))
        XCTAssertTrue(last.prompt.contains("No more tools now"))

        let schemaOnly = AgentProtocol.instructions(kind: .postgres, canQuery: false)
        XCTAssertFalse(schemaOnly.contains("run_query"))
        XCTAssertTrue(schemaOnly.contains("can't see rows"))
    }
}

final class AgentReadOnlyTests: XCTestCase {
    func testSQLReads() {
        for sql in [
            "SELECT * FROM orders WHERE status = 'paid'",
            "with t as (select 1 as x) select replace(name, 'a', 'b') from t",
            "SELECT substring(name FROM 1 FOR 3) FROM customers",
            "EXPLAIN SELECT * FROM orders",
            "SHOW TABLES",
            "select 'delete from x; update y' as text",
        ] {
            XCTAssertNil(SQLDialect(flavor: .postgres).readOnlyViolation(sql), sql)
        }
    }

    func testSQLWritesAreRefused() {
        for sql in [
            "DELETE FROM orders", "UPDATE orders SET total = 0", "insert into t values (1)", "DROP TABLE orders",
            "SELECT 1; DELETE FROM orders",
            "WITH gone AS (DELETE FROM orders RETURNING *) SELECT * FROM gone",
            "SELECT * INTO backup FROM orders",
            "SELECT * FROM orders FOR UPDATE",
            "EXPLAIN ANALYZE DELETE FROM orders",
            "SET search_path TO other",
            "SELECT pg_terminate_backend(123)",
            "SELECT * FROM t INTO OUTFILE '/tmp/x'",
            "BEGIN", "VACUUM", "COPY orders TO '/tmp/x'",
        ] {
            XCTAssertNotNil(SQLDialect(flavor: .postgres).readOnlyViolation(sql), sql)
        }
    }

    /// Ways around the check found in review: quoted function names, comments MySQL runs, backslash escapes.
    func testSQLCheckBypassesAreRefused() {
        XCTAssertNotNil(
            SQLDialect(flavor: .postgres)
                .readOnlyViolation("SELECT \"set_config\"('default_transaction_read_only', 'off', false)")
        )
        XCTAssertNotNil(
            SQLDialect(flavor: .postgres).readOnlyViolation("SELECT pg_catalog.\"pg_terminate_backend\"(1)")
        )
        XCTAssertNotNil(SQLDialect(flavor: .mysql).readOnlyViolation("SELECT `GET_LOCK`('x', 0)"))
        XCTAssertNotNil(SQLDialect(flavor: .mysql).readOnlyViolation("SELECT 1 /*! , SLEEP(5) */"))
        XCTAssertNotNil(SQLDialect(flavor: .mysql).readOnlyViolation("SELECT 1 --x\n, SLEEP(5)"))
        XCTAssertNotNil(
            SQLDialect(flavor: .postgres).readOnlyViolation("SELECT E'\\'', set_config('a', 'b', false), ''")
        )
        XCTAssertNotNil(SQLDialect(flavor: .mysql).readOnlyViolation("SELECT 'a\\'' , SLEEP(5) -- '"))
        // U&"…" is one quoted name to the lexer; it still names the blocked function (found in review of #245).
        for sql in ["SELECT U&\"pg_read_file\"('/etc/passwd')", "SELECT u&\"set_config\"('a', 'b', false)"] {
            XCTAssertNotNil(SQLDialect(flavor: .postgres).readOnlyViolation(sql), sql)
        }
        // A no-break space after MySQL's -- isn't a comment to the lexer or the splitter: two statements.
        XCTAssertNotNil(SQLDialect(flavor: .mysql).readOnlyViolation("SELECT 1 --\u{A0}x; FLUSH TABLES"))
        // PostgreSQL reads this name as pg_sleep and runs it (#214).
        XCTAssertNotNil(
            SQLDialect(flavor: .postgres).readOnlyViolation("SELECT U&\"pg_sl!0065ep\" UESCAPE '!' (0)")
        )
    }

    /// Found by running them on PostgreSQL inside BEGIN READ ONLY: they act anyway, or run SQL kept in a string.
    func testFunctionsTheReadOnlyTransactionAllows() {
        for sql in [
            "SELECT query_to_xml('select pg_terminate_backend(pid) from pg_stat_activity', true, false, '')",
            "SELECT * FROM ts_stat('select to_tsvector(pg_cancel_backend(1)::text)')",
            "SELECT ts_rewrite('a'::tsquery, 'select pg_reload_conf()')",
            "SELECT pg_advisory_lock_shared(42)", "SELECT pg_stat_reset()", "SELECT pg_switch_wal()",
            "SELECT pg_create_restore_point('x')", "SELECT pg_logical_emit_message(false, 'p', 'x')",
            "SELECT pg_drop_replication_slot('s')", "SELECT * FROM crosstab('select 1')",
            // They change an index or write WAL (#214).
            "SELECT brin_summarize_new_values('i')", "SELECT brin_desummarize_range('i', 0)",
            "SELECT gin_clean_pending_list('i')", "SELECT pg_log_standby_snapshot()",
        ] {
            XCTAssertNotNil(SQLDialect(flavor: .postgres).readOnlyViolation(sql), sql)
        }
        XCTAssertNotNil(SQLDialect(flavor: .mysql).readOnlyViolation("SELECT RELEASE_ALL_LOCKS()"))
        // Catalog views whose names start like blocked functions still read.
        for sql in ["SELECT * FROM pg_file_settings", "SELECT slot_name FROM pg_replication_slots"] {
            XCTAssertNil(SQLDialect(flavor: .postgres).readOnlyViolation(sql), sql)
        }
    }

    func testMongoEscapesAreReadBeforeTheCheck() {
        let out = MongoQueryDialect().readOnlyViolation("db.orders.aggregate([{ \"\\u0024out\": \"copy\" }])")
        XCTAssertEqual(out, "$out writes to a collection, so the command can't run.")
        let merge = MongoQueryDialect()
            .readOnlyViolation("db.orders.aggregate([{ \"\\x24merge\": { into: \"copy\" } }])")
        XCTAssertEqual(merge, "$merge writes to a collection, so the command can't run.")
        let where_ = MongoQueryDialect().readOnlyViolation("db.orders.find({ $where: \"true\" })")
        XCTAssertEqual(where_, "$where runs code on the server, so the command can't run.")
    }

    func testMongoReads() {
        for command in [
            "db.orders.find({ status: \"paid\" }).sort({ total: -1 })",
            "db.orders.aggregate([{ $group: { _id: \"$status\", n: { $sum: 1 } } }])",
            "db.orders.countDocuments({})", "db.orders.distinct(\"status\")", "show collections",
            "db.getCollectionNames()",
        ] {
            XCTAssertNil(MongoQueryDialect().readOnlyViolation(command), command)
        }
        for command in [
            "db.orders.deleteMany({})", "db.orders.updateOne({}, { $set: { a: 1 } })", "db.orders.drop()",
            "db.orders.aggregate([{ $match: {} }, { $out: \"copy\" }])", "db.dropDatabase()",
            "db.runCommand({ drop: \"orders\" })", "use admin", "db.orders.find(); db.orders.drop()",
            // Escapes are decoded by the parser, so they can't hide a stage.
            "db.orders.aggregate([{ \"\\u0024out\": \"copy\" }])",
            "db.orders.aggregate([{ $match: {} }, { \"\\x24merge\": { into: \"copy\" } }])",
            "db.orders.find({ $where: \"sleep(100) || true\" })",
            "db.orders.aggregate([{ $addFields: { x: { $function: { body: \"function() {}\", args: [], lang: \"js\" } } } }])",
        ] {
            XCTAssertNotNil(MongoQueryDialect().readOnlyViolation(command), command)
        }
    }
}

final class AgentToolboxTests: XCTestCase {
    private var path = ""

    override func setUp() async throws {
        path =
            FileManager.default.temporaryDirectory.appendingPathComponent("tabula-agent-\(UUID().uuidString).sqlite")
            .path
        let setup = try SQLiteDriver(path: path)
        _ = try await setup.executeScript(
            """
            CREATE TABLE customers (id INTEGER PRIMARY KEY, name TEXT NOT NULL);
            CREATE TABLE orders (id INTEGER PRIMARY KEY, customer_id INTEGER REFERENCES customers(id), total REAL, note TEXT);
            CREATE INDEX orders_customer ON orders(customer_id);
            INSERT INTO customers (name) VALUES ('An'), ('Bình');
            """
        )
        for index in 1...120 {
            _ = try await setup.execute(
                "INSERT INTO orders (customer_id, total, note) VALUES (\(index % 2 + 1), \(index), 'n\(index)')"
            )
        }
        await setup.close()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: path)
    }

    func testToolsOnSQLite() async throws {
        let driver = try SQLiteDriver(path: path)
        try await AgentToolbox.prepare(driver)
        let toolbox = AgentToolbox(driver: driver, currentSchema: "main", savedQueries: [])

        let tables = await toolbox.run(AgentToolCall(tool: .listTables))
        XCTAssertTrue(tables.contains("customers") && tables.contains("orders"), tables)

        let orders = await toolbox.run(AgentToolCall(tool: .describeTable, table: "ORDERS"))
        XCTAssertTrue(orders.contains("customer_id INTEGER"), orders)
        XCTAssertTrue(orders.contains("orders_customer"), orders)
        XCTAssertTrue(orders.contains("-> main.customers(id)"), orders)
        let missing = await toolbox.run(AgentToolCall(tool: .describeTable, table: "nope"))
        XCTAssertTrue(missing.hasPrefix("Error: no table named nope"), missing)

        // The row limit is added to the statement and the result is cut to it.
        let rows = await toolbox.run(AgentToolCall(tool: .runQuery, query: "SELECT id, total FROM orders ORDER BY id"))
        XCTAssertTrue(rows.hasPrefix("\(Defaults.AI.agentRowLimit) rows shown (more were returned"), rows)
        let count = await toolbox.run(AgentToolCall(tool: .runQuery, query: "SELECT count(*) AS n FROM orders"))
        XCTAssertEqual(count, "1 row:\nn\n120")

        let refused = await toolbox.run(AgentToolCall(tool: .runQuery, query: "DELETE FROM orders"))
        XCTAssertTrue(refused.hasPrefix("Refused:"), refused)
        let broken = await toolbox.run(AgentToolCall(tool: .runQuery, query: "SELECT * FROM missing_table"))
        XCTAssertTrue(broken.hasPrefix("Error:"), broken)

        // The connection itself is read-only, should a write ever get past the check.
        do {
            _ = try await driver.execute("DELETE FROM orders")
            XCTFail("The agent's connection accepted a write")
        } catch {}
        let after = try await driver.execute("SELECT count(*) FROM orders")
        XCTAssertEqual(after.rows.first?.first ?? nil, "120")
        await driver.close()
    }

    func testPostgresAgentConnectionIsReadOnly() async throws {
        guard let port = ProcessInfo.processInfo.environment["TABULA_TEST_PG_PORT"].flatMap(Int.init) else {
            throw XCTSkip("TABULA_TEST_PG_PORT not set")
        }
        let config = ConnectionConfig(kind: .postgres, port: port, user: "tabula", database: "tabula")
        let driver = try await DriverFactory.connect(config, password: "tabula")
        try await AgentToolbox.prepare(driver)
        do {
            _ = try await driver.execute("CREATE TABLE tabula_agent_probe (id int)")
            XCTFail("The agent's connection accepted a write")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("read-only"), error.localizedDescription)
        }
        let toolbox = AgentToolbox(driver: driver, currentSchema: "public", savedQueries: [])
        let result = await toolbox.run(AgentToolCall(tool: .runQuery, query: "SELECT 1 AS one"))
        XCTAssertEqual(result, "1 row:\none\n1")

        // Even past the check, each query's own read-only transaction can't be switched back to read-write.
        _ = try await driver.execute("SET default_transaction_read_only = off")
        for statement in [
            "SELECT set_config('transaction_read_only', 'off', true)",
            "CREATE TABLE tabula_agent_probe (id int)",
        ] {
            do {
                _ = try await toolbox.runReadOnly(statement)
                XCTFail("Ran in the agent's transaction: \(statement)")
            } catch {}
        }
        let after = try await driver.execute("SELECT to_regclass('public.tabula_agent_probe') IS NULL")
        XCTAssertEqual(after.rows.first?.first ?? nil, "true")
        await driver.close()
    }

    func testMySQLAgentQueriesAreReadOnly() async throws {
        guard let port = ProcessInfo.processInfo.environment["TABULA_TEST_MYSQL_PORT"].flatMap(Int.init) else {
            throw XCTSkip("TABULA_TEST_MYSQL_PORT not set")
        }
        let config = ConnectionConfig(kind: .mysql, port: port, user: "tabula", database: "tabula", tls: .require)
        let driver = try await DriverFactory.connect(config, password: "tabula")
        try await AgentToolbox.prepare(driver)
        let toolbox = AgentToolbox(driver: driver, currentSchema: "tabula", savedQueries: [])
        let before = try await driver.execute("SELECT count(*) FROM employees").rows.first?.first ?? nil
        // The session default can be changed by a statement, the per-query read-only transaction can't.
        _ = try await driver.execute("SET SESSION TRANSACTION READ WRITE")
        do {
            _ = try await toolbox.runReadOnly("INSERT INTO employees (name) VALUES ('agent probe')")
            XCTFail("The agent's transaction accepted a write")
        } catch {}
        let after = try await driver.execute("SELECT count(*) FROM employees").rows.first?.first ?? nil
        XCTAssertEqual(after, before)
        await driver.close()
    }

    func testResultTextCutsLongCells() {
        let long = String(repeating: "x", count: Defaults.AI.agentCellLength + 50)
        let text = AgentToolbox.text(
            of: QueryResult(columns: ["a", "b"], rows: [[long, nil], ["tab\there", "line\nbreak"]])
        )
        XCTAssertTrue(text.hasPrefix("2 rows:\na\tb\n"))
        XCTAssertTrue(text.contains(String(repeating: "x", count: Defaults.AI.agentCellLength) + "…\tNULL"))
        XCTAssertTrue(text.hasSuffix("tab here\tline break"))
        XCTAssertEqual(AgentToolbox.text(of: QueryResult()), "No rows returned.")
    }

    func testResultsAreShownInColumns() {
        let text = "2 rows:\nstatus\trevenue\torders\npaid\t393963.90\t857\nshipped\t263090.96\t572"
        XCTAssertEqual(
            AgentToolbox.aligned(text),
            """
            2 rows:
            status   revenue    orders
            paid     393963.90  857
            shipped  263090.96  572
            """
        )
        XCTAssertEqual(AgentToolbox.aligned("No rows returned."), "No rows returned.")
    }
}

final class ChatStoreTests: XCTestCase {
    func testSavesLoadsAndTrims() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("tabula-chats-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ChatStore(base: base)
        let connection = UUID()
        XCTAssertEqual(store.load(connection).conversations, [])

        var running = ChatMessage(
            role: .tool,
            text: "",
            tool: .init(call: AgentToolCall(tool: .runQuery, query: "SELECT 1"), status: .running)
        )
        running.thinking = ""
        let messages = [
            ChatMessage(role: .user, text: "How many orders?\nAnd by status?"), running,
            ChatMessage(role: .assistant, text: "There are 42."),
        ]
        let old = ChatConversation(title: "Old", updated: Date(timeIntervalSinceNow: -100), messages: messages)
        let new = ChatConversation(title: ChatConversation.title(for: messages), messages: messages)
        try store.save([old, new], for: connection)

        let loaded = store.load(connection).conversations
        XCTAssertEqual(loaded.map(\.id), [new.id, old.id])
        XCTAssertEqual(loaded.first?.title, "How many orders?")
        XCTAssertEqual(loaded.first?.messages.count, 3)
        // A tool that was running when the app quit is stopped, not left spinning.
        XCTAssertEqual(loaded.first?.messages[1].tool?.status, .stopped)
        XCTAssertEqual(loaded.first?.messages[1].tool?.call.query, "SELECT 1")

        let many = (0..<(Defaults.AI.savedConversations + 5))
            .map {
                ChatConversation(title: "\($0)", updated: Date(timeIntervalSince1970: Double($0)), messages: messages)
            }
        try store.save(many, for: connection)
        XCTAssertEqual(store.load(connection).conversations.count, Defaults.AI.savedConversations)
        XCTAssertEqual(store.load(connection).conversations.first?.title, "\(Defaults.AI.savedConversations + 4)")

        // One unreadable message or conversation is skipped; the rest load.
        let file = base.appendingPathComponent("Chats/\(connection.uuidString).json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [[String: Any]]
        var first = json[0]
        var firstMessages = first["messages"] as! [[String: Any]]
        firstMessages[0]["role"] = "system-from-a-later-version"
        first["messages"] = firstMessages
        json[0] = first
        json.append(["title": "no id"])
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        let lossy = store.load(connection).conversations
        XCTAssertEqual(lossy.count, Defaults.AI.savedConversations)
        XCTAssertEqual(lossy.first?.messages.count, 2)

        // A file that can't be read at all is kept aside, not overwritten by the next save.
        try Data("not json".utf8).write(to: file)
        let unreadable = store.load(connection)
        XCTAssertEqual(unreadable.conversations, [])
        XCTAssertEqual(unreadable.setAside?.lastPathComponent.hasPrefix("\(connection.uuidString).unreadable-"), true)
        let kept = try FileManager.default.contentsOfDirectory(atPath: base.appendingPathComponent("Chats").path)
        XCTAssertTrue(kept.contains { $0.hasPrefix("\(connection.uuidString).unreadable-") }, "\(kept)")

        try store.save([], for: connection)
        XCTAssertEqual(store.load(connection).conversations, [])
        XCTAssertEqual(ChatConversation.title(for: []), "New Chat")
        XCTAssertEqual(
            ChatConversation.title(for: [ChatMessage(role: .user, text: String(repeating: "a", count: 100))]).count,
            Defaults.AI.conversationTitleLength + 1
        )
    }

}

/// search_saved_queries (#94): the assistant finds the user's saved queries without touching the database.
final class SavedQueryToolTests: XCTestCase {
    private let queries = [
        SavedQuery(
            file: URL(fileURLWithPath: "/q/active_users.sql"),
            keyword: "active_users",
            group: "",
            sql: "SELECT * FROM users WHERE active"
        ),
        SavedQuery(
            file: URL(fileURLWithPath: "/q/reports/revenue.sql"),
            keyword: "revenue",
            group: "reports",
            sql: "SELECT sum(total) FROM orders"
        ),
    ]

    func testCallIsParsed() {
        let reply = "```tool\n{\"tool\": \"search_saved_queries\", \"search\": \"revenue\"}\n```"
        XCTAssertEqual(AgentProtocol.call(in: reply), AgentToolCall(tool: .searchSavedQueries, search: "revenue"))
        let keyword = "```tool\n{\"tool\": \"search_saved_queries\", \"keyword\": \"users\"}\n```"
        XCTAssertEqual(AgentProtocol.call(in: keyword)?.search, "users")
        XCTAssertTrue(AgentProtocol.instructions(kind: .postgres, canQuery: false).contains("search_saved_queries"))
    }

    func testSearchReturnsMatchesWithoutQueryingTheDatabase() async {
        let driver = RecordingDriver(failing: nil)
        let toolbox = AgentToolbox(driver: driver, currentSchema: "public", savedQueries: queries)
        let found = await toolbox.run(AgentToolCall(tool: .searchSavedQueries, search: "orders"))
        XCTAssertEqual(
            found,
            "1 saved query matches “orders”:\n\nKeyword: revenue (folder reports)\n```sql\nSELECT sum(total) FROM orders\n```"
        )
        let none = await toolbox.run(AgentToolCall(tool: .searchSavedQueries, search: "invoices"))
        XCTAssertEqual(none, "No saved query matches “invoices”.")
        let missing = await toolbox.run(AgentToolCall(tool: .searchSavedQueries))
        XCTAssertEqual(missing, "Error: search_saved_queries needs words to search for.")
        let executed = await driver.executed
        XCTAssertEqual(executed, [])
    }
}

/// The transaction a read-only agent query opens is always ended, even when a statement after BEGIN fails.
final class AgentReadOnlyTransactionTests: XCTestCase {
    func testFailedOpeningStatementStillRollsBack() async throws {
        let driver = RecordingDriver(failing: "SET LOCAL")
        let toolbox = AgentToolbox(driver: driver, currentSchema: "public", savedQueries: [])
        do {
            _ = try await toolbox.runReadOnly("SELECT 1")
            XCTFail("The failing opening statement was not reported")
        } catch {
            XCTAssertEqual(error.localizedDescription, "rejected")
        }
        let executed = await driver.executed
        XCTAssertEqual(executed.first, "BEGIN READ ONLY")
        XCTAssertEqual(executed.last, "ROLLBACK")
        XCTAssertFalse(executed.contains("SELECT 1"))
    }

    func testSuccessfulQueryRollsBack() async throws {
        let driver = RecordingDriver(failing: nil)
        let toolbox = AgentToolbox(driver: driver, currentSchema: "public", savedQueries: [])
        _ = try await toolbox.runReadOnly("SELECT 1")
        let executed = await driver.executed
        XCTAssertEqual(executed.suffix(2), ["SELECT 1", "ROLLBACK"])
    }
}

/// A PostgreSQL-shaped driver that records each statement and rejects the first one starting with `failing`.
private actor RecordingDriver: DatabaseDriver {
    nonisolated let kind: DatabaseKind = .postgres
    nonisolated let dialect: any QueryDialect = SQLDialect(flavor: .postgres)
    nonisolated let catalog: any DatabaseCatalog = PostgresCatalog()
    private let failing: String?
    private(set) var executed: [String] = []

    init(failing: String?) {
        self.failing = failing
    }

    func execute(_ sql: String) async throws -> QueryResult {
        executed.append(sql)
        if let failing, sql.hasPrefix(failing) {
            throw DatabaseError("rejected")
        }
        return QueryResult(statement: sql)
    }

    func schemas() async throws -> [String] { [] }
    func defaultSchema() async throws -> String { "" }
    func tables(in schema: String) async throws -> [TableRef] { [] }
    func columns(of table: TableRef) async throws -> [ColumnInfo] { [] }
    func indexes(of table: TableRef) async throws -> [IndexInfo] { [] }
    func close() async {}
}
