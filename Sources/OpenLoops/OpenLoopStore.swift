import AppKit
import Foundation
import FounderOfficeCore

enum PlanningPriorityChange {
    case unchanged
    case set(LoopPriority)
}

enum PlanningDeadlineChange {
    case unchanged
    case set(Date)
    case clear
}

enum PlanningUpdateResult {
    case saved
    case unchanged
    case failed(String)
}

@MainActor
final class OpenLoopStore: ObservableObject {
    @Published private(set) var items: [OpenLoop] = []
    @Published private(set) var lastSavedAt: Date?
    @Published private(set) var syncMessage = "Loading…"
    @Published private(set) var recentlyDeleted: OpenLoop?
    @Published private(set) var recoveryState: WorkspaceRecoveryState = .ready

    let rootURL: URL
    let jsonURL: URL
    let contextURL: URL

    private var watcher: Timer?
    private var lastKnownModificationDate: Date?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(rootURL: URL = WorkspaceLocator.openLoopsRoot) {
        self.rootURL = rootURL
        self.jsonURL = rootURL.appendingPathComponent("openloops.json")
        self.contextURL = rootURL.appendingPathComponent("OPEN_LOOPS_CONTEXT.md")

        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        loadFromDisk()
        #if !FOUNDER_OFFICE_DISTRIBUTION
        applyPreviewOverrides()
        #endif
        startWatching()
    }

    func stop() {
        watcher?.invalidate()
        watcher = nil
    }

    var activeCount: Int {
        items.filter { $0.deletedAt == nil && $0.status != .done }.count
    }

    func items(in status: LoopStatus) -> [OpenLoop] {
        items
            .filter { $0.deletedAt == nil && $0.status == status }
            .sorted(by: OpenLoopRules.precedes)
    }

    func count(in status: LoopStatus) -> Int {
        items.filter { $0.deletedAt == nil && $0.status == status }.count
    }

    func toggleCompletion(_ item: OpenLoop) {
        guard canEdit else { return }
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index] = OpenLoopRules.toggledCompletion(items[index], at: Date())
        persist()
    }

    func move(_ item: OpenLoop, to status: LoopStatus) {
        guard canEdit else { return }
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index] = OpenLoopRules.moved(items[index], to: status, at: Date())
        persist()
    }

    func updatePlanning(
        id: UUID,
        priorityChange: PlanningPriorityChange,
        deadlineChange: PlanningDeadlineChange
    ) -> PlanningUpdateResult {
        // Pull in a CLI or cloud write that may have landed since the watcher
        // last fired, then apply only the fields this editor actually changed.
        loadFromDisk(force: true)
        guard canEdit else {
            return .failed(recoveryState.message)
        }
        guard let index = items.firstIndex(where: { $0.id == id && $0.deletedAt == nil }) else {
            return .failed("This task is no longer available.")
        }

        let current = items[index]
        let resolvedPriority: LoopPriority
        switch priorityChange {
        case .unchanged:
            resolvedPriority = current.priority
        case let .set(priority):
            resolvedPriority = priority
        }

        let currentPlanningDay = current.dueAt.map(PlanningDate.day(fromStored:))
        let resolvedDueAt: Date?
        switch deadlineChange {
        case .unchanged:
            resolvedDueAt = current.dueAt
        case let .set(date):
            let selectedDay = PlanningDate.day(fromLocal: date)
            // Preserve a legacy time component when the calendar day did not change.
            // Deadlines are all-day values, so a priority-only edit must not rewrite one.
            resolvedDueAt = currentPlanningDay == selectedDay
                ? current.dueAt
                : PlanningDate.storedDate(for: selectedDay)
        case .clear:
            resolvedDueAt = nil
        }

        guard current.priority != resolvedPriority || current.dueAt != resolvedDueAt else {
            return .unchanged
        }

        let updated = OpenLoopRules.updatedPlanning(
            current,
            priority: resolvedPriority,
            dueAt: resolvedDueAt,
            at: Date()
        )

        items[index] = updated
        guard persist() else {
            items[index] = current
            return .failed("Couldn’t save those changes. Check the workspace and try again.")
        }
        return .saved
    }

    func add(title: String, details: String = "", status: LoopStatus, priority: LoopPriority, dueAt: Date?) {
        guard canEdit else { return }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return }
        let now = Date()

        items.append(
            OpenLoop(
                id: UUID(),
                title: cleanTitle,
                details: details.trimmingCharacters(in: .whitespacesAndNewlines),
                status: status,
                previousStatus: nil,
                priority: priority,
                dueAt: dueAt,
                createdAt: now,
                updatedAt: now,
                completedAt: nil,
                deletedAt: nil,
                source: "notch-widget",
                priorityUpdatedAt: now,
                dueAtUpdatedAt: now
            )
        )
        persist()
    }

    func delete(_ item: OpenLoop) {
        guard canEdit else { return }
        guard let index = items.firstIndex(where: { $0.id == item.id && $0.deletedAt == nil }) else { return }
        items[index] = OpenLoopRules.softDeleted(items[index], at: Date())
        recentlyDeleted = items[index]
        persist()
    }

    func undoLastDelete() {
        guard canEdit else { return }
        guard let deleted = recentlyDeleted,
              let index = items.firstIndex(where: { $0.id == deleted.id }) else { return }
        items[index] = OpenLoopRules.restored(items[index], at: Date())
        recentlyDeleted = nil
        persist()
    }

    func reload() {
        loadFromDisk(force: true)
    }

    func openContextFile() {
        NSWorkspace.shared.open(contextURL)
    }

    func revealDataFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([jsonURL])
    }

    private func loadFromDisk(force: Bool = false) {
        do {
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

            guard FileManager.default.fileExists(atPath: jsonURL.path) else {
                guard !recoveryState.requiresRecovery else {
                    syncMessage = recoveryState.message
                    return
                }
                items = Self.seedItems
                persist()
                return
            }

            let modificationDate = fileModificationDate()
            if !force, modificationDate == lastKnownModificationDate, !items.isEmpty { return }

            let data: Data
            do {
                data = try Data(contentsOf: jsonURL)
            } catch {
                requireRecovery(preservedCopyName: nil, error: error)
                return
            }

            let decodedDocument: OpenLoopsDocument
            do {
                decodedDocument = try decoder.decode(OpenLoopsDocument.self, from: data)
            } catch {
                let preservedCopyName = (try? CorruptFileQuarantine.preserve(jsonURL))?.lastPathComponent
                requireRecovery(preservedCopyName: preservedCopyName, error: error)
                return
            }
            let document = OpenLoopsMigration.upgradingPlanningSchema(decodedDocument)

            items = document.items
            lastSavedAt = document.updatedAt
            lastKnownModificationDate = modificationDate
            recoveryState = .ready
            syncMessage = "Synced"

            if !FileManager.default.fileExists(atPath: contextURL.path) {
                try writeContext(updatedAt: document.updatedAt)
            }
        } catch {
            syncMessage = "Sync error"
            AppDiagnostics.failure(.moveStoreLoad, category: .storage, error: error)
        }
    }

    #if !FOUNDER_OFFICE_DISTRIBUTION
    private func applyPreviewOverrides() {
        if ProcessInfo.processInfo.environment["OPENLOOPS_UI_TEST_FIXTURE"] == "1",
           items.isEmpty {
            let now = Date()
            items = [
                OpenLoop(
                    id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                    title: "Prepare launch brief",
                    details: "Synthetic UI test fixture",
                    status: .doing,
                    previousStatus: nil,
                    priority: .p1,
                    dueAt: nil,
                    createdAt: now,
                    updatedAt: now,
                    completedAt: nil,
                    deletedAt: nil,
                    source: "ui-test",
                    priorityUpdatedAt: now,
                    dueAtUpdatedAt: now
                )
            ]
            _ = persist()
        }

        guard let rawID = ProcessInfo.processInfo.environment["OPENLOOPS_PREVIEW_DELETED_ID"],
              let id = UUID(uuidString: rawID),
              let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].deletedAt = Date()
        recentlyDeleted = items[index]
    }
    #endif

    @discardableResult
    private func persist() -> Bool {
        guard canEdit else { return false }
        let now = Date()
        let document = OpenLoopsDocument(schemaVersion: 3, updatedAt: now, items: items)

        do {
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            let data = try encoder.encode(document)
            try data.write(to: jsonURL, options: .atomic)
            lastSavedAt = now
            lastKnownModificationDate = fileModificationDate()
            syncMessage = "Saved"
        } catch {
            syncMessage = "Save failed"
            AppDiagnostics.failure(.moveStoreSave, category: .storage, error: error)
            return false
        }

        // The JSON document is canonical. A derived Markdown refresh must never
        // turn a successful task save into an apparent failure.
        do {
            try writeContext(updatedAt: now)
        } catch {
            AppDiagnostics.failure(.moveStoreSave, category: .storage, error: error)
        }
        return true
    }

    private func startWatching() {
        watcher = Timer.scheduledTimer(withTimeInterval: 1.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.reloadIfChanged()
            }
        }
        watcher?.tolerance = 0.25
    }

    private func reloadIfChanged() {
        guard let modificationDate = fileModificationDate() else { return }
        guard modificationDate != lastKnownModificationDate else { return }
        loadFromDisk(force: true)
    }

    private func fileModificationDate() -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: jsonURL.path)
        return attributes?[.modificationDate] as? Date
    }

    private var canEdit: Bool {
        guard !recoveryState.requiresRecovery else {
            syncMessage = recoveryState.message
            return false
        }
        return true
    }

    private func requireRecovery(preservedCopyName: String?, error: Error) {
        lastKnownModificationDate = fileModificationDate()
        recoveryState = WorkspaceRecoveryState(
            affectedComponents: [.openLoops],
            preservedCopyNames: preservedCopyName.map { [$0] } ?? []
        )
        syncMessage = recoveryState.message
        AppDiagnostics.failure(.moveStoreLoad, category: .storage, error: error)
    }

    private func writeContext(updatedAt: Date) throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.timeZone = .current
        formatter.dateFormat = "d MMMM yyyy, HH:mm zzz"

        var markdown = "# Founder's Office Moves\n\n"
        markdown += "Updated: \(formatter.string(from: updatedAt))\n\n"
        markdown += "> This file is generated from `openloops.json`. Use the widget or `Scripts/openloops.py` to make changes.\n\n"

        for status in LoopStatus.allCases {
            let sectionItems = items(in: status)
            markdown += "## \(status.title) (\(sectionItems.count))\n\n"

            if sectionItems.isEmpty {
                markdown += "_None._\n\n"
                continue
            }

            for item in sectionItems {
                let checkbox = status == .done ? "x" : " "
                markdown += "- [\(checkbox)] **\(item.priority.rawValue)** — \(item.title)"
                if let dueAt = item.dueAt {
                    let dueFormatter = DateFormatter()
                    dueFormatter.locale = Locale(identifier: "en_GB")
                    dueFormatter.dateFormat = "d MMM yyyy"
                    let displayDate = PlanningDate.localDate(fromStored: dueAt)
                    markdown += " · Due \(dueFormatter.string(from: displayDate))"
                }
                markdown += "\n"
                if !item.details.isEmpty {
                    markdown += "  - \(item.details)\n"
                }
                markdown += "  - ID: `\(item.id.uuidString.lowercased())`\n"
            }
            markdown += "\n"
        }

        try markdown.write(to: contextURL, atomically: true, encoding: .utf8)
    }

    private static var seedItems: [OpenLoop] {
        []
    }
}

enum WorkspaceLocator {
    static var openLoopsRoot: URL {
        #if !FOUNDER_OFFICE_DISTRIBUTION
        if let override = ProcessInfo.processInfo.environment["OPENLOOPS_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }

        if let configured = Bundle.main.object(forInfoDictionaryKey: "OpenLoopsWorkspace") as? String,
           !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        #endif

        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return applicationSupport.appendingPathComponent("FoundersOffice", isDirectory: true)
    }
}
