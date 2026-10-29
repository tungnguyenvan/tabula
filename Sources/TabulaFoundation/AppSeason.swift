import Foundation

/// Times of year when Tabula's icon dresses up.
public enum AppSeason: Equatable, Sendable {
    case regular
    case halloween

    /// A day of the year, as a month and a day of that month.
    public struct Day: Comparable, Sendable {
        public let month: Int
        public let day: Int

        public static func < (lhs: Day, rhs: Day) -> Bool {
            (lhs.month, lhs.day) < (rhs.month, rhs.day)
        }
    }

    /// The Halloween icon shows from 25 October to 1 November, both included.
    public static let halloweenStart = Day(month: 10, day: 25)
    public static let halloweenEnd = Day(month: 11, day: 1)

    /// Halloween is a Gregorian date, whichever calendar the user reads dates in; the day is the user's own.
    public static var userCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    /// The season of `date`, by `calendar`'s days (the user's time zone, Gregorian, by default).
    public static func on(_ date: Date, calendar: Calendar = userCalendar) -> AppSeason {
        let today = Day(month: calendar.component(.month, from: date), day: calendar.component(.day, from: date))
        if halloweenStart <= today && today <= halloweenEnd {
            return .halloween
        }
        return .regular
    }
}
