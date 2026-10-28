import XCTest
@testable import TabulaCore

final class ChatSegmentTests: XCTestCase {
    func testTextCodeAndTable() {
        let reply = """
            **paid** brings in the most revenue.

            | Status | Revenue | Orders |
            |---|---:|:---:|
            | paid | 169,981.33 | 667 |
            | pending | 167,160.33 | 667 |

            The query:
            ```sql
            SELECT 1;
            ```
            """
        XCTAssertEqual(ChatSegment.split(reply), [
            .text("**paid** brings in the most revenue."),
            .table(MarkdownTable(header: ["Status", "Revenue", "Orders"], alignments: [.leading, .trailing, .center],
                                 rows: [["paid", "169,981.33", "667"], ["pending", "167,160.33", "667"]])),
            .text("The query:"),
            .code("SELECT 1;"),
        ])
    }

    func testRowsAreFittedToTheHeader() {
        let table = "a | b\n--- | ---\n| 1 |\n| 1 | 2 | 3 |"
        // Rows without leading pipes aren't taken for a table, as many renderers do; ours needs them.
        XCTAssertEqual(ChatSegment.split(table), [.text(table)])

        let piped = "| a | b |\n| --- | --- |\n| 1 |\n| 1 | 2 | 3 |\n| x \\| y | `code` |"
        XCTAssertEqual(ChatSegment.split(piped), [
            .table(MarkdownTable(header: ["a", "b"], alignments: [.leading, .leading],
                                 rows: [["1", ""], ["1", "2"], ["x | y", "`code`"]])),
        ])
    }

    func testPipesThatArentTables() {
        // A row of pipes without a separator row is text; so is a pipe inside a code block.
        let text = "| not | a table |\nno separator"
        XCTAssertEqual(ChatSegment.split(text), [.text(text)])
        XCTAssertEqual(ChatSegment.split("```\n| a |\n|---|\n```"), [.code("| a |\n|---|")])
        // A table still streaming in (separator not yet arrived) shows as text until it has one.
        XCTAssertEqual(ChatSegment.split("Results:\n| a | b |"), [.text("Results:\n| a | b |")])
        XCTAssertEqual(ChatSegment.split("| a | b |\n|---|---|"), [
            .table(MarkdownTable(header: ["a", "b"], alignments: [.leading, .leading], rows: [])),
        ])
    }
}
