import XCTest

@testable import TabulaFoundation

final class AppSeasonTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Ho_Chi_Minh")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    func testHalloweenRunsFromTwentyFifthOfOctoberToFirstOfNovember() {
        XCTAssertEqual(AppSeason.on(date(2026, 10, 24, hour: 23), calendar: calendar), .regular)
        XCTAssertEqual(AppSeason.on(date(2026, 10, 25, hour: 0), calendar: calendar), .halloween)
        XCTAssertEqual(AppSeason.on(date(2026, 10, 31), calendar: calendar), .halloween)
        XCTAssertEqual(AppSeason.on(date(2026, 11, 1, hour: 23), calendar: calendar), .halloween)
        XCTAssertEqual(AppSeason.on(date(2026, 11, 2, hour: 0), calendar: calendar), .regular)
    }

    func testOtherDaysAreRegular() {
        XCTAssertEqual(AppSeason.on(date(2026, 1, 1), calendar: calendar), .regular)
        XCTAssertEqual(AppSeason.on(date(2026, 10, 1), calendar: calendar), .regular)
        XCTAssertEqual(AppSeason.on(date(2026, 12, 25), calendar: calendar), .regular)
    }

    /// The default calendar is Gregorian, even for a user who reads dates in another calendar.
    func testDefaultCalendarIsGregorian() {
        XCTAssertEqual(AppSeason.userCalendar.identifier, .gregorian)
        XCTAssertEqual(AppSeason.userCalendar.timeZone, .current)
    }

    /// The day is read in the calendar's time zone: the same instant can be Halloween in one place only.
    func testTheDayIsTheUsersLocalDay() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        // 2 November 00:30 in Ho Chi Minh City is still 1 November in UTC.
        let instant = date(2026, 11, 2, hour: 0).addingTimeInterval(30 * 60)
        XCTAssertEqual(AppSeason.on(instant, calendar: calendar), .regular)
        XCTAssertEqual(AppSeason.on(instant, calendar: utc), .halloween)
    }
}
