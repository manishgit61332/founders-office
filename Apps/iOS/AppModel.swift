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
    @Published private(set) var recoveryState: WorkspaceRecoveryState

    private let storage: WorkspaceStorage
    private let cloudSync: FounderOfficeCloudSync?
    private var cancellables = Set<AnyCancellable>()

    init(storage: WorkspaceStorage = WorkspaceStorage()) {
        let openLoopsLoad = storage.loadOpenLoops()
        let personalizationLoad = storage.loadPersonalization()
        let initialOpenLoops = openLoopsLoad.value ?? OpenLoopsDocument(
            schemaVersion: 2,
            updatedAt: .now,
            items: []
        )
        let initialPersonalization = personalizationLoad.value ?? PersonalizationDocument(
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
        let initialRecoveryState = openLoopsLoad.recoveryState
            .merging(personalizationLoad.recoveryState)

        self.storage = storage
        self.openLoops = initialOpenLoops
        self.personalization = initialPersonalization
        self.recoveryState = initialRecoveryState

        if !initialRecoveryState.requiresRecovery {
            // Bootstrap the offline mirror before CKSyncEngine starts. This avoids
            // a first launch ever uploading an empty workspace over existing data.
            storage.save(initialOpenLoops)
            storage.save(initialPersonalization)
        }

        let snapshotStore = JSONSnapshotStore(rootURL: storage.storageDirectory)
        if let configuration = try? FounderOfficeCloudConfiguration.bundled() {
            cloudSync = FounderOfficeCloudSync(
                snapshotStore: snapshotStore,
                sidecarURL: storage.storageDirectory.appendingPathComponent("cloud-sync-state.json"),
                configuration: configuration
            )
        } else {
            cloudSync = nil
            cloudStatus = .error
        }

        NotificationCenter.default.publisher(for: .founderOfficeSnapshotDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.reloadFromOfflineMirror()
            }
            .store(in: &cancellables)

        if initialRecoveryState.requiresRecovery {
            cloudStatus = .error
        } else if let cloudSync {
            Task { [weak self] in
                guard let self else { return }
                await cloudSync.start()
                try? await cloudSync.syncNow()
                await refreshCloudStatus()
            }
        }
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
            source: "ios"
        )
        openLoops.items.append(loop)
        persistOpenLoops(at: now)
    }

    func toggleCompletion(_ loop: OpenLoop) {
        guard canEdit else { return }
        replace(loop, with: OpenLoopRules.toggledCompletion(loop, at: .now))
    }

    func move(_ loop: OpenLoop, to status: LoopStatus) {
        guard canEdit else { return }
        replace(loop, with: OpenLoopRules.moved(loop, to: status, at: .now))
    }

    func softDelete(_ loop: OpenLoop) {
        guard canEdit else { return }
        replace(loop, with: OpenLoopRules.softDeleted(loop, at: .now))
    }

    func updatePreferredName(_ preferredName: String) {
        guard canEdit else { return }
        let cleanValue = preferredName.trimmingCharacters(in: .whitespacesAndNewlines)
        personalization.preferredName = cleanValue.isEmpty ? nil : cleanValue
        persistPersonalization()
    }

    func updateWorkspaceName(_ workspaceName: String) {
        guard canEdit else { return }
        let cleanValue = workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        personalization.workspaceName = cleanValue.isEmpty ? "Founder's Office" : cleanValue
        persistPersonalization()
    }

    func updateAccent(_ accent: AccentPalette) {
        guard canEdit else { return }
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
        guard canEdit else { return }
        guard preset != .custom else { return }
        let appearance = AppearancePreferences.preset(preset)
        personalization.appearance = appearance
        personalization.accent = nearestLegacyAccent(to: appearance.accent.primaryColor)
        persistPersonalization()
    }

    func updateAccentMode(_ mode: AccentMode) {
        guard canEdit else { return }
        updateAppearance { appearance in
            var stops = appearance.accent.normalizedStops
            if mode == .gradient, stops.count == 1 {
                stops.append(AccentStop(color: RGB24Color(red: 126, green: 87, blue: 194), location: 1))
            }
            appearance.accent = AccentStyle(mode: mode, stops: stops, angleDegrees: appearance.accent.angleDegrees)
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
        updateAppearance { $0.accent.angleDegrees = angle }
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

    func setPrimaryGoal(_ goal: PrimaryGoal) {
        guard canEdit else { return }
        var updated = goal
        updated.updatedAt = .now
        updated.deletedAt = nil
        personalization.primaryGoal = updated
        persistPersonalization()
    }

    func clearPrimaryGoal() {
        guard canEdit else { return }
        guard var goal = personalization.primaryGoal else { return }
        let now = Date()
        goal.updatedAt = now
        goal.deletedAt = now
        personalization.primaryGoal = goal
        persistPersonalization(at: now)
    }

    func saveVisionImage(_ data: Data) {
        guard canEdit else { return }
        guard let image = UIImage(data: data),
              let jpeg = image.jpegData(compressionQuality: 0.9)
        else { return }

        let fileName = "vision-\(UUID().uuidString.lowercased()).jpg"
        guard storage.savePhoto(jpeg, named: fileName) else { return }
        personalization.photoFileName = fileName
        persistPersonalization()
    }

    func syncCloudNow() {
        guard canUseCloud, let cloudSync else { return }
        Task { [weak self] in
            guard let self else { return }
            try? await cloudSync.syncNow()
            await refreshCloudStatus()
        }
    }

    func resumeCloudAfterAccountReview(uploadLocalWorkspace: Bool) {
        guard canUseCloud, let cloudSync else { return }
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
        guard canEdit else { return }
        openLoops.updatedAt = date
        storage.save(openLoops)
        queueCloudSave()
    }

    private func persistPersonalization(at date: Date = .now) {
        guard canEdit else { return }
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
        guard canUseCloud, let cloudSync else { return }
        Task { [weak self] in
            guard let self else { return }
            await cloudSync.noteLocalChange()
            await refreshCloudStatus()
        }
    }

    private func refreshCloudStatus() async {
        guard let cloudSync else {
            cloudStatus = .error
            return
        }
        cloudStatus = await cloudSync.status
    }

    private func reloadFromOfflineMirror() {
        let openLoopsLoad = storage.loadOpenLoops()
        let personalizationLoad = storage.loadPersonalization()

        if let latestOpenLoops = openLoopsLoad.value {
            openLoops = latestOpenLoops
        }
        if let latestPersonalization = personalizationLoad.value {
            personalization = latestPersonalization
        }

        let discoveredRecovery = openLoopsLoad.recoveryState
            .merging(personalizationLoad.recoveryState)
        if discoveredRecovery.requiresRecovery {
            recoveryState = recoveryState.merging(discoveredRecovery)
            cloudStatus = .error
        }
    }

    private var canEdit: Bool {
        !recoveryState.requiresRecovery
    }

    private var canUseCloud: Bool {
        guard !recoveryState.requiresRecovery else {
            cloudStatus = .error
            return false
        }
        guard cloudSync != nil else {
            cloudStatus = .error
            return false
        }
        return true
    }
}

enum WorkspaceLoadResult<Value> {
    case missing
    case loaded(Value)
    case recoveryRequired(WorkspaceRecoveryState)

    var value: Value? {
        guard case let .loaded(value) = self else { return nil }
        return value
    }

    var recoveryState: WorkspaceRecoveryState {
        guard case let .recoveryRequired(state) = self else { return .ready }
        return state
    }
}

struct WorkspaceStorage {
    private let fileManager: FileManager
    private let appGroupID = "group.com.manish.foundersoffice"

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func loadOpenLoops() -> WorkspaceLoadResult<OpenLoopsDocument> {
        decode(OpenLoopsDocument.self, named: "openloops", component: .openLoops)
    }

    func loadPersonalization() -> WorkspaceLoadResult<PersonalizationDocument> {
        decode(PersonalizationDocument.self, named: "personalization", component: .personalization)
    }

    func save(_ document: OpenLoopsDocument) {
        encode(document, named: "openloops")
    }

    func save(_ document: PersonalizationDocument) {
        encode(document, named: "personalization")
    }

    func loadPhoto(named fileName: String) -> Data? {
        guard let fileName = AssetFileName.validated(fileName) else { return nil }
        return try? Data(contentsOf: photoDirectory.appendingPathComponent(fileName))
    }

    @discardableResult
    func savePhoto(_ data: Data, named fileName: String) -> Bool {
        guard let fileName = AssetFileName.validated(fileName) else { return false }
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

    private func decode<Value: Decodable>(
        _ type: Value.Type,
        named name: String,
        component: WorkspaceStorageComponent
    ) -> WorkspaceLoadResult<Value> {
        let localURL = storageDirectory.appendingPathComponent("\(name).json")
        let hasCanonicalFile = fileManager.fileExists(atPath: localURL.path)
        guard let sourceURL = hasCanonicalFile
            ? localURL
            : Bundle.main.url(forResource: name, withExtension: "json")
        else {
            return .missing
        }

        let data: Data
        do {
            data = try Data(contentsOf: sourceURL)
        } catch {
            return .recoveryRequired(recoveryState(for: component, preservedCopyName: nil))
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return .loaded(try decoder.decode(type, from: data))
        } catch {
            let preservedCopyName: String?
            if hasCanonicalFile {
                preservedCopyName = (try? CorruptFileQuarantine.preserve(
                    localURL,
                    fileManager: fileManager
                ))?.lastPathComponent
            } else {
                preservedCopyName = nil
            }
            return .recoveryRequired(
                recoveryState(for: component, preservedCopyName: preservedCopyName)
            )
        }
    }

    private func recoveryState(
        for component: WorkspaceStorageComponent,
        preservedCopyName: String?
    ) -> WorkspaceRecoveryState {
        WorkspaceRecoveryState(
            affectedComponents: [component],
            preservedCopyNames: preservedCopyName.map { [$0] } ?? []
        )
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
            let error = error as NSError
            assertionFailure(
                "Could not save \(name) (domain: \(error.domain), code: \(error.code))."
            )
        }
    }

    private func ensureStorageDirectory() throws {
        try fileManager.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: true
        )
    }
}
