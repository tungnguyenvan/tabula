import Foundation
import TabulaDrivers
import TabulaFoundation
import TabulaSQL
import TabulaUpdates

/// The blocks of an answer: text, fenced code (which gets Insert / Run / Copy) and Markdown tables, which the
/// inline Markdown that renders the text would otherwise show as rows of pipes.
public enum ChatSegment: Equatable, Sendable {
    case text(String)
    case code(String)
    case table(MarkdownTable)

    public static func split(_ reply: String) -> [ChatSegment] {
        var segments: [ChatSegment] = []
        var rest = Substring(reply)
        while let open = rest.range(of: "```") {
            segments += textAndTables(rest[..<open.lowerBound])
            var body = rest[open.upperBound...]
            // Skip the language tag on the fence line.
            if let newline = body.firstIndex(of: "\n") { body = body[body.index(after: newline)...] }
            guard let close = body.range(of: "```") else {
                segments.append(.code(body.trimmingCharacters(in: .whitespacesAndNewlines)))
                return segments
            }
            let code = body[..<close.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            if !code.isEmpty { segments.append(.code(code)) }
            rest = body[close.upperBound...]
        }
        return segments + textAndTables(rest)
    }

    /// Text outside code fences, with each table (a header row, a separator row, then rows) taken out.
    private static func textAndTables(_ text: Substring) -> [ChatSegment] {
        let lines = text.components(separatedBy: "\n")
        var segments: [ChatSegment] = []
        var pending: [String] = []
        func flushText() {
            let joined = pending.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { segments.append(.text(joined)) }
            pending = []
        }
        var index = 0
        while index < lines.count {
            if index + 1 < lines.count, MarkdownTable.isRow(lines[index]),
               let alignments = MarkdownTable.separator(lines[index + 1]) {
                var rows: [[String]] = []
                var next = index + 2
                while next < lines.count, MarkdownTable.isRow(lines[next]) {
                    rows.append(MarkdownTable.cells(lines[next]))
                    next += 1
                }
                flushText()
                segments.append(.table(MarkdownTable(header: MarkdownTable.cells(lines[index]), alignments: alignments, rows: rows)))
                index = next
            } else {
                pending.append(lines[index])
                index += 1
            }
        }
        flushText()
        return segments
    }
}

/// A GitHub-style Markdown table. Every row has as many cells as the header.
public struct MarkdownTable: Equatable, Sendable {
    public enum Alignment: Equatable, Sendable { case leading, center, trailing }

    public var header: [String]
    public var alignments: [Alignment]
    public var rows: [[String]]

    public init(header: [String], alignments: [Alignment], rows: [[String]]) {
        let width = header.count
        func fitted<T>(_ values: [T], _ filler: T) -> [T] {
            Array(values.prefix(width)) + Array(repeating: filler, count: max(0, width - values.count))
        }
        self.header = header
        self.alignments = fitted(alignments, .leading)
        self.rows = rows.map { fitted($0, "") }
    }

    static func isRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("|") && trimmed.count > 1
    }

    /// The cells of a row; `\|` is a pipe inside a cell.
    static func cells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") && !trimmed.hasSuffix("\\|") { trimmed.removeLast() }
        var cells: [String] = []
        var cell = ""
        var escaped = false
        for character in trimmed {
            if escaped {
                cell.append(character == "|" ? "|" : "\\\(character)")
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(cell.trimmingCharacters(in: .whitespaces))
                cell = ""
            } else {
                cell.append(character)
            }
        }
        if escaped { cell.append("\\") }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        return cells
    }

    /// The column alignments when `line` is a separator row (`| --- | :---: | ---: |`); nil otherwise.
    static func separator(_ line: String) -> [Alignment]? {
        guard isRow(line) || line.contains("|") else { return nil }
        let cells = cells(line)
        var alignments: [Alignment] = []
        for cell in cells {
            let left = cell.hasPrefix(":"), right = cell.hasSuffix(":")
            let dashes = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            alignments.append(left && right ? .center : right ? .trailing : .leading)
        }
        return alignments.isEmpty ? nil : alignments
    }
}
