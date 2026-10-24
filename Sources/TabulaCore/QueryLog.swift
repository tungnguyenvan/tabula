import Foundation

/// One statement sent to the server, as shown in the console log.
public struct QueryLogEntry: Identifiable, Sendable {
    public enum Outcome: Sendable, Equatable {
        case rows(Int)
        case affected(Int?)
        case failed(String)
    }

    public let id = UUID()
    public let date: Date
    public let statement: String
    public let duration: TimeInterval
    public let outcome: Outcome
    /// Catalog reads (tables, columns, indexes) the app makes on its own, as opposed to data queries.
    public let isMeta: Bool

    public init(date: Date, statement: String, duration: TimeInterval, outcome: Outcome, isMeta: Bool = false) {
        self.date = date
        self.statement = statement
        self.duration = duration
        self.outcome = outcome
        self.isMeta = isMeta
    }
}

/// Decorator that reports every call to `sink` and otherwise behaves exactly like the driver it wraps.
/// Statements the protocol extension builds (paging, counting, transactions) go through `execute`
/// here, so they are logged too.
public actor LoggingDriver: DatabaseDriver {
    public nonisolated let kind: DatabaseKind
    private let inner: any DatabaseDriver
    private let sink: @Sendable (QueryLogEntry) -> Void

    /// The wrapped driver, for polling the app does on its own (metrics) that would flood the log.
    public nonisolated var unlogged: any DatabaseDriver { inner }

    public init(_ inner: any DatabaseDriver, sink: @escaping @Sendable (QueryLogEntry) -> Void) {
        self.inner = inner
        self.kind = inner.kind
        self.sink = sink
    }

    public func execute(_ sql: String) async throws -> QueryResult {
        try await logged(sql) { try await $0.execute(sql) } outcome: { result in
            result.hasResultSet ? .rows(result.rows.count) : .affected(result.affectedRows)
        }
    }

    public func schemas() async throws -> [String] {
        try await logged("-- list schemas", meta: true) { try await $0.schemas() } outcome: { .rows($0.count) }
    }

    public func defaultSchema() async throws -> String {
        try await inner.defaultSchema()
    }

    public func tables(in schema: String) async throws -> [TableRef] {
        try await logged("-- list tables in \(schema)", meta: true) { try await $0.tables(in: schema) } outcome: { .rows($0.count) }
    }

    public func columns(of table: TableRef) async throws -> [ColumnInfo] {
        try await logged("-- columns of \(table.schema).\(table.name)", meta: true) { try await $0.columns(of: table) } outcome: { .rows($0.count) }
    }

    public func indexes(of table: TableRef) async throws -> [IndexInfo] {
        try await logged("-- indexes of \(table.schema).\(table.name)", meta: true) { try await $0.indexes(of: table) } outcome: { .rows($0.count) }
    }

    public func close() async {
        await inner.close()
    }

    private func logged<T>(_ statement: String, meta: Bool = false,
                           _ operation: (any DatabaseDriver) async throws -> T,
                           outcome: (T) -> QueryLogEntry.Outcome) async throws -> T {
        let start = Date()
        do {
            let value = try await operation(inner)
            sink(QueryLogEntry(date: start, statement: statement, duration: Date().timeIntervalSince(start), outcome: outcome(value), isMeta: meta))
            return value
        } catch {
            sink(QueryLogEntry(date: start, statement: statement, duration: Date().timeIntervalSince(start),
                               outcome: .failed(error.localizedDescription), isMeta: meta))
            throw error
        }
    }
}
