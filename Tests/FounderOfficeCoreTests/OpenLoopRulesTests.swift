import Testing
@testable import FounderOfficeCore

struct OpenLoopRulesTests {
    @Test
    func testCompletionAndReopenRestoreThePreviousColumn() {
        let original = TestFixtures.loop(status: .waiting)

        let completed = OpenLoopRules.toggledCompletion(original, at: TestFixtures.date(20))
        let reopened = OpenLoopRules.toggledCompletion(completed, at: TestFixtures.date(30))

        #expect(completed.status == .done)
        #expect(completed.previousStatus == .waiting)
        #expect(completed.completedAt == TestFixtures.date(20))
        #expect(reopened.status == .waiting)
        #expect(reopened.previousStatus == nil)
        #expect(reopened.completedAt == nil)
        #expect(reopened.updatedAt == TestFixtures.date(30))
    }

    @Test
    func testLegacyDoneMoveWithoutPreviousColumnReopensIntoNext() {
        let legacyDone = TestFixtures.loop(
            status: .done,
            completedAt: TestFixtures.date(10)
        )

        let reopened = OpenLoopRules.toggledCompletion(legacyDone, at: TestFixtures.date(20))

        #expect(reopened.status == .next)
        #expect(reopened.completedAt == nil)
    }

    @Test
    func testMovingToDoneAndBackMaintainsCoherentCompletionMetadata() {
        let original = TestFixtures.loop(status: .doing)

        let completed = OpenLoopRules.moved(original, to: .done, at: TestFixtures.date(20))
        let movedBack = OpenLoopRules.moved(completed, to: .waiting, at: TestFixtures.date(30))

        #expect(completed.previousStatus == .doing)
        #expect(completed.completedAt == TestFixtures.date(20))
        #expect(movedBack.status == .waiting)
        #expect(movedBack.previousStatus == nil)
        #expect(movedBack.completedAt == nil)
    }

    @Test
    func testMovingAnAlreadyDoneMoveKeepsItsOriginalColumn() {
        let done = TestFixtures.loop(
            status: .done,
            previousStatus: .waiting,
            completedAt: TestFixtures.date(10)
        )

        let refreshed = OpenLoopRules.moved(done, to: .done, at: TestFixtures.date(20))

        #expect(refreshed.previousStatus == .waiting)
        #expect(refreshed.completedAt == TestFixtures.date(20))
    }

    @Test
    func testSoftDeleteAndRestoreOnlyChangeTombstoneMetadata() {
        let original = TestFixtures.loop(status: .doing)

        let deleted = OpenLoopRules.softDeleted(original, at: TestFixtures.date(20))
        let restored = OpenLoopRules.restored(deleted, at: TestFixtures.date(30))

        #expect(deleted.deletedAt == TestFixtures.date(20))
        #expect(deleted.status == .doing)
        #expect(restored.deletedAt == nil)
        #expect(restored.status == .doing)
        #expect(restored.updatedAt == TestFixtures.date(30))
    }

    @Test
    func testPrecedenceUsesPriorityThenDeadlineThenFreshness() {
        let p0 = TestFixtures.loop(priority: .p0, dueAt: nil, updatedAt: TestFixtures.date(1))
        let dueSoon = TestFixtures.loop(priority: .p1, dueAt: TestFixtures.date(20))
        let dueLater = TestFixtures.loop(priority: .p1, dueAt: TestFixtures.date(30))
        let undatedNew = TestFixtures.loop(priority: .p1, updatedAt: TestFixtures.date(50))
        let undatedOld = TestFixtures.loop(priority: .p1, updatedAt: TestFixtures.date(40))

        #expect(OpenLoopRules.precedes(p0, dueSoon))
        #expect(OpenLoopRules.precedes(dueSoon, dueLater))
        #expect(OpenLoopRules.precedes(dueLater, undatedNew))
        #expect(OpenLoopRules.precedes(undatedNew, undatedOld))
    }
}
