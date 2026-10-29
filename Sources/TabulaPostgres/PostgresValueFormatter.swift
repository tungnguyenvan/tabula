import Foundation
import NIOCore
import TabulaDrivers
import TabulaFoundation
import TabulaSQL

/// Renders Postgres binary-format values as the same text psql would show, so a copied or exported value reads
/// back as the same value. One difference is deliberate: booleans are `true` / `false` rather than `t` / `f`.
///
/// Types without a decoder here whose bytes are UTF-8 text (text, varchar, enums, json, xml and most extension
/// types) show as that text; anything else shows as `\x` hex.
enum PostgresValueFormatter {
    private static let epochOffset: TimeInterval = 946_684_800  // 2000-01-01 relative to 1970-01-01

    static func string(_ bytes: ByteBuffer?, oid: UInt32) -> String? {
        guard var buffer = bytes else { return nil }
        return format(&buffer, oid: oid)
    }

    static func format(_ buffer: inout ByteBuffer, oid: UInt32) -> String {
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
        case 5069:  // xid8
            return buffer.readInteger(as: UInt64.self).map { String($0) } ?? ""
        case 700:  // float4
            return buffer.readInteger(as: UInt32.self).map { floatText(Float(bitPattern: $0), precision: 6) } ?? ""
        case 701:  // float8
            return float8(&buffer) ?? ""
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
        case 774:  // macaddr8
            return (buffer.readBytes(length: 8) ?? []).map { String(format: "%02x", $0) }.joined(separator: ":")
        case 1560, 1562:  // bit, varbit
            return bits(&buffer)
        case 27:  // tid: block, then the item in it
            guard let block = buffer.readInteger(as: UInt32.self), let item = buffer.readInteger(as: UInt16.self) else {
                return ""
            }
            return "(\(block),\(item))"
        case 3220:  // pg_lsn
            guard let lsn = buffer.readInteger(as: UInt64.self) else { return "" }
            return String(format: "%llX/%llX", lsn >> 32, lsn & 0xFFFF_FFFF)
        case 3614:
            return tsvector(&buffer) ?? fallback(&buffer)
        case 3615:
            return tsquery(&buffer) ?? fallback(&buffer)
        case 600, 601, 602, 603, 604, 628, 718:
            return geometry(&buffer, oid: oid) ?? fallback(&buffer)
        default:
            if let element = rangeElements[oid] {
                return range(&buffer, element: element) ?? fallback(&buffer)
            }
            if let element = multirangeElements[oid] {
                return multirange(&buffer, element: element) ?? fallback(&buffer)
            }
            if let array = array(&buffer) {
                return array
            }
            return fallback(&buffer)
        }
    }

    /// text, varchar, bpchar, name, json, xml, enums and most extension types are UTF-8 text in binary form;
    /// bytes that aren't text (invalid UTF-8, or NUL, which text can't hold) show as hex. Other control
    /// characters are text: catalog queries join names with chr(31).
    private static func fallback(_ buffer: inout ByteBuffer) -> String {
        let readerIndex = buffer.readerIndex
        if let text = buffer.readString(length: buffer.readableBytes),
            !text.contains("\u{FFFD}"), !text.unicodeScalars.contains(where: { $0.value == 0 })
        {
            return text
        }
        buffer.moveReaderIndex(to: readerIndex)
        return "\\x" + hex(&buffer)
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

    // MARK: Numbers

    static func float8(_ buffer: inout ByteBuffer) -> String? {
        buffer.readInteger(as: UInt64.self).map { floatText(Double(bitPattern: $0), precision: 15) }
    }

    /// A float as PostgreSQL writes it: the shortest digits that read back as the same value, with an exponent
    /// below 1e-4 and from 10^`precision` up (15 for float8, 6 for float4).
    static func floatText<Value: BinaryFloatingPoint & LosslessStringConvertible>(
        _ value: Value,
        precision: Int
    ) -> String {
        if value.isNaN {
            return "NaN"
        }
        let sign = value.sign == .minus ? "-" : ""
        if value.isInfinite {
            return sign + "Infinity"
        }
        // Swift's description is also the shortest round-trip form; only its layout differs.
        let description = value.magnitude.description
        var digits: String
        var exponent: Int
        if let e = description.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            let mantissa = description[..<e].split(separator: ".", omittingEmptySubsequences: false)
            guard let written = Int(description[description.index(after: e)...]) else {
                return sign + description
            }
            digits = mantissa.joined()
            exponent = written + mantissa[0].count - 1
        } else {
            let parts = description.split(separator: ".", omittingEmptySubsequences: false)
            let whole = parts.joined()
            guard let first = whole.firstIndex(where: { $0 != "0" }) else {
                return sign + "0"
            }
            exponent = parts[0].count - 1 - whole.distance(from: whole.startIndex, to: first)
            digits = String(whole[first...])
        }
        while digits.count > 1 && digits.hasSuffix("0") {
            digits.removeLast()
        }
        if exponent < -4 || exponent >= precision {
            var text = String(digits.prefix(1))
            if digits.count > 1 {
                text += "." + digits.dropFirst()
            }
            let magnitude = abs(exponent)
            return sign + text + "e" + (exponent < 0 ? "-" : "+") + (magnitude < 10 ? "0" : "") + String(magnitude)
        }
        if exponent < 0 {
            return sign + "0." + String(repeating: "0", count: -exponent - 1) + digits
        }
        if digits.count <= exponent + 1 {
            return sign + digits + String(repeating: "0", count: exponent + 1 - digits.count)
        }
        let point = digits.index(digits.startIndex, offsetBy: exponent + 1)
        return sign + digits[..<point] + "." + digits[point...]
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

    /// `bit` and `varbit`: the length in bits, then the bits, eight to a byte.
    private static func bits(_ buffer: inout ByteBuffer) -> String {
        guard let length = buffer.readInteger(as: Int32.self), length >= 0,
            let bytes = buffer.readBytes(length: (Int(length) + 7) / 8)
        else { return "" }
        var text = ""
        text.reserveCapacity(Int(length))
        for index in 0..<Int(length) {
            text.append(bytes[index / 8] & (0x80 >> UInt8(index % 8)) == 0 ? "0" : "1")
        }
        return text
    }

    // MARK: Dates and times

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
        let (text, era) = dateText(days: epochDays + Int64(days))
        return text + era
    }

    /// The date `days` after 1970-01-01, and " BC" for years before 1: PostgreSQL has no year 0, so 1 BC is
    /// year 0 of the proleptic calendar, 2 BC year -1.
    private static func dateText(days: Int64) -> (date: String, era: String) {
        let day = CivilTime.civil(fromDays: days)
        guard day.year < 1 else {
            return (CivilTime.dateText(days: days), "")
        }
        var text = ""
        CivilTime.appendPadded(1 - day.year, width: 4, to: &text)
        text.append("-")
        CivilTime.appendPadded(day.month, width: 2, to: &text)
        text.append("-")
        CivilTime.appendPadded(day.day, width: 2, to: &text)
        return (text, " BC")
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
        let (days, secondOfDay) = floorDivide(Int64(epochOffset) + seconds, CivilTime.secondsPerDay)
        let (date, era) = dateText(days: days)
        return date + " " + timeOfDay(secondOfDay * 1_000_000) + fractional(remainder) + (withZone ? "+00" : "") + era
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

    /// PostgreSQL's default interval style: each part with its own sign, and a "+" on a positive part that
    /// follows a negative one ("-1 days +02:00:00"); singular only for exactly 1.
    private static func interval(_ buffer: inout ByteBuffer) -> String {
        guard let micros = buffer.readInteger(as: Int64.self),
            let days = buffer.readInteger(as: Int32.self),
            let months = buffer.readInteger(as: Int32.self)
        else { return "" }
        var parts: [String] = []
        var afterNegative = false
        for (value, unit) in [(months / 12, "year"), (months % 12, "mon"), (days, "day")] where value != 0 {
            parts.append((afterNegative && value > 0 ? "+" : "") + "\(value) \(unit)" + (value == 1 ? "" : "s"))
            afterNegative = value < 0
        }
        if micros != 0 || parts.isEmpty {
            let sign = micros < 0 ? "-" : (afterNegative ? "+" : "")
            // Int64.min has no positive counterpart, so abs() would trap on it.
            let magnitude = micros.magnitude > UInt64(Int64.max) ? 0 : abs(micros)
            parts.append(sign + timeOfDay(magnitude))
        }
        return parts.joined(separator: " ")
    }

    // MARK: Network

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

    // MARK: Arrays

    private static func array(_ buffer: inout ByteBuffer) -> String? {
        let start = buffer.readerIndex
        // An element type is always named, which keeps other binary values that start with zeros from reading
        // as an empty array.
        guard buffer.readableBytes >= 12,
            let dimensions = buffer.readInteger(as: Int32.self), (0...6).contains(dimensions),
            let flags = buffer.readInteger(as: Int32.self), flags == 0 || flags == 1,
            let elementOID = buffer.readInteger(as: UInt32.self), elementOID != 0
        else {
            buffer.moveReaderIndex(to: start)
            return nil
        }
        if dimensions == 0 {
            guard buffer.readableBytes == 0 else {
                buffer.moveReaderIndex(to: start)
                return nil
            }
            return "{}"
        }
        var sizes: [Int] = []
        var lowerBounds: [Int] = []
        for _ in 0..<dimensions {
            guard let size = buffer.readInteger(as: Int32.self), size >= 0,
                let lowerBound = buffer.readInteger(as: Int32.self)
            else {
                buffer.moveReaderIndex(to: start)
                return nil
            }
            sizes.append(Int(size))
            lowerBounds.append(Int(lowerBound))
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
        // Bounds are written only when some dimension doesn't start at 1: "[0:1]={7,8}".
        let bounds =
            lowerBounds.allSatisfy { $0 == 1 }
            ? ""
            : zip(lowerBounds, sizes).map { "[\($0):\($0 + $1 - 1)]" }.joined() + "="
        return bounds + nest(elements[...], sizes: sizes[...])
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

    static func floorDivide(_ value: Int64, _ divisor: Int64) -> (Int64, Int64) {
        var quotient = value / divisor
        var remainder = value % divisor
        if remainder < 0 {
            quotient -= 1
            remainder += divisor
        }
        return (quotient, remainder)
    }
}
