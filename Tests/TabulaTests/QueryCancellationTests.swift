import XCTest

@testable import TabulaDrivers
@testable import TabulaFoundation
@testable import TabulaMySQL
@testable import TabulaPostgres
@testable import TabulaSQL

final class QueryCancellationTests: XCTestCase {
    func testStopBeforeStartRejectsAttachment() async throws {
        let scope = QueryCancelScope()
        scope.requestStop()
        XCTAssertNil(
            scope.attach {
                XCTFail("must not run")
                return .requested
            }
        )
        XCTAssertThrowsError(try scope.checkCancellation()) { XCTAssertTrue($0 is QueryCancelledError) }
        let outcome = await scope.cancel()
        XCTAssertEqual(outcome, .notRunning)
    }

    func testStopOnlyCallsCurrentHandlerOnce() async {
        let scope = QueryCancelScope()
        let calls = CancellationCounter()
        _ = scope.attach {
            await calls.increment()
            return .requested
        }
        async let first = scope.cancel()
        async let second = scope.cancel()
        let outcomes = await [first, second]
        XCTAssertEqual(outcomes.filter { $0 == .requested }.count, 1)
        XCTAssertEqual(outcomes.filter { $0 == .notRunning }.count, 1)
        let count = await calls.value
        XCTAssertEqual(count, 1)
        XCTAssertTrue(scope.isCancelled)
    }

    func testOldDetachDoesNotDetachNextStatement() async throws {
        let scope = QueryCancelScope()
        let old = try XCTUnwrap(
            scope.attach {
                XCTFail("old statement")
                return .requested
            }
        )
        scope.detach(old)
        let next = try XCTUnwrap(scope.attach { .requested })
        scope.detach(old)
        let outcome = await scope.cancel()
        XCTAssertEqual(outcome, .requested)
        scope.detach(next)
    }

    func testCompletedRunCannotCancelUnrelatedRun() async throws {
        let first = QueryCancelScope()
        let second = QueryCancelScope()
        let token = try XCTUnwrap(
            first.attach {
                XCTFail("completed statement")
                return .requested
            }
        )
        first.detach(token)
        _ = second.attach { .requested }
        let firstOutcome = await first.cancel()
        XCTAssertEqual(firstOutcome, .notRunning)
        XCTAssertFalse(second.isCancelled)
        let secondOutcome = await second.cancel()
        XCTAssertEqual(secondOutcome, .requested)
    }

    func testScriptSkipsRemainingStatementsEvenForUnsupportedDriver() async throws {
        let scope = QueryCancelScope()
        let driver = ScriptStopDriver()
        do {
            _ = try await QueryCancelScope.$current.withValue(scope) {
                try await driver.executeScript("SELECT 1; SELECT 2; SELECT 3")
            }
            XCTFail("expected the stopped script to end")
        } catch is QueryCancelledError {}
        let statements = await driver.statements
        XCTAssertEqual(statements, ["SELECT 1"])
        XCTAssertEqual(driver.queryCancellation, .afterCurrentStatement)
    }

    func testLoggingDriverForwardsSupportAndScope() async throws {
        let scope = QueryCancelScope()
        let inner = ScriptStopDriver()
        let driver = LoggingDriver(inner) { _ in }
        XCTAssertEqual(driver.queryCancellation, inner.queryCancellation)
        _ = try await QueryCancelScope.$current.withValue(scope) { try await driver.execute("SELECT 1") }
        XCTAssertTrue(scope.isCancelled, "the wrapped execute must inherit the run's scope")
    }

    func testExecutionGateKeepsQueuedWorkBehindCancellationDrain() async throws {
        let gate = QueryExecutionGate()
        let entered = CancellationCounter()
        await gate.acquire()
        let next = Task {
            await gate.acquire()
            await entered.increment()
            gate.release()
        }
        // Yield while the first execution still owns the gate: a later one may not start.
        for _ in 0..<20 { await Task.yield() }
        let beforeRelease = await entered.value
        XCTAssertEqual(beforeRelease, 0)
        gate.release()
        await next.value
        let afterRelease = await entered.value
        XCTAssertEqual(afterRelease, 1)
        await gate.acquire()
        gate.release()
    }
}

private actor CancellationCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

/// An unsupported driver can finish its current statement but still must not start the next one.
private actor ScriptStopDriver: DatabaseDriver {
    nonisolated let kind: DatabaseKind = .mysql
    nonisolated let dialect: any QueryDialect = SQLDialect(flavor: .mysql)
    nonisolated let catalog: any DatabaseCatalog = MySQLCatalog()
    private(set) var statements: [String] = []
    func execute(_ sql: String) async throws -> QueryResult {
        statements.append(sql)
        QueryCancelScope.current?.requestStop()
        return QueryResult(statement: sql)
    }
    func schemas() async throws -> [String] { [] }
    func defaultSchema() async throws -> String { "" }
    func tables(in schema: String) async throws -> [TableRef] { [] }
    func columns(of table: TableRef) async throws -> [ColumnInfo] { [] }
    func indexes(of table: TableRef) async throws -> [IndexInfo] { [] }
    func close() async {}
}

/// Uses only the disposable local test PostgreSQL; never follows an arbitrary host from the environment.
final class PostgresCancellationTests: XCTestCase {
    private func connect() async throws -> PostgresDriver {
        guard ProcessInfo.processInfo.environment["TABULA_TEST_PG_PORT"] == "55432" else {
            throw XCTSkip("Set TABULA_TEST_PG_PORT=55432 for the disposable local tabula-test-pg database")
        }
        return try await PostgresDriver.connect(
            ConnectionConfig(kind: .postgres, host: "127.0.0.1", port: 55432, user: "tabula", database: "tabula"),
            password: "tabula"
        )
    }

    /// Wait for pg_sleep, rather than guessing with a fixed delay, before pressing Stop.
    private func waitForSleep(_ observer: PostgresDriver) async throws {
        for _ in 0..<200 {
            let result = try await observer.execute(
                """
                SELECT count(*)::text FROM pg_catalog.pg_stat_activity
                WHERE application_name = 'Tabula' AND query LIKE '/* tabula-run:%'
                  AND query LIKE '%pg_sleep(15)%' AND wait_event = 'PgSleep'
                """
            )
            if result.rows.first?.first != "0" { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("pg_sleep did not start within five seconds")
        throw DatabaseError("pg_sleep did not start")
    }

    func testCancelSleepKeepsConnectionAndDoesNotCancelNextQuery() async throws {
        let driver = try await connect()
        let observer = try await connect()
        let scope = QueryCancelScope()
        let run = Task {
            try await QueryCancelScope.$current.withValue(scope) { try await driver.execute("SELECT pg_sleep(15)") }
        }
        do {
            try await waitForSleep(observer)
            let start = Date()
            let outcome = await scope.cancel()
            XCTAssertEqual(outcome, .requested)
            // Even when queued before the old execute finishes, this query cannot be targeted by Stop.
            let next = Task { try await driver.execute("SELECT 42") }
            do {
                _ = try await run.value
                XCTFail("expected server cancellation")
            } catch { XCTAssertEqual((error as? QueryCancelledError)?.serverInterrupted, true, "\(error)") }
            XCTAssertLessThan(Date().timeIntervalSince(start), 10)
            let result = try await next.value
            XCTAssertEqual(result.rows, [["42"]])
            let repeated = await scope.cancel()
            XCTAssertEqual(repeated, .notRunning)
            let last = try await driver.execute("SELECT 43")
            XCTAssertEqual(last.rows, [["43"]])
        } catch {
            _ = await scope.cancel()
            _ = try? await run.value
            await observer.close()
            await driver.close()
            throw error
        }
        await observer.close()
        await driver.close()
    }

    func testCancelledScriptDoesNotRunRemainingWriteOrCommitAndPreservesFailedTransaction() async throws {
        let driver = try await connect()
        let observer = try await connect()
        _ = try await driver.execute("CREATE TEMP TABLE tabula_cancel_test (id integer)")
        _ = try await driver.execute("BEGIN")
        _ = try await driver.execute("INSERT INTO tabula_cancel_test VALUES (1)")
        let scope = QueryCancelScope()
        let run = Task {
            try await QueryCancelScope.$current.withValue(scope) {
                try await driver.executeScript("SELECT pg_sleep(15); INSERT INTO tabula_cancel_test VALUES (2); COMMIT")
            }
        }
        do {
            try await waitForSleep(observer)
            let outcome = await scope.cancel()
            XCTAssertEqual(outcome, .requested)
            do {
                _ = try await run.value
                XCTFail("expected cancellation")
            } catch { XCTAssertTrue(error is QueryCancelledError, "\(error)") }
            // No automatic ROLLBACK: the user's failed transaction remains theirs to resolve.
            do {
                _ = try await driver.execute("SELECT 1")
                XCTFail("transaction should still be aborted")
            } catch { XCTAssertTrue(error.localizedDescription.contains("transaction is aborted"), "\(error)") }
            _ = try await driver.execute("ROLLBACK")
            let count = try await driver.execute("SELECT count(*)::text FROM tabula_cancel_test")
            XCTAssertEqual(count.rows, [["0"]])
        } catch {
            _ = await scope.cancel()
            _ = try? await run.value
            await observer.close()
            await driver.close()
            throw error
        }
        await observer.close()
        await driver.close()
    }

    func testStoppedQueuedRunDoesNotCancelOtherRun() async throws {
        let driver = try await connect()
        let firstScope = QueryCancelScope()
        let observer = try await connect()
        let first = Task {
            try await QueryCancelScope.$current.withValue(firstScope) {
                try await driver.execute("SELECT pg_sleep(15)")
            }
        }
        do {
            try await waitForSleep(observer)
            let queuedScope = QueryCancelScope()
            let queued = Task {
                try await QueryCancelScope.$current.withValue(queuedScope) { try await driver.execute("SELECT 999") }
            }
            let outcome = await queuedScope.cancel()
            XCTAssertEqual(outcome, .notRunning)
            XCTAssertFalse(firstScope.isCancelled)
            _ = await firstScope.cancel()
            _ = try? await first.value
            do {
                _ = try await queued.value
                XCTFail("queued statement must not execute")
            } catch { XCTAssertEqual((error as? QueryCancelledError)?.serverInterrupted, false, "\(error)") }
            let result = try await driver.execute("SELECT 7")
            XCTAssertEqual(result.rows, [["7"]])
        } catch {
            _ = await firstScope.cancel()
            _ = try? await first.value
            await observer.close()
            await driver.close()
            throw error
        }
        await observer.close()
        await driver.close()
    }

    func testAlreadyStoppedScopeDoesNotExecuteAnything() async throws {
        let driver = try await connect()
        let scope = QueryCancelScope()
        _ = await scope.cancel()
        do {
            _ = try await QueryCancelScope.$current.withValue(scope) { try await driver.execute("SELECT pg_sleep(15)") }
            XCTFail("expected cancellation before start")
        } catch { XCTAssertTrue(error is QueryCancelledError, "\(error)") }
        let result = try await driver.execute("SELECT 1")
        XCTAssertEqual(result.rows, [["1"]])
        await driver.close()
    }
}
