import Foundation
import Testing
@testable import FounderOfficeCore

private actor AppearanceCommitBoundaryStub: AppearanceDraftCommitBoundary {
    enum Response: Sendable {
        case saved(revision: Date)
        case conflict(AppearancePreferences)
        case failed(String)
    }

    private let response: Response
    private var receivedRequests: [AppearanceDraftCommitRequest] = []

    init(response: Response) {
        self.response = response
    }

    func commit(
        _ request: AppearanceDraftCommitRequest
    ) async -> AppearanceDraftCommitResult {
        receivedRequests.append(request)
        switch response {
        case let .saved(revision):
            return .saved(committedRevision: revision)
        case let .conflict(latest):
            return .conflict(latest: latest)
        case let .failed(message):
            return .failed(message)
        }
    }

    var requests: [AppearanceDraftCommitRequest] { receivedRequests }
}

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
        #expect(session.conflictingCommitted == remote)

        let adoptedLatest = session.useLatest()
        #expect(adoptedLatest)
        #expect(!session.hasConflict)
        #expect(!session.isDirty)
        #expect(session.draft.presetID == .native)
        #expect(session.conflictingCommitted == nil)
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

    @Test
    func saveReturnsUnchangedWithoutCrossingTheCommitBoundary() async {
        var session = AppearanceDraftSession(committed: .manish())
        let boundary = AppearanceCommitBoundaryStub(response: .failed("must not run"))

        let result = await session.save(using: boundary)

        #expect(result == .unchanged)
        #expect(await boundary.requests.isEmpty)
    }

    @Test
    func savedResultAdvancesTheBaselineExactlyOnce() async {
        let baselineRevision = Date(timeIntervalSince1970: 100)
        let committedRevision = Date(timeIntervalSince1970: 200)
        var committed = AppearancePreferences.manish()
        committed.updatedAt = baselineRevision
        var session = AppearanceDraftSession(committed: committed)
        session.update { $0.nodeStyleID = .pixel }
        let boundary = AppearanceCommitBoundaryStub(
            response: .saved(revision: committedRevision)
        )

        let result = await session.save(using: boundary)

        #expect(result == .saved)
        #expect(!session.isDirty)
        #expect(session.baselineRevision == committedRevision)
        #expect(session.draft.nodeStyleID == .pixel)
        #expect(session.saveError == nil)
        let requests = await boundary.requests
        #expect(requests.count == 1)
        #expect(requests.first?.baselineRevision == baselineRevision)
        #expect(requests.first?.policy == .requireBaseline)
        #expect(requests.first?.appearance.updatedAt == baselineRevision)
    }

    @Test
    func unresolvedConflictDoesNotInvokeTheBoundary() async {
        var committed = AppearancePreferences.manish()
        committed.updatedAt = Date(timeIntervalSince1970: 100)
        var session = AppearanceDraftSession(committed: committed)
        session.update { $0.nodeStyleID = .pixel }
        var remote = AppearancePreferences.preset(.minimal)
        remote.updatedAt = Date(timeIntervalSince1970: 200)
        session.observeCommitted(remote)
        let boundary = AppearanceCommitBoundaryStub(
            response: .saved(revision: Date(timeIntervalSince1970: 300))
        )

        let result = await session.save(using: boundary)

        #expect(result == .conflict)
        #expect(session.hasConflict)
        #expect(session.isDirty)
        #expect(await boundary.requests.isEmpty)
    }

    @Test
    func commitConflictKeepsThePreviewAndSurfacesLatestForReview() async {
        var committed = AppearancePreferences.manish()
        committed.updatedAt = Date(timeIntervalSince1970: 100)
        var session = AppearanceDraftSession(committed: committed)
        session.update { $0.nodeStyleID = .pixel }
        var remote = AppearancePreferences.preset(.minimal)
        remote.updatedAt = Date(timeIntervalSince1970: 200)
        let boundary = AppearanceCommitBoundaryStub(response: .conflict(remote))

        let result = await session.save(using: boundary)

        #expect(result == .conflict)
        #expect(session.hasConflict)
        #expect(session.isDirty)
        #expect(session.draft.nodeStyleID == .pixel)
        #expect(session.baseline == committed)
        #expect(session.conflictingCommitted == remote)
        #expect(await boundary.requests.count == 1)

        let adoptedLatest = session.useLatest()
        #expect(adoptedLatest)
        #expect(session.draft == remote)
        #expect(!session.hasConflict)
        #expect(!session.isDirty)
    }

    @Test
    func failedCommitKeepsTheDraftAndCustomerSafeError() async {
        let committed = AppearancePreferences.manish()
        var session = AppearanceDraftSession(committed: committed)
        session.update { $0.displayFontID = .monospaced }
        let boundary = AppearanceCommitBoundaryStub(response: .failed("Try again"))

        let result = await session.save(using: boundary)

        #expect(result == .failed("Try again"))
        #expect(session.isDirty)
        #expect(session.draft.displayFontID == .monospaced)
        #expect(session.baseline == committed)
        #expect(session.saveError == "Try again")
    }

    @Test
    func keepMineUsesExplicitOverwritePolicy() async {
        var committed = AppearancePreferences.manish()
        committed.updatedAt = Date(timeIntervalSince1970: 100)
        var session = AppearanceDraftSession(committed: committed)
        session.update { $0.nodeStyleID = .pixel }
        var remote = AppearancePreferences.preset(.minimal)
        remote.updatedAt = Date(timeIntervalSince1970: 200)
        session.observeCommitted(remote)
        let boundary = AppearanceCommitBoundaryStub(
            response: .saved(revision: Date(timeIntervalSince1970: 300))
        )

        let result = await session.save(policy: .overwriteLatest, using: boundary)

        #expect(result == .saved)
        #expect(!session.hasConflict)
        #expect(!session.isDirty)
        #expect(await boundary.requests.first?.policy == .overwriteLatest)
    }
}
