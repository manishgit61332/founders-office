import Foundation
import Testing
@testable import FounderOfficeCore

struct CalendarEventPresentationTests {
    private struct Event: Equatable {
        var id: String
        var start: Date
        var end: Date
        var kind: CalendarEventPresentation.Kind = .timed
    }

    @Test
    func finishedTimedEventNeverRemainsUpNext() {
        let now = Date(timeIntervalSince1970: 20_000)
        let finished = Event(id: "finished", start: now - 3_600, end: now - 1_800)
        let future = Event(id: "future", start: now + 900, end: now + 2_700)

        #expect(upNext(from: [finished, future], at: now) == future)
        #expect(upNext(from: [finished], at: now) == nil)
    }

    @Test
    func eventEndingExactlyNowIsFinished() {
        let now = Date(timeIntervalSince1970: 30_000)
        let endingNow = Event(id: "ending-now", start: now - 600, end: now)

        #expect(upNext(from: [endingNow], at: now) == nil)
    }

    @Test
    func ongoingEventPrecedesAFutureEvent() {
        let now = Date(timeIntervalSince1970: 40_000)
        let future = Event(id: "future", start: now + 300, end: now + 1_200)
        let ongoing = Event(id: "ongoing", start: now - 300, end: now + 600)

        // Selection is deterministic even if the provider's input is not sorted.
        #expect(upNext(from: [future, ongoing], at: now) == ongoing)
    }

    @Test
    func currentAllDayEventRemainsUntilItsExclusiveEnd() throws {
        var kolkata = Calendar(identifier: .gregorian)
        kolkata.timeZone = try #require(TimeZone(identifier: "Asia/Kolkata"))
        let dayStart = try #require(kolkata.date(from: DateComponents(year: 2026, month: 9, day: 1)))
        let dayEnd = try #require(kolkata.date(byAdding: .day, value: 1, to: dayStart))
        let event = Event(id: "all-day", start: dayStart, end: dayEnd, kind: .allDay)
        let evening = try #require(kolkata.date(bySettingHour: 20, minute: 0, second: 0, of: dayStart))

        #expect(upNext(from: [event], at: evening) == event)
        #expect(upNext(from: [event], at: dayEnd) == nil)
    }

    @Test
    func earliestUnfinishedEventWinsWithUnsortedInput() throws {
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let now = try #require(
            losAngeles.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 1, minute: 45))
        )
        let later = Event(id: "later", start: now + 7_200, end: now + 9_000)
        let sooner = Event(id: "sooner", start: now + 1_800, end: now + 3_600)

        #expect(upNext(from: [later, sooner], at: now) == sooner)
    }

    @Test
    func overnightEventRemainsUntilItsEndOnTheFollowingDay() throws {
        var kolkata = Calendar(identifier: .gregorian)
        kolkata.timeZone = try #require(TimeZone(identifier: "Asia/Kolkata"))
        let start = try #require(
            kolkata.date(from: DateComponents(year: 2026, month: 9, day: 1, hour: 23, minute: 30))
        )
        let end = try #require(
            kolkata.date(from: DateComponents(year: 2026, month: 9, day: 2, hour: 0, minute: 30))
        )
        let during = try #require(
            kolkata.date(from: DateComponents(year: 2026, month: 9, day: 2, hour: 0, minute: 15))
        )
        let event = Event(id: "overnight", start: start, end: end)

        #expect(upNext(from: [event], at: during) == event)
        #expect(upNext(from: [event], at: end) == nil)
    }

    @Test
    func repeatedDSTClockHourUsesAbsoluteInstants() throws {
        let formatter = ISO8601DateFormatter()
        let start = try #require(formatter.date(from: "2026-11-01T01:30:00-07:00"))
        let duringRepeatedHour = try #require(formatter.date(from: "2026-11-01T01:15:00-08:00"))
        let end = try #require(formatter.date(from: "2026-11-01T01:30:00-08:00"))
        let event = Event(id: "dst-fallback", start: start, end: end)

        #expect(upNext(from: [event], at: duringRepeatedHour) == event)
        #expect(upNext(from: [event], at: end) == nil)
    }

    @Test
    func publicHolidayCannotDisplacePersonalEvents() {
        let now = Date(timeIntervalSince1970: 1_788_523_200)
        let holiday = Event(id: "holiday", start: now - 3_600, end: now + 43_200, kind: .calendarNotice)
        let later = Event(id: "later", start: now + 7_200, end: now + 10_800)
        let sooner = Event(id: "sooner", start: now + 600, end: now + 1_800)

        #expect(upNext(from: [holiday, later, sooner], at: now) == sooner)
        #expect(upNext(from: [sooner, holiday, later], at: now) == sooner)
        #expect(upNext(from: [holiday, later, sooner], at: now + 1_800) == later)
    }

    @Test
    func holidayIsFallbackEvenWhenNextCommitmentIsTomorrow() {
        let now = Date(timeIntervalSince1970: 1_788_523_200)
        let holiday = Event(id: "holiday", start: now - 3_600, end: now + 43_200, kind: .calendarNotice)
        let tomorrow = Event(id: "tomorrow", start: now + 86_400, end: now + 90_000)

        #expect(upNext(from: [holiday, tomorrow], at: now) == tomorrow)
    }

    @Test
    func fallbackNoticesStillExpireAndSortByTime() {
        let now = Date(timeIntervalSince1970: 1_788_523_200)
        let finished = Event(id: "finished", start: now - 86_400, end: now, kind: .calendarNotice)
        let current = Event(id: "current", start: now - 3_600, end: now + 43_200, kind: .calendarNotice)
        let future = Event(id: "future", start: now + 86_400, end: now + 172_800, kind: .calendarNotice)

        #expect(upNext(from: [future, finished, current], at: now) == current)
        #expect(upNext(from: [finished, current], at: current.end) == nil)
    }

    @Test
    func timedCommitmentsWinWithinTodayButAllDayTodayBeatsTomorrow() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Kolkata"))
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 4)))
        let end = try #require(calendar.date(byAdding: .day, value: 1, to: start))
        let now = start + 12 * 3_600
        let personal = Event(id: "personal-all-day", start: start, end: end, kind: .allDay)
        let notice = Event(id: "notice", start: start, end: end, kind: .calendarNotice)
        let ongoing = Event(id: "ongoing", start: now - 300, end: now + 600)
        let tonight = Event(id: "tonight", start: start + 23 * 3_600, end: end)
        let tomorrow = Event(id: "tomorrow", start: end + 3_600, end: end + 7_200)

        #expect(upNext(from: [personal, notice, tomorrow, tonight, ongoing], at: now, calendar: calendar) == ongoing)
        #expect(upNext(from: [personal, notice, tomorrow, tonight], at: now, calendar: calendar) == tonight)
        #expect(upNext(from: [notice, tomorrow, personal], at: now, calendar: calendar) == personal)
        #expect(upNext(from: [notice, tomorrow, personal], at: end, calendar: calendar) == tomorrow)
    }

    @Test
    func personalAllDayRemainsRelevantAcrossShortDSTDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8)))
        let end = try #require(calendar.date(byAdding: .day, value: 1, to: start))
        #expect(end.timeIntervalSince(start) == 23 * 3_600)
        let personal = Event(id: "all-day", start: start, end: end, kind: .allDay)
        let tomorrow = Event(id: "tomorrow", start: end + 900, end: end + 1_800)

        #expect(upNext(from: [tomorrow, personal], at: end - 600, calendar: calendar) == personal)
        #expect(upNext(from: [tomorrow, personal], at: end, calendar: calendar) == tomorrow)
    }

    @Test
    func equalTimesUseEndThenStableInputOrder() {
        let now = Date(timeIntervalSince1970: 1_788_523_200)
        let short = Event(id: "short", start: now, end: now + 300)
        let long = Event(id: "long", start: now, end: now + 600)
        let tie = Event(id: "tie", start: now, end: now + 300)
        #expect(upNext(from: [long, short, tie], at: now) == short)
        #expect(upNext(from: [long, tie, short], at: now) == tie)
        #expect(upNext(from: [], at: now) == nil)
    }

    @Test("Timed events remain commitments even on read-only calendars", arguments: [false, true])
    func timedReferenceCalendarsAreNotMistakenForHolidays(involvesCurrentUser: Bool) {
        #expect(CalendarEventPresentation.kind(
            isAllDay: false,
            isReferenceCalendar: true,
            involvesCurrentUser: involvesCurrentUser
        ) == .timed)
    }

    @Test
    func allDayClassificationPreservesPersonalAndInvitedEvents() {
        #expect(CalendarEventPresentation.kind(
            isAllDay: true, isReferenceCalendar: true, involvesCurrentUser: false
        ) == .calendarNotice)
        #expect(CalendarEventPresentation.kind(
            isAllDay: true, isReferenceCalendar: true, involvesCurrentUser: true
        ) == .allDay)
        #expect(CalendarEventPresentation.kind(
            isAllDay: true, isReferenceCalendar: false, involvesCurrentUser: false
        ) == .allDay)
    }

    private func upNext(from events: [Event], at date: Date, calendar: Calendar = .current) -> Event? {
        CalendarEventPresentation.upNext(
            from: events,
            at: date,
            startDate: \.start,
            endDate: \.end,
            kind: \.kind,
            calendar: calendar
        )
    }
}
