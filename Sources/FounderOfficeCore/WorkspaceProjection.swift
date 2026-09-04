import CryptoKit
import Foundation

public struct WorkspaceExportManifest: Codable, Sendable {
    public struct FileRecord: Codable, Sendable {
        public var name: String
        public var byteCount: Int
        public var sha256: String

        public init(name: String, byteCount: Int, sha256: String) {
            self.name = name
            self.byteCount = byteCount
            self.sha256 = sha256
        }
    }

    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var workspaceID: UUID
    public var revision: WorkspaceRevision
    public var generatedAt: Date
    public var files: [FileRecord]

    public init(
        schemaVersion: Int = WorkspaceExportManifest.currentSchemaVersion,
        workspaceID: UUID,
        revision: WorkspaceRevision,
        generatedAt: Date,
        files: [FileRecord]
    ) {
        self.schemaVersion = schemaVersion
        self.workspaceID = workspaceID
        self.revision = revision
        self.generatedAt = generatedAt
        self.files = files
    }
}

enum WorkspaceProjection {
    static let openLoopsFileName = "openloops.json"
    static let personalizationFileName = "personalization.json"
    static let contextFileName = "OPEN_LOOPS_CONTEXT.md"
    static let manifestFileName = "workspace-export-manifest.json"

    static func contextMarkdown(
        for document: OpenLoopsDocument,
        generatedAt: Date,
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

        var markdown = "# Founder’s Office Moves\n\n"
        markdown += "Exported: \(timestamp.string(from: generatedAt))\n\n"
        markdown += "> Generated from the transactional workspace. Direct edits are not imported automatically.\n\n"

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
                    let displayDate = PlanningDate.localDate(fromStored: dueAt, calendar: calendar)
                    markdown += " · Due \(dueDate.string(from: displayDate))"
                }
                markdown += "\n"
                if !item.details.isEmpty {
                    markdown += "  - \(item.details)\n"
                }
                markdown += "  - ID: `\(item.id.uuidString.lowercased())`\n"
            }
            markdown += "\n"
        }

        return markdown
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
