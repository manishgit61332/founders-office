import Foundation
import FounderOfficeCloud
import FounderOfficeCore

enum CheckFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case let .failed(message): return message
        }
    }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw CheckFailure.failed(message) }
}

func date(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSince1970: seconds)
}

func makeLoop(
    id: UUID = UUID(),
    title: String = "Task",
    status: LoopStatus = .doing,
    updatedAt: Date
) -> OpenLoop {
    OpenLoop(
        id: id,
        title: title,
        details: "",
        status: status,
        previousStatus: nil,
        priority: .p1,
        dueAt: nil,
        createdAt: date(0),
        updatedAt: updatedAt,
        completedAt: nil,
        deletedAt: nil,
        source: "check"
    )
}

func document(items: [OpenLoop], updatedAt: Date) -> OpenLoopsDocument {
    OpenLoopsDocument(schemaVersion: 2, updatedAt: updatedAt, items: items)
}

func runChecks() async throws {
    let id = UUID()
    let older = makeLoop(id: id, title: "Older", updatedAt: date(10))
    let newer = makeLoop(id: id, title: "Newer", updatedAt: date(20))
    let merged = FounderOfficeMerge.openLoops(
        local: document(items: [older], updatedAt: date(10)),
        remote: document(items: [newer], updatedAt: date(20))
    )
    try expect(merged.items.first?.title == "Newer", "Newer task edit did not win")

    var deleted = older
    deleted.deletedAt = date(20)
    deleted.updatedAt = date(20)
    let deleteMerge = FounderOfficeMerge.openLoops(
        local: document(items: [deleted], updatedAt: date(20)),
        remote: document(items: [older], updatedAt: date(10))
    )
    try expect(deleteMerge.items.first?.deletedAt == date(20), "Delete tombstone was lost")

    var restored = deleted
    restored.deletedAt = nil
    restored.updatedAt = date(30)
    let restoreMerge = FounderOfficeMerge.openLoops(
        local: document(items: [deleted], updatedAt: date(20)),
        remote: document(items: [restored], updatedAt: date(30))
    )
    try expect(restoreMerge.items.first?.deletedAt == nil, "Newer restore did not win")

    let alpha = makeLoop(id: id, title: "Alpha", updatedAt: date(40))
    let beta = makeLoop(id: id, title: "Beta", updatedAt: date(40))
    let alphaDocument = document(items: [alpha], updatedAt: date(40))
    let betaDocument = document(items: [beta], updatedAt: date(40))
    let leftToRight = FounderOfficeMerge.openLoops(local: alphaDocument, remote: betaDocument)
    let rightToLeft = FounderOfficeMerge.openLoops(local: betaDocument, remote: alphaDocument)
    try expect(leftToRight.items == rightToLeft.items, "Equal-time merge did not converge")

    let waiting = makeLoop(status: .waiting, updatedAt: date(10))
    let completed = OpenLoopRules.toggledCompletion(waiting, at: date(20))
    let reopened = OpenLoopRules.toggledCompletion(completed, at: date(30))
    try expect(completed.status == .done, "Completion did not move task to Done")
    try expect(completed.previousStatus == .waiting, "Completion lost the previous column")
    try expect(reopened.status == .waiting, "Reopen did not restore the previous column")

    struct LegacyPersonalization: Encodable {
        var schemaVersion = 3
        var displayName = "Founder's Office"
        var accent = AccentPalette.blue
        var iconStyle: IconStyle? = .system
        var photoFileName: String? = nil
        var primaryGoal: PrimaryGoal? = nil
        var milestones: [Milestone] = []
    }

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let legacyData = try encoder.encode(LegacyPersonalization())
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(PersonalizationDocument.self, from: legacyData)
    try expect(decoded.displayName == "Founder's Office", "Legacy personalization did not decode")
    try expect(decoded.resolvedPreferredName == nil, "Legacy workspace name was guessed to be a person")
    try expect(decoded.resolvedWorkspaceName == "Founder's Office", "Legacy workspace name was lost")
    try expect(decoded.updatedAt == nil, "Legacy personalization gained false cloud metadata")

    let namedProfile = PersonalizationDocument(
        schemaVersion: 5,
        displayName: "Founder's Office",
        accent: .blue,
        iconStyle: .system,
        photoFileName: nil,
        primaryGoal: nil,
        milestones: [],
        preferredName: "Aarav Sharma",
        workspaceName: "North Star Studio"
    )
    try expect(namedProfile.resolvedPreferredName == "Aarav Sharma", "Preferred name was not preserved exactly")
    try expect(namedProfile.resolvedWorkspaceName == "North Star Studio", "Workspace name was not preserved")

    let temporaryRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("founder-office-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    let fileStore = JSONSnapshotStore(rootURL: temporaryRoot)
    let personalization = PersonalizationDocument(
        schemaVersion: 5,
        displayName: "Founder's Office",
        accent: .blue,
        iconStyle: .system,
        photoFileName: nil,
        primaryGoal: nil,
        milestones: [],
        updatedAt: date(10)
    )
    let localSnapshot = FounderOfficeSnapshot(
        openLoops: document(items: [older], updatedAt: date(10)),
        personalization: personalization
    )
    try await fileStore.persist(localSnapshot)
    let storedSnapshot = try await fileStore.readSnapshot()
    try expect(storedSnapshot.openLoops.items == [older], "Atomic JSON snapshot did not round-trip")
    try expect(
        FileManager.default.fileExists(atPath: temporaryRoot.appendingPathComponent("OPEN_LOOPS_CONTEXT.md").path),
        "Codex context mirror was not written"
    )

    let remoteSnapshot = FounderOfficeSnapshot(
        openLoops: document(items: [newer], updatedAt: date(20)),
        personalization: personalization
    )
    let mergedSnapshot = try await fileStore.mergeAndPersist(remoteSnapshot)
    try expect(mergedSnapshot.openLoops.items.first?.title == "Newer", "Cloud snapshot did not merge into local JSON")

    var agentJob = AgentJobEnvelope(
        moveID: id,
        provider: .codex,
        surface: .codexAppServer,
        origin: .explicitUserCommand,
        createdAt: date(100)
    )
    try agentJob.transition(to: .triaging, at: date(101))
    try agentJob.transition(to: .draftReady, at: date(102))
    try agentJob.transition(to: .queued, at: date(103))
    try agentJob.transition(to: .running, at: date(104))
    try expect(agentJob.startedAt == date(104), "Agent job did not record its first running timestamp")
    try agentJob.transition(to: .awaitingApproval, at: date(105))
    try agentJob.transition(to: .running, at: date(106))
    try agentJob.transition(to: .reviewReady, at: date(107))
    try expect(agentJob.state.requiresUser, "Review-ready work was not surfaced as requiring the user")
    try expect(agentJob.finishedAt == nil, "Review-ready work was treated as terminal")
    try agentJob.transition(to: .succeeded, at: date(108))
    try expect(agentJob.finishedAt == date(108), "Succeeded agent job did not record its finish time")

    do {
        try agentJob.transition(to: .running, at: date(109))
        throw CheckFailure.failed("Terminal agent job restarted instead of requiring a new attempt")
    } catch AgentJobTransitionError.invalid(from: .succeeded, to: .running) {
        // Expected: retries and continued work use a new attempt.
    }
}

Task {
    do {
        try await runChecks()
        print("FounderOfficeCoreChecks: all checks passed")
        exit(0)
    } catch {
        fputs("FounderOfficeCoreChecks failed: \(error)\n", stderr)
        exit(1)
    }
}
dispatchMain()
