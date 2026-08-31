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
    func testPriorityGroupsAreRankedDeterministicAndExcludeDoneAndDeletedMoves() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = try TestFixtures.calendarDate(2026, 9, 1, hour: 9, calendar: calendar)
        let earlyDeadline = PlanningDate.storedDate(
            for: try #require(PlanningDay(year: 2026, month: 8, day: 30))
        )
        let laterDeadline = PlanningDate.storedDate(
            for: try #require(PlanningDay(year: 2026, month: 9, day: 10))
        )

        let p0EarlyID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let p0LaterID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let p1FirstID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let p1SecondID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        let p2ID = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
        let p3ID = UUID(uuidString: "00000000-0000-0000-0000-000000000006")!
        let completedID = UUID(uuidString: "00000000-0000-0000-0000-000000000007")!
        let deletedID = UUID(uuidString: "00000000-0000-0000-0000-000000000008")!

        let items = [
            TestFixtures.loop(id: p3ID, title: "Low", priority: .p3),
            TestFixtures.loop(id: p1SecondID, title: "Same title", priority: .p1),
            TestFixtures.loop(
                id: completedID,
                title: "Completed critical",
                status: .done,
                priority: .p0,
                completedAt: now
            ),
            TestFixtures.loop(
                id: p0LaterID,
                title: "Later critical",
                priority: .p0,
                dueAt: laterDeadline
            ),
            TestFixtures.loop(id: p2ID, title: "Normal", priority: .p2),
            TestFixtures.loop(
                id: deletedID,
                title: "Deleted critical",
                priority: .p0,
                dueAt: earlyDeadline,
                deletedAt: now
            ),
            TestFixtures.loop(id: p1FirstID, title: "Same title", priority: .p1),
            TestFixtures.loop(
                id: p0EarlyID,
                title: "Early critical",
                priority: .p0,
                dueAt: earlyDeadline
            )
        ]

        let forward = MovePresentation(items: items, now: now, calendar: calendar)
        let reverse = MovePresentation(items: items.reversed(), now: now, calendar: calendar)

        #expect(forward.priorityGroups.map(\.priority) == [.p0, .p1, .p2, .p3])
        #expect(forward.items(in: .p0).map(\.id) == [p0EarlyID, p0LaterID])
        #expect(forward.items(in: .p1).map(\.id) == [p1FirstID, p1SecondID])
        #expect(forward.items(in: .p2).map(\.id) == [p2ID])
        #expect(forward.items(in: .p3).map(\.id) == [p3ID])
        #expect(forward.activeGroups.map(\.bucket) == [.overdue, .upcoming, .noDeadline])
        #expect(forward.allCompleted.map(\.id) == [completedID])
        #expect(!forward.priorityGroups.flatMap(\.items).contains { $0.id == deletedID })
        #expect(forward == reverse)
    }

    @Test
    func testActiveItemsDueOnSelectedLocalDateMatchStoredPlanningDayAtExtremeOffsets() throws {
        let selectedDay = try #require(PlanningDay(year: 2026, month: 9, day: 1))
        let otherDay = try #require(PlanningDay(year: 2026, month: 9, day: 2))
        let selectedDeadline = PlanningDate.storedDate(for: selectedDay)
        let otherDeadline = PlanningDate.storedDate(for: otherDay)
        let criticalID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let normalID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let otherID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!

        for offset in [-12 * 3_600, 14 * 3_600] {
            var calendar = Calendar(identifier: .gregorian)
            calendar.locale = Locale(identifier: "en_US_POSIX")
            calendar.timeZone = try #require(TimeZone(secondsFromGMT: offset))
            let selectedDate = try TestFixtures.calendarDate(
                selectedDay.year,
                selectedDay.month,
                selectedDay.day,
                hour: 8,
                calendar: calendar
            )
            let otherDate = try TestFixtures.calendarDate(
                otherDay.year,
                otherDay.month,
                otherDay.day,
                hour: 8,
                calendar: calendar
            )

            let presentation = MovePresentation(
                items: [
                    TestFixtures.loop(
                        id: normalID,
                        title: "Normal match",
                        priority: .p2,
                        dueAt: selectedDeadline
                    ),
                    TestFixtures.loop(
                        id: otherID,
                        title: "Other day",
                        priority: .p1,
                        dueAt: otherDeadline
                    ),
                    TestFixtures.loop(
                        title: "Completed match",
                        status: .done,
                        dueAt: selectedDeadline,
                        completedAt: selectedDate
                    ),
                    TestFixtures.loop(
                        title: "Deleted match",
                        dueAt: selectedDeadline,
                        deletedAt: selectedDate
                    ),
                    TestFixtures.loop(title: "Undated"),
                    TestFixtures.loop(
                        id: criticalID,
                        title: "Critical match",
                        priority: .p0,
                        dueAt: selectedDeadline
                    )
                ],
                now: selectedDate,
                calendar: calendar
            )

            #expect(
                presentation.activeItems(dueOn: selectedDate, calendar: calendar).map(\.id)
                    == [criticalID, normalID]
            )
            #expect(
                presentation.activeItems(dueOn: otherDate, calendar: calendar).map(\.id)
                    == [otherID]
            )
        }
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
