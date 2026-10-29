import XCTest

@testable import TabulaFoundation

final class DocumentTextsTests: XCTestCase {
    /// Writing documents is the slow part, so only the ones read are written.
    func testWritesOnlyTheDocumentsRead() {
        let written = WrittenRows()
        let texts = DocumentTexts(count: 3) { row in
            written.add(row)
            return "{ n: \(row) }"
        }
        XCTAssertEqual(texts.count, 3)
        XCTAssertEqual(written.rows, [])
        XCTAssertEqual(texts[2], "{ n: 2 }")
        XCTAssertEqual(written.rows, [2])
        XCTAssertEqual(Array(texts), ["{ n: 0 }", "{ n: 1 }", "{ n: 2 }"])
    }
}

private final class WrittenRows: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Int] = []
    var rows: [Int] { lock.withLock { stored } }
    func add(_ row: Int) { lock.withLock { stored.append(row) } }
}
