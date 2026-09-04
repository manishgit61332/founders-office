import Foundation
import Testing
@testable import FounderOfficeCore

struct PlanningDateTests {
    @Test
    func testLegacyLocalPickerInstantCanMigrateWithoutChangingItsSelectedDay() throws {
        var india = Calendar(identifier: .gregorian)
        india.timeZone = try #require(TimeZone(identifier: "Asia/Kolkata"))
        let legacyInstant = try TestFixtures.calendarDate(
            2026,
            9,
            1,
            hour: 0,
            minute: 15,
            calendar: india
        )

        #expect(!PlanningDate.isCanonicalStoredDate(legacyInstant))
        let migrated = PlanningDate.storedDate(fromLocal: legacyInstant, calendar: india)
        #expect(PlanningDate.isCanonicalStoredDate(migrated))
        #expect(PlanningDate.day(fromStored: migrated) == PlanningDay(year: 2026, month: 9, day: 1))
    }

    @Test
    func testLocalSelectionRoundTripsWithoutDayDriftAtExtremeOffsets() throws {
        let expectedDay = try #require(PlanningDay(year: 2026, month: 9, day: 1))
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.locale = Locale(identifier: "en_US_POSIX")
        utcCalendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let expectedStoredDate = try TestFixtures.calendarDate(
            expectedDay.year,
            expectedDay.month,
            expectedDay.day,
            hour: 12,
            calendar: utcCalendar
        )

        for offset in [-12 * 3_600, 14 * 3_600] {
            var localCalendar = Calendar(identifier: .gregorian)
            localCalendar.locale = Locale(identifier: "en_US_POSIX")
            localCalendar.timeZone = try #require(TimeZone(secondsFromGMT: offset))
            let selectedDate = try TestFixtures.calendarDate(
                expectedDay.year,
                expectedDay.month,
                expectedDay.day,
                hour: 8,
                calendar: localCalendar
            )

            let storedDate = PlanningDate.storedDate(
                fromLocal: selectedDate,
                calendar: localCalendar
            )
            let displayedDate = PlanningDate.localDate(
                fromStored: storedDate,
                calendar: localCalendar
            )

            #expect(storedDate == expectedStoredDate)
            #expect(PlanningDate.day(fromStored: storedDate) == expectedDay)
            #expect(
                PlanningDate.day(fromLocal: displayedDate, calendar: localCalendar) == expectedDay
            )
            #expect(
                PlanningDate.storedDate(fromLocal: displayedDate, calendar: localCalendar)
                    == storedDate
            )
        }
    }

    @Test
    func testExistingCanonicalNoonUTCDateRemainsCanonical() throws {
        let day = try #require(PlanningDay(year: 2026, month: 9, day: 12))
        let existing = PlanningDate.storedDate(for: day)

        for offset in [-12 * 3_600, 14 * 3_600] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try #require(TimeZone(secondsFromGMT: offset))
            let localDate = PlanningDate.localDate(fromStored: existing, calendar: calendar)

            #expect(PlanningDate.storedDate(fromLocal: localDate, calendar: calendar) == existing)
        }
    }

    @Test
    func testLegacyTimestampUsesItsUTCCalendarDay() throws {
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.locale = Locale(identifier: "en_US_POSIX")
        utcCalendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let legacyMidnight = try TestFixtures.calendarDate(
            2026,
            9,
            12,
            calendar: utcCalendar
        )
        let expectedDay = try #require(PlanningDay(year: 2026, month: 9, day: 12))

        #expect(PlanningDate.day(fromStored: legacyMidnight) == expectedDay)
        #expect(
            PlanningDate.storedDate(for: PlanningDate.day(fromStored: legacyMidnight))
                == PlanningDate.storedDate(for: expectedDay)
        )
    }

    @Test
    func testPlanningDayRejectsInvalidGregorianDates() {
        #expect(PlanningDay(year: 2026, month: 2, day: 29) == nil)
        #expect(PlanningDay(year: 2024, month: 2, day: 29) != nil)
    }
}
