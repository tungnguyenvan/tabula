import XCTest

@testable import TabulaFoundation
@testable import TabulaSQL
@testable import TabulaTransfer

/// CSV, TSV and JSON exports read back, by a strict reader, as the cells that were exported.
final class DelimitedExportRoundTripTests: XCTestCase {
    private let columns = ["id", "text", "bytes", "with,comma", "dup", "dup"]
    private let rows: [[String?]] = [
        ["1", "plain", "\\xdead00", "x", "a", "b"],
        ["2", "say \"hi\"\nnext line\r\ncrlf", nil, "", "tab\there", "semi;colon"],
        ["3", "  padded  ", "\\x", "comma, inside", "é😀", "=1+1"],
    ]

    /// RFC 4180 reading: quoted fields may hold the separator, quotes (doubled) and line breaks.
    private func read(_ text: String, separator: Character) -> [[String]] {
        var records: [[String]] = []
        var record: [String] = []
        var field = ""
        var quoted = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if quoted {
                if character == "\"" {
                    let next = text.index(after: index)
                    if next < text.endIndex, text[next] == "\"" {
                        field.append("\"")
                        index = next
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(character)
                }
            } else if character == "\"" {
                quoted = true
            } else if character == separator {
                record.append(field)
                field = ""
            } else if character == "\n" || character == "\r\n" {
                record.append(field)
                records.append(record)
                record = []
                field = ""
            } else {
                field.append(character)
            }
            index = text.index(after: index)
        }
        if !field.isEmpty || !record.isEmpty {
            record.append(field)
            records.append(record)
        }
        return records
    }

    func testCSVAndTSVReadBack() throws {
        for (format, separator) in [(ExportFormat.csv, Character(",")), (.tsv, "\t")] {
            let text = try ResultExporter.export(
                columns: columns,
                rows: rows,
                format: format,
                binaryColumns: [2],
                dialect: SQLDialect(flavor: .postgres)
            )
            let records = read(text, separator: separator)
            XCTAssertEqual(records.first, columns, "\(format)")
            // NULL and the empty string both export as an empty field, as CSV has no NULL.
            XCTAssertEqual(Array(records.dropFirst()), rows.map { $0.map { $0 ?? "" } }, "\(format)")
        }
    }

    func testJSONKeepsNullAndTellsDuplicateNamesApart() throws {
        let text = try ResultExporter.export(
            columns: columns,
            rows: rows,
            format: .json,
            binaryColumns: [2],
            dialect: SQLDialect(flavor: .postgres)
        )
        let objects = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]])
        XCTAssertEqual(objects.count, 3)
        XCTAssertTrue(objects[1]["bytes"] is NSNull)
        XCTAssertEqual(objects[1]["text"] as? String, "say \"hi\"\nnext line\r\ncrlf")
        XCTAssertEqual(objects[2]["with,comma"] as? String, "comma, inside")
        XCTAssertEqual(Set(objects[0].keys).count, 6, "both dup columns are kept, under different keys")
        XCTAssertEqual(Set(objects[0].values.compactMap { $0 as? String }).isSuperset(of: ["a", "b"]), true)
    }
}
