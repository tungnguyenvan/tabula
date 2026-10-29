import XCTest

@testable import TabulaDrivers
@testable import TabulaFoundation
@testable import TabulaMongo
@testable import TabulaSQL

/// Engines without transactions run the changes one by one; a failure says how many were already saved.
final class SequentialChangesTests: XCTestCase {
    func testFirstChangeFailingSavesNothing() async throws {
        let message = try await failureMessage(failingAt: 0, of: 3)
        XCTAssertEqual(message, "Change 1 of 3 failed: rejected")
    }

    func testSecondChangeFailingNamesTheSavedChange() async throws {
        let message = try await failureMessage(failingAt: 1, of: 3)
        XCTAssertEqual(message, "Change 2 of 3 failed: rejected The change before it was saved.")
    }

    func testLaterChangeFailingCountsTheSavedChanges() async throws {
        let message = try await failureMessage(failingAt: 2, of: 3)
        XCTAssertEqual(message, "Change 3 of 3 failed: rejected The 2 changes before it were saved.")
    }

    func testChangesAfterTheFailureDoNotRun() async throws {
        let driver = FailingDriver(failingAt: 1)
        _ = try? await driver.applyInTransaction(["a", "b", "c"])
        let executed = await driver.executed
        XCTAssertEqual(executed, ["a", "b"])
    }

    private func failureMessage(failingAt index: Int, of count: Int) async throws -> String {
        let driver = FailingDriver(failingAt: index)
        let statements = (0..<count).map { "change \($0)" }
        do {
            try await driver.applyInTransaction(statements)
        } catch {
            return error.localizedDescription
        }
        XCTFail("applyInTransaction did not throw")
        return ""
    }
}

/// A driver without transactions whose statement at `failingAt` is rejected.
private actor FailingDriver: DatabaseDriver {
    nonisolated let kind: DatabaseKind = .mongodb
    nonisolated let dialect: any QueryDialect = MongoQueryDialect()
    nonisolated let catalog: any DatabaseCatalog = MongoCatalog()
    private let failingAt: Int
    private(set) var executed: [String] = []

    init(failingAt: Int) {
        self.failingAt = failingAt
    }

    func execute(_ sql: String) async throws -> QueryResult {
        let index = executed.count
        executed.append(sql)
        if index == failingAt {
            throw DatabaseError("rejected")
        }
        return QueryResult(statement: sql)
    }

    func schemas() async throws -> [String] { [] }
    func defaultSchema() async throws -> String { "" }
    func tables(in schema: String) async throws -> [TableRef] { [] }
    func columns(of table: TableRef) async throws -> [ColumnInfo] { [] }
    func indexes(of table: TableRef) async throws -> [IndexInfo] { [] }
    func close() async {}
}
