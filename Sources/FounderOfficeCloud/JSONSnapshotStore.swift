import Foundation
import FounderOfficeCore

public extension Notification.Name {
    static let founderOfficeSnapshotDidChange = Notification.Name("FounderOfficeSnapshotDidChange")
}

public enum JSONSnapshotStoreError: Error {
    case invalidAssetFileName
}

/// A cross-platform, offline-first store used by both app targets. On the Mac,
/// these files remain the Codex-facing mirror; on iPhone they live inside the
/// app's Application Support directory.
public actor JSONSnapshotStore {
    public let rootURL: URL
    public let openLoopsURL: URL
    public let personalizationURL: URL
    public let contextURL: URL

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(rootURL: URL) {
        self.rootURL = rootURL
        openLoopsURL = rootURL.appendingPathComponent("openloops.json")
        personalizationURL = rootURL.appendingPathComponent("personalization.json")
        contextURL = rootURL.appendingPathComponent("OPEN_LOOPS_CONTEXT.md")

        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public func readSnapshot() throws -> FounderOfficeSnapshot {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        return FounderOfficeSnapshot(
            openLoops: try readOpenLoops(),
            personalization: try readPersonalization()
        )
    }

    @discardableResult
    public func mergeAndPersist(_ remote: FounderOfficeSnapshot) throws -> FounderOfficeSnapshot {
        let local = try readSnapshot()
        let merged = FounderOfficeSnapshot(
            openLoops: FounderOfficeMerge.openLoops(local: local.openLoops, remote: remote.openLoops),
            personalization: FounderOfficeMerge.personalization(
                local: local.personalization,
                remote: remote.personalization
            )
        )
        try persist(merged)
        return merged
    }

    public func persist(_ snapshot: FounderOfficeSnapshot) throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try encoder.encode(snapshot.openLoops).write(to: openLoopsURL, options: .atomic)
        try encoder.encode(snapshot.personalization).write(to: personalizationURL, options: .atomic)
        try writeContext(for: snapshot.openLoops)
        NotificationCenter.default.post(name: .founderOfficeSnapshotDidChange, object: nil)
    }

    public func photoURL(named fileName: String?) -> URL? {
        guard let fileName = fileName.flatMap(AssetFileName.validated) else { return nil }
        let url = rootURL
            .appendingPathComponent("Personalization", isDirectory: true)
            .appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func importPhoto(from sourceURL: URL, named fileName: String) throws {
        guard let fileName = AssetFileName.validated(fileName) else {
            throw JSONSnapshotStoreError.invalidAssetFileName
        }
        let directory = rootURL.appendingPathComponent("Personalization", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(fileName)
        let data = try Data(contentsOf: sourceURL)
        try data.write(to: destination, options: .atomic)
    }

    private func readOpenLoops() throws -> OpenLoopsDocument {
        guard FileManager.default.fileExists(atPath: openLoopsURL.path) else {
            return OpenLoopsDocument(schemaVersion: 3, updatedAt: Date(), items: [])
        }
        let document = try decoder.decode(
            OpenLoopsDocument.self,
            from: Data(contentsOf: openLoopsURL)
        )
        return OpenLoopsMigration.upgradingPlanningSchema(document)
    }

    private func readPersonalization() throws -> PersonalizationDocument {
        guard FileManager.default.fileExists(atPath: personalizationURL.path) else {
            return PersonalizationDocument(
                schemaVersion: 6,
                displayName: "Founder's Office",
                accent: .blue,
                iconStyle: .system,
                photoFileName: nil,
                primaryGoal: nil,
                milestones: [],
                updatedAt: Date(),
                preferredName: nil,
                workspaceName: "Founder's Office",
                appearance: .manish()
            )
        }
        return try decoder.decode(PersonalizationDocument.self, from: Data(contentsOf: personalizationURL))
    }

    private func writeContext(for document: OpenLoopsDocument) throws {
        let markdown = Self.contextMarkdown(for: document, calendar: .current)
        try markdown.write(to: contextURL, atomically: true, encoding: .utf8)
    }

    static func contextMarkdown(
        for document: OpenLoopsDocument,
        calendar: Calendar
    ) -> String {
        let timestamp = DateFormatter()
        timestamp.locale = Locale(identifier: "en_GB")
        timestamp.timeZone = calendar.timeZone
        timestamp.dateFormat = "d MMMM yyyy, HH:mm zzz"

        let dueDate = DateFormatter()
        dueDate.locale = Locale(identifier: "en_GB")
        dueDate.timeZone = calendar.timeZone
        dueDate.dateFormat = "d MMM yyyy"

        var markdown = "# Founder's Office Moves\n\n"
        markdown += "Updated: \(timestamp.string(from: document.updatedAt))\n\n"
        markdown += "> This file is generated from `openloops.json`. Use the widget or `Scripts/openloops.py` to make changes.\n\n"

        for status in LoopStatus.allCases {
            let items = document.items
                .filter { $0.deletedAt == nil && $0.status == status }
                .sorted(by: OpenLoopRules.precedes)
            markdown += "## \(status.title) (\(items.count))\n\n"

            if items.isEmpty {
                markdown += "_None._\n\n"
                continue
            }

            for item in items {
                markdown += "- [\(status == .done ? "x" : " ")] **\(item.priority.rawValue)** — \(item.title)"
                if let dueAt = item.dueAt {
                    let displayDate = PlanningDate.localDate(
                        fromStored: dueAt,
                        calendar: calendar
                    )
                    markdown += " · Due \(dueDate.string(from: displayDate))"
                }
                markdown += "\n"
                if !item.details.isEmpty { markdown += "  - \(item.details)\n" }
                markdown += "  - ID: `\(item.id.uuidString.lowercased())`\n"
            }
            markdown += "\n"
        }

        return markdown
    }
}
