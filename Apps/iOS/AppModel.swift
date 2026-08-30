import Combine
import Foundation
import FounderOfficeCloud
import FounderOfficeCore
import UIKit

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var openLoops: OpenLoopsDocument
    @Published private(set) var personalization: PersonalizationDocument
    @Published private(set) var cloudStatus: FounderOfficeCloudStatus = .preparing

    private let storage: WorkspaceStorage
    private let cloudSync: FounderOfficeCloudSync
    private var cancellables = Set<AnyCancellable>()

    init(storage: WorkspaceStorage = WorkspaceStorage()) {
        let initialOpenLoops = storage.loadOpenLoops() ?? OpenLoopsDocument(
            schemaVersion: 2,
            updatedAt: .now,
            items: []
        )
        let initialPersonalization = storage.loadPersonalization() ?? PersonalizationDocument(
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

        self.storage = storage
        self.openLoops = initialOpenLoops
        self.personalization = initialPersonalization

        // Bootstrap the offline mirror before CKSyncEngine starts. This avoids
        // a first launch ever uploading an empty workspace over existing data.
        storage.save(initialOpenLoops)
        storage.save(initialPersonalization)

        let snapshotStore = JSONSnapshotStore(rootURL: storage.storageDirectory)
        cloudSync = FounderOfficeCloudSync(
            snapshotStore: snapshotStore,
            sidecarURL: storage.storageDirectory.appendingPathComponent("cloud-sync-state.json")
        )

        NotificationCenter.default.publisher(for: .founderOfficeSnapshotDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.reloadFromOfflineMirror()
            }
            .store(in: &cancellables)

        Task { [weak self] in
            guard let self else { return }
            await cloudSync.start()
            try? await cloudSync.syncNow()
            await refreshCloudStatus()
        }
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
        guard let fileName = personalization.photoFileName,
              let data = storage.loadPhoto(named: fileName)
        else { return nil }
        return UIImage(data: data)
    }

    func addLoop(
        title: String,
        details: String,
        status: LoopStatus,
        priority: LoopPriority,
        dueAt: Date?
    ) {
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
            source: "ios"
        )
        openLoops.items.append(loop)
        persistOpenLoops(at: now)
    }

    func toggleCompletion(_ loop: OpenLoop) {
        replace(loop, with: OpenLoopRules.toggledCompletion(loop, at: .now))
    }

    func move(_ loop: OpenLoop, to status: LoopStatus) {
        replace(loop, with: OpenLoopRules.moved(loop, to: status, at: .now))
    }

    func softDelete(_ loop: OpenLoop) {
        replace(loop, with: OpenLoopRules.softDeleted(loop, at: .now))
    }

    func updatePreferredName(_ preferredName: String) {
        let cleanValue = preferredName.trimmingCharacters(in: .whitespacesAndNewlines)
        personalization.preferredName = cleanValue.isEmpty ? nil : cleanValue
        persistPersonalization()
    }

    func updateWorkspaceName(_ workspaceName: String) {
        let cleanValue = workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        personalization.workspaceName = cleanValue.isEmpty ? "Founder's Office" : cleanValue
        persistPersonalization()
    }

    func updateAccent(_ accent: AccentPalette) {
        personalization.accent = accent
        var appearance = personalization.resolvedAppearance
        appearance.presetID = .custom
        appearance.accent = AccentStyle(
            mode: .solid,
            stops: [AccentStop(color: accent.rgb24, location: 0)]
        )
        appearance.updatedAt = .now
        personalization.appearance = appearance
        persistPersonalization()
    }

    func applyAppearancePreset(_ preset: AppearancePresetID) {
        guard preset != .custom else { return }
        let appearance = AppearancePreferences.preset(preset)
        personalization.appearance = appearance
        personalization.accent = nearestLegacyAccent(to: appearance.accent.primaryColor)
        persistPersonalization()
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
        var updated = goal
        updated.updatedAt = .now
        updated.deletedAt = nil
        personalization.primaryGoal = updated
        persistPersonalization()
    }

    func clearPrimaryGoal() {
        guard var goal = personalization.primaryGoal else { return }
        let now = Date()
        goal.updatedAt = now
        goal.deletedAt = now
        personalization.primaryGoal = goal
        persistPersonalization(at: now)
    }

    func saveVisionImage(_ data: Data) {
        guard let image = UIImage(data: data),
              let jpeg = image.jpegData(compressionQuality: 0.9)
        else { return }

        let fileName = "vision-\(UUID().uuidString.lowercased()).jpg"
        guard storage.savePhoto(jpeg, named: fileName) else { return }
        personalization.photoFileName = fileName
        persistPersonalization()
    }

    func syncCloudNow() {
        Task { [weak self] in
            guard let self else { return }
            try? await cloudSync.syncNow()
            await refreshCloudStatus()
        }
    }

    func resumeCloudAfterAccountReview(uploadLocalWorkspace: Bool) {
        Task { [weak self] in
            guard let self else { return }
            try? await cloudSync.resumeAfterAccountReview(
                uploadLocalWorkspace: uploadLocalWorkspace
            )
            await refreshCloudStatus()
        }
    }

    private func replace(_ original: OpenLoop, with updated: OpenLoop) {
        guard let index = openLoops.items.firstIndex(where: { $0.id == original.id }) else { return }
        openLoops.items[index] = updated
        persistOpenLoops(at: updated.updatedAt)
    }

    private func persistOpenLoops(at date: Date) {
        openLoops.updatedAt = date
        storage.save(openLoops)
        queueCloudSave()
    }

    private func persistPersonalization(at date: Date = .now) {
        personalization.schemaVersion = max(personalization.schemaVersion, 6)
        personalization.updatedAt = date
        storage.save(personalization)
        queueCloudSave()
    }

    private func updateAppearance(_ update: (inout AppearancePreferences) -> Void) {
        var appearance = personalization.resolvedAppearance
        update(&appearance)
        appearance.presetID = .custom
        appearance.updatedAt = .now
        personalization.appearance = appearance
        personalization.accent = nearestLegacyAccent(to: appearance.accent.primaryColor)
        persistPersonalization()
    }

    private func nearestLegacyAccent(to color: RGB24Color) -> AccentPalette {
        AccentPalette.allCases.min { lhs, rhs in
            colorDistance(lhs.rgb24, color) < colorDistance(rhs.rgb24, color)
        } ?? .blue
    }

    private func colorDistance(_ lhs: RGB24Color, _ rhs: RGB24Color) -> Int {
        let red = Int(lhs.red) - Int(rhs.red)
        let green = Int(lhs.green) - Int(rhs.green)
        let blue = Int(lhs.blue) - Int(rhs.blue)
        return red * red + green * green + blue * blue
    }

    private func queueCloudSave() {
        Task { [weak self] in
            guard let self else { return }
            await cloudSync.noteLocalChange()
            await refreshCloudStatus()
        }
    }

    private func refreshCloudStatus() async {
        cloudStatus = await cloudSync.status
    }

    private func reloadFromOfflineMirror() {
        if let latestOpenLoops = storage.loadOpenLoops() {
            openLoops = latestOpenLoops
        }
        if let latestPersonalization = storage.loadPersonalization() {
            personalization = latestPersonalization
        }
    }
}

struct WorkspaceStorage {
    private let fileManager: FileManager
    private let appGroupID = "group.com.manish.foundersoffice"

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func loadOpenLoops() -> OpenLoopsDocument? {
        decode(OpenLoopsDocument.self, named: "openloops")
    }

    func loadPersonalization() -> PersonalizationDocument? {
        decode(PersonalizationDocument.self, named: "personalization")
    }

    func save(_ document: OpenLoopsDocument) {
        encode(document, named: "openloops")
    }

    func save(_ document: PersonalizationDocument) {
        encode(document, named: "personalization")
    }

    func loadPhoto(named fileName: String) -> Data? {
        try? Data(contentsOf: photoDirectory.appendingPathComponent(fileName))
    }

    @discardableResult
    func savePhoto(_ data: Data, named fileName: String) -> Bool {
        do {
            try ensureStorageDirectory()
            try fileManager.createDirectory(at: photoDirectory, withIntermediateDirectories: true)
            try data.write(to: photoDirectory.appendingPathComponent(fileName), options: .atomic)
            return true
        } catch {
            return false
        }
    }

    var storageDirectory: URL {
        if let groupURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            return groupURL.appendingPathComponent("FounderOffice", isDirectory: true)
        }

        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return applicationSupport.appendingPathComponent("FounderOffice", isDirectory: true)
    }

    private var photoDirectory: URL {
        storageDirectory.appendingPathComponent("Personalization", isDirectory: true)
    }

    private func decode<Value: Decodable>(_ type: Value.Type, named name: String) -> Value? {
        let localURL = storageDirectory.appendingPathComponent("\(name).json")
        let sourceURL = fileManager.fileExists(atPath: localURL.path)
            ? localURL
            : Bundle.main.url(forResource: name, withExtension: "json")

        guard let sourceURL, let data = try? Data(contentsOf: sourceURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }

    private func encode<Value: Encodable>(_ value: Value, named name: String) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        do {
            try ensureStorageDirectory()
            let data = try encoder.encode(value)
            try data.write(
                to: storageDirectory.appendingPathComponent("\(name).json"),
                options: .atomic
            )
        } catch {
            assertionFailure("Could not save \(name): \(error.localizedDescription)")
        }
    }

    private func ensureStorageDirectory() throws {
        try fileManager.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: true
        )
    }
}
