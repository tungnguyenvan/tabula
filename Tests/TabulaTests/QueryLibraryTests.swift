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
    }
}
