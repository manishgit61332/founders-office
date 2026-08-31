import Foundation
import FounderOfficeCore
import Testing
@testable import FounderOfficeCloud

struct JSONSnapshotStoreTests {
    @Test
    func contextDeadlinePreservesStoredPlanningDayAtUTCPlus14() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 14 * 3_600))

        let planningDay = try #require(PlanningDay(year: 2026, month: 9, day: 1))
        let dueAt = PlanningDate.storedDate(for: planningDay)
        let item = OpenLoop(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            title: "Date-only deadline",
            details: "",
            status: .next,
            previousStatus: nil,
            priority: .p1,
            dueAt: dueAt,
            createdAt: dueAt,
            updatedAt: dueAt,
            completedAt: nil,
            deletedAt: nil,
            source: "test"
        )
        let document = OpenLoopsDocument(
            schemaVersion: 3,
            updatedAt: dueAt,
            items: [item]
        )

        let context = JSONSnapshotStore.contextMarkdown(
            for: document,
            calendar: calendar
        )

        #expect(context.contains("Date-only deadline · Due 1 Sep 2026"))
        #expect(!context.contains("Date-only deadline · Due 2 Sep 2026"))
    }
}
