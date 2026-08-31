import AppKit
import Combine
import Foundation
import FounderOfficeCore
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

extension AccentPalette {
    var color: Color {
        switch self {
        case .blue: return Color(nsColor: .systemBlue)
        case .green: return Color(red: 0.53, green: 0.64, blue: 0.08)
        case .terracotta: return Color(red: 0.73, green: 0.31, blue: 0.22)
        case .violet: return Color(nsColor: .systemPurple)
        case .graphite: return Color(red: 0.53, green: 0.57, blue: 0.63)
        }
    }
}

@MainActor
final class PersonalizationStore: ObservableObject {
    @Published private(set) var document: PersonalizationDocument
    @Published private(set) var appearanceDraftSession: AppearanceDraftSession?
    @Published private(set) var isSavingAppearance = false
    @Published private(set) var message = "Saved locally"
    @Published private(set) var recoveryState: WorkspaceRecoveryState = .ready

    let session: WorkspaceSession
    let rootURL: URL
    let assetsURL: URL

    private var previewPhotoURL: URL?
    private var cancellable: AnyCancellable?
    private var writes: [PendingWrite] = []
    private var isWriting = false
    private var lastWriteSucceeded = true

    private struct PendingWrite {
        var document: PersonalizationDocument
        var entityKind: String
        var entityID: String
        var changedFields: [String]
        var fieldClocks: [String: Date]
        var precondition: WorkspacePatchPrecondition
        var completion: ((Result<WorkspaceTransactionResult, Error>) -> Void)?
    }

    init(session: WorkspaceSession) {
        self.session = session
        rootURL = session.rootURL
        assetsURL = rootURL.appendingPathComponent("Personalization", isDirectory: true)

        document = session.snapshot.content.personalization
        appearanceDraftSession = nil
        cancellable = session.$snapshot
            .dropFirst()
            .sink { [weak self] snapshot in
                guard let self, self.writes.isEmpty, !self.isWriting else { return }
                self.apply(snapshot.content.personalization)
            }
        #if !FOUNDER_OFFICE_DISTRIBUTION
        applyPreviewOverrides()
        #endif
    }

    func stop() {
        for write in writes {
            write.completion?(.failure(CancellationError()))
        }
        writes.removeAll()
        cancellable?.cancel()
        cancellable = nil
        appearanceDraftSession = nil
    }

    func reload() {
        Task { [weak self] in
            guard let self else { return }
            _ = await session.refresh()
            guard writes.isEmpty, !isWriting else { return }
            apply(session.snapshot.content.personalization)
        }
    }

    var hasPendingWrites: Bool { isWriting || !writes.isEmpty }

    func waitForPendingWrites() async -> Bool {
        for _ in 0..<500 where hasPendingWrites {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return !hasPendingWrites && lastWriteSucceeded
    }

    var preferredName: String { document.resolvedPreferredName ?? "" }
    var workspaceName: String { document.resolvedWorkspaceName }
    var accent: AccentPalette { document.accent }
    var appearance: AppearancePreferences {
        appearanceDraftSession?.draft ?? document.resolvedAppearance
    }
    var hasUnsavedAppearanceChanges: Bool { appearanceDraftSession?.isDirty == true }
    var hasAppearanceConflict: Bool { appearanceDraftSession?.hasConflict == true }
    var appearanceSaveError: String? { appearanceDraftSession?.saveError }
    var accentColor: Color { appearance.accent.primaryColor.swiftUIColor }
    var secondaryAccentColor: Color { appearance.accent.secondaryColor.swiftUIColor }
    var accentHex: String { appearance.accent.primaryColor.hex }
    // Navigation now follows macOS and always uses SF Symbols. Keep the stored
    // field only so older personalization documents continue to decode safely.
    var iconStyle: IconStyle { .system }
    var primaryGoal: PrimaryGoal? {
        guard document.primaryGoal?.deletedAt == nil else { return nil }
        return document.primaryGoal
    }
    var milestones: [Milestone] {
        document.milestones
            .filter { $0.deletedAt == nil }
            .sorted { $0.dueAt < $1.dueAt }
    }

    var photoURL: URL? {
        if let previewPhotoURL { return previewPhotoURL }
        guard let fileName = document.photoFileName.flatMap(AssetFileName.validated) else { return nil }
        return assetsURL.appendingPathComponent(fileName)
    }

    func updatePreferredName(_ value: String) {
        guard canEdit else { return }
        let cleanValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        document.preferredName = cleanValue.isEmpty ? nil : cleanValue
        persist()
    }

    func updateWorkspaceName(_ value: String) {
        guard canEdit else { return }
        let cleanValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        document.workspaceName = cleanValue.isEmpty ? "Founder's Office" : cleanValue
        persist()
    }

    func updateAccent(_ accent: AccentPalette) {
        guard canEdit else { return }
        updateAppearance { appearance in
            appearance.accent = AccentStyle(
                mode: .solid,
                stops: [AccentStop(color: accent.rgb24, location: 0)],
                angleDegrees: appearance.accent.angleDegrees
            )
        }
    }

    func applyPreset(_ preset: AppearancePresetID) {
        guard canEdit else { return }
        guard preset != .custom else { return }
        ensureAppearanceDraftSession()
        guard var session = appearanceDraftSession else { return }
        session.update { appearance in
            let revision = appearance.updatedAt
            appearance = AppearancePreferences.preset(preset)
            appearance.updatedAt = revision
        }
        appearanceDraftSession = session
    }

    func updateAccentMode(_ mode: AccentMode) {
        guard canEdit else { return }
        updateAppearance { appearance in
            var stops = appearance.accent.normalizedStops
            if mode == .gradient, stops.count == 1 {
                stops.append(
                    AccentStop(
                        color: RGB24Color(red: 126, green: 87, blue: 194),
                        location: 1
                    )
                )
            }
            appearance.accent = AccentStyle(
                mode: mode,
                stops: stops,
                angleDegrees: appearance.accent.angleDegrees
            )
        }
    }

    func updateAccentColor(_ color: RGB24Color, stopIndex: Int) {
        guard canEdit else { return }
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
        guard canEdit else { return }
        updateAppearance { appearance in
            appearance.accent.angleDegrees = angle
        }
    }

    func updateDisplayFont(_ font: FontChoiceID) {
        guard canEdit else { return }
        updateAppearance { $0.displayFontID = font }
    }

    func updateInterfaceFont(_ font: FontChoiceID) {
        guard canEdit else { return }
        updateAppearance { $0.interfaceFontID = font }
    }

    func updateNodeStyle(_ style: NodeStyleID) {
        guard canEdit else { return }
        updateAppearance { $0.nodeStyleID = style }
    }

    func updateSurfaceStyle(_ style: SurfaceStyleID) {
        guard canEdit else { return }
        updateAppearance { $0.surfaceStyleID = style }
    }

    func beginAppearanceEditing() {
        ensureAppearanceDraftSession()
    }

    func discardAppearanceChanges() {
        appearanceDraftSession = nil
    }

    func useLatestAppearance() {
        guard var session = appearanceDraftSession else { return }
        session.useLatest(document.resolvedAppearance)
        appearanceDraftSession = session
    }

    @discardableResult
    func keepMineAppearance() async -> AppearanceSaveResult {
        await saveAppearanceChanges(overwritingConflict: true)
    }

    @discardableResult
    func saveAppearanceChanges(overwritingConflict: Bool = false) async -> AppearanceSaveResult {
        guard var session = appearanceDraftSession, session.isDirty else {
            return .unchanged
        }
        guard canEdit else {
            let failure = recoveryState.message
            session.markFailed(failure)
            appearanceDraftSession = session
            return .failed(failure)
        }
        guard overwritingConflict || !session.hasConflict else {
            return .conflict
        }
        if overwritingConflict {
            session.resolveConflictKeepingDraft()
        }

        let now = Date()
        var committedAppearance = session.draft
        committedAppearance.updatedAt = now

        var candidate = document
        candidate.schemaVersion = max(candidate.schemaVersion, 6)
        candidate.appearance = committedAppearance
        candidate.accent = Self.nearestLegacyAccent(to: committedAppearance.accent.primaryColor)
        candidate.updatedAt = now

        isSavingAppearance = true
        defer { isSavingAppearance = false }
        let result = await persist(
            candidate,
            entityKind: "appearance",
            entityID: "appearance",
            changedFields: ["appearance", "accent", "updatedAt"],
            at: now,
            precondition: overwritingConflict ? .none : .appearanceRevision(session.baselineRevision)
        )

        switch result {
        case .success:
            lastWriteSucceeded = true
            document = candidate
            session.markSaved(committedAppearance)
            appearanceDraftSession = session
            message = "Saved locally"
            return .saved
        case let .failure(error):
            lastWriteSucceeded = false
            if let repositoryError = error as? WorkspaceRepositoryError,
               case .componentConflict = repositoryError {
                session.observeCommitted(self.session.snapshot.content.personalization.resolvedAppearance)
                appearanceDraftSession = session
                return .conflict
            }
            let failure = "Couldn’t save changes"
            session.markFailed(failure)
            appearanceDraftSession = session
            message = "Save failed"
            AppDiagnostics.failure(.personalizationSave, category: .storage, error: error)
            return .failed(failure)
        }
    }

    func updateIconStyle(_ style: IconStyle) {
        guard canEdit else { return }
        document.iconStyle = style
        persist()
    }

    func choosePhoto(onCompletion: @escaping () -> Void = {}) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a photo that reminds you what you’re building toward."
        panel.prompt = "Use Photo"

        panel.begin { [weak self] response in
            defer { onCompletion() }
            guard response == .OK, let sourceURL = panel.url else { return }
            Task { @MainActor in
                await self?.importPhoto(from: sourceURL)
            }
        }
    }

    func removePhoto() {
        guard canEdit else { return }
        let previousURL = photoURL
        previewPhotoURL = nil
        var candidate = document
        let now = Date()
        candidate.photoFileName = nil
        candidate.updatedAt = now
        Task { [weak self] in
            guard let self else { return }
            let result = await persist(
                candidate,
                entityKind: "asset",
                entityID: "vision-photo",
                changedFields: ["photoFileName", "updatedAt"],
                at: now,
                precondition: .none
            )
            guard case .success = result else { return }
            document = candidate
            if let previousURL, previousURL.path.hasPrefix(assetsURL.path) {
                try? await Task.detached { try FileManager.default.removeItem(at: previousURL) }.value
            }
        }
    }

    func addMilestone(title: String, dueAt: Date) {
        guard canEdit else { return }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return }
        let now = Date()
        document.milestones.append(
            Milestone(id: UUID(), title: cleanTitle, dueAt: dueAt, createdAt: now, updatedAt: now)
        )
        persist()
    }

    func deleteMilestone(_ milestone: Milestone) {
        guard canEdit else { return }
        guard let index = document.milestones.firstIndex(where: { $0.id == milestone.id }) else { return }
        let now = Date()
        document.milestones[index].updatedAt = now
        document.milestones[index].deletedAt = now
        persist()
    }

    func setPrimaryGoal(
        title: String,
        metric: String,
        currentValue: Double?,
        targetValue: Double?,
        unit: GoalValueUnit,
        dueAt: Date
    ) {
        guard canEdit else { return }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanMetric = metric.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return }

        let now = Date()
        let existing = document.primaryGoal
        document.primaryGoal = PrimaryGoal(
            id: existing?.id ?? UUID(),
            title: cleanTitle,
            metric: cleanMetric,
            currentValue: targetValue == nil ? nil : max(0, currentValue ?? 0),
            targetValue: targetValue.map { max(0, $0) },
            unit: unit,
            dueAt: dueAt,
            createdAt: existing?.createdAt ?? now,
            updatedAt: now,
            deletedAt: nil
        )
        persist()
    }

    func clearPrimaryGoal() {
        guard canEdit else { return }
        guard var goal = document.primaryGoal else { return }
        let now = Date()
        goal.updatedAt = now
        goal.deletedAt = now
        document.primaryGoal = goal
        persist()
    }

    private func importPhoto(from sourceURL: URL) async {
        guard canEdit else { return }
        do {
            let fileExtension = sourceURL.pathExtension.isEmpty ? "jpg" : sourceURL.pathExtension.lowercased()
            let fileName = "vision-\(UUID().uuidString.lowercased()).\(fileExtension)"
            let destinationURL = assetsURL.appendingPathComponent(fileName)
            let assetsURL = assetsURL
            try await Task.detached(priority: .userInitiated) {
                guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
                      CGImageSourceGetCount(source) > 0 else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                try FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            }.value

            let previousURL = photoURL
            var candidate = document
            let now = Date()
            candidate.photoFileName = fileName
            candidate.schemaVersion = max(candidate.schemaVersion, 6)
            candidate.updatedAt = now
            let result = await persist(
                candidate,
                entityKind: "asset",
                entityID: fileName,
                changedFields: ["photoFileName", "updatedAt"],
                at: now,
                precondition: .none
            )
            guard case .success = result else {
                try? await Task.detached { try FileManager.default.removeItem(at: destinationURL) }.value
                throw CocoaError(.fileWriteUnknown)
            }
            document = candidate

            if let previousURL, previousURL.path.hasPrefix(assetsURL.path), previousURL != destinationURL {
                try? await Task.detached { try FileManager.default.removeItem(at: previousURL) }.value
            }
            message = "Photo updated"
        } catch {
            message = "Couldn’t save that photo"
            AppDiagnostics.failure(.personalizationPhotoImport, category: .storage, error: error)
        }
    }

    private func persist() {
        guard canEdit else { return }
        let now = Date()
        document.schemaVersion = max(document.schemaVersion, 6)
        document.updatedAt = now
        enqueue(
            PendingWrite(
                document: document,
                entityKind: "personalization",
                entityID: "personalization",
                changedFields: ["personalization", "updatedAt"],
                fieldClocks: ["personalization": now, "updatedAt": now],
                precondition: .none,
                completion: nil
            )
        )
    }

    private func persist(
        _ candidate: PersonalizationDocument,
        entityKind: String,
        entityID: String,
        changedFields: [String],
        at date: Date,
        precondition: WorkspacePatchPrecondition
    ) async -> Result<WorkspaceTransactionResult, Error> {
        await withCheckedContinuation { continuation in
            enqueue(
                PendingWrite(
                    document: candidate,
                    entityKind: entityKind,
                    entityID: entityID,
                    changedFields: changedFields,
                    fieldClocks: Dictionary(uniqueKeysWithValues: changedFields.map { ($0, date) }),
                    precondition: precondition,
                    completion: { continuation.resume(returning: $0) }
                )
            )
        }
    }

    private func enqueue(_ write: PendingWrite) {
        writes.append(write)
        processNextWriteIfNeeded()
    }

    private func processNextWriteIfNeeded() {
        guard !isWriting, let write = writes.first else { return }
        isWriting = true
        message = "Saving…"
        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await session.commit(
                    WorkspacePatchMutation(
                        entityKind: write.entityKind,
                        entityID: write.entityID,
                        changedFields: write.changedFields,
                        fieldClocks: write.fieldClocks,
                        patch: .personalization(write.document),
                        precondition: write.precondition,
                        createdAt: write.document.updatedAt ?? Date()
                    )
                )
                finish(write: write, result: .success(result), snapshot: result.snapshot)
            } catch {
                finish(write: write, result: .failure(error), snapshot: session.snapshot)
            }
        }
    }

    private func finish(
        write: PendingWrite,
        result: Result<WorkspaceTransactionResult, Error>,
        snapshot: WorkspaceRepositorySnapshot
    ) {
        if !writes.isEmpty { writes.removeFirst() }
        isWriting = false

        switch result {
        case .success:
            lastWriteSucceeded = true
            message = "Saved locally"
            write.completion?(result)
        case let .failure(error):
            let abandoned = writes
            writes.removeAll()
            apply(snapshot.content.personalization)
            message = "Save failed"
            write.completion?(.failure(error))
            for pending in abandoned {
                pending.completion?(.failure(error))
            }
            AppDiagnostics.failure(.personalizationSave, category: .storage, error: error)
        }

        if writes.isEmpty {
            apply(session.snapshot.content.personalization)
        }
        processNextWriteIfNeeded()
    }

    private func apply(_ loadedDocument: PersonalizationDocument) {
        document = loadedDocument
        if var draft = appearanceDraftSession {
            draft.observeCommitted(loadedDocument.resolvedAppearance)
            appearanceDraftSession = draft
        }
        recoveryState = .ready
    }

    private func updateAppearance(_ update: (inout AppearancePreferences) -> Void) {
        ensureAppearanceDraftSession()
        guard var session = appearanceDraftSession else { return }
        session.update { appearance in
            update(&appearance)
            appearance.presetID = .custom
        }
        appearanceDraftSession = session
    }

    private func ensureAppearanceDraftSession() {
        guard appearanceDraftSession == nil else { return }
        appearanceDraftSession = AppearanceDraftSession(committed: document.resolvedAppearance)
    }

    private var canEdit: Bool {
        guard !recoveryState.requiresRecovery else {
            message = recoveryState.message
            return false
        }
        return true
    }

    #if !FOUNDER_OFFICE_DISTRIBUTION
    private func applyPreviewOverrides() {
        let environment = ProcessInfo.processInfo.environment
        if let rawPreset = environment["OPENLOOPS_PREVIEW_APPEARANCE_PRESET"] {
            let preset = AppearancePresetID(rawValue: rawPreset)
            if AppearancePresetID.builtIns.contains(preset) {
                document.appearance = AppearancePreferences.preset(preset)
                document.accent = Self.nearestLegacyAccent(to: document.resolvedAppearance.accent.primaryColor)
            }
        }
        if let rawAccent = environment["OPENLOOPS_PREVIEW_ACCENT"],
           let accent = AccentPalette(rawValue: rawAccent) {
            document.accent = accent
            document.appearance = .manish(accent: accent.rgb24)
        }
        if let rawStyle = environment["OPENLOOPS_PREVIEW_ICON_STYLE"],
           let style = IconStyle(rawValue: rawStyle) {
            document.iconStyle = style
        }
        if let path = environment["OPENLOOPS_PREVIEW_PHOTO"], !path.isEmpty {
            previewPhotoURL = URL(fileURLWithPath: path)
        }
        if let rawDays = environment["OPENLOOPS_PREVIEW_MILESTONE_DAYS"],
           let days = Int(rawDays),
           let dueAt = Calendar.current.date(byAdding: .day, value: days, to: Date()) {
            let targetValue = environment["OPENLOOPS_PREVIEW_GOAL_TARGET"].flatMap(Double.init)
            let currentValue = environment["OPENLOOPS_PREVIEW_GOAL_CURRENT"].flatMap(Double.init)
            let unit = environment["OPENLOOPS_PREVIEW_GOAL_UNIT"].flatMap(GoalValueUnit.init(rawValue:)) ?? .usd
            document.primaryGoal = PrimaryGoal(
                id: UUID(),
                title: environment["OPENLOOPS_PREVIEW_GOAL_TITLE"] ?? "Reach the primary goal",
                metric: environment["OPENLOOPS_PREVIEW_GOAL_METRIC"] ?? "MRR",
                currentValue: currentValue,
                targetValue: targetValue,
                unit: unit,
                dueAt: dueAt,
                createdAt: Date(),
                updatedAt: Date()
            )
        }
    }
    #endif

    private static func nearestLegacyAccent(to color: RGB24Color) -> AccentPalette {
        AccentPalette.allCases.min { lhs, rhs in
            colorDistance(lhs.rgb24, color) < colorDistance(rhs.rgb24, color)
        } ?? .blue
    }

    private static func colorDistance(_ lhs: RGB24Color, _ rhs: RGB24Color) -> Int {
        let red = Int(lhs.red) - Int(rhs.red)
        let green = Int(lhs.green) - Int(rhs.green)
        let blue = Int(lhs.blue) - Int(rhs.blue)
        return red * red + green * green + blue * blue
    }
}
