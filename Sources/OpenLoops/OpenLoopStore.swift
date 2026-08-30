import AppKit
import Foundation
import FounderOfficeCore

@MainActor
final class OpenLoopStore: ObservableObject {
    @Published private(set) var items: [OpenLoop] = []
    @Published private(set) var lastSavedAt: Date?
    @Published private(set) var syncMessage = "Loading…"
    @Published private(set) var recentlyDeleted: OpenLoop?

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
        applyPreviewOverrides()
        startWatching()
    }

    deinit {
        watcher?.invalidate()
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
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index] = OpenLoopRules.toggledCompletion(items[index], at: Date())
        persist()
    }

    func move(_ item: OpenLoop, to status: LoopStatus) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index] = OpenLoopRules.moved(items[index], to: status, at: Date())
        persist()
    }

    func add(title: String, details: String = "", status: LoopStatus, priority: LoopPriority, dueAt: Date?) {
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
                source: "notch-widget"
            )
        )
        persist()
    }

    func delete(_ item: OpenLoop) {
        guard let index = items.firstIndex(where: { $0.id == item.id && $0.deletedAt == nil }) else { return }
        items[index] = OpenLoopRules.softDeleted(items[index], at: Date())
        recentlyDeleted = items[index]
        persist()
    }

    func undoLastDelete() {
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
                items = Self.seedItems
                persist()
                return
            }

            let modificationDate = fileModificationDate()
            if !force, modificationDate == lastKnownModificationDate, !items.isEmpty { return }

            let data = try Data(contentsOf: jsonURL)
            let document = try decoder.decode(OpenLoopsDocument.self, from: data)
            items = document.items
            lastSavedAt = document.updatedAt
            lastKnownModificationDate = modificationDate
            syncMessage = "Synced"

            if !FileManager.default.fileExists(atPath: contextURL.path) {
                try writeContext(updatedAt: document.updatedAt)
            }
        } catch {
            syncMessage = "Sync error"
            AppDiagnostics.failure(.moveStoreLoad, category: .storage, error: error)
        }
    }

    private func applyPreviewOverrides() {
        guard let rawID = ProcessInfo.processInfo.environment["OPENLOOPS_PREVIEW_DELETED_ID"],
              let id = UUID(uuidString: rawID),
              let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].deletedAt = Date()
        recentlyDeleted = items[index]
    }

    private func persist() {
        let now = Date()
        let document = OpenLoopsDocument(schemaVersion: 2, updatedAt: now, items: items)

        do {
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
            let data = try encoder.encode(document)
            try data.write(to: jsonURL, options: .atomic)
            try writeContext(updatedAt: now)
            lastSavedAt = now
            lastKnownModificationDate = fileModificationDate()
            syncMessage = "Saved"
        } catch {
            syncMessage = "Save failed"
            AppDiagnostics.failure(.moveStoreSave, category: .storage, error: error)
        }
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
                    markdown += " · Due \(dueFormatter.string(from: dueAt))"
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
        if let override = ProcessInfo.processInfo.environment["OPENLOOPS_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }

        if let configured = Bundle.main.object(forInfoDictionaryKey: "OpenLoopsWorkspace") as? String,
           !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }

        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return applicationSupport.appendingPathComponent("FoundersOffice", isDirectory: true)
    }
}
