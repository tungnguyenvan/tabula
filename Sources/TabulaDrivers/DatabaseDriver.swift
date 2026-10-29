import Foundation
import TabulaFoundation
import TabulaSQL

/// One open database session. Actor implementations must account for reentrancy across awaits:
/// isolation alone does not serialize entire executions.
public protocol DatabaseDriver: AnyObject, Sendable {
    var kind: DatabaseKind { get }
    /// The database's query language: quoting, generated statements and script handling.
    var dialect: any QueryDialect { get }
    /// The database's catalog queries: version, schemas, foreign keys, metrics, routines.
    var catalog: any DatabaseCatalog { get }
    /// Whether Stop can interrupt the current server statement, or only skip subsequent statements.
    var queryCancellation: QueryCancellationSupport { get }

    /// Schemas (Postgres), databases (MySQL) or attached schemas (SQLite).
    func schemas() async throws -> [String]
    /// The schema to select when the workspace opens.
    func defaultSchema() async throws -> String
    func tables(in schema: String) async throws -> [TableRef]
    func columns(of table: TableRef) async throws -> [ColumnInfo]
    func indexes(of table: TableRef) async throws -> [IndexInfo]
    /// Executes exactly one SQL statement.
    func execute(_ sql: String) async throws -> QueryResult
    func queryEditTarget(for result: QueryResult) async throws -> QueryEditTarget?
    func commitQueryEdits(_ edits: [QueryRowEdit], target: QueryEditTarget) async throws -> [Int: [String?]]
    func close() async
}

extension DatabaseDriver {
    /// Runs several statements in order, returning every result. Stops at the first error.
    public func executeScript(_ script: String) async throws -> [QueryResult] {
        var results: [QueryResult] = []
        for statement in dialect.split(script) {
            try QueryCancelScope.current?.checkCancellation()
            results.append(try await execute(statement))
        }
        return results
    }

    public func fetchPage(_ request: TablePageRequest) async throws -> QueryResult {
        try await execute(dialect.selectPage(request))
    }

    public func countRows(_ table: TableRef, filter: String?) async throws -> Int? {
        let result = try await execute(dialect.countRows(table, filter: filter))
        guard let first = result.rows.first?.first, let text = first else { return nil }
        return Int(text)
    }

    /// Applies statements in one transaction, rolling back if one fails. Where the dialect has no transactions
    /// (MongoDB without a replica set), they run in order and the error says which were already applied.
    public func applyInTransaction(_ statements: [String]) async throws {
        guard !statements.isEmpty else { return }
        guard let begin = dialect.beginTransaction else {
            for (index, statement) in statements.enumerated() {
                do {
                    _ = try await execute(statement)
                } catch {
                    let saved = index == 0 ? "" : " The \(index) change\(index == 1 ? "" : "s") before it were saved."
                    throw DatabaseError(
                        "Change \(index + 1) of \(statements.count) failed: \(error.localizedDescription)\(saved)"
                    )
                }
            }
            return
        }
        _ = try await execute(begin)
        do {
            for statement in statements {
                _ = try await execute(statement)
            }
            _ = try await execute("COMMIT")
        } catch {
            // The statement's error is the one to report; a failed ROLLBACK ends with the connection anyway.
            _ = try? await execute("ROLLBACK")
            throw error
        }
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
                if gate.resume(.success(value)) {
                    watchdog.cancel()
                } else {
                    discard(value)
                }
            } catch {
                if gate.resume(.failure(error)) {
                    watchdog.cancel()
                }
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
