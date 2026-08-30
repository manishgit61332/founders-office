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

    let rootURL: URL
    let documentURL: URL
    let assetsURL: URL

    private var previewPhotoURL: URL?
    private var watcher: Timer?
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
        applyPreviewOverrides()
        startWatching()
    }

    deinit {
        watcher?.invalidate()
    }

    var preferredName: String { document.resolvedPreferredName ?? "" }
    var workspaceName: String { document.resolvedWorkspaceName }
    var accent: AccentPalette { document.accent }
    var accentColor: Color { document.accent.color }
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
        guard let fileName = document.photoFileName else { return nil }
        let url = assetsURL.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func updatePreferredName(_ value: String) {
        let cleanValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        document.preferredName = cleanValue.isEmpty ? nil : cleanValue
        persist()
    }

    func updateWorkspaceName(_ value: String) {
        let cleanValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        document.workspaceName = cleanValue.isEmpty ? "Founder's Office" : cleanValue
        persist()
    }

    func updateAccent(_ accent: AccentPalette) {
        document.accent = accent
        persist()
    }

    func updateIconStyle(_ style: IconStyle) {
        document.iconStyle = style
        persist()
    }

    func choosePhoto() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a photo that reminds you what you’re building toward."
        panel.prompt = "Use Photo"

        panel.begin { [weak self] response in
            guard response == .OK, let sourceURL = panel.url else { return }
            Task { @MainActor in
                self?.importPhoto(from: sourceURL)
            }
        }
    }

    func removePhoto() {
        let previousURL = photoURL
        document.photoFileName = nil
        previewPhotoURL = nil
        persist()
        if let previousURL, previousURL.path.hasPrefix(assetsURL.path) {
            try? FileManager.default.removeItem(at: previousURL)
        }
    }

    func addMilestone(title: String, dueAt: Date) {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return }
        let now = Date()
        document.milestones.append(
            Milestone(id: UUID(), title: cleanTitle, dueAt: dueAt, createdAt: now, updatedAt: now)
        )
        persist()
    }

    func deleteMilestone(_ milestone: Milestone) {
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
        guard var goal = document.primaryGoal else { return }
        let now = Date()
        goal.updatedAt = now
        goal.deletedAt = now
        document.primaryGoal = goal
        persist()
    }

    private func importPhoto(from sourceURL: URL) {
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
        guard FileManager.default.fileExists(atPath: documentURL.path) else { return }
        do {
            let modificationDate = fileModificationDate()
            if !force, modificationDate == lastKnownModificationDate { return }
            let data = try Data(contentsOf: documentURL)
            document = try decoder.decode(PersonalizationDocument.self, from: data)
            lastKnownModificationDate = modificationDate
        } catch {
            message = "Personalization reset"
            AppDiagnostics.failure(.personalizationLoad, category: .storage, error: error)
        }
    }

    private func persist() {
        do {
            document.schemaVersion = 5
            document.updatedAt = Date()
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            let data = try encoder.encode(document)
            try data.write(to: documentURL, options: .atomic)
            lastKnownModificationDate = fileModificationDate()
            message = "Saved locally"
        } catch {
            message = "Save failed"
            AppDiagnostics.failure(.personalizationSave, category: .storage, error: error)
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

    private func applyPreviewOverrides() {
        let environment = ProcessInfo.processInfo.environment
        if let rawAccent = environment["OPENLOOPS_PREVIEW_ACCENT"],
           let accent = AccentPalette(rawValue: rawAccent) {
            document.accent = accent
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

    private static let defaultDocument = PersonalizationDocument(
        schemaVersion: 5,
        displayName: "Founder's Office",
        accent: .blue,
        iconStyle: .system,
        photoFileName: nil,
        primaryGoal: nil,
        milestones: [],
        preferredName: nil,
        workspaceName: "Founder's Office"
    )
}
