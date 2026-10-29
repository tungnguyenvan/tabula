import Foundation
import NIOCore

/// Ranges, multiranges and geometric values, written as PostgreSQL's output functions write them.
extension PostgresValueFormatter {
    /// The built-in range types and the type of their bounds.
    static let rangeElements: [UInt32: UInt32] = [
        3904: 23,  // int4range
        3926: 20,  // int8range
        3906: 1700,  // numrange
        3908: 1114,  // tsrange
        3910: 1184,  // tstzrange
        3912: 1082,  // daterange
    ]

    /// The built-in multirange types and the type of their ranges' bounds.
    static let multirangeElements: [UInt32: UInt32] = [
        4451: 23,  // int4multirange
        4536: 20,  // int8multirange
        4532: 1700,  // nummultirange
        4533: 1114,  // tsmultirange
        4534: 1184,  // tstzmultirange
        4535: 1082,  // datemultirange
    ]

    private enum RangeFlag {
        static let empty: UInt8 = 0x01
        static let lowerInclusive: UInt8 = 0x02
        static let upperInclusive: UInt8 = 0x04
        static let lowerInfinite: UInt8 = 0x08
        static let upperInfinite: UInt8 = 0x10
    }

    /// `[1,5)`, `(,10]` or `empty`: a flags byte, then each finite bound with its length.
    static func range(_ buffer: inout ByteBuffer, element: UInt32) -> String? {
        let start = buffer.readerIndex
        guard let flags = buffer.readInteger(as: UInt8.self) else {
            return nil
        }
        if flags & RangeFlag.empty != 0 {
            return buffer.readableBytes == 0 ? "empty" : nil
        }
        func bound(infinite: UInt8) -> String?? {
            guard flags & infinite == 0 else {
                return .some(nil)
            }
            guard let length = buffer.readInteger(as: Int32.self), length >= 0,
                var slice = buffer.readSlice(length: Int(length))
            else {
                return nil
            }
            return .some(quoteRangeBound(format(&slice, oid: element)))
        }
        guard let lower = bound(infinite: RangeFlag.lowerInfinite),
            let upper = bound(infinite: RangeFlag.upperInfinite)
        else {
            buffer.moveReaderIndex(to: start)
            return nil
        }
        return (flags & RangeFlag.lowerInclusive != 0 ? "[" : "(") + (lower ?? "") + "," + (upper ?? "")
            + (flags & RangeFlag.upperInclusive != 0 ? "]" : ")")
    }

    /// `{[1,2),[5,6)}`: the number of ranges, then each with its length.
    static func multirange(_ buffer: inout ByteBuffer, element: UInt32) -> String? {
        let start = buffer.readerIndex
        guard let count = buffer.readInteger(as: Int32.self), count >= 0 else {
            return nil
        }
        var ranges: [String] = []
        for _ in 0..<count {
            guard let length = buffer.readInteger(as: Int32.self), length >= 0,
                var slice = buffer.readSlice(length: Int(length)),
                let text = range(&slice, element: element)
            else {
                buffer.moveReaderIndex(to: start)
                return nil
            }
            ranges.append(text)
        }
        return "{" + ranges.joined(separator: ",") + "}"
    }

    /// A bound is quoted when it is empty or holds a character the range syntax uses, with quotes and backslashes
    /// doubled inside.
    private static func quoteRangeBound(_ text: String) -> String {
        let needsQuotes = text.isEmpty || text.contains(where: { "\"\\()[],".contains($0) || $0.isWhitespace })
        guard needsQuotes else {
            return text
        }
        return "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\"\"")
            + "\""
    }

    /// point, lseg, path, box, polygon, line and circle: float8 coordinates.
    static func geometry(_ buffer: inout ByteBuffer, oid: UInt32) -> String? {
        let start = buffer.readerIndex
        func number() -> String? { float8(&buffer) }
        func point() -> String? {
            guard let x = number(), let y = number() else { return nil }
            return "(\(x),\(y))"
        }
        func points(_ count: Int) -> [String]? {
            var list: [String] = []
            for _ in 0..<count {
                guard let next = point() else { return nil }
                list.append(next)
            }
            return list
        }
        let text: String?
        switch oid {
        case 600:  // point
            text = point()
        case 601:  // lseg
            text = points(2).map { "[" + $0.joined(separator: ",") + "]" }
        case 603:  // box: upper right corner, then lower left
            text = points(2).map { $0.joined(separator: ",") }
        case 602:  // path: closed flag, then the points
            guard let closed = buffer.readInteger(as: UInt8.self), let count = buffer.readInteger(as: Int32.self),
                count >= 0, Int(count) <= buffer.readableBytes / 16
            else {
                text = nil
                break
            }
            text = points(Int(count))
                .map { closed == 1 ? "(" + $0.joined(separator: ",") + ")" : "[" + $0.joined(separator: ",") + "]" }
        case 604:  // polygon
            guard let count = buffer.readInteger(as: Int32.self), count >= 0, Int(count) <= buffer.readableBytes / 16
            else {
                text = nil
                break
            }
            text = points(Int(count)).map { "(" + $0.joined(separator: ",") + ")" }
        case 628:  // line: Ax + By + C = 0
            guard let a = number(), let b = number(), let c = number() else {
                text = nil
                break
            }
            text = "{\(a),\(b),\(c)}"
        case 718:  // circle
            guard let center = point(), let radius = number() else {
                text = nil
                break
            }
            text = "<\(center),\(radius)>"
        default:
            text = nil
        }
        guard let text, buffer.readableBytes == 0 else {
            buffer.moveReaderIndex(to: start)
            return nil
        }
        return text
    }
}
