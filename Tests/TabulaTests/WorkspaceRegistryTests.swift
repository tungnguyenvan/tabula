import AppKit
import XCTest

@testable import Tabula
@testable import TabulaFoundation
@testable import TabulaSQLite

/// Routing app-wide keys and menu commands to the workspace of the key window.
@MainActor
final class WorkspaceRegistryTests: XCTestCase {
    private var path = ""

    override class func setUp() {
        super.setUp()
        TestDataDirectory.prepare()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(atPath: path)
    }

    private func controlTab(shift: Bool) throws -> NSEvent {
        try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: shift ? [.control, .shift] : [.control],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "\t",
                charactersIgnoringModifiers: "\t",
                isARepeat: false,
                keyCode: KeyCode.tab
            )
        )
    }

    func testControlTabReachesTheActiveWindowsWorkspace() async throws {
        try TestDataDirectory.check()
        path = FileManager.default.temporaryDirectory.appendingPathComponent("tabula-reg-\(UUID()).sqlite").path
        let driver = try SQLiteDriver(path: path)
        _ = try await driver.execute("CREATE TABLE t (id INTEGER PRIMARY KEY)")
        await driver.close()

        let session = ConnectionSession()
        await session.open(ConnectionConfig(kind: .sqlite, filePath: path), appState: AppState())
        guard case .sql(let workspace) = try XCTUnwrap(session.active) else {
            return XCTFail("a SQL workspace")
        }
        workspace.newQueryTab()
        workspace.selectTab(number: 1)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: true
        )
        WorkspaceRegistry.register(session, window: window)
        WorkspaceRegistry.makeActiveForTesting(window)
        XCTAssertTrue(ActiveWorkspace.shared.model === workspace)

        XCTAssertTrue(WorkspaceRegistry.handle(try controlTab(shift: false)))
        XCTAssertEqual(workspace.selectedTabID, workspace.tabs[1].id)
        XCTAssertTrue(WorkspaceRegistry.handle(try controlTab(shift: true)))
        XCTAssertEqual(workspace.selectedTabID, workspace.tabs[0].id)

        // Other keys are left alone.
        let plainTab = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown,
                location: .zero,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                characters: "\t",
                charactersIgnoringModifiers: "\t",
                isARepeat: false,
                keyCode: KeyCode.tab
            )
        )
        XCTAssertFalse(WorkspaceRegistry.handle(plainTab))
        XCTAssertTrue(WorkspaceRegistry.confirmCloseResults())

        session.closeAll()
        XCTAssertNil(ActiveWorkspace.shared.model, "a window without connections has no workspace")
    }

    func testWindowRequestsAreUsedOnce() {
        WindowRequests.request(WindowID.shortcuts)
        XCTAssertTrue(WindowRequests.consume(WindowID.shortcuts))
        XCTAssertFalse(WindowRequests.consume(WindowID.shortcuts), "a window macOS restores by itself closes")
    }
}
