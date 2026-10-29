import XCTest

@testable import Tabula
@testable import TabulaDrivers
@testable import TabulaFoundation

@MainActor
final class QueryLogModelTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 0)

    func testCopiedLogRunsAsItRan() {
        let log = QueryLogModel()
        log.append(QueryLogEntry(date: date, statement: "SELECT 1 -- the answer", duration: 0.01, outcome: .rows(1)))
        log.append(
            QueryLogEntry(
                date: date,
                statement: "SELEC 2",
                duration: 0,
                outcome: .failed("syntax error at or near \"SELEC\"\nLINE 1: SELEC 2\n        ^")
            )
        )
        log.append(QueryLogEntry(date: date, statement: "DELETE FROM t;", duration: 0, outcome: .affected(3)))
        log.append(QueryLogEntry(date: date, statement: "SELECT 'a -- b'", duration: 0, outcome: .rows(1)))
        let lines = log.text.components(separatedBy: "\n")
        // Every line is a comment, a statement, or the terminator of one.
        let code = lines.filter { !$0.hasPrefix("-- ") && !$0.isEmpty }
        XCTAssertEqual(code, ["SELECT 1 -- the answer", ";", "SELEC 2;", "DELETE FROM t;", "SELECT 'a -- b';"])
        XCTAssertTrue(log.text.contains("-- LINE 1: SELEC 2\n--         ^"), log.text)
    }

    func testTerminators() {
        XCTAssertEqual(QueryLogModel.terminated("SELECT 1"), "SELECT 1;")
        XCTAssertEqual(QueryLogModel.terminated("SELECT 1;  \n"), "SELECT 1;")
        XCTAssertEqual(QueryLogModel.terminated("SELECT 1 /* note */"), "SELECT 1 /* note */;")
        XCTAssertEqual(QueryLogModel.terminated("db.orders.find() // recent"), "db.orders.find() // recent\n;")
        XCTAssertEqual(QueryLogModel.terminated("SELECT 1 # note"), "SELECT 1 # note\n;")
    }

    func testOnlyTheLatestEntriesAreKeptAndMetaIsHidden() {
        let log = QueryLogModel()
        for index in 0..<(Defaults.consoleLogLimit + 3) {
            log.append(QueryLogEntry(date: date, statement: "SELECT \(index)", duration: 0, outcome: .rows(1)))
        }
        XCTAssertEqual(log.entries.count, Defaults.consoleLogLimit)
        XCTAssertEqual(log.entries.first?.statement, "SELECT 3")
        log.clear()
        log.append(QueryLogEntry(date: date, statement: "catalog read", duration: 0, outcome: .rows(1), isMeta: true))
        XCTAssertTrue(log.visible.isEmpty)
        log.showMeta = true
        XCTAssertEqual(log.visible.count, 1)
        XCTAssertTrue(log.text.hasSuffix("\ncatalog read"), "catalog reads aren't given a terminator")
    }
}
