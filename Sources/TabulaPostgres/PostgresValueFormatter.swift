import Foundation
import NIOCore
import TabulaDrivers
import TabulaFoundation
import TabulaSQL

/// Renders Postgres binary-format values as the same text psql would show.
enum PostgresValueFormatter {
    private static let epochOffset: TimeInterval = 946_684_800  // 2000-01-01 relative to 1970-01-01

    static func string(_ bytes: ByteBuffer?, oid: UInt32) -> String? {
        guard var buffer = bytes else { return nil }
        return format(&buffer, oid: oid)
    }

    private static func format(_ buffer: inout ByteBuffer, oid: UInt32) -> String {
        switch oid {
        case 16:  // bool
            return buffer.readInteger(as: UInt8.self) == 1 ? "true" : "false"
        case 21:  // int2
            return buffer.readInteger(as: Int16.self).map { String($0) } ?? ""
        case 23:  // int4
            return buffer.readInteger(as: Int32.self).map { String($0) } ?? ""
        case 20:  // int8
            return buffer.readInteger(as: Int64.self).map { String($0) } ?? ""
        case 26, 28, 24, 2202, 2205, 2206, 3734, 4089, 4096:  // oid, xid and reg* types
            return buffer.readInteger(as: UInt32.self).map { String($0) } ?? ""
        case 700:  // float4
            return buffer.readInteger(as: UInt32.self).map { "\(Float(bitPattern: $0))" } ?? ""
        case 701:  // float8
            return buffer.readInteger(as: UInt64.self).map { "\(Double(bitPattern: $0))" } ?? ""
        case 1700:
            return numeric(&buffer)
        case 790:  // money, in cents
            guard let cents = buffer.readInteger(as: Int64.self) else { return "" }
            let sign = cents < 0 ? "-" : ""
            let magnitude = cents.magnitude
            return String(format: "%@$%llu.%02llu", sign, magnitude / 100, magnitude % 100)
        case 2950:
            return uuid(&buffer)
        case 17:
            return "\\x" + hex(&buffer)
        case 3802:  // jsonb: one version byte, then JSON text
            buffer.moveReaderIndex(forwardBy: min(1, buffer.readableBytes))
            return buffer.readString(length: buffer.readableBytes) ?? ""
        case 1082:
            return date(&buffer)
        case 1083:
            return buffer.readInteger(as: Int64.self).map(timeOfDay) ?? ""
        case 1266:  // timetz: microseconds + zone offset in seconds west of UTC
            guard let micros = buffer.readInteger(as: Int64.self), let zone = buffer.readInteger(as: Int32.self) else {
                return ""
            }
            return timeOfDay(micros) + zoneSuffix(secondsEast: -Int(zone))
        case 1114:
            return timestamp(&buffer, withZone: false)
        case 1184:
            return timestamp(&buffer, withZone: true)
        case 1186:
            return interval(&buffer)
        case 869, 650:
            return inet(&buffer)
        case 829:  // macaddr
            return (buffer.readBytes(length: 6) ?? []).map { String(format: "%02x", $0) }.joined(separator: ":")
        case 600:  // point
            guard let x = buffer.readInteger(as: UInt64.self), let y = buffer.readInteger(as: UInt64.self) else {
                return ""
            }
            return "(\(Double(bitPattern: x)),\(Double(bitPattern: y)))"
        default:
            if let array = array(&buffer) {
                return array
            }
            // text, varchar, bpchar, name, json, xml, enums and most extension types are UTF-8 text in binary form.
            let readerIndex = buffer.readerIndex
            if let text = buffer.readString(length: buffer.readableBytes),
                !text.contains("\u{FFFD}"), !text.unicodeScalars.contains(where: { $0.value == 0 })
            {
                return text
            }
            buffer.moveReaderIndex(to: readerIndex)
            return "\\x" + hex(&buffer)
        }
    }

    private static func hex(_ buffer: inout ByteBuffer) -> String {
        (buffer.readBytes(length: buffer.readableBytes) ?? []).map { String(format: "%02x", $0) }.joined()
    }

    private static func uuid(_ buffer: inout ByteBuffer) -> String {
        guard let bytes = buffer.readBytes(length: 16) else { return "" }
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let parts = [
            hex.prefix(8), hex.dropFirst(8).prefix(4), hex.dropFirst(12).prefix(4), hex.dropFirst(16).prefix(4),
            hex.dropFirst(20),
        ]
        return parts.joined(separator: "-")
    }

    private static func numeric(_ buffer: inout ByteBuffer) -> String {
        guard let count = buffer.readInteger(as: Int16.self),
            let weight = buffer.readInteger(as: Int16.self),
            let sign = buffer.readInteger(as: UInt16.self),
            let scale = buffer.readInteger(as: Int16.self),
            count >= 0, weight < 10_000
        else { return "" }
        switch sign {
        case 0xC000: return "NaN"
        case 0xD000: return "Infinity"
        case 0xF000: return "-Infinity"
        default: break
        }
        var digits: [Int16] = []
        for _ in 0..<count {
            digits.append(buffer.readInteger(as: Int16.self) ?? 0)
        }

        var integerPart = ""
        if weight < 0 {
            integerPart = "0"
        } else {
            for index in 0...Int(weight) {
                let group = index < digits.count ? digits[index] : 0
                integerPart += index == 0 ? String(group) : String(format: "%04d", group)
            }
        }
        var fraction = ""
        if scale > 0 {
            var groupIndex = Int(weight) + 1
            while fraction.count < Int(scale) {
                let group: Int16 = groupIndex >= 0 && groupIndex < digits.count ? digits[groupIndex] : 0
                fraction += String(format: "%04d", group)
                groupIndex += 1
            }
            fraction = "." + fraction.prefix(Int(scale))
        }
        return (sign == 0x4000 ? "-" : "") + integerPart + fraction
    }

    /// Postgres counts dates from 2000-01-01.
    private static let epochDays = Int64(epochOffset) / CivilTime.secondsPerDay

    private static func date(_ buffer: inout ByteBuffer) -> String {
        guard let days = buffer.readInteger(as: Int32.self) else { return "" }
        if days == Int32.max {
            return "infinity"
        }
        if days == Int32.min {
            return "-infinity"
        }
        return CivilTime.dateText(days: epochDays + Int64(days))
    }

    private static func timestamp(_ buffer: inout ByteBuffer, withZone: Bool) -> String {
        guard let micros = buffer.readInteger(as: Int64.self) else { return "" }
        if micros == Int64.max {
            return "infinity"
        }
        if micros == Int64.min {
            return "-infinity"
        }
        let (seconds, remainder) = floorDivide(micros, 1_000_000)
        let text = CivilTime.dateTimeText(seconds: Int64(epochOffset) + seconds)
        return text + fractional(remainder) + (withZone ? "+00" : "")
    }

    private static func timeOfDay(_ micros: Int64) -> String {
        let (seconds, remainder) = floorDivide(micros, 1_000_000)
        return String(format: "%02lld:%02lld:%02lld", seconds / 3600, seconds / 60 % 60, seconds % 60)
            + fractional(remainder)
    }

    private static func fractional(_ micros: Int64) -> String {
        guard micros != 0 else { return "" }
        var text = String(format: "%06lld", micros)
        while text.hasSuffix("0") { text.removeLast() }
        return "." + text
    }

    private static func zoneSuffix(secondsEast: Int) -> String {
        let sign = secondsEast < 0 ? "-" : "+"
        let magnitude = abs(secondsEast)
        let hours = String(format: "%02d", magnitude / 3600)
        let minutes = magnitude / 60 % 60
        return sign + hours + (minutes == 0 ? "" : String(format: ":%02d", minutes))
    }

    private static func interval(_ buffer: inout ByteBuffer) -> String {
        guard let micros = buffer.readInteger(as: Int64.self),
            let days = buffer.readInteger(as: Int32.self),
            let months = buffer.readInteger(as: Int32.self)
        else { return "" }
        var parts: [String] = []
        let years = months / 12
        let remainingMonths = months % 12
        if years != 0 {
            parts.append("\(years) year\(years.magnitude == 1 ? "" : "s")")
        }
        if remainingMonths != 0 {
            parts.append("\(remainingMonths) mon\(remainingMonths.magnitude == 1 ? "" : "s")")
        }
        if days != 0 {
            parts.append("\(days) day\(days.magnitude == 1 ? "" : "s")")
        }
        if micros != 0 || parts.isEmpty {
            let sign = micros < 0 ? "-" : ""
            // Int64.min has no positive counterpart, so abs() would trap on it.
            let magnitude = micros.magnitude > UInt64(Int64.max) ? 0 : abs(micros)
            parts.append(sign + timeOfDay(magnitude))
        }
        return parts.joined(separator: " ")
    }

    private static func inet(_ buffer: inout ByteBuffer) -> String {
        // The address family comes first; the address length says the same, so it is skipped.
        guard buffer.readInteger(as: UInt8.self) != nil,
            let bits = buffer.readInteger(as: UInt8.self),
            let isCIDR = buffer.readInteger(as: UInt8.self),
            let length = buffer.readInteger(as: UInt8.self),
            let address = buffer.readBytes(length: Int(length))
        else { return "" }
        let text: String
        if address.count == 4 {
            text = address.map(String.init).joined(separator: ".")
        } else {
            var raw = in6_addr()
            withUnsafeMutableBytes(of: &raw) { $0.copyBytes(from: address.prefix(16)) }
            var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            inet_ntop(AF_INET6, &raw, &output, socklen_t(output.count))
            text = String(cString: output)
        }
        let full = address.count == 4 ? 32 : 128
        return (isCIDR == 1 || Int(bits) != full) ? "\(text)/\(bits)" : text
    }

    private static func array(_ buffer: inout ByteBuffer) -> String? {
        let start = buffer.readerIndex
        guard buffer.readableBytes >= 12,
            let dimensions = buffer.readInteger(as: Int32.self), (0...6).contains(dimensions),
            let flags = buffer.readInteger(as: Int32.self), flags == 0 || flags == 1,
            let elementOID = buffer.readInteger(as: UInt32.self)
        else {
            buffer.moveReaderIndex(to: start)
            return nil
        }
        if dimensions == 0 { return "{}" }
        var sizes: [Int] = []
        for _ in 0..<dimensions {
            guard let size = buffer.readInteger(as: Int32.self), size >= 0, buffer.readInteger(as: Int32.self) != nil
            else {
                buffer.moveReaderIndex(to: start)
                return nil
            }
            sizes.append(Int(size))
        }
        // Every element takes at least four bytes, which bounds a corrupt header.
        let total = sizes.reduce(1) { $0.multipliedReportingOverflow(by: $1).overflow ? Int.max : $0 * $1 }
        guard total <= buffer.readableBytes / 4 else {
            buffer.moveReaderIndex(to: start)
            return nil
        }
        var elements: [String] = []
        for _ in 0..<total {
            guard let length = buffer.readInteger(as: Int32.self) else {
                buffer.moveReaderIndex(to: start)
                return nil
            }
            if length < 0 {
                elements.append("NULL")
                continue
            }
            guard var slice = buffer.readSlice(length: Int(length)) else {
                buffer.moveReaderIndex(to: start)
                return nil
            }
            elements.append(quoteArrayElement(format(&slice, oid: elementOID)))
        }
        guard buffer.readableBytes == 0 else {
            buffer.moveReaderIndex(to: start)
            return nil
        }
        return nest(elements[...], sizes: sizes[...])
    }

    private static func nest(_ elements: ArraySlice<String>, sizes: ArraySlice<Int>) -> String {
        guard let size = sizes.first else {
            return elements.first ?? ""
        }
        let inner = sizes.dropFirst()
        let stride = inner.reduce(1, *)
        var groups: [String] = []
        for index in 0..<size {
            let lower = elements.startIndex + index * stride
            groups.append(inner.isEmpty ? elements[lower] : nest(elements[lower..<lower + stride], sizes: inner))
        }
        return "{" + groups.joined(separator: ",") + "}"
    }

    private static func quoteArrayElement(_ text: String) -> String {
        let needsQuotes =
            text.isEmpty || text.uppercased() == "NULL"
            || text.contains(where: { " ,{}\"\\".contains($0) || $0.isNewline })
        guard needsQuotes else {
            return text
        }
        return "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            + "\""
    }

    private static func floorDivide(_ value: Int64, _ divisor: Int64) -> (Int64, Int64) {
        var quotient = value / divisor
        var remainder = value % divisor
        if remainder < 0 {
            quotient -= 1
            remainder += divisor
        }
        return (quotient, remainder)
    }
}
