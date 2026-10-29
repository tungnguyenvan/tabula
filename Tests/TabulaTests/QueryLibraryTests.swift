import XCTest

@testable import TabulaFoundation
@testable import TabulaStorage

final class QueryLibraryTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("QueryLibraryTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    func testMissingLibraryIsEmpty() throws {
        XCTAssertEqual(try QueryLibrary(base: base).load(), [])
    }

    func testSaveAndLoadWithGroups() throws {
        let library = QueryLibrary(base: base)
        try library.save("SELECT * FROM users WHERE active", keyword: "active_users")
        try library.save("SELECT sum(total) FROM orders", keyword: "revenue", group: "reports/monthly")
        // A file added in Finder, with a name that isn't a valid keyword, still shows up.
        let reports = library.directory.appendingPathComponent("reports", isDirectory: true)
        try "SELECT 1".write(to: reports.appendingPathComponent("Top customers.sql"), atomically: true, encoding: .utf8)
        try "not sql".write(to: reports.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)

        // Bytes that aren't text in any encoding Foundation can detect are reported, not listed.
        let binary = library.directory.appendingPathComponent("broken.sql")
        try Data([0xFF, 0xFE, 0x00, 0xD8, 0x00]).write(to: binary)
        let contents = try library.contents()
        XCTAssertEqual(contents.unreadable.map(\.lastPathComponent), ["broken.sql"])
        // Its keyword is still taken: saving must not overwrite the file the user couldn't see.
        XCTAssertThrowsError(try library.save("SELECT 2", keyword: "broken")) { error in
            XCTAssertEqual(error as? QueryLibrary.LibraryError, .keywordTaken("broken"))
        }
        XCTAssertEqual(try Data(contentsOf: binary), Data([0xFF, 0xFE, 0x00, 0xD8, 0x00]))
        try FileManager.default.removeItem(at: binary)

        let loaded = try library.load()
        XCTAssertEqual(loaded.map(\.keyword), ["active_users", "Top customers", "revenue"])
        XCTAssertEqual(loaded.map(\.group), ["", "reports", "reports/monthly"])
        XCTAssertEqual(loaded.first?.sql, "SELECT * FROM users WHERE active")
    }

    func testKeywordsAreSingleWordsAndUnique() throws {
        let library = QueryLibrary(base: base)
        XCTAssertThrowsError(try library.save("SELECT 1", keyword: "two words")) { error in
            XCTAssertEqual(error as? QueryLibrary.LibraryError, .invalidKeyword("two words"))
        }
        XCTAssertThrowsError(try library.save("SELECT 1", keyword: "1st"))
        XCTAssertThrowsError(try library.save("SELECT 1", keyword: "../escape"))
        XCTAssertTrue(QueryLibrary.isValidKeyword("đơn_hàng2"))
        XCTAssertFalse(QueryLibrary.isValidKeyword("top-users"), "the editor reads “-” as an operator")

        XCTAssertThrowsError(try library.save("SELECT 1", keyword: "outside", group: "../..")) { error in
            XCTAssertEqual(error as? QueryLibrary.LibraryError, .invalidFolder("../.."))
        }
        XCTAssertThrowsError(try library.save("SELECT 1", keyword: "hidden", group: "a/.git"))

        try library.save("SELECT 1", keyword: "daily")
        XCTAssertThrowsError(try library.save("SELECT 2", keyword: "Daily", group: "other")) { error in
            XCTAssertEqual(error as? QueryLibrary.LibraryError, .keywordTaken("Daily"))
        }
    }

    /// Links: one to a file inside the library is listed; one leading outside is reported; a save can't follow a
    /// linked folder out of the library.
    func testLinks() throws {
        let library = QueryLibrary(base: base)
        let saved = try library.save("SELECT 1", keyword: "inside")
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "SELECT 2".write(to: outside.appendingPathComponent("elsewhere.sql"), atomically: true, encoding: .utf8)
        let links = FileManager.default
        try links.createSymbolicLink(
            at: library.directory.appendingPathComponent("alias.sql"),
            withDestinationURL: saved.file
        )
        try links.createSymbolicLink(
            at: library.directory.appendingPathComponent("away.sql"),
            withDestinationURL: outside.appendingPathComponent("elsewhere.sql")
        )
        try links.createSymbolicLink(
            at: library.directory.appendingPathComponent("shared"),
            withDestinationURL: outside
        )

        let contents = try library.contents()
        XCTAssertEqual(contents.queries.map(\.keyword), ["alias", "inside"])
        XCTAssertEqual(contents.unreadable.map(\.lastPathComponent), ["away.sql"])
        XCTAssertThrowsError(try library.save("SELECT 3", keyword: "escaped", group: "shared")) { error in
            XCTAssertEqual(error as? QueryLibrary.LibraryError, .invalidFolder("shared"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: outside.appendingPathComponent("escaped.sql").path))
    }

    func testRemoveMovesToTrash() throws {
        let library = QueryLibrary(base: base)
        let saved = try library.save("SELECT 1", keyword: "scratch")
        try library.remove(saved)
        XCTAssertEqual(try library.load(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: saved.file.path))
    }

    func testSearchRanksKeywordThenGroupThenSQL() {
        func query(_ keyword: String, group: String = "", sql: String) -> SavedQuery {
            SavedQuery(file: URL(fileURLWithPath: "/q/\(keyword).sql"), keyword: keyword, group: group, sql: sql)
        }
        let queries = [
            query("monthly_totals", sql: "SELECT sum(total) FROM orders"),
            query("users_by_city", group: "orders", sql: "SELECT city FROM users"),
            query("order_items", sql: "SELECT * FROM order_items"),
            query("đơn_hàng", sql: "SELECT * FROM orders WHERE status = 'paid'"),
        ]
        XCTAssertEqual(
            SavedQuery.search(queries, for: "order").map(\.keyword),
            ["order_items", "users_by_city", "monthly_totals", "đơn_hàng"]
        )
        XCTAssertEqual(SavedQuery.search(queries, for: "DON").map(\.keyword), ["đơn_hàng"], "case and accents ignored")
        XCTAssertEqual(SavedQuery.search(queries, for: "  ").count, queries.count)
        XCTAssertEqual(SavedQuery.search(queries, for: "nothing"), [])
        // Every word must be found, anywhere: "city users" finds users_by_city, "orders paid" the query whose
        // SQL has both words.
        XCTAssertEqual(SavedQuery.search(queries, for: "city users").map(\.keyword), ["users_by_city"])
        XCTAssertEqual(SavedQuery.search(queries, for: "orders paid").map(\.keyword), ["đơn_hàng"])
    }
}
