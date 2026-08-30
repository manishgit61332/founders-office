import AppKit
import Foundation
import FounderOfficeCore
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
    @Published private(set) var message = "Saved locally"
    @Published private(set) var recoveryState: WorkspaceRecoveryState = .ready

    let rootURL: URL
    let documentURL: URL
    let assetsURL: URL

    private var previewPhotoURL: URL?
    private var watcher: Timer?
    private var pendingAppearanceSave: Task<Void, Never>?
    private var lastKnownModificationDate: Date?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(rootURL: URL) {
        self.rootURL = rootURL
        documentURL = rootURL.appendingPathComponent("personalization.json")
        assetsURL = rootURL.appendingPathComponent("Personalization", isDirectory: true)

        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        document = Self.defaultDocument
        load()
        #if !FOUNDER_OFFICE_DISTRIBUTION
        applyPreviewOverrides()
        #endif
        startWatching()
    }

    isolated deinit {
        watcher?.invalidate()
        pendingAppearanceSave?.cancel()
    }

    var preferredName: String { document.resolvedPreferredName ?? "" }
    var workspaceName: String { document.resolvedWorkspaceName }
    var accent: AccentPalette { document.accent }
    var appearance: AppearancePreferences { document.resolvedAppearance }
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
        let url = assetsURL.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Fresh workspace bootstrap is the only path allowed to materialize the
    /// default document. The caller checks this write before committing the
    /// durable workspace identity or starting onboarding/cloud services.
    func ensureCanonicalDocumentExists() throws {
        guard !FileManager.default.fileExists(atPath: documentURL.path) else { return }
        guard !recoveryState.requiresRecovery else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try writeCanonicalDocument()
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
        document.accent = accent
        var updatedAppearance = appearance
        updatedAppearance.presetID = .custom
        updatedAppearance.accent = AccentStyle(
            mode: .solid,
            stops: [AccentStop(color: accent.rgb24, location: 0)],
            angleDegrees: updatedAppearance.accent.angleDegrees
        )
        updatedAppearance.updatedAt = .now
        document.appearance = updatedAppearance
        persist()
    }

    func applyPreset(_ preset: AppearancePresetID) {
        guard canEdit else { return }
        guard preset != .custom else { return }
        let updatedAppearance = AppearancePreferences.preset(preset)
        document.appearance = updatedAppearance
        document.accent = Self.nearestLegacyAccent(to: updatedAppearance.accent.primaryColor)
        persist()
    }

    func updateAccentMode(_ mode: AccentMode) {
        guard canEdit else { return }
        updateAppearance(debounced: true) { appearance in
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
        updateAppearance(debounced: true) { appearance in
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
        updateAppearance(debounced: true) { appearance in
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

    func flushPendingChanges() {
        guard pendingAppearanceSave != nil else { return }
        pendingAppearanceSave?.cancel()
        pendingAppearanceSave = nil
        persist()
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
                self?.importPhoto(from: sourceURL)
            }
        }
    }

    func removePhoto() {
        guard canEdit else { return }
        let previousURL = photoURL
        document.photoFileName = nil
        previewPhotoURL = nil
        persist()
        if let previousURL, previousURL.path.hasPrefix(assetsURL.path) {
            try? FileManager.default.removeItem(at: previousURL)
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

    private func importPhoto(from sourceURL: URL) {
        guard canEdit else { return }
        guard NSImage(contentsOf: sourceURL) != nil else {
            message = "That file isn’t a readable image"
            return
        }

        do {
            try FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true)
            let fileExtension = sourceURL.pathExtension.isEmpty ? "jpg" : sourceURL.pathExtension.lowercased()
            let fileName = "vision-\(UUID().uuidString.lowercased()).\(fileExtension)"
            let destinationURL = assetsURL.appendingPathComponent(fileName)
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)

            let previousURL = photoURL
            document.photoFileName = fileName
            persist()

            if let previousURL, previousURL.path.hasPrefix(assetsURL.path), previousURL != destinationURL {
                try? FileManager.default.removeItem(at: previousURL)
            }
            message = "Photo updated"
        } catch {
            message = "Couldn’t save that photo"
            AppDiagnostics.failure(.personalizationPhotoImport, category: .storage, error: error)
        }
    }

    private func load(force: Bool = false) {
        guard FileManager.default.fileExists(atPath: documentURL.path) else {
            if recoveryState.requiresRecovery {
                message = recoveryState.message
            }
            return
        }

        let modificationDate = fileModificationDate()
        if !force, modificationDate == lastKnownModificationDate { return }

        let data: Data
        do {
            data = try Data(contentsOf: documentURL)
        } catch {
            requireRecovery(preservedCopyName: nil, error: error)
            return
        }

        do {
            document = try decoder.decode(PersonalizationDocument.self, from: data)
        } catch {
            let preservedCopyName = (try? CorruptFileQuarantine.preserve(documentURL))?.lastPathComponent
            requireRecovery(preservedCopyName: preservedCopyName, error: error)
            return
        }

        lastKnownModificationDate = modificationDate
        recoveryState = .ready
        message = "Saved locally"
    }

    private func persist() {
        guard canEdit else { return }
        do {
            try writeCanonicalDocument()
        } catch {
            message = "Save failed"
            AppDiagnostics.failure(.personalizationSave, category: .storage, error: error)
        }
    }

    private func writeCanonicalDocument() throws {
        document.schemaVersion = max(document.schemaVersion, 6)
        document.updatedAt = Date()
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let data = try encoder.encode(document)
        try data.write(to: documentURL, options: .atomic)
        lastKnownModificationDate = fileModificationDate()
        message = "Saved locally"
    }

    private func updateAppearance(
        debounced: Bool = false,
        _ update: (inout AppearancePreferences) -> Void
    ) {
        var updatedAppearance = appearance
        update(&updatedAppearance)
        updatedAppearance.presetID = .custom
        updatedAppearance.updatedAt = .now
        document.appearance = updatedAppearance
        document.accent = Self.nearestLegacyAccent(to: updatedAppearance.accent.primaryColor)

        if debounced {
            persistAppearanceAfterDelay()
        } else {
            pendingAppearanceSave?.cancel()
            pendingAppearanceSave = nil
            persist()
        }
    }

    private func persistAppearanceAfterDelay() {
        pendingAppearanceSave?.cancel()
        pendingAppearanceSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.persist()
                self?.pendingAppearanceSave = nil
            }
        }
    }

    private func startWatching() {
        watcher = Timer.scheduledTimer(withTimeInterval: 1.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self,
                      self.fileModificationDate() != self.lastKnownModificationDate else { return }
                self.load(force: true)
            }
        }
        watcher?.tolerance = 0.25
    }

    private func fileModificationDate() -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: documentURL.path)
        return attributes?[.modificationDate] as? Date
    }

    private var canEdit: Bool {
        guard !recoveryState.requiresRecovery else {
            message = recoveryState.message
            return false
        }
        return true
    }

    private func requireRecovery(preservedCopyName: String?, error: Error) {
        lastKnownModificationDate = fileModificationDate()
        recoveryState = WorkspaceRecoveryState(
            affectedComponents: [.personalization],
            preservedCopyNames: preservedCopyName.map { [$0] } ?? []
        )
        message = recoveryState.message
        AppDiagnostics.failure(.personalizationLoad, category: .storage, error: error)
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

    private static let defaultDocument = PersonalizationDocument(
        schemaVersion: 6,
        displayName: "Founder's Office",
        accent: .blue,
        iconStyle: .system,
        photoFileName: nil,
        primaryGoal: nil,
        milestones: [],
        preferredName: nil,
        workspaceName: "Founder's Office",
        appearance: .manish()
    )

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
