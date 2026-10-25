import Foundation

/// One open database session. Implementations are actors, so calls are serialized per connection.
public protocol DatabaseDriver: AnyObject, Sendable {
    var kind: DatabaseKind { get }

    /// Schemas (Postgres), databases (MySQL) or attached schemas (SQLite).
    func schemas() async throws -> [String]
    /// The schema to select when the workspace opens.
    func defaultSchema() async throws -> String
    func tables(in schema: String) async throws -> [TableRef]
    func columns(of table: TableRef) async throws -> [ColumnInfo]
    func indexes(of table: TableRef) async throws -> [IndexInfo]
    /// Executes exactly one SQL statement.
    func execute(_ sql: String) async throws -> QueryResult
    func close() async
}

public enum DriverFactory {
    public static func connect(_ config: ConnectionConfig, password: String?) async throws -> any DatabaseDriver {
        switch config.kind {
        case .sqlite:
            return try SQLiteDriver(path: config.filePath)
        case .postgres:
            return try await PostgresDriver.connect(config, password: password)
        case .mysql:
            return try await MySQLDriver.connect(config, password: password)
        case .mongodb:
            return try await MongoDriver.connect(config, password: password)
        case .redis:
            throw DatabaseError("Redis connections use RedisDriver, not the SQL driver interface.")
        }
    }
}

extension DatabaseDriver {
    public var dialect: SQLDialect { SQLDialect(kind: kind) }

    /// Runs several statements in order, returning every result. Stops at the first error.
    public func executeScript(_ script: String) async throws -> [QueryResult] {
        var results: [QueryResult] = []
        for statement in SQLSplitter.split(script, kind: kind) {
            results.append(try await execute(statement))
        }
        return results
    }

    /// Makes `schema` the one unqualified names refer to, as the sidebar's schema picker promises:
    /// `SET search_path` on PostgreSQL (keeping public for extensions and shared tables), `USE` on MySQL.
    public func useSchema(_ schema: String) async throws {
        guard !schema.isEmpty else { return }
        let d = dialect
        switch kind {
        case .postgres:
            let path = schema == "public" ? [schema] : [schema, "public"]
            _ = try await execute("SET search_path TO " + path.map(d.quoteIdentifier).joined(separator: ", "))
        case .mysql:
            _ = try await execute("USE \(d.quoteIdentifier(schema))")
        case .mongodb:
            _ = try await execute("use \(schema)")
        case .sqlite, .redis:
            break
        }
    }

    /// Server version as reported by the database, e.g. "PostgreSQL 16.11 on aarch64…".
    public func serverVersion() async -> String? {
        if kind == .mongodb {
            return (try? await execute("db.version()")).flatMap { $0.rows.first?.first ?? nil }.map { "MongoDB " + $0 }
        }
        let sql = kind == .sqlite ? "SELECT 'SQLite ' || sqlite_version()" : "SELECT version()"
        guard let result = try? await execute(sql), let value = result.rows.first?.first ?? nil else { return nil }
        if kind == .mysql { return "MySQL " + value }
        return value
    }

    public func fetchPage(_ request: TablePageRequest) async throws -> QueryResult {
        try await execute(dialect.selectPage(request))
    }

    public func countRows(_ table: TableRef, filter: String?) async throws -> Int? {
        let result = try await execute(dialect.countRows(table, filter: filter))
        guard let first = result.rows.first?.first, let text = first else { return nil }
        return Int(text)
    }

    /// Applies statements atomically, rolling back if any statement fails.
    public func applyInTransaction(_ statements: [String]) async throws {
        guard !statements.isEmpty else { return }
        if kind == .mongodb {
            // Multi-document transactions need a replica set; run the changes in order and say where it stopped.
            for (index, statement) in statements.enumerated() {
                do {
                    _ = try await execute(statement)
                } catch {
                    let saved = index == 0 ? "" : " The \(index) change\(index == 1 ? "" : "s") before it were saved."
                    throw DatabaseError("Change \(index + 1) of \(statements.count) failed: \(error.localizedDescription)\(saved)")
                }
            }
            return
        }
        _ = try await execute(dialect.beginTransaction)
        do {
            for statement in statements {
                _ = try await execute(statement)
            }
            _ = try await execute("COMMIT")
        } catch {
            _ = try? await execute("ROLLBACK")
            throw error
        }
    }
}

public struct TablePageRequest: Sendable, Hashable {
    public var table: TableRef
    public var limit: Int
    public var offset: Int
    public var orderBy: String?
    public var ascending: Bool
    /// Raw SQL condition placed after WHERE, typed by the user.
    public var filter: String?

    public init(table: TableRef, limit: Int = Defaults.pageSize, offset: Int = 0, orderBy: String? = nil, ascending: Bool = true, filter: String? = nil) {
        self.table = table
        self.limit = limit
        self.offset = offset
        self.orderBy = orderBy
        self.ascending = ascending
        self.filter = filter
    }
}

/// Fails with a readable error if `operation` does not finish in time (used for connecting).
/// The operation may not be cancellable (NIO futures aren't), so on timeout this returns at once
/// and hands any late result to `discard`, e.g. to close a connection that arrived too late.
public func withTimeout<T: Sendable>(
    seconds: Double,
    _ what: String,
    discard: @escaping @Sendable (T) -> Void = { _ in },
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let gate = ResumeOnce<T>()
    return try await withCheckedThrowingContinuation { continuation in
        gate.continuation = continuation
        let watchdog = Task {
            try await Task.sleep(for: .seconds(seconds))
            return gate.resume(.failure(DatabaseError("\(what) timed out after \(Int(seconds)) seconds.")))
        }
        let work = Task {
            do {
                let value = try await operation()
                if gate.resume(.success(value)) { watchdog.cancel() } else { discard(value) }
            } catch {
                if gate.resume(.failure(error)) { watchdog.cancel() }
            }
        }
        Task { if (try? await watchdog.value) == true { work.cancel() } }
    }
}

/// Resumes a continuation exactly once, whichever side finishes first.
private final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    var continuation: CheckedContinuation<T, any Error>?

    @discardableResult
    func resume(_ result: Result<T, any Error>) -> Bool {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        guard let pending else { return false }
        pending.resume(with: result)
        return true
    }
}
