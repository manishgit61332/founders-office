import Testing
@testable import FounderOfficeCore

struct TransientPresentationSessionTests {
    @Test
    func overlappingPresentationsRestoreOnlyAfterTheLastLease() {
        var session = TransientPresentationSession()
        let colour = session.begin("colour", hostIsExpanded: true)
        let menu = session.begin("menu", hostIsExpanded: true)

        #expect(session.phase == .presenting)
        #expect(session.activeCount == 2)
        let restoredAfterColour = session.end(colour)
        #expect(!restoredAfterColour)
        #expect(session.phase == .presenting)
        let restoredAfterMenu = session.end(menu)
        #expect(restoredAfterMenu)
        #expect(session.phase == .restoring)

        session.finishRestoring()
        #expect(session.phase == .idle)
    }

    @Test
    func duplicateEndDoesNotTriggerASecondRestore() {
        var session = TransientPresentationSession()
        let lease = session.begin("calendar", hostIsExpanded: true)

        let firstEndRestored = session.end(lease)
        let duplicateEndRestored = session.end(lease)
        #expect(firstEndRestored)
        #expect(!duplicateEndRestored)
        #expect(session.phase == .restoring)
    }

    @Test
    func cancellationReturnsDirectlyToIdle() {
        var session = TransientPresentationSession()
        session.begin("photo", hostIsExpanded: false)

        session.cancelAll()

        #expect(session.phase == .idle)
        #expect(!session.isActive)
    }

    @Test
    func firstSuspendingLeaseCollapsesOnceAndBalancedEndRestores() {
        var session = TransientPresentationSession()
        let localEditor = session.begin("local-editor", hostIsExpanded: true)
        #expect(!session.hostSuspensionRequested)

        let colour = session.begin(
            "colour",
            hostIsExpanded: true,
            suspendsHost: true
        )
        #expect(session.hostSuspensionRequested)
        #expect(session.hostWasExpanded)

        let menu = session.begin(
            "menu",
            hostIsExpanded: false,
            suspendsHost: true
        )
        #expect(session.hostWasExpanded)
        let restoredAfterColour = session.end(colour)
        let restoredAfterMenu = session.end(menu)
        let restoredAfterLocalEditor = session.end(localEditor)
        #expect(!restoredAfterColour)
        #expect(!restoredAfterMenu)
        #expect(restoredAfterLocalEditor)
        #expect(session.phase == .restoring)
    }
}
