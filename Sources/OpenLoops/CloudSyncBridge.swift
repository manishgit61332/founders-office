import Combine
import Foundation
import FounderOfficeCloud

/// Connects the Codex-facing JSON files to the same CKSyncEngine transport used
/// by iPhone. It is activated only by the signed Xcode target because CloudKit
/// requires iCloud and remote-notification entitlements.
@MainActor
final class CloudSyncBridge {
    private let rootURL: URL
    private let sync: FounderOfficeCloudSync
    private var watcher: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var lastOpenLoopsModification: Date?
    private var lastPersonalizationModification: Date?

    init(rootURL: URL) {
        self.rootURL = rootURL
        let snapshotStore = JSONSnapshotStore(rootURL: rootURL)
        sync = FounderOfficeCloudSync(
            snapshotStore: snapshotStore,
            sidecarURL: rootURL
                .appendingPathComponent(".founders-office-cloud", isDirectory: true)
                .appendingPathComponent("sync-state.json")
        )
    }

    deinit {
        watcher?.invalidate()
    }

    func start() {
        rememberModificationDates()
        NotificationCenter.default.publisher(for: .founderOfficeSnapshotDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                // Cloud-origin writes have already been merged. Advance the
                // file baseline so the watcher does not echo them back as a
                // new local edit and create a device-to-device sync loop.
                self?.rememberModificationDates()
            }
            .store(in: &cancellables)

        Task {
            await sync.start()
            try? await sync.syncNow()
        }

        watcher = Timer.scheduledTimer(withTimeInterval: 1.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.queueChangedFiles()
            }
        }
        watcher?.tolerance = 0.25
    }

    private func queueChangedFiles() {
        let previousOpenLoops = lastOpenLoopsModification
        let previousPersonalization = lastPersonalizationModification
        rememberModificationDates()

        guard previousOpenLoops != lastOpenLoopsModification
                || previousPersonalization != lastPersonalizationModification else { return }
        Task { await sync.noteLocalChange() }
    }

    private func rememberModificationDates() {
        lastOpenLoopsModification = modificationDate(
            at: rootURL.appendingPathComponent("openloops.json")
        )
        lastPersonalizationModification = modificationDate(
            at: rootURL.appendingPathComponent("personalization.json")
        )
    }

    private func modificationDate(at url: URL) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.modificationDate] as? Date
    }
}
