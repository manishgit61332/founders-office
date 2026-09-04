import Foundation
import FounderOfficeCore

struct PreparedWorkspaceBootstrap: Sendable {
    let decision: WorkspaceBootstrapDecision
    let workspaceExistedBeforeLaunch: Bool
    let identityURL: URL
    let preservedIdentityCopyName: String?
}

enum WorkspaceBootstrapCoordinator {
    private struct IdentityDocument: Codable {
        static let currentSchemaVersion = 1

        var schemaVersion: Int
        var workspaceID: UUID
        var createdAt: Date
    }

    static let identityFileName = "workspace-identity.json"

    static func inspect(
        rootURL: URL,
        expectedWorkspaceID: UUID?,
        fileManager: FileManager = .default
    ) -> PreparedWorkspaceBootstrap {
        let openLoopsURL = rootURL.appendingPathComponent("openloops.json")
        let personalizationURL = rootURL.appendingPathComponent("personalization.json")
        let identityURL = rootURL.appendingPathComponent(identityFileName)
        let databaseURL = rootURL.appendingPathComponent("founders-office.sqlite3")
        let openLoopsExists = fileManager.fileExists(atPath: openLoopsURL.path)
        let personalizationExists = fileManager.fileExists(atPath: personalizationURL.path)
        let identityExists = fileManager.fileExists(atPath: identityURL.path)
        let databaseExists = fileManager.fileExists(atPath: databaseURL.path)

        var onDiskWorkspaceID: UUID?
        var identityReadable = !identityExists
        var preservedIdentityCopyName: String?

        if identityExists {
            do {
                let data = try Data(contentsOf: identityURL)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let document = try decoder.decode(IdentityDocument.self, from: data)
                guard document.schemaVersion == IdentityDocument.currentSchemaVersion else {
                    throw CocoaError(.coderInvalidValue)
                }
                onDiskWorkspaceID = document.workspaceID
                identityReadable = true
            } catch {
                preservedIdentityCopyName = (try? CorruptFileQuarantine.preserve(identityURL))?.lastPathComponent
                identityReadable = false
            }
        }

        let decision: WorkspaceBootstrapDecision
        if databaseExists {
            guard identityExists, identityReadable, let onDiskWorkspaceID else {
                return PreparedWorkspaceBootstrap(
                    decision: .requireRecovery(affectedComponents: WorkspaceStorageComponent.allCases),
                    workspaceExistedBeforeLaunch: true,
                    identityURL: identityURL,
                    preservedIdentityCopyName: preservedIdentityCopyName
                )
            }
            if let expectedWorkspaceID, expectedWorkspaceID != onDiskWorkspaceID {
                decision = .requireRecovery(affectedComponents: WorkspaceStorageComponent.allCases)
            } else {
                decision = .useExisting(workspaceID: onDiskWorkspaceID, needsIdentityCommit: false)
            }
        } else {
            decision = WorkspaceBootstrapPolicy.decide(
                openLoopsExists: openLoopsExists,
                personalizationExists: personalizationExists,
                identityFileExists: identityExists,
                identityFileIsReadable: identityReadable,
                onDiskWorkspaceID: onDiskWorkspaceID,
                expectedWorkspaceID: expectedWorkspaceID
            )
        }

        return PreparedWorkspaceBootstrap(
            decision: decision,
            workspaceExistedBeforeLaunch: databaseExists || (openLoopsExists && personalizationExists),
            identityURL: identityURL,
            preservedIdentityCopyName: preservedIdentityCopyName
        )
    }

    static func commitIdentity(
        workspaceID: UUID,
        to identityURL: URL,
        fileManager: FileManager = .default
    ) throws {
        try fileManager.createDirectory(
            at: identityURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let document = IdentityDocument(
            schemaVersion: IdentityDocument.currentSchemaVersion,
            workspaceID: workspaceID,
            createdAt: Date()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(document).write(to: identityURL, options: .atomic)
    }
}
