import AppKit
import XCTest

@testable import Tabula

/// How a grid cell shows its value and state, including when the table view reuses it for another row.
@MainActor
final class GridCellViewTests: XCTestCase {
    private func strikethrough(_ field: NSTextField) -> Bool {
        let text = field.attributedStringValue
        guard text.length > 0 else { return false }
        return text.attribute(.strikethroughStyle, at: 0, effectiveRange: nil) != nil
    }

    func testValuesNullAndDefault() throws {
        let cell = GridCellView(frame: .zero)
        let field = try XCTUnwrap(cell.textField)
        cell.configure(.value("line one\nline two\r\nthree\rfour\u{2028}five"), state: .normal)
        XCTAssertEqual(field.stringValue, "line one ⏎ line two ⏎ three ⏎ four ⏎ five", "every line break shows as ⏎")
        cell.configure(.null, state: .normal)
        XCTAssertEqual(field.stringValue, "NULL")
        XCTAssertEqual(field.textColor, .tertiaryLabelColor)
        cell.configure(.defaultValue, state: .inserted)
        XCTAssertEqual(field.stringValue, "DEFAULT")
        XCTAssertNotNil(cell.layer?.backgroundColor, "a new row is tinted")
    }

    func testLongValuesAreCutWithATooltip() throws {
        let cell = GridCellView(frame: .zero)
        let field = try XCTUnwrap(cell.textField)
        cell.configure(.value(String(repeating: "x", count: 3000)), state: .normal)
        XCTAssertEqual(field.stringValue.count, 2001)
        XCTAssertTrue(field.stringValue.hasSuffix("…"))
        XCTAssertEqual(field.toolTip?.count, 1000)
        cell.configure(.value("short"), state: .normal)
        XCTAssertNil(field.toolTip)
    }

    /// A cell drawn for a deleted row and then reused for another must not stay struck through or tinted.
    func testReuseClearsTheDeletedLook() throws {
        let cell = GridCellView(frame: .zero)
        let field = try XCTUnwrap(cell.textField)
        cell.configure(.value("gone"), state: .deleted)
        XCTAssertTrue(strikethrough(field))
        XCTAssertNotNil(cell.layer?.backgroundColor)
        cell.configure(.value("kept"), state: .normal)
        XCTAssertEqual(field.stringValue, "kept")
        XCTAssertFalse(strikethrough(field))
        XCTAssertNil(cell.layer?.backgroundColor)
        cell.configure(.null, state: .normal)
        XCTAssertFalse(strikethrough(field))
    }
}

final class SidebarGroupsTests: XCTestCase {
    func testCollapsingIsRememberedAndFilteringShowsEverything() {
        XCTAssertFalse(SidebarGroups("").isCollapsed(.tables))
        let views = SidebarGroups("").toggling(.views)
        XCTAssertEqual(views, "views")
        let both = SidebarGroups(views).toggling(.tables)
        XCTAssertEqual(both, "tables,views", "stored in a steady order")
        XCTAssertTrue(SidebarGroups(both).isCollapsed(.tables))
        XCTAssertFalse(SidebarGroups(both).isExpanded(.tables, filtering: false))
        XCTAssertTrue(SidebarGroups(both).isExpanded(.tables, filtering: true), "a filter shows every group")
        XCTAssertEqual(SidebarGroups(both).toggling(.tables), "views")
        // A name this version doesn't know (or a stray comma) changes nothing.
        XCTAssertFalse(SidebarGroups(",future,").isCollapsed(.functions))
        XCTAssertEqual(SidebarGroups("future").toggling(.triggers), "future,triggers")
    }
}
