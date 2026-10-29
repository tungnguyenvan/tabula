import Foundation
import TabulaFoundation
import TabulaSQL

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

        public init(name: String, rows: Int?, dataBytes: Int?, indexBytes: Int?) {
            self.name = name
            self.rows = rows
            self.dataBytes = dataBytes
            self.indexBytes = indexBytes
        }
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

package enum Units {
    package static let kibibyte: Double = 1024
    package static let mebibyte: Double = 1024 * 1024
    static let secondsPerMinute = 60
    static let secondsPerHour = 60 * 60
    static let secondsPerDay = 24 * 60 * 60
}

extension MetricsSample.TableStat {
    /// From a row with name, row_count, data_bytes and index_bytes columns.
    package init(_ row: Record) {
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

