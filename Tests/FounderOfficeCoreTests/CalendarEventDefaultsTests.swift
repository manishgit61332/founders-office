import Foundation
import Testing
@testable import FounderOfficeCore

struct CalendarEventDefaultsTests {
    @Test
    func testTodayRoundsToTheNextLocalHalfHour() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 5 * 3_600 + 30 * 60))
        let now = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 31, hour: 10, minute: 8
        )))

        let suggested = CalendarEventDefaults.suggestedStart(
            for: now,
            now: now,
            calendar: calendar
        )

        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: suggested)
        #expect(parts.year == 2026)
        #expect(parts.month == 8)
        #expect(parts.day == 31)
        #expect(parts.hour == 10)
        #expect(parts.minute == 30)
    }

    @Test
    func testLateNightTodayNeverDefaultsToTomorrow() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 14 * 3_600))
        let now = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 31, hour: 23, minute: 47
        )))

        let suggested = CalendarEventDefaults.suggestedStart(
            for: now,
            now: now,
            calendar: calendar
        )

        #expect(calendar.isDate(suggested, inSameDayAs: now))
        #expect(suggested == now)
    }

    @Test
    func testFutureDayDefaultsToNineInThatCalendar() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: -12 * 3_600))
        let now = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 31, hour: 23, minute: 47
        )))
        let selected = try #require(calendar.date(byAdding: .day, value: 2, to: now))

        let suggested = CalendarEventDefaults.suggestedStart(
            for: selected,
            now: now,
            calendar: calendar
        )

        let parts = calendar.dateComponents([.day, .hour, .minute], from: suggested)
        #expect(parts.day == 2)
        #expect(parts.hour == 9)
        #expect(parts.minute == 0)
    }
}
