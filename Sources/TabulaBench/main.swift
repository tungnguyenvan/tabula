import Foundation
import TabulaConnections
import TabulaDrivers
import TabulaFoundation
import TabulaMongo
import TabulaRedis
import TabulaSQL

// Times what Tabula does against real servers: connecting, reading the catalog, loading grid pages, sorting,
// filtering, counting, large results and committing edits. Every step goes through the same drivers and
// generated statements the app uses, so the numbers include formatting the cells for the grid.
//
// Usage: swift run -c release TabulaBench [--rows N] [--runs N] [--only postgres,mysql,sqlite,mongodb,redis]
// Servers are the test containers from the README (ports overridable with the TABULA_TEST_*_PORT variables).
// TABULA_BENCH_OUTPUT writes the report to a file; TABULA_BENCH_SQLITE sets where the SQLite database goes.
// The benchmark tables are left in place (bench_items, and the tabula_bench database on MongoDB) for
// scripts/benchmark.sh, which also measures the app's memory with them open.

enum Bench {
    /// Rows (documents, keys) in each benchmark table.
    static var rows = 100_000
    /// Timed repetitions of each step after one warm-up; the report gives the median and the slowest.
    static var runs = 7
    static let pageSizes = [300, 1000, 5000]
    /// Offset of the "deep page" step: half-way through the table.
    static var deepOffset: Int { rows / 2 }
    /// Rows in the "large result" step, as a query tab with no row limit would return.
    static let largeResult = 50_000
    /// Cells edited in one commit.
    static let editCount = 100
    static let table = "bench_items"
    static let mongoDatabase = "tabula_bench"
    static let password = "tabula"
}

struct Step {
    var name: String
    var samples: [Double]
    var rows: Int?

    var median: Double { samples.sorted()[samples.count / 2] }
    var slowest: Double { samples.max() ?? 0 }
}

func time(_ body: () async throws -> Int?) async throws -> (Double, Int?) {
    let clock = ContinuousClock()
    var rows: Int?
    let elapsed = try await clock.measure { rows = try await body() }
    return (Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000, rows)
}

/// One warm-up, then `Bench.runs` timed runs.
func measure(_ name: String, runs: Int = Bench.runs, _ body: () async throws -> Int?) async throws -> Step {
    _ = try await body()
    var samples: [Double] = []
    var rows: Int?
    for _ in 0..<runs {
        let (milliseconds, count) = try await time(body)
        samples.append(milliseconds)
        rows = count
    }
    return Step(name: name, samples: samples, rows: rows)
}

let environment = ProcessInfo.processInfo.environment
func port(_ variable: String, _ fallback: Int) -> Int { environment[variable].flatMap(Int.init) ?? fallback }

// MARK: SQL databases and MongoDB (the table workspace)

/// The same steps for every database that opens in the table workspace.
func benchmarkTables(
    _ config: ConnectionConfig,
    password: String?,
    schema: String,
    seed: (any DatabaseDriver) async throws -> Void
) async throws -> [Step] {
    var steps: [Step] = []
    steps.append(
        try await measure("Connect", runs: 5) {
            let driver = try await DriverFactory.connect(config, password: password)
            await driver.close()
            return nil
        }
    )
    let driver = try await DriverFactory.connect(config, password: password)
    defer { Task { await driver.close() } }
    print("  seeding \(Bench.rows) rows…")
    try await seed(driver)
    let table = TableRef(schema: schema, name: Bench.table)
    let dialect = driver.dialect

    steps.append(
        try await measure("Catalog: schemas, tables, columns, indexes") {
            _ = try await driver.schemas()
            let tables = try await driver.tables(in: schema)
            _ = try await driver.columns(of: table)
            _ = try await driver.indexes(of: table)
            return tables.count
        }
    )
    for size in Bench.pageSizes {
        steps.append(
            try await measure("Page of \(size)") {
                try await driver.fetchPage(TablePageRequest(table: table, limit: size)).rows.count
            }
        )
    }
    steps.append(
        try await measure("Page of 300 at row \(Bench.deepOffset)") {
            try await driver.fetchPage(
                TablePageRequest(table: table, limit: Defaults.pageSize, offset: Bench.deepOffset)
            )
            .rows.count
        }
    )
    steps.append(
        try await measure("Page of 300 sorted by an unindexed column") {
            try await driver.fetchPage(
                TablePageRequest(table: table, limit: Defaults.pageSize, orderBy: "amount", ascending: false)
            )
            .rows.count
        }
    )
    let filter = dialect.condition([FilterRule(column: "name", op: .contains, value: "77")])
    steps.append(
        try await measure("Filtered page (name contains 77) + count") {
            let page = try await driver.fetchPage(
                TablePageRequest(table: table, limit: Defaults.pageSize, filter: filter)
            )
            _ = try await driver.countRows(table, filter: filter)
            return page.rows.count
        }
    )
    steps.append(
        try await measure("Count all rows") {
            try await driver.countRows(table, filter: nil)
        }
    )
    steps.append(
        try await measure("Query returning \(Bench.largeResult) rows", runs: 3) {
            try await driver.execute(dialect.selectPage(TablePageRequest(table: table, limit: Bench.largeResult))).rows
                .count
        }
    )
    steps.append(
        try await measure("Commit \(Bench.editCount) edited cells") {
            let page = try await driver.fetchPage(TablePageRequest(table: table, limit: Bench.editCount))
            let statements = try editStatements(page, table: table, dialect: dialect)
            try await driver.applyInTransaction(statements)
            return statements.count
        }
    )
    return steps
}

/// Updates of the `status` column of every row in `page`, the way the grid builds them.
func editStatements(_ page: QueryResult, table: TableRef, dialect: any QueryDialect) throws -> [String] {
    let value = "edited-\(Int.random(in: 0..<1_000_000))"
    guard let status = page.columns.firstIndex(of: "status") else { throw DatabaseError("No status column") }
    let keyColumns = page.columns.firstIndex(of: "id").map { [$0] } ?? []
    let edits = Dictionary(uniqueKeysWithValues: page.rows.indices.map { ($0, [status: String?.some(value)]) })
    return try dialect.statements(
        for: TableChanges(
            table: table,
            columns: page.columns,
            rows: page.rows,
            documents: page.documents,
            keyColumns: keyColumns,
            deleted: [],
            edited: edits,
            inserted: []
        )
    )
}

// MARK: Seeding

func seedPostgres(_ driver: any DatabaseDriver) async throws {
    _ = try await driver.executeScript(
        """
        DROP TABLE IF EXISTS public.\(Bench.table);
        CREATE TABLE public.\(Bench.table) (id bigint PRIMARY KEY, name text, email text, amount numeric(12,2),
          status text, tags text[], attrs jsonb, created timestamptz);
        INSERT INTO public.\(Bench.table)
        SELECT i, 'Customer ' || i, 'c' || i || '@example.com', (i * 37 % 100000) / 100.0,
          (ARRAY['paid','pending','shipped'])[i % 3 + 1], ARRAY['tag' || (i % 5), 'x'],
          jsonb_build_object('city', (ARRAY['Hà Nội','Đà Nẵng','TP.HCM'])[i % 3 + 1], 'n', i % 40),
          timestamptz '2024-01-01' + (i || ' minutes')::interval
        FROM generate_series(1, \(Bench.rows)) i;
        ANALYZE public.\(Bench.table);
        """
    )
}

func seedMySQL(_ driver: any DatabaseDriver) async throws {
    _ = try await driver.executeScript(
        """
        DROP TABLE IF EXISTS \(Bench.table);
        CREATE TABLE \(Bench.table) (id BIGINT PRIMARY KEY, name VARCHAR(64), email VARCHAR(64), amount DECIMAL(12,2),
          status VARCHAR(16), attrs JSON, created DATETIME);
        SET SESSION cte_max_recursion_depth = \(Bench.rows + 1);
        INSERT INTO \(Bench.table)
        WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < \(Bench.rows))
        SELECT i, CONCAT('Customer ', i), CONCAT('c', i, '@example.com'), (i * 37 % 100000) / 100,
          ELT(i % 3 + 1, 'paid', 'pending', 'shipped'), JSON_OBJECT('city', ELT(i % 3 + 1, 'Hà Nội', 'Đà Nẵng', 'TP.HCM'), 'n', i % 40),
          TIMESTAMPADD(MINUTE, i, '2024-01-01')
        FROM n;
        ANALYZE TABLE \(Bench.table);
        """
    )
}

func seedSQLite(_ driver: any DatabaseDriver) async throws {
    _ = try await driver.executeScript(
        """
        DROP TABLE IF EXISTS \(Bench.table);
        CREATE TABLE \(Bench.table) (id INTEGER PRIMARY KEY, name TEXT, email TEXT, amount REAL, status TEXT, attrs TEXT, created TEXT);
        WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < \(Bench.rows))
        INSERT INTO \(Bench.table) SELECT i, 'Customer ' || i, 'c' || i || '@example.com', (i * 37 % 100000) / 100.0,
          CASE i % 3 WHEN 0 THEN 'paid' WHEN 1 THEN 'pending' ELSE 'shipped' END,
          json_object('city', CASE i % 3 WHEN 0 THEN 'Hà Nội' WHEN 1 THEN 'Đà Nẵng' ELSE 'TP.HCM' END, 'n', i % 40),
          datetime('2024-01-01', '+' || i || ' minutes')
        FROM n;
        """
    )
}

/// Documents are made on the server by one aggregation, through Tabula's own shell statements.
func seedMongo(_ driver: any DatabaseDriver) async throws {
    _ = try await driver.execute("use \(Bench.mongoDatabase)")
    _ = try await driver.execute("db.\(Bench.table).drop()")
    _ = try await driver.execute(
        """
        db.aggregate([
          { $documents: [{ i: { $range: [1, \(Bench.rows + 1)] } }] },
          { $unwind: "$i" },
          { $project: { _id: 0, id: "$i", name: { $concat: ["Customer ", { $toString: "$i" }] },
            email: { $concat: ["c", { $toString: "$i" }, "@example.com"] },
            amount: { $toDecimal: { $divide: [{ $mod: [{ $multiply: ["$i", 37] }, 100000] }, 100] } },
            status: { $arrayElemAt: [["paid", "pending", "shipped"], { $mod: ["$i", 3] }] },
            address: { city: { $arrayElemAt: [["Hà Nội", "Đà Nẵng", "TP.HCM"], { $mod: ["$i", 3] }] }, n: { $mod: ["$i", 40] } },
            tags: [{ $concat: ["tag", { $toString: { $mod: ["$i", 5] } }] }, "x"],
            created: { $add: [ISODate("2024-01-01T00:00:00Z"), { $multiply: ["$i", 60000] }] } } },
          { $out: "\(Bench.table)" }
        ])
        """
    )
}

// MARK: Redis

func benchmarkRedis(_ config: ConnectionConfig) async throws -> [Step] {
    var steps: [Step] = []
    steps.append(
        try await measure("Connect", runs: 5) {
            let redis = try await RedisDriver.connect(config, password: Bench.password)
            await redis.close()
            return nil
        }
    )
    let redis = try await RedisDriver.connect(config, password: Bench.password)
    defer { Task { await redis.close() } }
    print("  seeding \(Bench.rows) keys…")
    _ = try await redis.send("FLUSHDB")
    _ = try await redis.send(
        "EVAL",
        """
        for i = 1, tonumber(ARGV[1]) do
          if i % 10 == 0 then redis.call('HSET', 'bench:hash:' .. i, 'name', 'Customer ' .. i, 'n', i)
          else redis.call('SET', 'bench:item:' .. i, 'value ' .. i) end
        end
        for i = 1, 5000 do redis.call('HSET', 'bench:big', 'field' .. i, 'v' .. i) end
        return 1
        """,
        "0",
        String(Bench.rows)
    )
    steps.append(
        try await measure("Scan 500 keys") {
            try await redis.scanKeys(match: "*", type: nil).keys.count
        }
    )
    steps.append(
        try await measure("Scan 500 keys + type, TTL, size, preview") {
            let keys = try await redis.scanKeys(match: "*", type: nil).keys
            return try await redis.summaries(of: keys).count
        }
    )
    steps.append(
        try await measure("Scan keys matching bench:hash:*") {
            try await redis.scanKeys(match: "bench:hash:*", type: nil).keys.count
        }
    )
    steps.append(
        try await measure("Page of a 5,000-field hash") {
            try await redis.page(RedisBytes(Array("bench:big".utf8)), type: .hash, after: nil).rows.count
        }
    )
    _ = try await redis.send("FLUSHDB")
    return steps
}

// MARK: Shell text (no server)

/// The MongoDB grid writes every value as shell text and reads documents back for edits; this is that work alone.
func benchmarkShellText() async throws -> [Step] {
    let document =
        #"{ _id: ObjectId("65f1a2b3c4d5e6f708091a2b"), name: "Customer 12345", email: "c12345@example.com", amount: NumberDecimal("123.45"), status: "paid", address: { city: "Hà Nội", n: 5 }, tags: ["tag0", "x"], created: ISODate("2024-01-09T13:45:00.000Z") }"#
    let count = Bench.largeResult
    var steps: [Step] = []
    steps.append(
        try await measure("Parse \(count) documents", runs: 3) {
            for _ in 0..<count {
                _ = try MongoShell.parseDocument(document)
            }
            return count
        }
    )
    let parsed = try MongoShell.parseDocument(document)
    steps.append(
        try await measure("Write \(count) documents and their cells", runs: 3) {
            for _ in 0..<count {
                _ = MongoShell.format(parsed)
                for pair in parsed.pairs {
                    _ = MongoShell.cell(pair.value)
                }
            }
            return count
        }
    )
    return steps
}

// MARK: Report

var arguments = CommandLine.arguments.dropFirst().makeIterator()
var only: Set<String>?
while let argument = arguments.next() {
    switch argument {
    case "--rows": Bench.rows = arguments.next().flatMap(Int.init) ?? Bench.rows
    case "--runs": Bench.runs = arguments.next().flatMap(Int.init) ?? Bench.runs
    case "--only": only = Set((arguments.next() ?? "").split(separator: ",").map(String.init))
    default: break
    }
}
func wanted(_ name: String) -> Bool { only?.contains(name) ?? true }

var sections: [(title: String, steps: [Step])] = []
func run(_ title: String, _ key: String, _ body: () async throws -> [Step]) async {
    guard wanted(key) else { return }
    print("\(title)…")
    do {
        sections.append((title, try await body()))
    } catch {
        print("  skipped: \(error.localizedDescription)")
    }
}

let host = Defaults.host
await run("PostgreSQL", "postgres") {
    let config = ConnectionConfig(
        kind: .postgres,
        host: host,
        port: port("TABULA_TEST_PG_PORT", 55432),
        user: "tabula",
        database: "tabula"
    )
    return try await benchmarkTables(config, password: Bench.password, schema: "public", seed: seedPostgres)
}
await run("MySQL", "mysql") {
    let config = ConnectionConfig(
        kind: .mysql,
        host: host,
        port: port("TABULA_TEST_MYSQL_PORT", 53306),
        user: "tabula",
        database: "tabula",
        tls: .require
    )
    return try await benchmarkTables(config, password: Bench.password, schema: "tabula", seed: seedMySQL)
}
await run("SQLite", "sqlite") {
    let path = environment["TABULA_BENCH_SQLITE"] ?? NSTemporaryDirectory() + "tabula-bench.sqlite"
    try? FileManager.default.removeItem(atPath: path)
    return try await benchmarkTables(
        ConnectionConfig(kind: .sqlite, filePath: path),
        password: nil,
        schema: "main",
        seed: seedSQLite
    )
}
await run("MongoDB", "mongodb") {
    let config = ConnectionConfig(
        kind: .mongodb,
        host: host,
        port: port("TABULA_TEST_MONGO_PORT", 57017),
        user: "tabula",
        database: Bench.mongoDatabase
    )
    return try await benchmarkTables(config, password: Bench.password, schema: Bench.mongoDatabase, seed: seedMongo)
}
await run("Redis", "redis") {
    try await benchmarkRedis(
        ConnectionConfig(
            kind: .redis,
            host: host,
            port: port("TABULA_TEST_REDIS_PORT", 56379),
            user: "tabula",
            database: "15"
        )
    )
}
await run("MongoDB shell text (no server)", "shell") { try await benchmarkShellText() }

func format(_ milliseconds: Double) -> String {
    milliseconds < 10
        ? String(format: "%.2f", milliseconds)
        : milliseconds < 100 ? String(format: "%.1f", milliseconds) : String(format: "%.0f", milliseconds)
}

var report =
    "Rows per table: \(Bench.rows). Each step: one warm-up, then \(Bench.runs) runs (Connect 5, the large query 3); times in milliseconds.\n"
for section in sections {
    report += "\n### \(section.title)\n\n| Step | Median | Slowest | Rows |\n| --- | ---: | ---: | ---: |\n"
    for step in section.steps {
        report +=
            "| \(step.name) | \(format(step.median)) | \(format(step.slowest)) | \(step.rows.map(String.init) ?? "") |\n"
    }
}
print("\n" + report)
if let output = environment["TABULA_BENCH_OUTPUT"] {
    try? report.write(toFile: output, atomically: true, encoding: .utf8)
}
