import Foundation
import SQLite3

/// Stops the statement a SQLite connection is running, from another thread: for Stop, and when a statement runs
/// past the connection's time limit (set on the assistant's connection only).
///
/// SQLite asks a progress handler every few thousand steps of a statement whether to go on; this one answers
/// from the run's own state. Unlike `sqlite3_interrupt`, which SQLite forgets when no statement has started
/// yet, a Stop that arrives just before the statement starts still ends it. Each statement gets a run id, so
/// a Stop meant for one run never reaches the next.
final class SQLiteInterrupter: @unchecked Sendable {
    enum Reason: Sendable, Equatable {
        case stop
        case timeLimit(seconds: Int)
    }

    /// Steps of the statement between checks: frequent enough to stop within milliseconds, rare enough to cost
    /// nothing measurable.
    private static let stepsBetweenChecks: Int32 = 10_000

    private let lock = NSLock()
    private var limit: Int?
    private var running: UUID?
    private var deadline: UInt64?
    private var reason: Reason?

    /// Installs the progress handler on `handle`. The interrupter must outlive every statement on it, which the
    /// driver that owns both guarantees.
    init(handle: OpaquePointer) {
        sqlite3_progress_handler(
            handle,
            Self.stepsBetweenChecks,
            { context in
                guard let context else { return 0 }
                let interrupter = Unmanaged<SQLiteInterrupter>.fromOpaque(context).takeUnretainedValue()
                return interrupter.shouldInterrupt() ? 1 : 0
            },
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    /// The longest a statement may run, in seconds; nil for no limit.
    var timeLimitSeconds: Int? {
        get { lock.withLock { limit } }
        set { lock.withLock { limit = newValue } }
    }

    /// Marks a statement as running; pass the id to `interrupt` and `end`.
    func begin() -> UUID {
        let id = UUID()
        lock.withLock {
            running = id
            reason = nil
            deadline = limit.map { DispatchTime.now().uptimeNanoseconds + UInt64($0) * 1_000_000_000 }
        }
        return id
    }

    /// Why the run was interrupted, or nil when it wasn't. After this, interrupts for `id` do nothing.
    @discardableResult
    func end(_ id: UUID) -> Reason? {
        lock.withLock {
            guard running == id else { return nil }
            running = nil
            deadline = nil
            return reason
        }
    }

    /// Asks run `id` to stop at its next check; false when it already ended.
    func interrupt(_ id: UUID, because why: Reason) -> Bool {
        lock.withLock {
            guard running == id else { return false }
            if reason == nil {
                reason = why
            }
            return true
        }
    }

    private func shouldInterrupt() -> Bool {
        lock.withLock {
            guard running != nil else { return false }
            if reason == nil, let deadline, let limit, DispatchTime.now().uptimeNanoseconds >= deadline {
                reason = .timeLimit(seconds: limit)
            }
            return reason != nil
        }
    }
}
