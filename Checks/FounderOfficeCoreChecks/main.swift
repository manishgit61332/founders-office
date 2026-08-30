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
    try expect(decoded.appearance == nil, "Legacy personalization gained a fabricated appearance payload")
    try expect(decoded.resolvedAppearance.presetID == .manish, "Legacy personalization did not resolve to the Manish default")

    try expect(RGB24Color(hex: "#000000")?.hex == "#000000", "Black RGB24 colour did not round-trip")
    try expect(RGB24Color(hex: "FFFFFF")?.hex == "#FFFFFF", "White RGB24 colour did not round-trip")
    try expect(RGB24Color(hex: "#0a84ff")?.hex == "#0A84FF", "Mixed-case RGB24 colour did not normalize")
    try expect(RGB24Color(hex: "#12345") == nil, "Invalid short RGB24 colour was accepted")

    let normalizedAccent = AccentStyle(
        mode: .gradient,
        stops: [
            AccentStop(color: RGB24Color(red: 255, green: 0, blue: 0), location: 1.4),
            AccentStop(color: RGB24Color(red: 0, green: 0, blue: 255), location: -0.2)
        ],
        angleDegrees: 450
    )
    try expect(normalizedAccent.normalizedStops.map(\.location) == [0, 1], "Gradient stops were not clamped and ordered")
    try expect(normalizedAccent.angleDegrees == 90, "Gradient angle was not normalized")
    let negativeAngle = AccentStyle(mode: .solid, stops: [], angleDegrees: -45)
    try expect(negativeAngle.angleDegrees == 315, "Negative gradient angle was not normalized")
    let reversibleSolid = AccentStyle(
        mode: .solid,
        stops: [
            AccentStop(color: RGB24Color(red: 10, green: 20, blue: 30), location: 0),
            AccentStop(color: RGB24Color(red: 40, green: 50, blue: 60), location: 1)
        ]
    )
    try expect(reversibleSolid.normalizedStops.count == 2, "Solid mode discarded the saved gradient stop")

    var interactionLeases = InteractionLeaseRegistry()
    let dateLease = interactionLeases.begin("date")
    let menuLease = interactionLeases.begin("menu")
    try expect(interactionLeases.isActive && interactionLeases.count == 2, "Overlapping interactions were not retained")
    interactionLeases.end(dateLease)
    try expect(interactionLeases.isActive && interactionLeases.count == 1, "Ending one interaction released another")
    interactionLeases.end(dateLease)
    try expect(interactionLeases.count == 1, "Ending the same interaction twice corrupted the registry")
    interactionLeases.end(menuLease)
    try expect(!interactionLeases.isActive, "Interaction registry stayed active after every lease ended")

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

    var customAppearance = AppearancePreferences.preset(.minimal)
    customAppearance.presetID = AppearancePresetID(rawValue: "future-theme")
    customAppearance.displayFontID = FontChoiceID(rawValue: "future-font")
    let themedProfile = PersonalizationDocument(
        schemaVersion: 6,
        displayName: "Founder's Office",
        accent: .blue,
        iconStyle: .system,
        photoFileName: nil,
        primaryGoal: nil,
        milestones: [],
        appearance: customAppearance
    )
    let themedData = try encoder.encode(themedProfile)
    let themedRoundTrip = try decoder.decode(PersonalizationDocument.self, from: themedData)
    try expect(themedRoundTrip.appearance?.presetID.rawValue == "future-theme", "Unknown theme identifier was not preserved")
    try expect(themedRoundTrip.appearance?.displayFontID.rawValue == "future-font", "Unknown font identifier was not preserved")
    try expect(themedRoundTrip.resolvedAppearance.accent.mode == .gradient, "Gradient appearance did not round-trip")
    try expect(themedRoundTrip.resolvedAppearance.accent.primaryColor.hex == "#74AA9C", "Exact 24-bit accent colour was not preserved")

    let temporaryRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("founder-office-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: temporaryRoot) }
    let fileStore = JSONSnapshotStore(rootURL: temporaryRoot)
    let freshSnapshot = try await fileStore.readSnapshot()
    try expect(freshSnapshot.personalization.schemaVersion == 6, "Fresh cloud snapshot did not use the appearance schema")
    try expect(freshSnapshot.personalization.appearance?.presetID == .manish, "Fresh cloud snapshot did not seed the Manish style")
    let personalization = PersonalizationDocument(
        schemaVersion: 6,
        displayName: "Founder's Office",
        accent: .blue,
        iconStyle: .system,
        photoFileName: nil,
        primaryGoal: nil,
        milestones: [],
        updatedAt: date(10),
        appearance: AppearancePreferences.preset(.native)
    )
    let localSnapshot = FounderOfficeSnapshot(
        openLoops: document(items: [older], updatedAt: date(10)),
        personalization: personalization
    )
    try await fileStore.persist(localSnapshot)
    let storedSnapshot = try await fileStore.readSnapshot()
    try expect(storedSnapshot.openLoops.items == [older], "Atomic JSON snapshot did not round-trip")
    try expect(storedSnapshot.personalization.appearance?.presetID == .native, "Appearance payload was lost from the atomic snapshot")
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
