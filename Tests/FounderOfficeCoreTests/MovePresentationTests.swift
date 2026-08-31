import Foundation
import Testing
@testable import FounderOfficeCore

struct MovePresentationTests {
    @Test
    func testDeadlineAndHistoryBucketsUseCalendarDaysAcrossDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let now = try TestFixtures.calendarDate(2026, 3, 9, hour: 12, calendar: calendar)
        let yesterday = try TestFixtures.calendarDate(2026, 3, 8, hour: 12, calendar: calendar)
        let beforeToday = try TestFixtures.calendarDate(2026, 3, 8, hour: 23, minute: 59, calendar: calendar)
        let today = try TestFixtures.calendarDate(2026, 3, 9, hour: 8, calendar: calendar)
        let tomorrow = try TestFixtures.calendarDate(2026, 3, 10, calendar: calendar)
        let oldCompletion = try TestFixtures.calendarDate(2026, 3, 7, hour: 23, minute: 59, calendar: calendar)

        let presentation = MovePresentation(
            items: [
                TestFixtures.loop(
                    title: "Overdue",
                    dueAt: PlanningDate.storedDate(fromLocal: beforeToday, calendar: calendar)
                ),
                TestFixtures.loop(
                    title: "Today",
                    dueAt: PlanningDate.storedDate(fromLocal: today, calendar: calendar)
                ),
                TestFixtures.loop(
                    title: "Upcoming",
                    dueAt: PlanningDate.storedDate(fromLocal: tomorrow, calendar: calendar)
                ),
                TestFixtures.loop(title: "Undated"),
                TestFixtures.loop(status: .done, completedAt: yesterday),
                TestFixtures.loop(status: .done, completedAt: oldCompletion)
            ],
            now: now,
            calendar: calendar
        )

        let expectedBuckets: [ActiveDeadlineBucket] = [.overdue, .today, .upcoming, .noDeadline]
        #expect(presentation.activeGroups.map { $0.bucket } == expectedBuckets)
        #expect(presentation.recentCompleted.count == 1)
        #expect(presentation.olderCompleted.count == 1)
    }

    @Test
    func testDeadlineBucketsCompareStoredDaysWithLocalDaysAtExtremeOffsets() throws {
        let overdueDay = try #require(PlanningDay(year: 2026, month: 8, day: 31))
        let todayDay = try #require(PlanningDay(year: 2026, month: 9, day: 1))
        let upcomingDay = try #require(PlanningDay(year: 2026, month: 9, day: 2))

        for offset in [-12 * 3_600, 14 * 3_600] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.locale = Locale(identifier: "en_US_POSIX")
            calendar.timeZone = try #require(TimeZone(secondsFromGMT: offset))
            let now = try TestFixtures.calendarDate(
                todayDay.year,
                todayDay.month,
                todayDay.day,
                hour: 9,
                calendar: calendar
            )

            let presentation = MovePresentation(
                items: [
                    TestFixtures.loop(
                        title: "Overdue",
                        dueAt: PlanningDate.storedDate(for: overdueDay)
                    ),
                    TestFixtures.loop(
                        title: "Today",
                        dueAt: PlanningDate.storedDate(for: todayDay)
                    ),
                    TestFixtures.loop(
                        title: "Upcoming",
                        dueAt: PlanningDate.storedDate(for: upcomingDay)
                    )
                ],
                now: now,
                calendar: calendar
            )

            #expect(presentation.items(in: .overdue).map(\.title) == ["Overdue"])
            #expect(presentation.items(in: .today).map(\.title) == ["Today"])
            #expect(presentation.items(in: .upcoming).map(\.title) == ["Upcoming"])
        }
    }

    @Test
    func testSoftDeletedMovesNeverAppearButDoneHistoryIsRetained() {
        let visibleDone = TestFixtures.loop(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            status: .done,
            completedAt: TestFixtures.date(10)
        )
        let deletedActive = TestFixtures.loop(
            status: .doing,
            deletedAt: TestFixtures.date(20)
        )
        let deletedDone = TestFixtures.loop(
            status: .done,
            completedAt: TestFixtures.date(10),
            deletedAt: TestFixtures.date(20)
        )

        let presentation = MovePresentation(
            items: [visibleDone, deletedActive, deletedDone],
            now: TestFixtures.date(30),
            calendar: Calendar(identifier: .gregorian)
        )

        #expect(presentation.activeGroups.isEmpty)
        #expect(presentation.allCompleted.map { $0.id } == [visibleDone.id])
    }

    @Test
    func testPresentationIsDeterministicWhenInputOrderChanges() {
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let items = [
            TestFixtures.loop(id: secondID, title: "Same title", status: .doing),
            TestFixtures.loop(id: firstID, title: "Same title", status: .doing)
        ]

        let forward = MovePresentation(items: items, now: TestFixtures.date(30))
        let reverse = MovePresentation(items: items.reversed(), now: TestFixtures.date(30))

        #expect(forward == reverse)
        #expect(forward.items(in: .noDeadline).map { $0.id } == [firstID, secondID])
    }
}
