import Foundation
import NIOCore

/// tsvector and tsquery, written as PostgreSQL's output functions write them.
extension PostgresValueFormatter {
    /// `'lexeme':1A,2 'other'`: each lexeme quoted, with its positions and their weights (A–C; D is unwritten).
    static func tsvector(_ buffer: inout ByteBuffer) -> String? {
        let start = buffer.readerIndex
        guard let count = buffer.readInteger(as: Int32.self), count >= 0 else {
            buffer.moveReaderIndex(to: start)
            return nil
        }
        var lexemes: [String] = []
        for _ in 0..<count {
            guard let word = readCString(&buffer), let positionCount = buffer.readInteger(as: UInt16.self) else {
                buffer.moveReaderIndex(to: start)
                return nil
            }
            var text = quoteLexeme(word)
            var positions: [String] = []
            for _ in 0..<positionCount {
                guard let entry = buffer.readInteger(as: UInt16.self) else {
                    buffer.moveReaderIndex(to: start)
                    return nil
                }
                let weight = ["", "C", "B", "A"][Int(entry >> 14)]
                positions.append(String(entry & 0x3FFF) + weight)
            }
            if !positions.isEmpty {
                text += ":" + positions.joined(separator: ",")
            }
            lexemes.append(text)
        }
        guard buffer.readableBytes == 0 else {
            buffer.moveReaderIndex(to: start)
            return nil
        }
        return lexemes.joined(separator: " ")
    }

    /// One item of a tsquery: a lexeme, or an operator over the items after it.
    private indirect enum QueryItem {
        case lexeme(String, weight: UInt8, prefix: Bool)
        case not(QueryItem)
        case binary(op: UInt8, distance: Int16, left: QueryItem, right: QueryItem)
    }

    private enum QueryOperator {
        static let not: UInt8 = 1
        static let and: UInt8 = 2
        static let or: UInt8 = 3
        static let phrase: UInt8 = 4

        /// Binding strength, as the server orders them when it decides on parentheses.
        static func priority(_ op: UInt8) -> Int {
            switch op {
            case not: 4
            case phrase: 3
            case and: 2
            default: 1
            }
        }
    }

    /// `'fat' & ( 'rat' | 'cat:*' )`: the items arrive in prefix order, each operator followed by its right
    /// operand and then its left.
    static func tsquery(_ buffer: inout ByteBuffer) -> String? {
        let start = buffer.readerIndex
        guard let count = buffer.readInteger(as: Int32.self), count >= 0 else {
            buffer.moveReaderIndex(to: start)
            return nil
        }
        if count == 0 {
            return buffer.readableBytes == 0 ? "" : nil
        }
        var remaining = Int(count)
        func item() -> QueryItem? {
            guard remaining > 0, let kind = buffer.readInteger(as: UInt8.self) else { return nil }
            remaining -= 1
            switch kind {
            case 1:
                guard let weight = buffer.readInteger(as: UInt8.self), let prefix = buffer.readInteger(as: UInt8.self),
                    let word = readCString(&buffer)
                else { return nil }
                return .lexeme(word, weight: weight, prefix: prefix != 0)
            case 2:
                guard let op = buffer.readInteger(as: UInt8.self) else { return nil }
                if op == QueryOperator.not {
                    return item().map(QueryItem.not)
                }
                var distance: Int16 = 0
                if op == QueryOperator.phrase {
                    guard let read = buffer.readInteger(as: Int16.self) else { return nil }
                    distance = read
                }
                guard let right = item(), let left = item() else { return nil }
                return .binary(op: op, distance: distance, left: left, right: right)
            default:
                return nil
            }
        }
        guard let root = item(), remaining == 0, buffer.readableBytes == 0 else {
            buffer.moveReaderIndex(to: start)
            return nil
        }
        return infix(root, parentPriority: -1, rightOfPhrase: false)
    }

    private static func infix(_ item: QueryItem, parentPriority: Int, rightOfPhrase: Bool) -> String {
        switch item {
        case .lexeme(let word, let weight, let prefix):
            var text = quoteLexeme(word)
            let weights = [(UInt8(8), "A"), (4, "B"), (2, "C"), (1, "D")].filter { weight & $0.0 != 0 }.map(\.1)
            if prefix || !weights.isEmpty {
                text += ":" + (prefix ? "*" : "") + weights.joined()
            }
            return text
        case .not(let operand):
            let priority = QueryOperator.priority(QueryOperator.not)
            let inner = "!" + infix(operand, parentPriority: priority, rightOfPhrase: false)
            return priority < parentPriority ? "( " + inner + " )" : inner
        case .binary(let op, let distance, let left, let right):
            let priority = QueryOperator.priority(op)
            let isPhrase = op == QueryOperator.phrase
            let symbol: String
            switch op {
            case QueryOperator.and: symbol = "&"
            case QueryOperator.or: symbol = "|"
            default: symbol = distance == 1 ? "<->" : "<\(distance)>"
            }
            let rightText = infix(right, parentPriority: priority, rightOfPhrase: isPhrase)
            let leftText = infix(left, parentPriority: priority, rightOfPhrase: false)
            let inner = leftText + " " + symbol + " " + rightText
            return priority < parentPriority || (isPhrase && rightOfPhrase) ? "( " + inner + " )" : inner
        }
    }

    /// A lexeme in single quotes, with quotes and backslashes inside doubled.
    private static func quoteLexeme(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// A NUL-terminated UTF-8 string.
    private static func readCString(_ buffer: inout ByteBuffer) -> String? {
        guard let end = buffer.readableBytesView.firstIndex(of: 0),
            let text = buffer.readString(length: end - buffer.readerIndex)
        else { return nil }
        buffer.moveReaderIndex(forwardBy: 1)
        return text
    }
}
