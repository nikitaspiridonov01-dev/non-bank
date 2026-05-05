import XCTest
@testable import non_bank

final class RepeatIntervalTests: XCTestCase {

    private var calendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    // MARK: - Daily

    func testDaily_nextOccurrence_returnsNextDay() {
        let interval = RepeatInterval.daily(hour: 9, minute: 30)
        // "now" is 2024-06-15 10:00 UTC → already past 09:30 today → next = tomorrow 09:30
        let now = makeDate(year: 2024, month: 6, day: 15, hour: 10, minute: 0)
        let next = interval.nextOccurrence(after: now, calendar: calendar)

        XCTAssertNotNil(next)
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: next!)
        XCTAssertEqual(comps.day, 16)
        XCTAssertEqual(comps.hour, 9)
        XCTAssertEqual(comps.minute, 30)
    }

    func testDaily_nextOccurrence_sameDayIfBeforeTime() {
        let interval = RepeatInterval.daily(hour: 14, minute: 0)
        let now = makeDate(year: 2024, month: 6, day: 15, hour: 10, minute: 0)
        let next = interval.nextOccurrence(after: now, calendar: calendar)

        XCTAssertNotNil(next)
        let comps = calendar.dateComponents([.day, .hour], from: next!)
        XCTAssertEqual(comps.day, 15)
        XCTAssertEqual(comps.hour, 14)
    }

    // MARK: - Weekly

    func testWeekly_nextOccurrence_findsCorrectDay() {
        // Every Monday and Wednesday at 08:00
        let interval = RepeatInterval.weekly(hour: 8, minute: 0, daysOfWeek: [.monday, .wednesday])
        // 2024-06-15 is Saturday
        let now = makeDate(year: 2024, month: 6, day: 15, hour: 10, minute: 0)
        let next = interval.nextOccurrence(after: now, calendar: calendar)

        XCTAssertNotNil(next)
        let weekday = calendar.component(.weekday, from: next!)
        // Monday = 2 in Gregorian calendar
        XCTAssertEqual(weekday, 2) // Should be next Monday (June 17)
    }

    // MARK: - Monthly

    func testMonthly_nextOccurrence_findsCorrectDayOfMonth() {
        let interval = RepeatInterval.monthly(hour: 10, minute: 0, daysOfMonth: [1, 15])
        // Now is June 15 at 11:00 → already past 10:00 on the 15th → next = July 1
        let now = makeDate(year: 2024, month: 6, day: 15, hour: 11, minute: 0)
        let next = interval.nextOccurrence(after: now, calendar: calendar)

        XCTAssertNotNil(next)
        let comps = calendar.dateComponents([.month, .day, .hour], from: next!)
        XCTAssertEqual(comps.month, 7)
        XCTAssertEqual(comps.day, 1)
        XCTAssertEqual(comps.hour, 10)
    }

    // MARK: - Yearly

    func testYearly_nextOccurrence() {
        let interval = RepeatInterval.yearly(hour: 12, minute: 0, month: .december, dayOfMonth: 25)
        let now = makeDate(year: 2024, month: 6, day: 15, hour: 10, minute: 0)
        let next = interval.nextOccurrence(after: now, calendar: calendar)

        XCTAssertNotNil(next)
        let comps = calendar.dateComponents([.year, .month, .day, .hour], from: next!)
        XCTAssertEqual(comps.year, 2024)
        XCTAssertEqual(comps.month, 12)
        XCTAssertEqual(comps.day, 25)
        XCTAssertEqual(comps.hour, 12)
    }

    func testYearly_nextOccurrence_rollsToNextYear() {
        let interval = RepeatInterval.yearly(hour: 12, minute: 0, month: .january, dayOfMonth: 1)
        let now = makeDate(year: 2024, month: 6, day: 15, hour: 10, minute: 0)
        let next = interval.nextOccurrence(after: now, calendar: calendar)

        XCTAssertNotNil(next)
        let comps = calendar.dateComponents([.year, .month, .day], from: next!)
        XCTAssertEqual(comps.year, 2025)
        XCTAssertEqual(comps.month, 1)
        XCTAssertEqual(comps.day, 1)
    }

    // MARK: - Display Label

    func testDisplayLabel_daily() {
        let interval = RepeatInterval.daily(hour: 9, minute: 0)
        XCTAssertEqual(interval.displayLabel, "Every day at 09:00")
    }

    func testDisplayLabel_weekly() {
        let interval = RepeatInterval.weekly(hour: 10, minute: 30, daysOfWeek: [.monday, .friday])
        let label = interval.displayLabel
        XCTAssertTrue(label.contains("Weekly"))
        XCTAssertTrue(label.contains("Mon"))
        XCTAssertTrue(label.contains("Fri"))
        XCTAssertTrue(label.contains("10:30"))
    }

    func testDisplayLabel_monthly() {
        let interval = RepeatInterval.monthly(hour: 8, minute: 0, daysOfMonth: [1, 15])
        let label = interval.displayLabel
        XCTAssertTrue(label.contains("Monthly"))
        XCTAssertTrue(label.contains("1"))
        XCTAssertTrue(label.contains("15"))
        XCTAssertTrue(label.contains("08:00"))
    }

    func testDisplayLabel_yearly() {
        let interval = RepeatInterval.yearly(hour: 12, minute: 0, month: .december, dayOfMonth: 25)
        let label = interval.displayLabel
        XCTAssertTrue(label.contains("Yearly"))
        XCTAssertTrue(label.contains("Dec"))
        XCTAssertTrue(label.contains("25"))
        XCTAssertTrue(label.contains("12:00"))
    }

    // MARK: - Codable

    func testCodable_roundtrip() throws {
        let intervals: [RepeatInterval] = [
            .daily(hour: 9, minute: 0),
            .weekly(hour: 10, minute: 30, daysOfWeek: [.monday, .wednesday]),
            .monthly(hour: 8, minute: 0, daysOfMonth: [1, 15]),
            .yearly(hour: 12, minute: 0, month: .december, dayOfMonth: 25),
        ]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for original in intervals {
            let data = try encoder.encode(original)
            let decoded = try decoder.decode(RepeatInterval.self, from: data)
            XCTAssertEqual(decoded, original)
        }
    }

    // MARK: - Helpers

    private func makeDate(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = hour
        comps.minute = minute
        comps.timeZone = TimeZone(identifier: "UTC")
        return calendar.date(from: comps)!
    }
}
