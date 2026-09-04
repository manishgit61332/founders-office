import Combine
import FounderOfficeCore
import Foundation

/// iPhone's local authority. The SQLite repository is opened before auth or
/// networking, so an unavailable account never prevents local use.
@MainActor
final class IOSWorkspaceSession: ObservableObject {
    @Published private(set) var snapshot: WorkspaceRepositorySnapshot
    @Published private(set) var lastErrorMessage: String?

    let repository: SQLiteWorkspaceRepository
    let rootURL: URL

    private var changeTask: Task<Void, Never>?

    private init(
        rootURL: URL,
        repository: SQLiteWorkspaceRepository,
        snapshot: WorkspaceRepositorySnapshot,
        events: AsyncStream<WorkspaceRepositoryEvent>
    ) {
        self.rootURL = rootURL
        self.repository = repository
        self.snapshot = snapshot
        observe(events)
    }

    deinit { changeTask?.cancel() }

    static func open(rootURL: URL) async throws -> IOSWorkspaceSession {
        let preparation = await Task.detached(priority: .userInitiated) {
            IOSWorkspaceBootstrap.prepare(rootURL: rootURL)
        }.value

        let workspaceID: UUID
        let needsIdentityCommit: Bool
        switch preparation.decision {
        case let .initializeNew(id):
            workspaceID = id
            needsIdentityCommit = true
        case let .useExisting(id, shouldCommit):
            workspaceID = id
            needsIdentityCommit = shouldCommit
        case .requireRecovery:
            throw IOSWorkspaceSessionError.recoveryRequired(preparation.recoveryState)
        }

        let repository = try await SQLiteWorkspaceRepository.open(
            configuration: WorkspaceRepositoryConfiguration(
                databaseURL: rootURL.appendingPathComponent("founders-office.sqlite3"),
                workspaceID: workspaceID,
                legacyDirectoryURL: rootURL,
                initialSnapshot: Self.freshSnapshot
            )
        )
        let events = await repository.events()
        let snapshot = try await repository.snapshot()

        if needsIdentityCommit {
            try await Task.detached(priority: .userInitiated) {
                try IOSWorkspaceBootstrap.commitIdentity(workspaceID: workspaceID, to: preparation.identityURL)
            }.value
        }

        return IOSWorkspaceSession(
            rootURL: rootURL,
            repository: repository,
            snapshot: snapshot,
            events: events
        )
    }

    @discardableResult
    func commit(_ mutation: WorkspacePatchMutation) async throws -> WorkspaceTransactionResult {
        do {
            let result = try await repository.transact(patch: mutation)
            apply(result.snapshot)
            lastErrorMessage = nil
            return result
        } catch {
            if let current = try? await repository.snapshot() { apply(current) }
            lastErrorMessage = "The change could not be saved locally."
            throw error
        }
    }

    private func observe(_ events: AsyncStream<WorkspaceRepositoryEvent>) {
        changeTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.apply(event.snapshot) }
            }
        }
    }

    private func apply(_ next: WorkspaceRepositorySnapshot) {
        guard next.revision >= snapshot.revision else { return }
        snapshot = next
    }

    static var freshSnapshot: FounderOfficeSnapshot {
        let now = Date()
        return FounderOfficeSnapshot(
            openLoops: OpenLoopsDocument(schemaVersion: 3, updatedAt: now, items: []),
            personalization: PersonalizationDocument(
                schemaVersion: 6,
                displayName: "Founder's Office",
                accent: .blue,
                iconStyle: .system,
                photoFileName: nil,
                primaryGoal: nil,
                milestones: [],
                updatedAt: now,
                preferredName: nil,
                workspaceName: "Founder's Office",
                appearance: .manish()
            )
        )
    }
}

enum IOSWorkspaceSessionError: Error {
    case recoveryRequired(WorkspaceRecoveryState)
}

private struct IOSWorkspaceBootstrapPreparation: Sendable {
    let decision: WorkspaceBootstrapDecision
    let identityURL: URL
    let recoveryState: WorkspaceRecoveryState
}

private enum IOSWorkspaceBootstrap {
    private struct IdentityDocument: Codable {
        let schemaVersion: Int
        let workspaceID: UUID

        static let currentSchemaVersion = 1
    }

    static func prepare(rootURL: URL, fileManager: FileManager = .default) -> IOSWorkspaceBootstrapPreparation {
        let identityURL = rootURL.appendingPathComponent("workspace-identity.json")
        let databaseURL = rootURL.appendingPathComponent("founders-office.sqlite3")
        let openLoopsURL = rootURL.appendingPathComponent("openloops.json")
        let personalizationURL = rootURL.appendingPathComponent("personalization.json")
        let identityExists = fileManager.fileExists(atPath: identityURL.path)
        let databaseExists = fileManager.fileExists(atPath: databaseURL.path)

        var diskID: UUID?
        var identityReadable = !identityExists
        var preservedCopyNames: [String] = []
        if identityExists {
            do {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let document = try decoder.decode(IdentityDocument.self, from: Data(contentsOf: identityURL))
                guard document.schemaVersion == IdentityDocument.currentSchemaVersion else {
                    throw CocoaError(.coderInvalidValue)
                }
                diskID = document.workspaceID
                identityReadable = true
            } catch {
                identityReadable = false
                if let copy = try? CorruptFileQuarantine.preserve(identityURL, fileManager: fileManager) {
                    preservedCopyNames = [copy.lastPathComponent]
                }
            }
        }

        let decision: WorkspaceBootstrapDecision
        if databaseExists {
            guard identityReadable, let diskID else {
                decision = .requireRecovery(affectedComponents: WorkspaceStorageComponent.allCases)
                return IOSWorkspaceBootstrapPreparation(
                    decision: decision,
                    identityURL: identityURL,
                    recoveryState: WorkspaceRecoveryState(
                        affectedComponents: WorkspaceStorageComponent.allCases,
                        preservedCopyNames: preservedCopyNames
                    )
                )
            }
            decision = .useExisting(workspaceID: diskID, needsIdentityCommit: false)
        } else {
            decision = WorkspaceBootstrapPolicy.decide(
                openLoopsExists: fileManager.fileExists(atPath: openLoopsURL.path),
                personalizationExists: fileManager.fileExists(atPath: personalizationURL.path),
                identityFileExists: identityExists,
                identityFileIsReadable: identityReadable,
                onDiskWorkspaceID: diskID,
                expectedWorkspaceID: nil
            )
        }

        let recovery: WorkspaceRecoveryState
        if case let .requireRecovery(affected) = decision {
            recovery = WorkspaceRecoveryState(
                affectedComponents: affected,
                preservedCopyNames: preservedCopyNames
            )
        } else {
            recovery = .ready
        }
        return IOSWorkspaceBootstrapPreparation(
            decision: decision,
            identityURL: identityURL,
            recoveryState: recovery
        )
    }

    static func commitIdentity(workspaceID: UUID, to url: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(
            IdentityDocument(schemaVersion: IdentityDocument.currentSchemaVersion, workspaceID: workspaceID)
        ).write(to: url, options: .atomic)
    }
}
