import BSON
import Foundation

extension DatabaseDriver {
    /// serverStatus and dbStats as a metrics sample: connections, operations, memory, cache, storage, collections.
    func mongoMetrics(database: String) async throws -> MetricsSample {
        func document(_ statement: String) async throws -> Document {
            try MongoShell.parseDocument(try await execute(statement).documents?.first ?? "")
        }
        let status = try await document("db.adminCommand({ serverStatus: 1 })")
        let stats = try await document("db.getSiblingDB(\(MongoShell.quoted(database))).runCommand({ dbStats: 1 })")
        func number(_ document: Document?, _ path: String...) -> Double {
            var current: Primitive? = document
            for key in path { current = (current as? Document)?[key] }
            return current.flatMap(MongoShellParser.double) ?? (current as? Decimal128).flatMap { Double(MongoDecimal.string($0)) } ?? 0
        }
        let connections = status["connections"] as? Document
        let operations = status["opcounters"] as? Document
        let network = status["network"] as? Document
        let memory = status["mem"] as? Document
        let cache = (status["wiredTiger"] as? Document)?["cache"] as? Document
        let replication = status["repl"] as? Document
        let current = number(connections, "current"), available = number(connections, "available")
        let operationNames = ["insert", "query", "update", "delete", "getmore", "command"]

        var tables: [MetricsSample.TableStat] = []
        let collections = try await execute("db.getSiblingDB(\(MongoShell.quoted(database))).getCollectionInfos({ type: \"collection\" })")
        for text in (collections.documents ?? []).prefix(Defaults.Metrics.tableLimit) {
            guard let name = (try? MongoShell.parseDocument(text))?["name"] as? String, !name.hasPrefix("system.") else { continue }
            let table = TableRef(schema: database, name: name)
            guard let stat = try? await document(MongoDialect.collection(table) + ".stats()"),
                  let storage = stat["storageStats"] as? Document else { continue }
            tables.append(.init(name: name, rows: Int(number(storage, "count")), dataBytes: Int(number(storage, "size")),
                                indexBytes: Int(number(storage, "totalIndexSize"))))
        }
        tables.sort { ($0.totalBytes ?? 0) > ($1.totalBytes ?? 0) }

        var sample = MetricsSample(
            groups: [
                .init("Server", [
                    .init("Version", (status["version"] as? String).map { "MongoDB " + $0 } ?? ""),
                    .init("Host", status["host"] as? String ?? ""),
                    .init("Uptime", MetricFormat.duration(seconds: number(status, "uptime"))),
                    .init("Storage engine", ((status["storageEngine"] as? Document)?["name"] as? String) ?? ""),
                    .init("Replica set", (replication?["setName"] as? String).map { name in
                        "\(name) (\(replication?["isWritablePrimary"] as? Bool == true ? "primary" : "secondary"))"
                    } ?? "standalone"),
                ]),
                .init("Connections & memory", [
                    .init("Open", "\(Int(current)) of \(Int(current + available))"),
                    .init("Active", MetricFormat.number(number(connections, "active"))),
                    .init("Resident memory", MetricFormat.bytes(number(memory, "resident") * Units.mebibyte)),
                    .init("Cache used", cache.map { cache in
                        let used = number(cache, "bytes currently in the cache"), limit = number(cache, "maximum bytes configured")
                        return "\(MetricFormat.bytes(used)) of \(MetricFormat.bytes(limit))"
                    } ?? ""),
                ]),
                .init("Operations (since start)", operationNames.map { .init($0, MetricFormat.number(number(operations, $0))) }),
                .init("Database \(database)", [
                    .init("Collections", MetricFormat.number(number(stats, "collections"))),
                    .init("Views", MetricFormat.number(number(stats, "views"))),
                    .init("Documents", MetricFormat.number(number(stats, "objects"))),
                    .init("Data size", MetricFormat.bytes(number(stats, "dataSize"))),
                    .init("Storage size", MetricFormat.bytes(number(stats, "storageSize"))),
                    .init("Indexes", "\(MetricFormat.number(number(stats, "indexes"))) · \(MetricFormat.bytes(number(stats, "indexSize")))"),
                ]),
            ],
            counters: ["Operations/s": operationNames.reduce(0) { $0 + number(operations, $1) },
                       "Network in KB/s": number(network, "bytesIn") / Units.kibibyte,
                       "Network out KB/s": number(network, "bytesOut") / Units.kibibyte],
            gauges: ["Connections": current, "Memory MB": number(memory, "resident")],
            tables: tables)
        sample.tablesAreCollections = true
        return sample
    }
}
