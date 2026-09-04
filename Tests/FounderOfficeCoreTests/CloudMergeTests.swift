import Foundation
import Testing
@testable import FounderOfficeCore

struct CloudMergeTests {
    @Test
    func testNewerMoveWinsRegardlessOfMergeDirection() throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let older = TestFixtures.loop(id: id, title: "Older", updatedAt: TestFixtures.date(10))
        let newer = TestFixtures.loop(id: id, title: "Newer", updatedAt: TestFixtures.date(20))

        let localNewer = FounderOfficeMerge.openLoops(
            local: TestFixtures.document(updatedAt: TestFixtures.date(20), items: [newer]),
            remote: TestFixtures.document(updatedAt: TestFixtures.date(10), items: [older])
        )
        let remoteNewer = FounderOfficeMerge.openLoops(
            local: TestFixtures.document(updatedAt: TestFixtures.date(10), items: [older]),
            remote: TestFixtures.document(updatedAt: TestFixtures.date(20), items: [newer])
        )

        #expect(try #require(localNewer.items.first).title == "Newer")
        #expect(localNewer.items == remoteNewer.items)
    }

    @Test
    func testMergePreservesDisjointMovesAndSortsByStableID() {
        let laterID = UUID(uuidString: "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF")!
        let earlierID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let local = TestFixtures.loop(id: laterID, title: "Local")
        let remote = TestFixtures.loop(id: earlierID, title: "Remote")

        let merged = FounderOfficeMerge.openLoops(
            local: TestFixtures.document(items: [local]),
            remote: TestFixtures.document(items: [remote])
        )

        #expect(merged.items.map { $0.id } == [earlierID, laterID])
    }

    @Test
    func testDisjointPriorityAndDeadlineEditsMergeWithoutDataLoss() throws {
        let id = UUID()
        let base = TestFixtures.loop(
            id: id,
            priority: .p2,
            dueAt: nil,
            updatedAt: TestFixtures.date(5)
        )
        let priorityEdit = OpenLoopRules.updatedPlanning(
            base,
            priority: .p0,
            dueAt: nil,
            at: TestFixtures.date(10)
        )
        let deadlineEdit = OpenLoopRules.updatedPlanning(
            base,
            priority: .p2,
            dueAt: TestFixtures.date(100),
            at: TestFixtures.date(20)
        )

        let leftToRight = FounderOfficeMerge.openLoops(
            local: TestFixtures.document(updatedAt: TestFixtures.date(10), items: [priorityEdit]),
            remote: TestFixtures.document(updatedAt: TestFixtures.date(20), items: [deadlineEdit])
        )
        let rightToLeft = FounderOfficeMerge.openLoops(
            local: TestFixtures.document(updatedAt: TestFixtures.date(20), items: [deadlineEdit]),
            remote: TestFixtures.document(updatedAt: TestFixtures.date(10), items: [priorityEdit])
        )

        let merged = try #require(leftToRight.items.first)
        #expect(merged.priority == .p0)
        #expect(merged.dueAt == TestFixtures.date(100))
        #expect(merged.priorityUpdatedAt == TestFixtures.date(10))
        #expect(merged.dueAtUpdatedAt == TestFixtures.date(20))
        #expect(leftToRight.items == rightToLeft.items)
    }

    @Test
    func testLaterPlanningEditCannotEraseNewerCompletion() throws {
        let id = UUID()
        let base = TestFixtures.loop(
            id: id,
            status: .doing,
            priority: .p2,
            updatedAt: TestFixtures.date(10)
        )
        let completed = OpenLoopRules.toggledCompletion(base, at: TestFixtures.date(20))
        let stalePriorityEdit = OpenLoopRules.updatedPlanning(
            base,
            priority: .p0,
            dueAt: base.dueAt,
            at: TestFixtures.date(30)
        )

        let localFirst = FounderOfficeMerge.openLoops(
            local: TestFixtures.document(updatedAt: TestFixtures.date(30), items: [stalePriorityEdit]),
            remote: TestFixtures.document(updatedAt: TestFixtures.date(20), items: [completed])
        )
        let remoteFirst = FounderOfficeMerge.openLoops(
            local: TestFixtures.document(updatedAt: TestFixtures.date(20), items: [completed]),
            remote: TestFixtures.document(updatedAt: TestFixtures.date(30), items: [stalePriorityEdit])
        )

        let merged = try #require(localFirst.items.first)
        #expect(merged.status == .done)
        #expect(merged.completedAt == TestFixtures.date(20))
        #expect(merged.priority == .p0)
        #expect(localFirst.items == remoteFirst.items)
    }

    @Test
    func testLaterPlanningEditCannotResurrectNewerDeletion() throws {
        let id = UUID()
        let base = TestFixtures.loop(
            id: id,
            priority: .p2,
            updatedAt: TestFixtures.date(10)
        )
        let deleted = OpenLoopRules.softDeleted(base, at: TestFixtures.date(20))
        let staleDeadlineEdit = OpenLoopRules.updatedPlanning(
            base,
            priority: base.priority,
            dueAt: TestFixtures.date(100),
            at: TestFixtures.date(30)
        )

        let localFirst = FounderOfficeMerge.openLoops(
            local: TestFixtures.document(updatedAt: TestFixtures.date(30), items: [staleDeadlineEdit]),
            remote: TestFixtures.document(updatedAt: TestFixtures.date(20), items: [deleted])
        )
        let remoteFirst = FounderOfficeMerge.openLoops(
            local: TestFixtures.document(updatedAt: TestFixtures.date(20), items: [deleted]),
            remote: TestFixtures.document(updatedAt: TestFixtures.date(30), items: [staleDeadlineEdit])
        )

        let merged = try #require(localFirst.items.first)
        #expect(merged.deletedAt == TestFixtures.date(20))
        #expect(merged.dueAt == TestFixtures.date(100))
        #expect(localFirst.items == remoteFirst.items)
    }

    @Test
    func testNewerSchemaTwoPlanningEditIsNotIgnoredBySchemaThreeClock() throws {
        let id = UUID()
        var schemaThree = TestFixtures.loop(
            id: id,
            priority: .p0,
            updatedAt: TestFixtures.date(10)
        )
        schemaThree.priorityUpdatedAt = TestFixtures.date(10)
        schemaThree.dueAtUpdatedAt = TestFixtures.date(10)

        let legacyEdit = TestFixtures.loop(
            id: id,
            priority: .p3,
            updatedAt: TestFixtures.date(20)
        )
        let merged = FounderOfficeMerge.openLoops(
            local: TestFixtures.document(
                schemaVersion: 3,
                updatedAt: TestFixtures.date(10),
                items: [schemaThree]
            ),
            remote: TestFixtures.document(
                schemaVersion: 2,
                updatedAt: TestFixtures.date(20),
                items: [legacyEdit]
            )
        )

        let item = try #require(merged.items.first)
        #expect(item.priority == .p3)
        #expect(item.priorityUpdatedAt == TestFixtures.date(20))
    }

    @Test
    func testNewerTombstoneWinsAndNewerRestoreWins() throws {
        let id = UUID()
        let active = TestFixtures.loop(id: id, updatedAt: TestFixtures.date(10))
        var deleted = active
        deleted.deletedAt = TestFixtures.date(20)
        deleted.updatedAt = TestFixtures.date(20)

        let deletionMerge = FounderOfficeMerge.openLoops(
            local: TestFixtures.document(items: [active]),
            remote: TestFixtures.document(updatedAt: TestFixtures.date(20), items: [deleted])
        )
        #expect(try #require(deletionMerge.items.first).deletedAt == TestFixtures.date(20))

        var restored = deleted
        restored.deletedAt = nil
        restored.updatedAt = TestFixtures.date(30)
        let restorationMerge = FounderOfficeMerge.openLoops(
            local: TestFixtures.document(updatedAt: TestFixtures.date(20), items: [deleted]),
            remote: TestFixtures.document(updatedAt: TestFixtures.date(30), items: [restored])
        )
        #expect(try #require(restorationMerge.items.first).deletedAt == nil)
    }

    @Test
    func testEqualTimestampConflictConverges() {
        let id = UUID()
        let alpha = TestFixtures.loop(id: id, title: "Alpha", updatedAt: TestFixtures.date(40))
        let beta = TestFixtures.loop(id: id, title: "Beta", updatedAt: TestFixtures.date(40))
        let alphaDocument = TestFixtures.document(updatedAt: TestFixtures.date(40), items: [alpha])
        let betaDocument = TestFixtures.document(updatedAt: TestFixtures.date(40), items: [beta])

        let leftToRight = FounderOfficeMerge.openLoops(local: alphaDocument, remote: betaDocument)
        let rightToLeft = FounderOfficeMerge.openLoops(local: betaDocument, remote: alphaDocument)

        #expect(leftToRight.items == rightToLeft.items)
    }

    @Test
    func testDocumentMetadataUsesHighestSchemaAndLatestTimestamp() {
        let local = TestFixtures.document(
            schemaVersion: 2,
            updatedAt: TestFixtures.date(100),
            items: []
        )
        let remote = TestFixtures.document(
            schemaVersion: 7,
            updatedAt: TestFixtures.date(50),
            items: []
        )

        let merged = FounderOfficeMerge.openLoops(local: local, remote: remote)

        #expect(merged.schemaVersion == 7)
        #expect(merged.updatedAt == TestFixtures.date(100))
    }

    @Test
    func testPersonalizationUsesNewestWholeDocument() {
        let local = TestFixtures.personalization(
            updatedAt: TestFixtures.date(10),
            preferredName: "Older"
        )
        let remote = TestFixtures.personalization(
            updatedAt: TestFixtures.date(20),
            preferredName: "Newer"
        )

        let merged = FounderOfficeMerge.personalization(local: local, remote: remote)

        #expect(merged.resolvedPreferredName == "Newer")
    }

    @Test
    func testEqualTimestampPersonalizationConflictConverges() {
        let alpha = TestFixtures.personalization(
            updatedAt: TestFixtures.date(30),
            preferredName: "Alpha"
        )
        let beta = TestFixtures.personalization(
            updatedAt: TestFixtures.date(30),
            preferredName: "Beta"
        )

        let leftToRight = FounderOfficeMerge.personalization(local: alpha, remote: beta)
        let rightToLeft = FounderOfficeMerge.personalization(local: beta, remote: alpha)

        #expect(leftToRight.resolvedPreferredName == rightToLeft.resolvedPreferredName)
    }
}
