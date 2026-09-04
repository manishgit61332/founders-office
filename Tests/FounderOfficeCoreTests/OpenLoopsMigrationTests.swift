import Foundation
import Testing
@testable import FounderOfficeCore

struct OpenLoopsMigrationTests {
    @Test
    func testSchemaTwoIOSDeadlineAndPlanningClocksUpgradeOnce() throws {
        var india = Calendar(identifier: .gregorian)
        india.timeZone = try #require(TimeZone(identifier: "Asia/Kolkata"))
        let legacyPickerInstant = try TestFixtures.calendarDate(
            2026,
            9,
            1,
            hour: 0,
            minute: 15,
            calendar: india
        )
        let item = TestFixtures.loop(
            priority: .p2,
            dueAt: legacyPickerInstant,
            updatedAt: TestFixtures.date(50),
            source: "ios"
        )
        let legacy = TestFixtures.document(schemaVersion: 2, items: [item])

        let upgraded = OpenLoopsMigration.upgradingPlanningSchema(
            legacy,
            calendar: india
        )
        let upgradedItem = try #require(upgraded.items.first)
        let dueAt = try #require(upgradedItem.dueAt)

        #expect(upgraded.schemaVersion == 3)
        #expect(PlanningDate.day(fromStored: dueAt) == PlanningDay(year: 2026, month: 9, day: 1))
        #expect(upgradedItem.priorityUpdatedAt == item.updatedAt)
        #expect(upgradedItem.dueAtUpdatedAt == item.updatedAt)
        #expect(OpenLoopsMigration.upgradingPlanningSchema(upgraded, calendar: india).items == upgraded.items)
    }
}
