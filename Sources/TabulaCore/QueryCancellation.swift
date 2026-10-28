import Foundation

/// What Stop can do to a statement that is already running on the server.
public enum QueryCancellationSupport: Sendable, Equatable {
    /// The driver asks the server to cancel the running statement.
    case server
    /// The running statement always runs to completion; Stop only skips the statements after it.
    case afterCurrentStatement
}

/// The answer to a Stop request.
public enum QueryCancelOutcome: Sendable, Equatable {
    /// The server was asked to cancel the running statement. It ends with `QueryCancelledError`, or,
    /// if it was already finishing, with its normal result.
    case requested
    /// No statement was running for the scope (between statements, or still waiting for the connection).
    case notRunning
    /// The driver can't cancel a running statement; it will finish on its own.
    case unsupported
    /// Asking the server failed; the statement keeps running until it finishes.
    case failed(String)
}

/// Thrown by `execute` for a statement that the user stopped, and for statements a stopped run never started.
public struct QueryCancelledError: LocalizedError, Sendable {
    /// False when Stop prevented a statement from starting, rather than interrupting it on the server.
    public let serverInterrupted: Bool
    public init(serverInterrupted: Bool = false) { self.serverInterrupted = serverInterrupted }
    public var errorDescription: String? { "Query stopped." }
}

/// One user run (a statement or a script) that Stop can end. Set it as `QueryCancelScope.current` while
/// executing; drivers that support cancellation attach the statement they are running to it, so a Stop
/// only ever reaches a statement started for this run, never a later, unrelated one.
public final class QueryCancelScope: @unchecked Sendable {
    @TaskLocal public static var current: QueryCancelScope?

    public typealias Handler = @Sendable () async -> QueryCancelOutcome

    private let lock = NSLock()
    private var cancelled = false
    private var handler: (id: UUID, cancel: Handler)?

    public init() {}

    public var isCancelled: Bool { lock.withLock { cancelled } }

    public func checkCancellation() throws {
        if isCancelled { throw QueryCancelledError() }
    }

    /// Synchronously prevents further steps before the asynchronous server request gets scheduled.
    public func requestStop() { lock.withLock { cancelled = true } }

    /// Installs how to stop the step now in progress. Returns nil, installing nothing, when the scope was
    /// already stopped: the caller must then not start the step. Pass the returned id to `detach`.
    public func attach(_ cancel: @escaping Handler) -> UUID? {
        lock.withLock {
            guard !cancelled else { return nil }
            let id = UUID()
            handler = (id, cancel)
            return id
        }
    }

    public func detach(_ id: UUID) {
        lock.withLock { if handler?.id == id { handler = nil } }
    }

    /// Stops the run: nothing new starts in this scope, and the step in progress, if any, is cancelled.
    @discardableResult
    public func cancel() async -> QueryCancelOutcome {
        let running: Handler? = lock.withLock {
            cancelled = true
            defer { handler = nil }
            return handler?.cancel
        }
        guard let running else { return .notRunning }
        return await running()
    }
}

/// A FIFO async lock for whole driver executions. Actor isolation alone is reentrant at every await.
final class QueryExecutionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        await withCheckedContinuation { continuation in
            let ready: Bool = lock.withLock {
                if busy { waiters.append(continuation); return false }
                busy = true
                return true
            }
            if ready { continuation.resume() }
        }
    }

    func release() {
        let next: CheckedContinuation<Void, Never>? = lock.withLock {
            if waiters.isEmpty { busy = false; return nil }
            return waiters.removeFirst()
        }
        next?.resume()
    }
}

extension DatabaseDriver {
    /// Drivers without server-side cancellation let the running statement finish.
    public var queryCancellation: QueryCancellationSupport { .afterCurrentStatement }
}
