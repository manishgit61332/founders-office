import Foundation
import Testing
@testable import FounderOfficeCore

struct CalendarEventPresentationTests {
    private struct Event: Equatable {
        var id: String
        var start: Date
        var end: Date
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
        let event = Event(id: "all-day", start: dayStart, end: dayEnd)
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

    private func upNext(from events: [Event], at date: Date) -> Event? {
        CalendarEventPresentation.upNext(
            from: events,
            at: date,
            startDate: \.start,
            endDate: \.end
        )
    }
}
