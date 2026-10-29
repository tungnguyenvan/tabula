import Foundation

public struct ForeignKeyInfo: Hashable, Sendable, Identifiable {
    public var name: String
    public var table: TableRef
    public var columns: [String]
    public var referencedTable: TableRef
    /// Empty when SQLite points at the referenced table's primary key implicitly.
    public var referencedColumns: [String]
    public var id: String { "\(table.id).\(name)" }

    public init(name: String, table: TableRef, columns: [String], referencedTable: TableRef, referencedColumns: [String]) {
        self.name = name
        self.table = table
        self.columns = columns
        self.referencedTable = referencedTable
        self.referencedColumns = referencedColumns
    }
}

/// One refresh of server statistics.
public struct MetricsSample: Sendable {
    public struct Item: Sendable, Hashable {
        public var label: String
        public var value: String
        public init(_ label: String, _ value: String) { self.label = label; self.value = value }
    }

    public struct Group: Sendable, Identifiable {
        public var title: String
        public var items: [Item]
        public var id: String { title }
        public init(_ title: String, _ items: [Item]) { self.title = title; self.items = items.filter { !$0.value.isEmpty } }
    }

    public struct TableStat: Sendable, Identifiable, Hashable {
        public var name: String
        public var rows: Int?
        public var dataBytes: Int?
        public var indexBytes: Int?
        public var id: String { name }
        public var totalBytes: Int? { dataBytes.map { $0 + (indexBytes ?? 0) } }
    }

    public var time: Date
    public var groups: [Group]
    /// Cumulative counters (transactions, commands…); rates come from the difference between samples.
    public var counters: [String: Double]
    /// Point-in-time values worth charting (connections, memory…).
    public var gauges: [String: Double]
    public var tables: [TableStat]
    /// MongoDB lists collections of documents.
    public var tablesAreCollections = false

    public init(time: Date = Date(), groups: [Group], counters: [String: Double] = [:], gauges: [String: Double] = [:], tables: [TableStat] = []) {
        self.time = time
        self.groups = groups
        self.counters = counters
        self.gauges = gauges
        self.tables = tables
    }
}

enum Units {
    static let kibibyte: Double = 1024
    static let mebibyte: Double = 1024 * 1024
    static let secondsPerMinute = 60
    static let secondsPerHour = 60 * 60
    static let secondsPerDay = 24 * 60 * 60
}

extension MetricsSample.TableStat {
    /// From a row with name, row_count, data_bytes and index_bytes columns.
    init(_ row: Record) {
        self.init(name: row["name"] ?? "", rows: row.int("row_count"), dataBytes: row.int("data_bytes"), indexBytes: row.int("index_bytes"))
    }
}

public enum MetricFormat {
    public static func bytes(_ value: Double?) -> String {
        guard let value else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }

    public static func duration(seconds: Double?) -> String {
        guard var seconds = seconds.map({ Int($0) }) else { return "" }
        let days = seconds / Units.secondsPerDay; seconds %= Units.secondsPerDay
        let hours = seconds / Units.secondsPerHour; seconds %= Units.secondsPerHour
        let minutes = seconds / Units.secondsPerMinute
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m \(seconds % Units.secondsPerMinute)s"
    }

    public static func percent(_ part: Double, of total: Double) -> String {
        guard total > 0 else { return "—" }
        return (part / total).formatted(.percent.precision(.fractionLength(1)))
    }

    public static func number(_ value: Double?) -> String {
        guard let value else { return "" }
        return value.formatted(.number.precision(.fractionLength(0)))
    }
}

extension RedisDriver {
    /// Parses INFO into a sample: memory, clients, throughput, hit rate, persistence, replication, keyspace.
    public func metrics() async throws -> MetricsSample {
        let text = try await run([.text("INFO"), .text("everything")]).string ?? ""
        var info: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) where !line.hasPrefix("#") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 { info[String(parts[0])] = String(parts[1]) }
        }
        let n = { (key: String) in Double(info[key] ?? "") ?? 0 }
        let hits = n("keyspace_hits"), misses = n("keyspace_misses")
        let maxMemory = n("maxmemory")
        let keyspace = info.keys.filter { $0.hasPrefix("db") && Int($0.dropFirst(2)) != nil }
            .sorted { Int($0.dropFirst(2))! < Int($1.dropFirst(2))! }
            .map { MetricsSample.Item($0, info[$0]?.replacingOccurrences(of: ",", with: ", ") ?? "") }
        return MetricsSample(
            groups: [
                .init("Server", [
                    .init("Version", info["redis_version"].map { "Redis " + $0 } ?? ""),
                    .init("Mode", info["redis_mode"] ?? ""),
                    .init("Role", info["role"] ?? ""),
                    .init("Uptime", MetricFormat.duration(seconds: n("uptime_in_seconds"))),
                    .init("OS", info["os"] ?? ""),
                ]),
                .init("Memory", [
                    .init("Used", info["used_memory_human"] ?? ""),
                    .init("Peak", info["used_memory_peak_human"] ?? ""),
                    .init("Limit", maxMemory > 0 ? "\(MetricFormat.bytes(maxMemory)) (\(info["maxmemory_policy"] ?? ""))" : "none"),
                    .init("Fragmentation ratio", info["mem_fragmentation_ratio"] ?? ""),
                    .init("Evicted keys", MetricFormat.number(n("evicted_keys"))),
                ]),
                .init("Clients & throughput", [
                    .init("Connected clients", MetricFormat.number(n("connected_clients"))),
                    .init("Blocked clients", MetricFormat.number(n("blocked_clients"))),
                    .init("Ops/s (server)", MetricFormat.number(n("instantaneous_ops_per_sec"))),
                    .init("Hit rate", MetricFormat.percent(hits, of: hits + misses)),
                    .init("Commands processed", MetricFormat.number(n("total_commands_processed"))),
                    .init("Expired keys", MetricFormat.number(n("expired_keys"))),
                ]),
                .init("Persistence & replication", [
                    .init("Last RDB save", n("rdb_last_save_time") > 0
                          ? Date(timeIntervalSince1970: n("rdb_last_save_time")).formatted(date: .abbreviated, time: .shortened) : ""),
                    .init("Changes since save", MetricFormat.number(n("rdb_changes_since_last_save"))),
                    .init("AOF", info["aof_enabled"] == "1" ? "on" : "off"),
                    .init("Replicas", MetricFormat.number(n("connected_slaves"))),
                ]),
                .init("Keyspace", keyspace.isEmpty ? [.init("Keys", "none")] : keyspace),
            ],
            counters: ["Commands/s": n("total_commands_processed"), "Network in KB/s": n("total_net_input_bytes") / Units.kibibyte,
                       "Network out KB/s": n("total_net_output_bytes") / Units.kibibyte],
            gauges: ["Memory MB": n("used_memory") / Units.mebibyte, "Clients": n("connected_clients")])
    }
}
