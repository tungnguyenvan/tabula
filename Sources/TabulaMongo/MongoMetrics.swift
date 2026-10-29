import BSON
import Foundation
import TabulaDrivers
import TabulaFoundation
import TabulaSQL

/// MongoDB's catalog: server and database commands. It has no foreign keys, routines or separate databases
/// list (databases are the schemas). Collection sizes take a round trip each, so they are cached for a while.
actor MongoCatalog: DatabaseCatalog {
    private var collectionStats: (database: String, time: Date, stats: [MetricsSample.TableStat])?

    nonisolated var routines: (any RoutineCatalog)? { nil }

    func serverVersion(on driver: any DatabaseDriver) async throws -> String {
        guard let version = try await driver.value("db.version()") else {
            throw DatabaseError("The server didn't report its version.")
        }
        return "MongoDB " + version
    }

    func useSchema(_ schema: String, on driver: any DatabaseDriver) async throws {
        _ = try await driver.execute("use \(schema)")
    }

    func serverDatabases(on driver: any DatabaseDriver) async throws -> [String] { [] }
    func currentDatabase(on driver: any DatabaseDriver) async throws -> String? { nil }
    func foreignKeys(in schema: String, on driver: any DatabaseDriver) async throws -> [ForeignKeyInfo] { [] }

    /// The shell has no read-only session; `MongoReadOnlyCheck` lets only reads through.
    func prepareReadOnlySession(timeoutSeconds: Int, on driver: any DatabaseDriver) async throws {}
    nonisolated func readOnlyTransaction(timeoutSeconds: Int) -> [String]? { nil }

    /// serverStatus and dbStats as a metrics sample: connections, operations, memory, cache, storage, collections.
    func metrics(schema database: String, on driver: any DatabaseDriver) async throws -> MetricsSample {
        func document(_ statement: String) async throws -> Document {
            guard let text = try await driver.execute(statement).documents?.first else {
                throw DatabaseError("The server returned nothing for \(statement).")
            }
            return try MongoShell.parseDocument(text)
        }
        let status = try await document("db.adminCommand({ serverStatus: 1 })")
        let stats = try await document("db.getSiblingDB(\(MongoShell.quoted(database))).runCommand({ dbStats: 1 })")
        func number(_ document: Document?, _ path: String...) -> Double {
            var current: Primitive? = document
            for key in path { current = (current as? Document)?[key] }
            return current.flatMap(MongoShellParser.double) ?? (current as? Decimal128)
                .flatMap { Double(MongoDecimal.string($0)) } ?? 0
        }
        let connections = status["connections"] as? Document
        let operations = status["opcounters"] as? Document
        let network = status["network"] as? Document
        let memory = status["mem"] as? Document
        let cache = (status["wiredTiger"] as? Document)?["cache"] as? Document
        let replication = status["repl"] as? Document
        let current = number(connections, "current")
        let available = number(connections, "available")
        let operationNames = ["insert", "query", "update", "delete", "getmore", "command"]

        let tables = try await largestCollections(in: database, on: driver)

        var sample = MetricsSample(
            groups: [
                .init(
                    "Server",
                    [
                        .init("Version", (status["version"] as? String).map { "MongoDB " + $0 } ?? ""),
                        .init("Host", status["host"] as? String ?? ""),
                        .init("Uptime", MetricFormat.duration(seconds: number(status, "uptime"))),
                        .init("Storage engine", ((status["storageEngine"] as? Document)?["name"] as? String) ?? ""),
                        .init(
                            "Replica set",
                            (replication?["setName"] as? String)
                                .map { name in
                                    "\(name) (\(replication?["isWritablePrimary"] as? Bool == true ? "primary" : "secondary"))"
                                } ?? "standalone"
                        ),
                    ]
                ),
                .init(
                    "Connections & memory",
                    [
                        .init("Open", "\(Int(current)) of \(Int(current + available))"),
                        .init("Active", MetricFormat.number(number(connections, "active"))),
                        .init("Resident memory", MetricFormat.bytes(number(memory, "resident") * Units.mebibyte)),
                        .init(
                            "Cache used",
                            cache.map { cache in
                                let used = number(cache, "bytes currently in the cache")
                                let limit = number(cache, "maximum bytes configured")
                                return "\(MetricFormat.bytes(used)) of \(MetricFormat.bytes(limit))"
                            } ?? ""
                        ),
                    ]
                ),
                .init(
                    "Operations (since start)",
                    operationNames.map { .init($0, MetricFormat.number(number(operations, $0))) }
                ),
                .init(
                    "Database \(database)",
                    [
                        .init("Collections", MetricFormat.number(number(stats, "collections"))),
                        .init("Views", MetricFormat.number(number(stats, "views"))),
                        .init("Documents", MetricFormat.number(number(stats, "objects"))),
                        .init("Data size", MetricFormat.bytes(number(stats, "dataSize"))),
                        .init("Storage size", MetricFormat.bytes(number(stats, "storageSize"))),
                        .init(
                            "Indexes",
                            "\(MetricFormat.number(number(stats, "indexes"))) · \(MetricFormat.bytes(number(stats, "indexSize")))"
                        ),
                    ]
                ),
            ],
            counters: [
                "Operations/s": operationNames.reduce(0) { $0 + number(operations, $1) },
                "Network in KB/s": number(network, "bytesIn") / Units.kibibyte,
                "Network out KB/s": number(network, "bytesOut") / Units.kibibyte,
            ],
            gauges: ["Connections": current, "Memory MB": number(memory, "resident")],
            tables: tables
        )
        sample.tablesAreCollections = true
        return sample
    }

    /// The largest collections by data plus index size, measured for up to `statsCollectionLimit` collections and
    /// reused for `statsRefreshInterval` seconds.
    private func largestCollections(
        in database: String,
        on driver: any DatabaseDriver
    ) async throws -> [MetricsSample.TableStat] {
        if let cached = collectionStats, cached.database == database,
            Date().timeIntervalSince(cached.time) < Defaults.Mongo.statsRefreshInterval
        {
            return cached.stats
        }
        var stats: [MetricsSample.TableStat] = []
        for table in try await driver.tables(in: database).filter({ $0.kind == .table })
            .prefix(Defaults.Mongo.statsCollectionLimit)
        {
            // A collection the account may not read the stats of is left out of the ranking.
            guard let result = try? await driver.execute(MongoDialect.collection(table) + ".stats()"),
                let text = result.documents?.first, let stat = try? MongoShell.parseDocument(text),
                let storage = stat["storageStats"] as? Document
            else { continue }
            func number(_ key: String) -> Int { storage[key].flatMap(MongoShellParser.double).map { Int($0) } ?? 0 }
            stats.append(
                .init(
                    name: table.name,
                    rows: number("count"),
                    dataBytes: number("size"),
                    indexBytes: number("totalIndexSize")
                )
            )
        }
        stats.sort { ($0.totalBytes ?? 0) > ($1.totalBytes ?? 0) }
        let largest = Array(stats.prefix(Defaults.Metrics.tableLimit))
        collectionStats = (database, Date(), largest)
        return largest
    }
}
