import XCTest

@testable import TabulaFoundation
@testable import TabulaStorage

/// Connection passwords live in one Keychain item, so one "Always Allow" covers them all (#266). An in-memory
/// keychain stands in for the real one; the user's Keychain is never used.
final class ConnectionPasswordTests: XCTestCase {
    /// Items by account; `refused` accounts throw as the Keychain does when the user denies access.
    final class MemoryKeychain: PasswordKeychain, @unchecked Sendable {
        var items: [String: String] = [:]
        var refused: Set<String> = []
        private let lock = NSLock()

        func read(account: String) throws -> String? {
            lock.lock()
            defer { lock.unlock() }
            if refused.contains(account) {
                throw KeychainError(status: errSecAuthFailed)
            }
            return items[account]
        }

        func write(_ value: String?, account: String, label: String?) throws {
            lock.lock()
            defer { lock.unlock() }
            if refused.contains(account) {
                throw KeychainError(status: errSecAuthFailed)
            }
            items[account] = value
        }
    }

    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tabula-pw-\(UUID())")

    func testPasswordsShareOneItem() throws {
        let keychain = MemoryKeychain()
        let store = ConnectionStore(directory: directory, keychain: keychain)
        let first = UUID()
        let second = UUID()
        try store.setPassword("one", for: first)
        try store.setPassword("two", for: second)
        XCTAssertEqual(Array(keychain.items.keys), [ConnectionStore.sharedAccount], "one item for every connection")
        XCTAssertEqual(store.password(for: first), "one")
        XCTAssertEqual(store.password(for: second), "two")
        try store.setPassword(nil, for: first)
        XCTAssertNil(store.password(for: first))
        XCTAssertEqual(store.password(for: second), "two")
        try store.setPassword("", for: second)
        XCTAssertTrue(keychain.items.isEmpty, "no item is left once no connection has a password")
    }

    /// A connection's own item, from earlier versions, moves into the shared one the first time it is read.
    func testAnOldItemMovesOver() throws {
        let keychain = MemoryKeychain()
        let store = ConnectionStore(directory: directory, keychain: keychain)
        let kept = UUID()
        let old = UUID()
        try store.setPassword("kept", for: kept)
        keychain.items[old.uuidString] = "from before"
        XCTAssertEqual(store.password(for: old), "from before")
        XCTAssertNil(keychain.items[old.uuidString], "the old item is gone")
        XCTAssertEqual(try store.passwords(), [kept: "kept", old: "from before"])
    }

    /// When the shared item can't be read (access denied), nothing is written over it: a save fails rather than
    /// drop every other connection's password, and an old item is still read without moving.
    func testARefusedReadNeverOverwrites() throws {
        let keychain = MemoryKeychain()
        let store = ConnectionStore(directory: directory, keychain: keychain)
        let other = UUID()
        let old = UUID()
        try store.setPassword("other", for: other)
        keychain.items[old.uuidString] = "from before"
        keychain.refused = [ConnectionStore.sharedAccount]
        XCTAssertThrowsError(try store.setPassword("new", for: UUID()))
        XCTAssertEqual(store.password(for: old), "from before")
        XCTAssertEqual(keychain.items[old.uuidString], "from before", "not moved while the shared item is unreadable")
        keychain.refused = []
        XCTAssertEqual(try store.passwords(), [other: "other"])
    }
}
