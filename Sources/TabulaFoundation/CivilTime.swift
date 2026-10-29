import Foundation

/// UTC calendar arithmetic for writing and reading timestamps in grid cells.
///
/// Date formatters go through ICU and its locale data, which costs microseconds per value; a page of 5,000 rows
/// with a timestamp column spent most of its time there. These are the proleptic Gregorian calendar's integer
/// formulas (Howard Hinnant's days-from-civil), exact for every year the formats can show.
package enum CivilTime {
    package static let secondsPerDay: Int64 = 86_400

    package struct Day: Equatable {
        var year: Int64
        var month: Int64
        var day: Int64
    }

    /// The date `days` after 1970-01-01.
    package static func civil(fromDays days: Int64) -> Day {
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthIndex = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthIndex + 2) / 5 + 1
        let month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9
        return Day(year: yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month: month, day: day)
    }

    /// Days from 1970-01-01 to the date.
    package static func days(from date: Day) -> Int64 {
        let year = date.month <= 2 ? date.year - 1 : date.year
        let era = (year >= 0 ? year : year - 399) / 400
        let yearOfEra = year - era * 400
        let monthIndex = date.month > 2 ? date.month - 3 : date.month + 9
        let dayOfYear = (153 * monthIndex + 2) / 5 + date.day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    package static func floorDivide(_ value: Int64, _ divisor: Int64) -> (quotient: Int64, remainder: Int64) {
        let quotient = value >= 0 ? value / divisor : -((-value + divisor - 1) / divisor)
        return (quotient, value - quotient * divisor)
    }

    // MARK: Writing

    /// "2024-01-09".
    package static func dateText(days: Int64) -> String {
        let date = civil(fromDays: days)
        var text = ""
        text.reserveCapacity(10)
        appendDate(date, to: &text)
        return text
    }

    /// "2024-01-09 13:45:00" (Postgres style) or "2024-01-09T13:45:00" with `separator: "T"`.
    package static func dateTimeText(seconds: Int64, separator: Character = " ") -> String {
        let (days, secondOfDay) = floorDivide(seconds, secondsPerDay)
        var text = ""
        text.reserveCapacity(19)
        appendDate(civil(fromDays: days), to: &text)
        text.append(separator)
        appendTime(secondOfDay, to: &text)
        return text
    }

    /// "2024-01-09T13:45:00.000Z", as MongoDB and JavaScript write dates; nil outside years 1 to 9999.
    package static func isoText(milliseconds: Int64) -> String? {
        let (seconds, millisecond) = floorDivide(milliseconds, 1000)
        let (days, secondOfDay) = floorDivide(seconds, secondsPerDay)
        let date = civil(fromDays: days)
        guard (1...9999).contains(date.year) else { return nil }
        var text = ""
        text.reserveCapacity(24)
        appendDate(date, to: &text)
        text.append("T")
        appendTime(secondOfDay, to: &text)
        text.append(".")
        appendPadded(millisecond, width: 3, to: &text)
        text.append("Z")
        return text
    }

    private static func appendDate(_ date: Day, to text: inout String) {
        if date.year < 0 {
            text.append("-")
        }
        appendPadded(abs(date.year), width: 4, to: &text)
        text.append("-")
        appendPadded(date.month, width: 2, to: &text)
        text.append("-")
        appendPadded(date.day, width: 2, to: &text)
    }

    private static func appendTime(_ secondOfDay: Int64, to text: inout String) {
        appendPadded(secondOfDay / 3600, width: 2, to: &text)
        text.append(":")
        appendPadded(secondOfDay / 60 % 60, width: 2, to: &text)
        text.append(":")
        appendPadded(secondOfDay % 60, width: 2, to: &text)
    }

    package static func appendPadded(_ value: Int64, width: Int, to text: inout String) {
        let digits = String(value)
        if digits.count < width {
            text.append(String(repeating: "0", count: width - digits.count))
        }
        text.append(digits)
    }

    // MARK: Reading

    /// Milliseconds since 1970 for ISO 8601 text as the shell accepts it: a date, optionally with a time
    /// (`T` or a space), seconds, a fraction and a zone (`Z`, `+07:00`, `+0700`, `+07`); no zone means UTC.
    package static func milliseconds(iso text: String) -> Int64? {
        var scanner = Array(text.utf8)[...]
        func number(_ count: Int) -> Int64? {
            guard scanner.count >= count else { return nil }
            var value: Int64 = 0
            for byte in scanner.prefix(count) {
                guard byte >= 0x30 && byte <= 0x39 else { return nil }
                value = value * 10 + Int64(byte - 0x30)
            }
            scanner = scanner.dropFirst(count)
            return value
        }
        func take(_ character: Character) -> Bool {
            guard let ascii = character.asciiValue, scanner.first == ascii else { return false }
            scanner = scanner.dropFirst()
            return true
        }
        guard let year = number(4), take("-"), let month = number(2), take("-"), let day = number(2),
            (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        let date = Day(year: year, month: month, day: day)
        let dayNumber = days(from: date)
        // Rejects dates that don't exist, such as February 30.
        guard civil(fromDays: dayNumber) == date else { return nil }
        var milliseconds = dayNumber * secondsPerDay * 1000
        guard !scanner.isEmpty else { return milliseconds }

        guard take("T") || take(" "), let hour = number(2), take(":"), let minute = number(2), hour < 24, minute < 60
        else { return nil }
        var second: Int64 = 0
        if take(":") {
            guard let value = number(2), value < 61 else { return nil }
            second = value
        }
        milliseconds += ((hour * 60 + minute) * 60 + second) * 1000
        if take(".") || take(",") {
            var fraction: Int64 = 0
            var digits = 0
            while let byte = scanner.first, byte >= 0x30 && byte <= 0x39 {
                if digits < 3 {
                    fraction = fraction * 10 + Int64(byte - 0x30)
                    digits += 1
                }
                scanner = scanner.dropFirst()
            }
            guard digits > 0 else { return nil }
            while digits < 3 {
                fraction *= 10
                digits += 1
            }
            milliseconds += fraction
        }
        if take("Z") || take("z") || scanner.isEmpty {
            return scanner.isEmpty ? milliseconds : nil
        }
        let east: Int64
        if take("+") { east = 1 } else if take("-") { east = -1 } else { return nil }
        guard let zoneHours = number(2), zoneHours <= 18 else { return nil }
        var zoneMinutes: Int64 = 0
        _ = take(":")
        if !scanner.isEmpty {
            guard let value = number(2), value < 60 else { return nil }
            zoneMinutes = value
        }
        guard scanner.isEmpty else { return nil }
        return milliseconds - east * (zoneHours * 60 + zoneMinutes) * 60_000
    }
}
