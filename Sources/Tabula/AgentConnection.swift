import Foundation
import TabulaAI
import TabulaDrivers
import TabulaFoundation

/// The assistant's own connection to the workspace's database: opened the first time a tool needs it, made
/// read-only where the server can enforce it, and kept for the following tool calls. Requests that arrive
/// while it opens wait for the same connection. Closing it (the workspace disconnects) also discards one
/// still opening, so a connection to the old database is never kept.
@MainActor
final class AgentConnection {
    private var driver: LoggingDriver?
    /// The schema unqualified names resolve to on this connection.
    private var schema: String?
    private var opening: Task<LoggingDriver, any Error>?
    /// Bumped by `close`; a connection that finishes opening after that is closed, not kept.
    private var generation = 0

    /// The connection with `selectedSchema` in use, opened with `open` when there is none yet.
    func driver(
        selectedSchema: String,
        open: @escaping @MainActor () async throws -> LoggingDriver
    ) async throws -> LoggingDriver {
        let current: LoggingDriver
        if let driver {
            current = driver
        } else {
            current = try await openOnce(open)
        }
        // Unqualified names resolve as in the user's queries.
        if schema != selectedSchema {
            try await current.useSchema(selectedSchema)
            schema = selectedSchema
        }
        return current
    }

    private func openOnce(_ open: @escaping @MainActor () async throws -> LoggingDriver) async throws -> LoggingDriver {
        let started = generation
        let task: Task<LoggingDriver, any Error>
        if let opening {
            task = opening
        } else {
            task = Task {
                let opened = try await open()
                do {
                    try await AgentToolbox.prepare(opened)
                    try Task.checkCancellation()
                } catch {
                    await opened.close()
                    throw error
                }
                return opened
            }
            opening = task
        }
        let opened = try await task.value
        guard started == generation else {
            await opened.close()
            throw CancellationError()
        }
        opening = nil
        driver = opened
        schema = nil
        return opened
    }

    /// Closes the connection, and stops one still opening.
    func close() async {
        generation += 1
        opening?.cancel()
        opening = nil
        let closing = driver
        driver = nil
        schema = nil
        await closing?.close()
    }
}
