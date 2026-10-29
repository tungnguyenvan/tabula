import Foundation
import XCTest

@testable import Tabula

/// Points the app's stores (workspace states, chats, the query library) at a temporary folder, so tests of the
/// app's models never read or write the user's. The stores read TABULA_DATA_DIR once per process, so every test
/// class that touches them calls `prepare()` in its class `setUp`, and `check()` before each test.
enum TestDataDirectory {
    static let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("tabula-tests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)

    static func prepare() {
        setenv("TABULA_DATA_DIR", url.path, 1)
        // With passwords.json in the folder, debug builds read passwords from it and never touch the Keychain.
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let passwords = url.appendingPathComponent("passwords.json")
        if !FileManager.default.fileExists(atPath: passwords.path) {
            try? Data("{}".utf8).write(to: passwords)
        }
    }

    /// Skips the test when a store (or the passwords file, which keeps the Keychain out) was set up before
    /// TABULA_DATA_DIR was.
    @MainActor
    static func check() throws {
        guard WorkspaceModel.stateStore.directory.path.hasPrefix(url.path),
            AppState.chatStore.directory.path.hasPrefix(url.path),
            AppState.queryLibrary.directory.path.hasPrefix(url.path),
            AppState.testPasswords != nil
        else {
            throw XCTSkip("A store was set up before TABULA_DATA_DIR; run this test on its own.")
        }
    }
}
