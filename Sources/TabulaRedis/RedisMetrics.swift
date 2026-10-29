import Foundation
import TabulaDrivers
import TabulaFoundation

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
