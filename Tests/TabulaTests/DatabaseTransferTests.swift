import XCTest

@testable import Tabula
@testable import TabulaConnections
@testable import TabulaDrivers
@testable import TabulaFoundation
@testable import TabulaTransfer

/// The dump / restore sheet's model, restoring SQL scripts into the test PostgreSQL with this Mac's psql.
/// The file comes from TABULA_DEBUG_RESTORE_FROM, as in scripted checks, instead of the open panel.
@MainActor
final class DatabaseTransferTests: XCTestCase {
    private var files: [URL] = []

    private func postgres(tag: ConnectionTag = .local) throws -> ConnectionConfig {
        guard ProcessInfo.processInfo.environment["TABULA_TEST_PG_PORT"] == "55432" else {
            throw XCTSkip("Set TABULA_TEST_PG_PORT=55432 for the disposable local tabula-test-pg database")
        }
        var config = ConnectionConfig(kind: .postgres, port: 55432, user: "tabula", database: "tabula")
        config.tag = tag
        return config
    }

    override func tearDown() async throws {
        unsetenv("TABULA_DEBUG_RESTORE_FROM")
        for file in files {
            try? FileManager.default.removeItem(at: file)
        }
        files = []
    }

    private func script(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "tabula-restore-\(UUID().uuidString).sql"
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
        files.append(url)
        return url
    }

    private func restore(
        _ file: URL,
        config: ConnectionConfig,
        onRestored: @escaping () -> Void = {}
    ) async throws
        -> DatabaseTransfer
    {
        let transfer = DatabaseTransfer(
            direction: .restore,
            config: config,
            database: "tabula",
            password: "tabula",
            serverMajor: 16,
            serverIsMariaDB: false,
            onRestored: onRestored
        )
        setenv("TABULA_DEBUG_RESTORE_FROM", file.path, 1)
        XCTAssertTrue(transfer.chooseFile())
        XCTAssertEqual(transfer.fileKind, .script)
        for _ in 0..<300 where transfer.tool == nil && transfer.toolProblem == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard transfer.tool != nil else {
            throw XCTSkip(transfer.toolProblem ?? "psql not found")
        }
        return transfer
    }

    private func finish(_ transfer: DatabaseTransfer) async throws {
        transfer.start()
        for _ in 0..<1000 where transfer.isRunning {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(transfer.isRunning)
    }

    private func tableExists(_ name: String) async throws -> Bool {
        let driver = try await DriverFactory.connect(try postgres(), password: "tabula")
        defer { Task { await driver.close() } }
        let found = try await driver.execute("SELECT to_regclass('public.\(name)') IS NOT NULL").rows.first?.first
        return found == "true"
    }

    func testScriptRestoresAndReportsIt() async throws {
        let table = "restore_" + UUID().uuidString.prefix(8).lowercased()
        let file = try script("CREATE TABLE \(table) (n int);\nINSERT INTO \(table) VALUES (1), (2);\n")
        var restored = false
        let transfer = try await restore(file, config: try postgres()) { restored = true }
        XCTAssertTrue(transfer.canStart)
        try await finish(transfer)
        XCTAssertEqual(transfer.phase, .finished("Restored “\(file.lastPathComponent)” into tabula."))
        XCTAssertTrue(restored, "the workspace reloads its tables")
        let exists = try await tableExists(table)
        XCTAssertTrue(exists)
        let driver = try await DriverFactory.connect(try postgres(), password: "tabula")
        _ = try await driver.execute("DROP TABLE \(table)")
        await driver.close()
    }

    /// One transaction by default: a failure part-way changes nothing, and the message says so.
    func testFailedScriptChangesNothing() async throws {
        let table = "restore_" + UUID().uuidString.prefix(8).lowercased()
        let file = try script("CREATE TABLE \(table) (n int);\nINSERT INTO missing_table VALUES (1);\n")
        let transfer = try await restore(file, config: try postgres())
        XCTAssertTrue(transfer.restoreOptions.singleTransaction)
        try await finish(transfer)
        guard case .failed(let message) = transfer.phase else {
            return XCTFail("expected the restore to fail, got \(transfer.phase)")
        }
        XCTAssertTrue(message.contains("missing_table"), message)
        XCTAssertTrue(message.hasSuffix("Nothing was changed: the restore ran in one transaction."), message)
        let exists = try await tableExists(table)
        XCTAssertFalse(exists, "the CREATE TABLE before the failure was rolled back")
    }

    func testProductionRestoreWaitsForTheTypedName() async throws {
        let file = try script("SELECT 1;\n")
        let transfer = try await restore(file, config: try postgres(tag: .production))
        XCTAssertFalse(transfer.canStart)
        transfer.typedConfirmation = "tabul"
        XCTAssertFalse(transfer.canStart)
        transfer.typedConfirmation = "tabula"
        XCTAssertTrue(transfer.canStart)
    }

    /// psql commands could run programs on this Mac; the restore refuses the script before running it.
    func testScriptsWithPsqlCommandsAreRefused() async throws {
        let file = try script("SELECT 1;\n\\! touch /tmp/tabula-should-not-exist\n")
        let transfer = try await restore(file, config: try postgres())
        try await finish(transfer)
        guard case .failed(let message) = transfer.phase else {
            return XCTFail("expected the script to be refused, got \(transfer.phase)")
        }
        XCTAssertTrue(message.contains("\\!"), message)
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/tabula-should-not-exist"))
    }
}
