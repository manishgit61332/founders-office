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

func makePresentationLoop(
    id: UUID,
    title: String,
    status: LoopStatus,
    priority: LoopPriority = .p1,
    dueAt: Date? = nil,
    completedAt: Date? = nil,
    deletedAt: Date? = nil,
    updatedAt: Date
) -> OpenLoop {
    OpenLoop(
        id: id,
        title: title,
        details: "",
        status: status,
        previousStatus: status == .done ? .next : nil,
        priority: priority,
        dueAt: dueAt,
        createdAt: date(0),
        updatedAt: updatedAt,
        completedAt: completedAt,
        deletedAt: deletedAt,
        source: "presentation-check"
    )
}

func calendarDate(
    _ year: Int,
    _ month: Int,
    _ day: Int,
    hour: Int = 0,
    minute: Int = 0,
    calendar: Calendar
) throws -> Date {
    var components = DateComponents()
    components.calendar = calendar
    components.timeZone = calendar.timeZone
    components.year = year
    components.month = month
    components.day = day
    components.hour = hour
    components.minute = minute
    components.second = 0
    guard let result = calendar.date(from: components) else {
        throw CheckFailure.failed("Could not construct deterministic calendar date")
    }
    return result
}

func document(items: [OpenLoop], updatedAt: Date) -> OpenLoopsDocument {
    OpenLoopsDocument(schemaVersion: 3, updatedAt: updatedAt, items: items)
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

    var presentationCalendar = Calendar(identifier: .gregorian)
    presentationCalendar.locale = Locale(identifier: "en_US_POSIX")
    presentationCalendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    let presentationNow = try calendarDate(
        2026,
        3,
        9,
        hour: 12,
        calendar: presentationCalendar
    )
    let startOfYesterday = try calendarDate(2026, 3, 8, calendar: presentationCalendar)
    let justBeforeToday = try calendarDate(
        2026,
        3,
        8,
        hour: 23,
        minute: 59,
        calendar: presentationCalendar
    )
    let todayMorning = try calendarDate(
        2026,
        3,
        9,
        hour: 9,
        calendar: presentationCalendar
    )
    let todayEvening = try calendarDate(
        2026,
        3,
        9,
        hour: 18,
        calendar: presentationCalendar
    )
    let startOfTomorrow = try calendarDate(2026, 3, 10, calendar: presentationCalendar)
    let beforeRecentWindow = try calendarDate(
        2026,
        3,
        7,
        hour: 23,
        minute: 59,
        calendar: presentationCalendar
    )
    let overdueDeadline = PlanningDate.storedDate(
        fromLocal: justBeforeToday,
        calendar: presentationCalendar
    )
    let todayDeadline = PlanningDate.storedDate(
        fromLocal: todayMorning,
        calendar: presentationCalendar
    )
    let tomorrowDeadline = PlanningDate.storedDate(
        fromLocal: startOfTomorrow,
        calendar: presentationCalendar
    )

    let overdueID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let todayP0ID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    let todayAlphaID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
    let todayZuluID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
    let upcomingID = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!
    let noDeadlineID = UUID(uuidString: "00000000-0000-0000-0000-000000000006")!
    let waitingID = UUID(uuidString: "00000000-0000-0000-0000-000000000007")!
    let deletedActiveID = UUID(uuidString: "00000000-0000-0000-0000-000000000008")!
    let recentTodayID = UUID(uuidString: "00000000-0000-0000-0000-000000000009")!
    let recentYesterdayID = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
    let olderID = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
    let nilCompletionID = UUID(uuidString: "00000000-0000-0000-0000-000000000012")!
    let deletedDoneID = UUID(uuidString: "00000000-0000-0000-0000-000000000013")!
    let todayLaterP1ID = UUID(uuidString: "00000000-0000-0000-0000-000000000014")!
    let noDeadlineTieFirstID = UUID(uuidString: "00000000-0000-0000-0000-000000000015")!
    let noDeadlineTieSecondID = UUID(uuidString: "00000000-0000-0000-0000-000000000016")!
    let olderP0ID = UUID(uuidString: "00000000-0000-0000-0000-000000000017")!

    let presentationItems = [
        makePresentationLoop(
            id: noDeadlineID,
            title: "No date",
            status: .next,
            priority: .p2,
            updatedAt: presentationNow
        ),
        makePresentationLoop(
            id: todayZuluID,
            title: "Zulu",
            status: .doing,
            dueAt: todayDeadline,
            updatedAt: presentationNow
        ),
        makePresentationLoop(
            id: deletedDoneID,
            title: "Deleted Done",
            status: .done,
            completedAt: todayEvening,
            deletedAt: presentationNow,
            updatedAt: presentationNow
        ),
        makePresentationLoop(
            id: upcomingID,
            title: "Tomorrow",
            status: .next,
            dueAt: tomorrowDeadline,
            updatedAt: presentationNow
        ),
        makePresentationLoop(
            id: olderID,
            title: "Older completion",
            status: .done,
            completedAt: beforeRecentWindow,
            updatedAt: presentationNow
        ),
        makePresentationLoop(
            id: todayP0ID,
            title: "Critical later today",
            status: .next,
            priority: .p0,
            dueAt: todayDeadline,
            updatedAt: presentationNow
        ),
        makePresentationLoop(
            id: waitingID,
            title: "Blocked today",
            status: .waiting,
            priority: .p2,
            dueAt: todayDeadline,
            updatedAt: presentationNow
        ),
        makePresentationLoop(
            id: overdueID,
            title: "Overdue",
            status: .doing,
            dueAt: overdueDeadline,
            updatedAt: presentationNow
        ),
        makePresentationLoop(
            id: recentYesterdayID,
            title: "Yesterday completion",
            status: .done,
            completedAt: startOfYesterday,
            updatedAt: presentationNow
        ),
        makePresentationLoop(
            id: nilCompletionID,
            title: "Legacy completion",
            status: .done,
            completedAt: nil,
            updatedAt: presentationNow
        ),
        makePresentationLoop(
            id: deletedActiveID,
            title: "Deleted active",
            status: .doing,
            dueAt: todayDeadline,
            deletedAt: presentationNow,
            updatedAt: presentationNow
        ),
        makePresentationLoop(
            id: todayAlphaID,
            title: "Alpha",
            status: .doing,
            dueAt: todayDeadline,
            updatedAt: presentationNow
        ),
        makePresentationLoop(
            id: recentTodayID,
            title: "Today completion",
            status: .done,
            completedAt: todayEvening,
            updatedAt: presentationNow
        ),
        makePresentationLoop(
            id: todayLaterP1ID,
            title: "A title that sorts first",
            status: .next,
            dueAt: todayDeadline,
            updatedAt: presentationNow
        ),
        makePresentationLoop(
            id: noDeadlineTieSecondID,
            title: "Same title",
            status: .doing,
            updatedAt: presentationNow
        ),
        makePresentationLoop(
            id: noDeadlineTieFirstID,
            title: "Same title",
            status: .doing,
            updatedAt: presentationNow
        ),
        makePresentationLoop(
            id: olderP0ID,
            title: "Priority tie breaker",
            status: .done,
            priority: .p0,
            completedAt: beforeRecentWindow,
            updatedAt: presentationNow
        )
    ]

    let movePresentation = MovePresentation(
        items: presentationItems,
        now: presentationNow,
        calendar: presentationCalendar
    )
    try expect(
        movePresentation.activeGroups.map(\.bucket) == [.overdue, .today, .upcoming, .noDeadline],
        "Active deadline groups were not emitted in urgency order"
    )
    try expect(
        movePresentation.items(in: .overdue).map(\.id) == [overdueID],
        "Pre-midnight deadline was not classified as overdue"
    )
    try expect(
        movePresentation.items(in: .today).map(\.id)
            == [todayP0ID, todayLaterP1ID, todayAlphaID, todayZuluID, waitingID],
        "Today Moves were not sorted by deadline, priority, and title"
    )
    try expect(
        movePresentation.items(in: .upcoming).map(\.id) == [upcomingID],
        "Tomorrow boundary was not classified as upcoming"
    )
    try expect(
        movePresentation.items(in: .noDeadline).map(\.id)
            == [noDeadlineTieFirstID, noDeadlineTieSecondID, noDeadlineID],
        "Undated Moves were not classified and deterministically tie-broken"
    )
    try expect(
        !movePresentation.activeGroups.flatMap(\.items).contains(where: { $0.id == deletedActiveID }),
        "Soft-deleted active Move remained visible"
    )
    try expect(
        movePresentation.recentCompleted.map(\.id) == [recentTodayID, recentYesterdayID],
        "Recent Done history did not use today-and-yesterday calendar boundaries"
    )
    try expect(
        movePresentation.olderCompleted.map(\.id) == [olderP0ID, olderID, nilCompletionID],
        "Older Done history did not retain dated and legacy nil-completion Moves"
    )
    try expect(
        movePresentation.allCompleted.count == 5,
        "Visible Done history was lost during presentation grouping"
    )
    try expect(
        !movePresentation.allCompleted.contains(where: { $0.id == deletedDoneID }),
        "Soft-deleted Done Move remained visible"
    )

    let reversedPresentation = MovePresentation(
        items: presentationItems.reversed(),
        now: presentationNow,
        calendar: presentationCalendar
    )
    try expect(
        reversedPresentation == movePresentation,
        "Move presentation changed when the input order changed"
    )

    let emptyPresentation = MovePresentation(
        items: [],
        now: presentationNow,
        calendar: presentationCalendar
    )
    try expect(emptyPresentation.activeGroups.isEmpty, "Empty store emitted empty presentation sections")
    try expect(emptyPresentation.items(in: .today).isEmpty, "Missing bucket did not return an empty collection")

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

    try expect(
        AssetFileName.validated("vision-00000000-0000-0000-0000-000000000000.jpg") != nil,
        "Generated vision asset name was rejected"
    )
    try expect(AssetFileName.validated("../../Library/secret.jpg") == nil, "Parent traversal asset name was accepted")
    try expect(AssetFileName.validated("folder/vision.jpg") == nil, "Nested asset path was accepted")
    try expect(AssetFileName.validated("folder\\vision.jpg") == nil, "Windows-style asset path was accepted")
    try expect(AssetFileName.validated("vision.exe") == nil, "Unsupported asset extension was accepted")

    let taskRecovery = WorkspaceRecoveryState(affectedComponents: [.openLoops])
    let personalizationRecovery = WorkspaceRecoveryState(affectedComponents: [.personalization])
    let combinedRecovery = taskRecovery.merging(personalizationRecovery)
    try expect(taskRecovery.requiresRecovery, "Task corruption did not require recovery")
    try expect(taskRecovery.message.hasPrefix("Tasks need recovery"), "Task recovery message was unclear")
    try expect(
        personalizationRecovery.message.hasPrefix("Personalization needs recovery"),
        "Personalization recovery message was ungrammatical"
    )
    try expect(
        combinedRecovery.affectedComponents == [.openLoops, .personalization],
        "Multiple damaged stores were not combined deterministically"
    )

    let quarantineRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("founder-office-recovery-check-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: quarantineRoot) }
    try FileManager.default.createDirectory(at: quarantineRoot, withIntermediateDirectories: true)
    let corruptURL = quarantineRoot.appendingPathComponent("openloops.json")
    let corruptData = Data("{not-json".utf8)
    try corruptData.write(to: corruptURL)
    let preservedURL = try CorruptFileQuarantine.preserve(corruptURL)
    try expect(
        FileManager.default.fileExists(atPath: corruptURL.path),
        "Quarantine removed the canonical fail-safe file"
    )
    let preservedData = try Data(contentsOf: preservedURL)
    try expect(
        preservedData == corruptData,
        "Quarantine did not preserve the damaged bytes exactly"
    )
    let secondPreservedURL = try CorruptFileQuarantine.preserve(corruptURL)
    try expect(secondPreservedURL != preservedURL, "Quarantine reused and replaced an existing backup")
    let corruptSnapshotStore = JSONSnapshotStore(rootURL: quarantineRoot)
    do {
        _ = try await corruptSnapshotStore.readSnapshot()
        throw CheckFailure.failed("Cloud snapshot accepted corrupt canonical tasks")
    } catch is DecodingError {
        // Expected: cloud transport must fail closed instead of seeding defaults.
    }
    let canonicalAfterCloudRead = try Data(contentsOf: corruptURL)
    try expect(
        canonicalAfterCloudRead == corruptData,
        "Cloud snapshot read replaced corrupt canonical tasks"
    )

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
