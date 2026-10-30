import XCTest

@testable import TabulaDrivers

/// Runs `body`, then runs `cleanup` on `driver` and closes it, whether `body` passed or threw. Tests used to drop
/// their tables from a detached Task in a `defer`, which the test process could end before, leaving tables in the
/// shared test databases.
func runThenClean(
    _ driver: any DatabaseDriver,
    cleanup: [String],
    _ body: () async throws -> Void
) async throws {
    do {
        try await body()
    } catch {
        for statement in cleanup {
            _ = try? await driver.execute(statement)
        }
        await driver.close()
        throw error
    }
    for statement in cleanup {
        _ = try? await driver.execute(statement)
    }
    await driver.close()
}
