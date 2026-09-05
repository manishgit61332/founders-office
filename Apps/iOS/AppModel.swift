import Combine
import FounderOfficeCore
import FounderOfficeIdentity
import Foundation
import UIKit
import WidgetKit

enum TaskPlanningSaveResult: Equatable {
    case saved
    case unchanged
    case failed
}

enum IOSAppRoute: Equatable {
    case home
    case moves(UUID?)
    case calendar(String?)
    case goal(UUID)
}

/// SwiftUI-facing iOS workspace state. The SQLite repository is the local
/// authority; JSON remains a read-only legacy migration input and CloudKit is
/// not constructed here.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var openLoops: OpenLoopsDocument
    @Published private(set) var personalization: PersonalizationDocument
    @Published private(set) var recoveryState: WorkspaceRecoveryState = .ready
    @Published private(set) var isOpeningWorkspace = true
    @Published private(set) var saveMessage: String?
    @Published private(set) var route: IOSAppRoute?
    @Published private(set) var workspaceSession: IOSWorkspaceSession?

    private let storage: IOSWorkspaceStorage
    private var sessionCancellable: AnyCancellable?
    private var widgetIsSignedIn = false
    private var widgetCommitment: IOSWidgetProjection.Commitment?

    init(storage: IOSWorkspaceStorage = IOSWorkspaceStorage()) {
        self.storage = storage
        let snapshot = IOSWorkspaceSession.freshSnapshot
        openLoops = snapshot.openLoops
        personalization = snapshot.personalization

        // Do not let a stale App Group file expose content before the Keychain
        // session has been revalidated.
        publishWidgetProjection()
        Task { [weak self] in await self?.openWorkspace() }
    }

    var recoveryMessage: String? {
        recoveryState.requiresRecovery ? recoveryState.message : nil
    }

    var visibleLoops: [OpenLoop] {
        openLoops.items
            .filter { $0.deletedAt == nil }
            .sorted(by: OpenLoopRules.precedes)
    }

    var nextMove: OpenLoop? {
        visibleLoops.first { $0.status == .doing }
            ?? visibleLoops.first { $0.status == .next }
    }

    var activePrimaryGoal: PrimaryGoal? {
        guard let goal = personalization.primaryGoal, goal.deletedAt == nil else { return nil }
        return goal
    }

    var visionImage: UIImage? {
        guard let fileName = personalization.resolvedPhotoFileName,
              let data = storage.loadPhoto(named: fileName) else { return nil }
        return UIImage(data: data)
    }

    var hasCustomerData: Bool {
        !openLoops.items.isEmpty
            || activePrimaryGoal != nil
            || personalization.milestones.contains(where: { $0.deletedAt == nil })
            || personalization.resolvedPhotoFileName != nil
            || personalization.resolvedPreferredName != nil
            || personalization.resolvedWorkspaceName != "Founder's Office"
    }

    func addLoop(
        title: String,
        details: String,
        status: LoopStatus,
        priority: LoopPriority,
        dueAt: Date?
    ) {
        guard canEdit else { return }
        let now = Date()
        let loop = OpenLoop(
            id: UUID(),
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            details: details.trimmingCharacters(in: .whitespacesAndNewlines),
            status: status,
            previousStatus: nil,
            priority: priority,
            dueAt: dueAt,
            createdAt: now,
            updatedAt: now,
            completedAt: nil,
            deletedAt: nil,
            source: "ios",
            priorityUpdatedAt: now,
            dueAtUpdatedAt: now
        )
        var candidate = openLoops
        candidate.schemaVersion = max(candidate.schemaVersion, 3)
        candidate.updatedAt = now
        candidate.items.append(loop)
        persistOpenLoops(
            candidate,
            entityID: loop.id,
            changedFields: [
                "title", "details", "status", "previousStatus", "priority", "dueAt",
                "createdAt", "updatedAt", "priorityUpdatedAt", "dueAtUpdatedAt",
                "completedAt", "deletedAt", "source"
            ],
            at: now
        )
    }

    func toggleCompletion(_ loop: OpenLoop) {
        guard canEdit, let index = openLoops.items.firstIndex(where: { $0.id == loop.id }) else { return }
        let now = Date()
        var candidate = openLoops
        candidate.items[index] = OpenLoopRules.toggledCompletion(loop, at: now)
        candidate.updatedAt = now
        persistOpenLoops(
            candidate,
            entityID: loop.id,
            changedFields: ["status", "previousStatus", "completedAt", "updatedAt"],
            at: now
        )
    }

    func move(_ loop: OpenLoop, to status: LoopStatus) {
        guard canEdit, let index = openLoops.items.firstIndex(where: { $0.id == loop.id }) else { return }
        let now = Date()
        var candidate = openLoops
        candidate.items[index] = OpenLoopRules.moved(loop, to: status, at: now)
        candidate.updatedAt = now
        persistOpenLoops(
            candidate,
            entityID: loop.id,
            changedFields: ["status", "previousStatus", "completedAt", "updatedAt"],
            at: now
        )
    }

    @discardableResult
    func updatePlanning(
        id: UUID,
        priority: LoopPriority,
        dueAt: Date?,
        updatesPriority: Bool,
        updatesDeadline: Bool
    ) -> TaskPlanningSaveResult {
        guard canEdit,
              let index = openLoops.items.firstIndex(where: { $0.id == id && $0.deletedAt == nil }) else {
            return .failed
        }
        let current = openLoops.items[index]
        let resolvedPriority = updatesPriority ? priority : current.priority
        let resolvedDeadline = updatesDeadline ? dueAt : current.dueAt
        let updated = OpenLoopRules.updatedPlanning(
            current,
            priority: resolvedPriority,
            dueAt: resolvedDeadline,
            at: .now
        )
        guard updated != current else { return .unchanged }

        let now = Date()
        var candidate = openLoops
        candidate.items[index] = updated
        candidate.updatedAt = now
        let fields = [
            current.priority == resolvedPriority ? nil : "priority",
            current.priority == resolvedPriority ? nil : "priorityUpdatedAt",
            current.dueAt == resolvedDeadline ? nil : "dueAt",
            current.dueAt == resolvedDeadline ? nil : "dueAtUpdatedAt",
            "updatedAt"
        ].compactMap { $0 }
        persistOpenLoops(candidate, entityID: id, changedFields: fields, at: now)
        return .saved
    }

    func softDelete(_ loop: OpenLoop) {
        guard canEdit, let index = openLoops.items.firstIndex(where: { $0.id == loop.id }) else { return }
        let now = Date()
        var candidate = openLoops
        candidate.items[index] = OpenLoopRules.softDeleted(loop, at: now)
        candidate.updatedAt = now
        persistOpenLoops(
            candidate,
            entityID: loop.id,
            changedFields: ["deletedAt", "updatedAt"],
            at: now
        )
    }

    func updateWorkspaceName(_ workspaceName: String) {
        guard canEdit else { return }
        let now = Date()
        var candidate = personalization
        let clean = workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        candidate.workspaceName = clean.isEmpty ? "Founder's Office" : clean
        candidate.updatedAt = now
        persistPersonalization(
            candidate,
            entityKind: .workspace,
            entityID: "workspace",
            changedFields: ["workspaceName", "updatedAt"],
            at: now
        )
    }

    func updateAccent(_ accent: AccentPalette) {
        updateAppearance { appearance in
            appearance.accent = AccentStyle(
                mode: .solid,
                stops: [AccentStop(color: accent.rgb24, location: 0)],
                angleDegrees: appearance.accent.angleDegrees
            )
        }
    }

    func applyAppearancePreset(_ preset: AppearancePresetID) {
        guard preset != .custom else { return }
        var candidate = AppearancePreferences.preset(preset)
        candidate.updatedAt = .now
        persistAppearance(candidate)
    }

    func updateAccentMode(_ mode: AccentMode) {
        updateAppearance { appearance in
            var stops = appearance.accent.normalizedStops
            if mode == .gradient, stops.count == 1 {
                stops.append(AccentStop(color: RGB24Color(red: 126, green: 87, blue: 194), location: 1))
            }
            appearance.accent = AccentStyle(mode: mode, stops: stops, angleDegrees: appearance.accent.angleDegrees)
        }
    }

    func updateAccentColor(_ color: RGB24Color, stopIndex: Int) {
        updateAppearance { appearance in
            var stops = appearance.accent.normalizedStops
            while stops.count <= stopIndex {
                stops.append(AccentStop(color: color, location: stops.isEmpty ? 0 : 1))
            }
            stops[stopIndex].color = color
            appearance.accent = AccentStyle(
                mode: appearance.accent.mode,
                stops: stops,
                angleDegrees: appearance.accent.angleDegrees
            )
        }
    }

    func updateAccentAngle(_ angle: Double) {
        updateAppearance { $0.accent.angleDegrees = angle }
    }

    func updateDisplayFont(_ font: FontChoiceID) {
        updateAppearance { $0.displayFontID = font }
    }

    func updateInterfaceFont(_ font: FontChoiceID) {
        updateAppearance { $0.interfaceFontID = font }
    }

    func updateNodeStyle(_ style: NodeStyleID) {
        updateAppearance { $0.nodeStyleID = style }
    }

    func updateSurfaceStyle(_ style: SurfaceStyleID) {
        updateAppearance { $0.surfaceStyleID = style }
    }

    func setPrimaryGoal(_ goal: PrimaryGoal) {
        guard canEdit else { return }
        let now = Date()
        var candidate = personalization
        var updated = goal
        updated.updatedAt = now
        updated.deletedAt = nil
        candidate.primaryGoal = updated
        candidate.updatedAt = now
        persistPersonalization(
            candidate,
            entityKind: .primaryGoal,
            entityID: updated.id.uuidString.lowercased(),
            changedFields: [
                "title", "metric", "currentValue", "targetValue", "unit", "dueAt",
                "createdAt", "updatedAt", "deletedAt"
            ],
            at: now
        )
    }

    func clearPrimaryGoal() {
        guard canEdit, var goal = personalization.primaryGoal else { return }
        let now = Date()
        goal.updatedAt = now
        goal.deletedAt = now
        var candidate = personalization
        candidate.primaryGoal = goal
        candidate.updatedAt = now
        persistPersonalization(
            candidate,
            entityKind: .primaryGoal,
            entityID: goal.id.uuidString.lowercased(),
            changedFields: ["updatedAt", "deletedAt"],
            at: now
        )
    }

    func setWidgetAccountState(_ state: ProductAuthState) {
        if case .signedIn = state {
            widgetIsSignedIn = true
        } else {
            widgetIsSignedIn = false
        }
        publishWidgetProjection()
    }

    func updateWidgetCalendar(nextEvent: DeviceCalendarEvent?) {
        widgetCommitment = nextEvent.map {
                IOSWidgetProjection.Commitment(
                    id: $0.id,
                    title: $0.title,
                    startAt: $0.startDate
                )
            }
        publishWidgetProjection()
    }

    func handleDeepLink(_ url: URL) {
        guard url.scheme?.lowercased() == "founders-office" else { return }
        let parts = url.pathComponents.filter { $0 != "/" }
        switch (url.host?.lowercased(), parts.first) {
        case ("home", _): route = .home
        case ("moves", _): route = .moves(nil)
        case ("move", let id?): route = .moves(UUID(uuidString: id))
        case ("calendar", let id?): route = .calendar(id)
        case ("calendar", _): route = .calendar(nil)
        case ("goal", let id?) where UUID(uuidString: id) != nil:
            route = .goal(UUID(uuidString: id)!)
        default: route = .home
        }
    }

    func consumeRoute() { route = nil }

    func navigate(to destination: IOSAppRoute) {
        route = destination
    }

    func refreshWorkspace() {
        guard let workspaceSession else { return }
        Task { [weak self, workspaceSession] in
            if let latest = try? await workspaceSession.repository.snapshot() {
                self?.apply(latest)
            }
        }
    }

    private func openWorkspace() async {
        do {
            let session = try await IOSWorkspaceSession.open(rootURL: storage.storageDirectory)
            workspaceSession = session
            apply(session.snapshot)
            sessionCancellable = session.$snapshot
                .dropFirst()
                .receive(on: RunLoop.main)
                .sink { [weak self] in self?.apply($0) }
        } catch let IOSWorkspaceSessionError.recoveryRequired(state) {
            recoveryState = state
            saveMessage = state.message
        } catch {
            recoveryState = WorkspaceRecoveryState(affectedComponents: WorkspaceStorageComponent.allCases)
            saveMessage = recoveryState.message
        }
        isOpeningWorkspace = false
    }

    private func persistOpenLoops(
        _ candidate: OpenLoopsDocument,
        entityID: UUID,
        changedFields: [String],
        at date: Date
    ) {
        guard let session = workspaceSession else { return }
        openLoops = candidate
        publishWidgetProjection()
        let mutation = WorkspacePatchMutation(
            entityKind: WorkspaceLocalEntityKind.move.rawValue,
            entityID: entityID.uuidString.lowercased(),
            changedFields: changedFields,
            fieldClocks: Dictionary(uniqueKeysWithValues: changedFields.map { ($0, date) }),
            patch: .openLoops(candidate),
            createdAt: date
        )
        commit(mutation, through: session)
    }

    private func persistPersonalization(
        _ candidate: PersonalizationDocument,
        entityKind: WorkspaceLocalEntityKind,
        entityID: String,
        changedFields: [String],
        at date: Date
    ) {
        guard let session = workspaceSession else { return }
        personalization = candidate
        publishWidgetProjection()
        let mutation = WorkspacePatchMutation(
            entityKind: entityKind.rawValue,
            entityID: entityID,
            changedFields: changedFields,
            fieldClocks: Dictionary(uniqueKeysWithValues: changedFields.map { ($0, date) }),
            patch: .personalization(candidate),
            createdAt: date
        )
        commit(mutation, through: session)
    }

    private func commit(_ mutation: WorkspacePatchMutation, through session: IOSWorkspaceSession) {
        Task { [weak self, session] in
            do {
                _ = try await session.commit(mutation)
            } catch {
                guard let self else { return }
                apply(session.snapshot)
                saveMessage = "The change could not be saved locally."
            }
        }
    }

    private func updateAppearance(_ update: (inout AppearancePreferences) -> Void) {
        guard canEdit else { return }
        var appearance = personalization.resolvedAppearance
        update(&appearance)
        appearance.presetID = .custom
        appearance.updatedAt = .now
        persistAppearance(appearance)
    }

    private func persistAppearance(_ appearance: AppearancePreferences) {
        guard canEdit else { return }
        let now = appearance.updatedAt ?? .now
        var candidate = personalization
        candidate.appearance = appearance
        candidate.accent = nearestLegacyAccent(to: appearance.accent.primaryColor)
        candidate.updatedAt = now
        persistPersonalization(
            candidate,
            entityKind: .appearance,
            entityID: WorkspaceLocalEntityKind.appearance.rawValue,
            changedFields: ["appearance", "accent", "updatedAt"],
            at: now
        )
    }

    private func nearestLegacyAccent(to color: RGB24Color) -> AccentPalette {
        AccentPalette.allCases.min { lhs, rhs in
            let lhsDistance = colorDistance(lhs.rgb24, color)
            let rhsDistance = colorDistance(rhs.rgb24, color)
            return lhsDistance < rhsDistance
        } ?? .blue
    }

    private func colorDistance(_ lhs: RGB24Color, _ rhs: RGB24Color) -> Int {
        let red = Int(lhs.red) - Int(rhs.red)
        let green = Int(lhs.green) - Int(rhs.green)
        let blue = Int(lhs.blue) - Int(rhs.blue)
        return red * red + green * green + blue * blue
    }

    private func apply(_ snapshot: WorkspaceRepositorySnapshot) {
        openLoops = snapshot.content.openLoops
        personalization = snapshot.content.personalization
        recoveryState = .ready
        publishWidgetProjection()
    }

    private func publishWidgetProjection() {
        let goal = activePrimaryGoal.map { goal in
            IOSWidgetProjection.Goal(
                id: goal.id,
                title: goal.title,
                progress: goal.targetValue.map { target in
                    let current = goal.currentValue ?? .zero
                    return "\(goal.unit.format(current)) of \(goal.unit.format(target))"
                }
            )
        }
        let move = nextMove.map { IOSWidgetProjection.Move(id: $0.id, title: $0.title, dueAt: $0.dueAt) }
        _ = IOSWidgetProjectionStore.save(
            IOSWidgetProjection(
                isSignedIn: widgetIsSignedIn,
                nextMove: move,
                nextCommitment: widgetCommitment,
                primaryGoal: goal
            )
        )
        WidgetCenter.shared.reloadAllTimelines()
    }

    private var canEdit: Bool {
        guard !isOpeningWorkspace, workspaceSession != nil, !recoveryState.requiresRecovery else {
            if !isOpeningWorkspace { saveMessage = recoveryState.message }
            return false
        }
        return true
    }
}

struct IOSWorkspaceStorage {
    private let fileManager: FileManager
    private let appGroupID = IOSWidgetProjectionStore.appGroupID

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    var storageDirectory: URL {
        if let groupURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            return groupURL.appendingPathComponent("FounderOffice", isDirectory: true)
        }
        return fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FounderOffice", isDirectory: true)
    }

    func loadPhoto(named fileName: String) -> Data? {
        guard let fileName = AssetFileName.validated(fileName) else { return nil }
        return try? Data(contentsOf: storageDirectory
            .appendingPathComponent("Personalization", isDirectory: true)
            .appendingPathComponent(fileName))
    }
}
