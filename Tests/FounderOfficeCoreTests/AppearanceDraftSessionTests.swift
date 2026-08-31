import Foundation
import Testing
@testable import FounderOfficeCore

struct AppearanceDraftSessionTests {
    @Test
    func draftChangesDoNotAdvanceTheDurableRevision() {
        let revision = Date(timeIntervalSince1970: 100)
        var committed = AppearancePreferences.manish()
        committed.updatedAt = revision
        var session = AppearanceDraftSession(committed: committed)

        session.update { appearance in
            appearance.surfaceStyleID = .solidBlack
        }

        #expect(session.isDirty)
        #expect(session.draft.surfaceStyleID == .solidBlack)
        #expect(session.draft.updatedAt == revision)
        #expect(session.baseline.surfaceStyleID != .solidBlack)
    }

    @Test
    func discardRestoresTheCommittedAppearance() {
        let committed = AppearancePreferences.manish()
        var session = AppearanceDraftSession(committed: committed)
        session.update { $0.interfaceFontID = .monospaced }

        session.discard()

        #expect(!session.isDirty)
        #expect(session.draft == committed)
        #expect(session.saveError == nil)
    }

    @Test
    func remoteChangeCreatesConflictWithoutReplacingDirtyPreview() {
        var committed = AppearancePreferences.manish()
        committed.updatedAt = Date(timeIntervalSince1970: 100)
        var session = AppearanceDraftSession(committed: committed)
        session.update { $0.nodeStyleID = .pixel }

        var remote = AppearancePreferences.preset(.native)
        remote.updatedAt = Date(timeIntervalSince1970: 200)
        session.observeCommitted(remote)

        #expect(session.hasConflict)
        #expect(session.isDirty)
        #expect(session.draft.nodeStyleID == .pixel)

        session.useLatest(remote)
        #expect(!session.hasConflict)
        #expect(!session.isDirty)
        #expect(session.draft.presetID == .native)
    }

    @Test
    func cleanSessionFollowsRemoteChange() {
        let committed = AppearancePreferences.manish()
        var session = AppearanceDraftSession(committed: committed)
        let remote = AppearancePreferences.preset(.minimal)

        session.observeCommitted(remote)

        #expect(!session.hasConflict)
        #expect(!session.isDirty)
        #expect(session.draft.presetID == .minimal)
    }

    @Test
    func failedSaveKeepsTheDraftAndSurfacesRetryableError() {
        let committed = AppearancePreferences.manish()
        var session = AppearanceDraftSession(committed: committed)
        session.update { $0.displayFontID = .monospaced }

        session.markFailed("Couldn’t save changes")

        #expect(session.isDirty)
        #expect(session.draft.displayFontID == .monospaced)
        #expect(session.saveError == "Couldn’t save changes")
        #expect(session.baseline == committed)

        session.update { $0.nodeStyleID = .pixel }
        #expect(session.saveError == nil)
        #expect(session.isDirty)
        #expect(session.baseline == committed)
    }

    @Test
    func discardAfterAConflictReturnsToTheOriginalCommittedBaseline() {
        var committed = AppearancePreferences.manish()
        committed.updatedAt = Date(timeIntervalSince1970: 100)
        var session = AppearanceDraftSession(committed: committed)
        session.update { $0.surfaceStyleID = .solidBlack }

        var remote = AppearancePreferences.preset(.minimal)
        remote.updatedAt = Date(timeIntervalSince1970: 200)
        session.observeCommitted(remote)
        session.discard()

        #expect(!session.isDirty)
        #expect(!session.hasConflict)
        #expect(session.draft == committed)
    }

    @Test
    func terminationPolicyOnlyQuitsAfterSaveOrExplicitDiscard() {
        #expect(
            AppearanceTerminationPolicy.decision(for: .save, saveResult: .saved)
                == .terminate
        )
        #expect(
            AppearanceTerminationPolicy.decision(for: .save, saveResult: .unchanged)
                == .terminate
        )
        #expect(
            AppearanceTerminationPolicy.decision(for: .save, saveResult: .conflict)
                == .continueEditing
        )
        #expect(
            AppearanceTerminationPolicy.decision(for: .save, saveResult: .failed("disk"))
                == .continueEditing
        )
        #expect(AppearanceTerminationPolicy.decision(for: .discard) == .terminate)
        #expect(AppearanceTerminationPolicy.decision(for: .cancel) == .continueEditing)
    }
}
