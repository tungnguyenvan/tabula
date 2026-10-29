import Security
import XCTest
@testable import TabulaStorage

/// Opt-in integration tests. Each test owns a uniquely named, disposable item, never a connection's credentials.
final class KeychainItemTests: XCTestCase {
    private var item: KeychainItem!

    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["TABULA_TEST_KEYCHAIN"] == "1" else {
            throw XCTSkip("Set TABULA_TEST_KEYCHAIN=1 to test disposable Keychain items.")
        }
        item = KeychainItem(service: "app.tabula.tests.\(UUID().uuidString)", account: "test", label: "Tabula test item")
    }

    override func tearDownWithError() throws {
        if let item { try item.write(nil) }
    }

    func testUpdatingKeepsTheExistingItem() throws {
        try item.write("first test value")
        let original = try persistentReference()
        // Keychain can reuse a persistent reference after deletion, so also mark the existing item's metadata.
        let marked = SecItemUpdate(query as CFDictionary, [kSecAttrComment as String: "Keep existing metadata"] as CFDictionary)
        XCTAssertEqual(marked, errSecSuccess)
        XCTAssertEqual(item.read(), "first test value")

        try item.write("second test value")
        XCTAssertEqual(item.read(), "second test value")
        XCTAssertEqual(try persistentReference(), original, "Updating must not delete and recreate the item.")
        var attributesQuery = query
        attributesQuery[kSecReturnAttributes as String] = true
        var attributes: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(attributesQuery as CFDictionary, &attributes), errSecSuccess)
        XCTAssertEqual((attributes as? [String: Any])?[kSecAttrComment as String] as? String, "Keep existing metadata")

        try item.write("second test value")
        XCTAssertEqual(try persistentReference(), original, "Saving the same password must keep the item too.")
    }

    func testRemovingAndCreatingAgain() throws {
        try item.write("disposable test value")
        try item.write(nil)
        XCTAssertNil(item.read())
        try item.write(nil)

        try item.write("another test value")
        XCTAssertEqual(item.read(), "another test value")
        try item.write("")
        XCTAssertNil(item.read())
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: item.service, kSecAttrAccount as String: item.account]
    }

    private func persistentReference() throws -> Data {
        var query = query
        query[kSecReturnPersistentRef as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        return try XCTUnwrap(result as? Data)
    }
}
