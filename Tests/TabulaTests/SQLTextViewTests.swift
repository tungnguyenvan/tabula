import AppKit
import XCTest

@testable import Tabula
@testable import TabulaSQL

/// The SQL editor's own editing commands, on a text view with no window.
@MainActor
final class SQLTextViewTests: XCTestCase {
    private func editor(_ text: String, selection: NSRange? = nil) -> SQLTextView {
        let view = SQLTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        view.dialect = SQLDialect(flavor: .postgres)
        view.isRichText = false
        view.allowsUndo = true
        view.string = text
        view.setSelectedRange(selection ?? NSRange(location: 0, length: 0))
        return view
    }

    func testCommentingLinesKeepsIndentationAndBlankLines() {
        let view = editor("SELECT 1\n\n    FROM t\n", selection: NSRange(location: 0, length: 20))
        view.toggleLineComments()
        XCTAssertEqual(view.string, "-- SELECT 1\n\n    -- FROM t\n")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 0, length: 26), "the lines stay selected")
        view.toggleLineComments()
        XCTAssertEqual(view.string, "SELECT 1\n\n    FROM t\n", "a second ⌘/ takes the comments off")
    }

    func testMixedLinesAreAllCommented() {
        let view = editor("-- SELECT 1\nSELECT 2", selection: NSRange(location: 0, length: 20))
        view.toggleLineComments()
        XCTAssertEqual(view.string, "-- -- SELECT 1\n-- SELECT 2")
    }

    func testUncommentingWithoutASpaceAndOnlyTheCaretLine() {
        let view = editor("--a\n--b\nSELECT 3", selection: NSRange(location: 1, length: 0))
        view.toggleLineComments()
        XCTAssertEqual(view.string, "a\n--b\nSELECT 3", "only the caret's line changes")
    }

    /// In the app the undo manager is the tab's; here the window's, grouped by hand as there is no run loop.
    func testCommentingCanBeUndone() throws {
        let view = editor("SELECT 1")
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = view
        let undo = try XCTUnwrap(view.undoManager)
        undo.groupsByEvent = false
        undo.beginUndoGrouping()
        view.toggleLineComments()
        undo.endUndoGrouping()
        XCTAssertEqual(view.string, "-- SELECT 1")
        undo.undo()
        XCTAssertEqual(view.string, "SELECT 1")
    }

    func testNewlineKeepsTheLinesIndentation() {
        let view = editor("SELECT\n\t  a,", selection: NSRange(location: 12, length: 0))
        view.insertNewline(nil)
        XCTAssertEqual(view.string, "SELECT\n\t  a,\n\t  ")
        XCTAssertEqual(view.selectedRange(), NSRange(location: 16, length: 0))
    }

    func testTabWithoutASuggestionInsertsATab() {
        let view = editor("SELECT", selection: NSRange(location: 6, length: 0))
        view.insertTab(nil)
        XCTAssertEqual(view.string, "SELECT\t")
    }
}
