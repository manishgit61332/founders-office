import CryptoKit
import Foundation
import SQLite3

public actor SQLiteWorkspaceRepository: WorkspaceRepository, WorkspaceSyncRepository,
    WorkspaceProvisioningRepository {
    private let database: SQLiteWorkspaceDatabase
    private var latestSnapshot: WorkspaceRepositorySnapshot
    private var changeContinuations: [UUID: AsyncStream<WorkspaceChange>.Continuation] = [:]
    private var remoteChangeContinuations: [UUID: AsyncStream<WorkspaceRepositorySnapshot>.Continuation] = [:]

    private init(
        database: SQLiteWorkspaceDatabase,
        snapshot: WorkspaceRepositorySnapshot
    ) {
        self.database = database
        latestSnapshot = snapshot
    }

    /// Opens and migrates the database on a generic executor so callers on
    /// `MainActor` never perform SQLite or legacy JSON I/O themselves.
    public static func open(
        configuration: WorkspaceRepositoryConfiguration
    ) async throws -> SQLiteWorkspaceRepository {
        let opened = try await Task.detached(priority: .userInitiated) {
            try SQLiteWorkspaceDatabase.open(configuration: configuration)
        }.value
        return SQLiteWorkspaceRepository(database: opened.database, snapshot: opened.snapshot)
    }

    public func snapshot() throws -> WorkspaceRepositorySnapshot {
        let snapshot = try database.loadSnapshot()
        latestSnapshot = snapshot
        return snapshot
    }

    public func transact(
        expectedRevision: WorkspaceRevision,
        mutation: WorkspaceMutation
    ) throws -> WorkspaceTransactionResult {
        let result = try database.transact(
            expectedRevision: expectedRevision,
            mutation: mutation
        )

        switch result {
        case let .committed(change):
            latestSnapshot = change.snapshot
            for continuation in changeContinuations.values {
                continuation.yield(change)
            }
            return .committed(change)
        case let .unchanged(snapshot):
            latestSnapshot = snapshot
            return .unchanged(snapshot)
        case let .replayed(snapshot, committedRevision):
            latestSnapshot = snapshot
            return .replayed(snapshot: snapshot, committedRevision: committedRevision)
        }
    }

    /// Applies a local component patch to the latest durable snapshot. Because
    /// this method performs no suspension before SQLite commits, concurrent UI
    /// requests are serialized by the repository actor in arrival order.
    public func transact(patch request: WorkspacePatchMutation) throws -> WorkspaceTransactionResult {
        let current = try database.loadSnapshot()
        switch request.precondition {
        case .none:
            break
        case let .appearanceRevision(expected):
            guard current.content.personalization.resolvedAppearance.updatedAt == expected else {
                throw WorkspaceRepositoryError.componentConflict(component: "Appearance")
            }
        }

        let replacement = try Self.mergePatch(request, into: current.content)

        return try transact(
            expectedRevision: current.revision,
            mutation: WorkspaceMutation(
                operationID: request.operationID,
                idempotencyKey: request.idempotencyKey,
                entityKind: request.entityKind,
                entityID: request.entityID,
                changedFields: request.changedFields,
                fieldClocks: request.fieldClocks,
                replacement: replacement,
                createdAt: request.createdAt
            )
        )
    }

    /// Entity-scoped merge prevents a stale whole-component UI document from
    /// overwriting an unrelated entity that arrived through sync while the UI
    /// edit was queued. The outbox mask and the local commit now describe the
    /// same atomic change.
    private static func mergePatch(
        _ request: WorkspacePatchMutation,
        into current: FounderOfficeSnapshot
    ) throws -> FounderOfficeSnapshot {
        var replacement = current
        let fields = Set(request.changedFields)
        switch request.patch {
        case let .openLoops(proposed):
            guard request.entityKind == WorkspaceLocalEntityKind.move.rawValue,
                  let identifier = UUID(uuidString: request.entityID),
                  let proposedMove = proposed.items.first(where: { $0.id == identifier }) else {
                throw WorkspaceRepositoryError.invalidMutation(reason: "Move patch is not entity scoped")
            }
            if let index = replacement.openLoops.items.firstIndex(where: { $0.id == identifier }) {
                var move = replacement.openLoops.items[index]
                for field in fields {
                    switch field {
                    case "title": move.title = proposedMove.title
                    case "details": move.details = proposedMove.details
                    case "status": move.status = proposedMove.status
                    case "previousStatus": move.previousStatus = proposedMove.previousStatus
                    case "priority": move.priority = proposedMove.priority
                    case "dueAt": move.dueAt = proposedMove.dueAt
                    case "createdAt": move.createdAt = proposedMove.createdAt
                    case "updatedAt": move.updatedAt = proposedMove.updatedAt
                    case "priorityUpdatedAt": move.priorityUpdatedAt = proposedMove.priorityUpdatedAt
                    case "dueAtUpdatedAt": move.dueAtUpdatedAt = proposedMove.dueAtUpdatedAt
                    case "completedAt": move.completedAt = proposedMove.completedAt
                    case "deletedAt": move.deletedAt = proposedMove.deletedAt
                    case "source": move.source = proposedMove.source
                    default:
                        throw WorkspaceRepositoryError.invalidMutation(reason: "Move patch field is unsupported")
                    }
                }
                replacement.openLoops.items[index] = move
            } else {
                let required: Set<String> = ["title", "details", "status", "priority", "createdAt"]
                guard required.isSubset(of: fields) else {
                    throw WorkspaceRepositoryError.invalidMutation(reason: "New Move patch is incomplete")
                }
                replacement.openLoops.items.append(proposedMove)
            }
            replacement.openLoops.schemaVersion = max(
                replacement.openLoops.schemaVersion,
                proposed.schemaVersion
            )
            replacement.openLoops.updatedAt = max(replacement.openLoops.updatedAt, proposed.updatedAt)

        case let .personalization(proposed):
            switch WorkspaceLocalEntityKind(metadataValue: request.entityKind) {
            case .profile:
                for field in fields {
                    switch field {
                    case "displayName": replacement.personalization.displayName = proposed.displayName
                    case "preferredName": replacement.personalization.preferredName = proposed.preferredName
                    case "iconStyle": replacement.personalization.iconStyle = proposed.iconStyle
                    case "updatedAt": replacement.personalization.updatedAt = proposed.updatedAt
                    default:
                        throw WorkspaceRepositoryError.invalidMutation(reason: "Profile patch field is unsupported")
                    }
                }
            case .workspace:
                for field in fields {
                    switch field {
                    case "workspaceName": replacement.personalization.workspaceName = proposed.workspaceName
                    case "updatedAt": replacement.personalization.updatedAt = proposed.updatedAt
                    default:
                        throw WorkspaceRepositoryError.invalidMutation(reason: "Workspace patch field is unsupported")
                    }
                }
            case .appearance:
                for field in fields {
                    switch field {
                    case "appearance": replacement.personalization.appearance = proposed.appearance
                    case "accent": replacement.personalization.accent = proposed.accent
                    case "updatedAt": replacement.personalization.updatedAt = proposed.updatedAt
                    default:
                        throw WorkspaceRepositoryError.invalidMutation(reason: "Appearance patch field is unsupported")
                    }
                }
            case .primaryGoal:
                guard let identifier = UUID(uuidString: request.entityID),
                      let proposedGoal = proposed.primaryGoal,
                      proposedGoal.id == identifier else {
                    throw WorkspaceRepositoryError.invalidMutation(reason: "Primary goal patch is not entity scoped")
                }
                replacement.personalization.primaryGoal = mergeGoal(
                    current: replacement.personalization.primaryGoal,
                    proposed: proposedGoal,
                    fields: fields
                )
                replacement.personalization.updatedAt = latest(
                    replacement.personalization.updatedAt,
                    proposed.updatedAt
                )
            case .milestone:
                guard let identifier = UUID(uuidString: request.entityID),
                      let proposedMilestone = proposed.milestones.first(where: { $0.id == identifier }) else {
                    throw WorkspaceRepositoryError.invalidMutation(reason: "Milestone patch is not entity scoped")
                }
                if let index = replacement.personalization.milestones.firstIndex(where: { $0.id == identifier }) {
                    replacement.personalization.milestones[index] = mergeMilestone(
                        current: replacement.personalization.milestones[index],
                        proposed: proposedMilestone,
                        fields: fields
                    )
                } else {
                    guard Set(["title", "dueAt", "createdAt"]).isSubset(of: fields) else {
                        throw WorkspaceRepositoryError.invalidMutation(reason: "New milestone patch is incomplete")
                    }
                    replacement.personalization.milestones.append(proposedMilestone)
                }
                replacement.personalization.updatedAt = latest(
                    replacement.personalization.updatedAt,
                    proposed.updatedAt
                )
            case .asset:
                let allowed: Set<String> = ["photoFileName", "visionImageAsset", "updatedAt"]
                guard fields.isSubset(of: allowed) else {
                    throw WorkspaceRepositoryError.invalidMutation(reason: "Asset patch field is unsupported")
                }
                if fields.contains("photoFileName") {
                    replacement.personalization.photoFileName = proposed.photoFileName
                }
                if fields.contains("visionImageAsset") {
                    replacement.personalization.visionImageAsset = proposed.visionImageAsset
                }
                if fields.contains("updatedAt") {
                    replacement.personalization.updatedAt = proposed.updatedAt
                }
            case .move, .none:
                throw WorkspaceRepositoryError.invalidMutation(reason: "Personalization patch entity is unsupported")
            }
            replacement.personalization.schemaVersion = max(
                replacement.personalization.schemaVersion,
                proposed.schemaVersion
            )
        }
        return replacement
    }

    private static func mergeGoal(
        current: PrimaryGoal?,
        proposed: PrimaryGoal,
        fields: Set<String>
    ) -> PrimaryGoal {
        guard var goal = current, goal.id == proposed.id else { return proposed }
        if fields.contains("title") { goal.title = proposed.title }
        if fields.contains("metric") { goal.metric = proposed.metric }
        if fields.contains("currentValue") { goal.currentValue = proposed.currentValue }
        if fields.contains("targetValue") { goal.targetValue = proposed.targetValue }
        if fields.contains("unit") { goal.unit = proposed.unit }
        if fields.contains("dueAt") { goal.dueAt = proposed.dueAt }
        if fields.contains("createdAt") { goal.createdAt = proposed.createdAt }
        if fields.contains("updatedAt") { goal.updatedAt = proposed.updatedAt }
        if fields.contains("deletedAt") { goal.deletedAt = proposed.deletedAt }
        return goal
    }

    private static func mergeMilestone(
        current: Milestone,
        proposed: Milestone,
        fields: Set<String>
    ) -> Milestone {
        var milestone = current
        if fields.contains("title") { milestone.title = proposed.title }
        if fields.contains("dueAt") { milestone.dueAt = proposed.dueAt }
        if fields.contains("createdAt") { milestone.createdAt = proposed.createdAt }
        if fields.contains("updatedAt") { milestone.updatedAt = proposed.updatedAt }
        if fields.contains("deletedAt") { milestone.deletedAt = proposed.deletedAt }
        return milestone
    }

    private static func latest(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (.some(lhs), .some(rhs)): return max(lhs, rhs)
        case let (.some(lhs), nil): return lhs
        case let (nil, .some(rhs)): return rhs
        case (nil, nil): return nil
        }
    }

    public func changes() -> AsyncStream<WorkspaceChange> {
        let identifier = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(32)) { continuation in
            changeContinuations[identifier] = continuation
            continuation.onTermination = { [weak self] _ in
                Task {
                    await self?.removeChangeContinuation(identifier)
                }
            }
        }
    }

    public func pendingOperations(limit: Int = 100) throws -> [WorkspaceOutboxOperation] {
        try database.pendingOperations(limit: limit)
    }

    public func recordDeliveryAttempt(operationIDs: [UUID]) throws {
        try database.recordDeliveryAttempt(operationIDs: operationIDs)
    }

    /// Removes only operations positively acknowledged by the remote sync
    /// endpoint. Idempotency receipts remain durable after acknowledgement.
    public func acknowledgeOperations(operationIDs: [UUID]) throws {
        try database.acknowledgeOperations(operationIDs: operationIDs)
    }

    public func syncBinding() throws -> WorkspaceSyncBinding? {
        try database.syncBinding()
    }

    public func bindSync(_ binding: WorkspaceSyncBinding) throws {
        try database.bindSync(binding)
    }

    /// Installs a fully verified remote feed as the canonical local snapshot.
    /// Network work happens before this call. Export and the SQLite replacement
    /// are then serialized by this actor so local edits cannot slip between
    /// preservation and replacement.
    public func attachExistingWorkspace(
        bootstrap: WorkspaceBootstrap,
        pages: [SyncPullResponse],
        authorization: ExistingWorkspaceAttachmentAuthorization
    ) throws -> ExistingWorkspaceAttachmentCommit {
        let plan = try database.prepareExistingWorkspaceAttachment(
            bootstrap: bootstrap,
            pages: pages
        )
        let current = try database.loadSnapshot()
        switch authorization {
        case .freshDevice:
            guard !Self.hasCustomerData(current.content) else {
                throw WorkspaceSyncRepositoryError.replacementExportRequired
            }
        case let .exportAndReplace(destination):
            guard current.content.personalization.visionImageAsset == nil,
                  current.content.personalization.photoFileName == nil else {
                throw WorkspaceSyncRepositoryError.assetsDisabled
            }
            _ = try Self.writeExport(
                snapshot: current,
                to: destination,
                generatedAt: Date(),
                calendar: .current
            )
        }

        let updated = try database.commitExistingWorkspaceAttachment(plan)
        latestSnapshot = updated
        for continuation in remoteChangeContinuations.values {
            continuation.yield(updated)
        }
        return ExistingWorkspaceAttachmentCommit(snapshot: updated, binding: plan.binding)
    }

    private static func hasCustomerData(_ snapshot: FounderOfficeSnapshot) -> Bool {
        let personalization = snapshot.personalization
        return !snapshot.openLoops.items.isEmpty
            || personalization.primaryGoal != nil
            || !personalization.milestones.isEmpty
            || personalization.visionImageAsset != nil
            || personalization.photoFileName != nil
            || personalization.resolvedPreferredName != nil
            || personalization.resolvedWorkspaceName != "Founder's Office"
            || personalization.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                != "Founder's Office"
            || personalization.resolvedAppearance != .manish()
            || personalization.accent != .blue
            || (personalization.iconStyle ?? .system) != .system
    }

    public func syncCursor() throws -> SyncCursor {
        try database.syncCursor()
    }

    public func syncStatus() throws -> WorkspaceSyncStatus {
        try database.syncStatus()
    }

    public func setSyncStatus(_ status: WorkspaceSyncStatus) throws {
        try database.setSyncStatus(status)
    }

    public func pendingSyncBatch(
        maximumCount: Int = 100,
        maximumByteCount: Int = 2 * 1_024 * 1_024
    ) throws -> WorkspacePendingSyncBatch {
        try database.pendingSyncBatch(
            maximumCount: maximumCount,
            maximumByteCount: maximumByteCount
        )
    }

    public func remoteRevision(entityType: SyncEntityType, entityID: UUID) throws -> Int64 {
        try database.remoteRevision(entityType: entityType, entityID: entityID)
    }

    public func canonicalBootstrapPlan() throws -> WorkspaceCanonicalBootstrapPlan {
        try database.canonicalBootstrapPlan()
    }

    public func acknowledgeCanonicalBootstrap(
        plan: WorkspaceCanonicalBootstrapPlan,
        bootstrap: WorkspaceBootstrap,
        responses: [SyncPushResponse]
    ) throws -> WorkspaceCanonicalBootstrapReceipt {
        try database.acknowledgeCanonicalBootstrap(
            plan: plan,
            bootstrap: bootstrap,
            responses: responses
        )
    }

    public func acknowledgeRemoteOperations(
        _ acknowledgements: [WorkspaceRemoteOperationAcknowledgement],
        conflicts: [WorkspacePersistedSyncConflict]
    ) throws {
        try database.acknowledgeRemoteOperations(acknowledgements, conflicts: conflicts)
    }

    public func applyRemotePage(_ response: SyncPullResponse) throws {
        let updated = try database.applyRemotePage(response)
        if let updated {
            latestSnapshot = updated
            for continuation in remoteChangeContinuations.values {
                continuation.yield(updated)
            }
        }
    }

    public func persistedSyncConflicts(limit: Int = 100) throws -> [WorkspacePersistedSyncConflict] {
        try database.persistedSyncConflicts(limit: limit)
    }

    public func remoteChanges() -> AsyncStream<WorkspaceRepositorySnapshot> {
        let identifier = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
            remoteChangeContinuations[identifier] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeRemoteChangeContinuation(identifier) }
            }
        }
    }

    private func removeRemoteChangeContinuation(_ identifier: UUID) {
        remoteChangeContinuations.removeValue(forKey: identifier)
    }

    /// Writes a revision-consistent, immutable projection. The destination
    /// must not exist; exports never replace canonical or previously exported
    /// customer data.
    @discardableResult
    public func export(
        to destinationURL: URL,
        generatedAt: Date = Date(),
        calendar: Calendar = .current
    ) throws -> WorkspaceExportManifest {
        let snapshot = try database.loadSnapshot()
        latestSnapshot = snapshot
        return try Self.writeExport(
            snapshot: snapshot,
            to: destinationURL,
            generatedAt: generatedAt,
            calendar: calendar
        )
    }

    /// Ensures one immutable generated projection exists for the current
    /// revision. Existing revision directories are never replaced.
    @discardableResult
    public func ensureProjection(
        in projectionsRootURL: URL,
        generatedAt: Date = Date(),
        calendar: Calendar = .current
    ) throws -> URL {
        let snapshot = try database.loadSnapshot()
        latestSnapshot = snapshot
        let revisionName = String(format: "revision-%012lld", snapshot.revision.rawValue)
        let destinationURL = projectionsRootURL.appendingPathComponent(revisionName, isDirectory: true)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try Self.pruneGeneratedProjections(in: projectionsRootURL, keeping: 2)
            return destinationURL
        }
        _ = try Self.writeExport(
            snapshot: snapshot,
            to: destinationURL,
            generatedAt: generatedAt,
            calendar: calendar
        )
        try Self.pruneGeneratedProjections(in: projectionsRootURL, keeping: 2)
        return destinationURL
    }

    private static func pruneGeneratedProjections(
        in rootURL: URL,
        keeping retentionCount: Int
    ) throws {
        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        let candidates: [URL]
        do {
            candidates = try fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )
            .filter { url in
                guard url.lastPathComponent.range(
                    of: #"^revision-[0-9]{12}$"#,
                    options: .regularExpression
                ) != nil,
                let values = try? url.resourceValues(forKeys: keys) else { return false }
                return values.isDirectory == true && values.isSymbolicLink != true
            }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        } catch {
            throw WorkspaceRepositoryError.exportFailed(operation: "inspect_generated_projections")
        }

        for staleURL in candidates.dropFirst(max(1, retentionCount)) {
            do {
                try fileManager.removeItem(at: staleURL)
            } catch {
                throw WorkspaceRepositoryError.exportFailed(operation: "prune_generated_projection")
            }
        }
    }

    private func removeChangeContinuation(_ identifier: UUID) {
        changeContinuations.removeValue(forKey: identifier)
    }

    private static func writeExport(
        snapshot: WorkspaceRepositorySnapshot,
        to destinationURL: URL,
        generatedAt: Date,
        calendar: Calendar
    ) throws -> WorkspaceExportManifest {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw WorkspaceRepositoryError.exportDestinationExists
        }

        let parentURL = destinationURL.deletingLastPathComponent()
        let stagingURL = parentURL.appendingPathComponent(
            ".founder-office-export-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )

        do {
            try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: false)
        } catch {
            throw WorkspaceRepositoryError.exportFailed(operation: "create_staging_directory")
        }

        var shouldRemoveStaging = true
        defer {
            if shouldRemoveStaging {
                try? fileManager.removeItem(at: stagingURL)
            }
        }

        let encoder = WorkspaceJSONCodec.makeEncoder(prettyPrinted: true)
        let openLoopsData: Data
        let personalizationData: Data
        do {
            openLoopsData = try encoder.encode(snapshot.content.openLoops)
            personalizationData = try encoder.encode(snapshot.content.personalization)
        } catch {
            throw WorkspaceRepositoryError.exportFailed(operation: "encode_projection")
        }
        let contextData = Data(
            WorkspaceProjection.contextMarkdown(
                for: snapshot.content.openLoops,
                generatedAt: generatedAt,
                calendar: calendar
            ).utf8
        )

        let projectedFiles = [
            (WorkspaceProjection.openLoopsFileName, openLoopsData),
            (WorkspaceProjection.personalizationFileName, personalizationData),
            (WorkspaceProjection.contextFileName, contextData)
        ]
        let records = projectedFiles.map { name, data in
            WorkspaceExportManifest.FileRecord(
                name: name,
                byteCount: data.count,
                sha256: WorkspaceProjection.digest(data)
            )
        }
        let manifest = WorkspaceExportManifest(
            workspaceID: snapshot.workspaceID,
            revision: snapshot.revision,
            generatedAt: generatedAt,
            files: records
        )

        do {
            for (name, data) in projectedFiles {
                try data.write(
                    to: stagingURL.appendingPathComponent(name),
                    options: [.atomic]
                )
            }
            let manifestData = try encoder.encode(manifest)
            try manifestData.write(
                to: stagingURL.appendingPathComponent(WorkspaceProjection.manifestFileName),
                options: [.atomic]
            )
            try fileManager.moveItem(at: stagingURL, to: destinationURL)
            shouldRemoveStaging = false
            return manifest
        } catch {
            if fileManager.fileExists(atPath: destinationURL.path) {
                throw WorkspaceRepositoryError.exportDestinationExists
            }
            throw WorkspaceRepositoryError.exportFailed(operation: "commit_projection")
        }
    }
}

private enum SQLiteWorkspaceTransactionResult {
    case committed(WorkspaceChange)
    case unchanged(WorkspaceRepositorySnapshot)
    case replayed(WorkspaceRepositorySnapshot, WorkspaceRevision)
}

private struct OpenedSQLiteWorkspace: @unchecked Sendable {
    var database: SQLiteWorkspaceDatabase
    var snapshot: WorkspaceRepositorySnapshot
}

private struct LegacyWorkspaceImport {
    var snapshot: FounderOfficeSnapshot
    var openLoopsDigest: String
    var personalizationDigest: String
}

private struct WorkspaceOperationReceipt {
    var fingerprint: Data
    var fingerprintVersion: Int
    var resultRevision: WorkspaceRevision
}

private struct StoredWorkspaceState {
    var workspaceID: UUID
    var writerID: WorkspaceWriterID
    var revision: WorkspaceRevision
    var snapshotData: Data
}

private struct LegacyOutboxUpgrade {
    var operationID: String
    var entityKind: String
    var entityID: String
    var payload: Data
}

private struct ValidatedWorkspaceMutation {
    var mutation: WorkspaceMutation
    var snapshotData: Data
    var fingerprint: Data
}

private struct StoredBootstrapReceipt {
    let receiptID: UUID
    let acceptedCursor: SyncCursor
    let operationsDigest: Data
}

private struct StoredBootstrapAttempt {
    let accountID: FounderAccountID
    let remoteWorkspaceID: WorkspaceID
    let deviceID: DeviceID
    let plan: WorkspaceCanonicalBootstrapPlan
}

private struct StoredRemoteAcknowledgement {
    let entityType: SyncEntityType
    let entityID: UUID
    let remoteRevision: Int64
    let fieldClocks: [String: Date]
}

private struct RemoteEntityKey: Hashable {
    let type: SyncEntityType
    let id: UUID
}

private struct PreparedRemoteEntityRevision {
    let entityType: SyncEntityType
    let entityID: UUID
    let revision: Int64
    let fieldClocks: [String: Date]
}

private struct PreparedExistingWorkspaceAttachment {
    let expectedLocalRevision: WorkspaceRevision
    let binding: WorkspaceSyncBinding
    let cursor: SyncCursor
    let replacement: FounderOfficeSnapshot
    let remoteRevisions: [PreparedRemoteEntityRevision]
    let appliedChanges: [SyncChange]
}

private enum SQLiteWorkspaceValue {
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
    case null
}

private final class SQLiteWorkspaceDatabase: @unchecked Sendable {
    static let currentSchemaVersion = 4
    static let applicationID: Int64 = 1_179_600_454 // ASCII "FOFF"
    static let supportedOpenLoopsSchemaVersion = 3
    static let supportedPersonalizationSchemaVersion = 6

    private let connection: OpaquePointer
    private let codec = WorkspaceJSONCodec()

    private init(connection: OpaquePointer) {
        self.connection = connection
    }

    deinit {
        sqlite3_close_v2(connection)
    }

    static func open(
        configuration: WorkspaceRepositoryConfiguration
    ) throws -> OpenedSQLiteWorkspace {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: configuration.databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw WorkspaceRepositoryError.databaseUnavailable(
                operation: "create_database_directory",
                code: Int32(SQLITE_CANTOPEN)
            )
        }

        var pointer: OpaquePointer?
        let openResult = sqlite3_open_v2(
            configuration.databaseURL.path,
            &pointer,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let pointer else {
            if let pointer {
                sqlite3_close_v2(pointer)
            }
            throw WorkspaceRepositoryError.databaseUnavailable(
                operation: "open_database",
                code: openResult
            )
        }

        let database = SQLiteWorkspaceDatabase(connection: pointer)
        try database.configureConnection()
        try database.migrateIfNeeded()
        try database.configureDurability()

        if let existing = try database.readState() {
            guard existing.workspaceID == configuration.workspaceID else {
                throw WorkspaceRepositoryError.workspaceMismatch
            }
            if let requestedWriterID = configuration.requestedWriterID,
               requestedWriterID != existing.writerID {
                throw WorkspaceRepositoryError.writerMismatch
            }
            return OpenedSQLiteWorkspace(database: database, snapshot: existing)
        }

        let legacyImport: LegacyWorkspaceImport?
        if let legacyDirectoryURL = configuration.legacyDirectoryURL {
            legacyImport = try loadLegacyWorkspace(from: legacyDirectoryURL)
        } else {
            legacyImport = nil
        }
        let seedSnapshot: FounderOfficeSnapshot
        if let legacyImport {
            seedSnapshot = legacyImport.snapshot
        } else if let initialSnapshot = configuration.initialSnapshot {
            seedSnapshot = initialSnapshot
        } else {
            throw WorkspaceRepositoryError.missingBootstrapSnapshot
        }

        let normalized = try database.codec.canonicalized(seedSnapshot)
        let writerID = configuration.requestedWriterID ?? WorkspaceWriterID()
        let snapshot = WorkspaceRepositorySnapshot(
            workspaceID: configuration.workspaceID,
            writerID: writerID,
            revision: .initial,
            content: normalized
        )
        try database.insertInitialState(snapshot, legacyImport: legacyImport)
        return OpenedSQLiteWorkspace(database: database, snapshot: snapshot)
    }

    func loadSnapshot() throws -> WorkspaceRepositorySnapshot {
        guard let snapshot = try readState() else {
            throw WorkspaceRepositoryError.invalidDatabase
        }
        return snapshot
    }

    func transact(
        expectedRevision: WorkspaceRevision,
        mutation: WorkspaceMutation
    ) throws -> SQLiteWorkspaceTransactionResult {
        let validated = try validate(mutation, expectedRevision: expectedRevision)
        let result: SQLiteWorkspaceTransactionResult = try transaction {
            guard let current = try readStoredState() else {
                throw WorkspaceRepositoryError.invalidDatabase
            }

            if let receipt = try receipt(for: mutation.idempotencyKey) {
                let expectedFingerprint: Data
                switch receipt.fingerprintVersion {
                case 1:
                    expectedFingerprint = try legacyFingerprint(
                        mutation: validated.mutation,
                        expectedRevision: expectedRevision
                    )
                case 2:
                    expectedFingerprint = validated.fingerprint
                default:
                    throw WorkspaceRepositoryError.invalidDatabase
                }
                guard receipt.fingerprint == expectedFingerprint else {
                    throw WorkspaceRepositoryError.idempotencyKeyReused
                }
                return .replayed(try decodeState(current), receipt.resultRevision)
            }

            if try receiptExists(operationID: mutation.operationID) {
                throw WorkspaceRepositoryError.operationIDReused
            }

            guard current.revision == expectedRevision else {
                throw WorkspaceRepositoryError.revisionConflict(
                    expected: expectedRevision,
                    actual: current.revision
                )
            }

            if current.snapshotData == validated.snapshotData {
                try insertReceipt(
                    mutation: mutation,
                    fingerprint: validated.fingerprint,
                    resultRevision: current.revision,
                    producedChange: false
                )
                return .unchanged(
                    WorkspaceRepositorySnapshot(
                        workspaceID: current.workspaceID,
                        writerID: current.writerID,
                        revision: current.revision,
                        content: validated.mutation.replacement
                    )
                )
            }

            let committedRevision = WorkspaceRevision(rawValue: current.revision.rawValue + 1)
            let nextSnapshot = WorkspaceRepositorySnapshot(
                workspaceID: current.workspaceID,
                writerID: current.writerID,
                revision: committedRevision,
                content: validated.mutation.replacement
            )
            let localEnvelope: WorkspaceLocalOperationEnvelopeV2
            let outboxPayload: Data
            do {
                localEnvelope = try WorkspaceLocalOperationBuilder.makeEnvelope(
                    entityKind: validated.mutation.entityKind,
                    entityID: validated.mutation.entityID,
                    changedFields: validated.mutation.changedFields,
                    snapshot: validated.mutation.replacement,
                    createdAt: validated.mutation.createdAt
                )
                outboxPayload = try WorkspaceLocalOperationBuilder.encode(localEnvelope)
            } catch let error as WorkspaceLocalOperationError {
                let reason: String
                switch error {
                case .unsupportedEntityKind:
                    reason = "entity kind is unsupported"
                case .missingEntity:
                    reason = "entity metadata does not identify one record"
                case .payloadTooLarge:
                    reason = "entity operation exceeds the local safety limit"
                case .unsupportedFormat, .invalidMetadata, .invalidRecord:
                    reason = "entity operation metadata is invalid"
                }
                throw WorkspaceRepositoryError.invalidMutation(reason: reason)
            }
            let operation = WorkspaceOutboxOperation(
                operationID: mutation.operationID,
                idempotencyKey: mutation.idempotencyKey,
                workspaceID: current.workspaceID,
                writerID: current.writerID,
                baseRevision: current.revision,
                committedRevision: committedRevision,
                entityKind: localEnvelope.entityKind.rawValue,
                entityID: localEnvelope.entityID,
                changedFields: validated.mutation.changedFields,
                fieldClocks: validated.mutation.fieldClocks,
                payload: outboxPayload,
                createdAt: validated.mutation.createdAt
            )

            try insertReceipt(
                mutation: mutation,
                fingerprint: validated.fingerprint,
                resultRevision: committedRevision,
                producedChange: true
            )
            try insertOutbox(operation)
            try updateState(
                nextSnapshot,
                snapshotData: validated.snapshotData,
                expectedRevision: current.revision
            )
            let change = WorkspaceChange(snapshot: nextSnapshot, operation: operation)
            return .committed(change)
        }
        return result
    }

    func pendingOperations(limit: Int) throws -> [WorkspaceOutboxOperation] {
        guard limit > 0, limit <= 1_000 else {
            throw WorkspaceRepositoryError.invalidMutation(
                reason: "outbox limit must be between 1 and 1000"
            )
        }
        let statement = try prepare(
            """
            SELECT operation_id, idempotency_key, workspace_id, writer_id,
                   base_revision, committed_revision, entity_kind, entity_id,
                   changed_fields, field_clocks, payload_format_version,
                   payload, created_at, delivery_attempts
            FROM operation_outbox
            ORDER BY committed_revision ASC, operation_id ASC
            LIMIT ?
            """,
            operation: "read_outbox"
        )
        try statement.bind([.integer(Int64(limit))], operation: "read_outbox")

        var operations: [WorkspaceOutboxOperation] = []
        while try statement.step(operation: "read_outbox") {
            operations.append(try decodeOutboxOperation(statement, operation: "read_outbox"))
        }
        return operations
    }

    private func decodeOutboxOperation(
        _ statement: SQLiteWorkspaceStatement,
        operation databaseOperation: String
    ) throws -> WorkspaceOutboxOperation {
        let changedFields: [String]
        let fieldClocks: [String: Date]
        do {
            changedFields = try codec.decoder.decode(
                [String].self,
                from: try statement.requiredBlob(at: 8, operation: databaseOperation)
            )
            fieldClocks = try codec.decoder.decode(
                [String: Date].self,
                from: try statement.requiredBlob(at: 9, operation: databaseOperation)
            )
        } catch {
            throw WorkspaceRepositoryError.invalidDatabase
        }
        guard let operationID = UUID(
            uuidString: try statement.requiredText(at: 0, operation: databaseOperation)
        ),
        let idempotencyUUID = UUID(
            uuidString: try statement.requiredText(at: 1, operation: databaseOperation)
        ),
        let workspaceID = UUID(
            uuidString: try statement.requiredText(at: 2, operation: databaseOperation)
        ),
        let writerUUID = UUID(
            uuidString: try statement.requiredText(at: 3, operation: databaseOperation)
        ) else {
            throw WorkspaceRepositoryError.invalidDatabase
        }
        let value = WorkspaceOutboxOperation(
            operationID: operationID,
            idempotencyKey: WorkspaceIdempotencyKey(rawValue: idempotencyUUID),
            workspaceID: workspaceID,
            writerID: WorkspaceWriterID(rawValue: writerUUID),
            baseRevision: WorkspaceRevision(rawValue: statement.integer(at: 4)),
            committedRevision: WorkspaceRevision(rawValue: statement.integer(at: 5)),
            entityKind: try statement.requiredText(at: 6, operation: databaseOperation),
            entityID: try statement.requiredText(at: 7, operation: databaseOperation),
            changedFields: changedFields,
            fieldClocks: fieldClocks,
            payloadFormatVersion: Int(statement.integer(at: 10)),
            payload: try statement.requiredBlob(at: 11, operation: databaseOperation),
            createdAt: Date(timeIntervalSince1970: statement.double(at: 12)),
            deliveryAttempts: Int(statement.integer(at: 13))
        )
        guard value.baseRevision.rawValue >= 0,
              value.committedRevision.rawValue > value.baseRevision.rawValue,
              value.createdAt.timeIntervalSinceReferenceDate.isFinite,
              value.deliveryAttempts >= 0,
              value.changedFields == Array(Set(value.changedFields)).sorted(),
              Set(value.fieldClocks.keys) == Set(value.changedFields),
              value.fieldClocks.values.allSatisfy({
                  $0.timeIntervalSinceReferenceDate.isFinite
              }) else {
            throw WorkspaceRepositoryError.invalidDatabase
        }
        do {
            _ = try value.decodedLocalPayload()
        } catch {
            throw WorkspaceRepositoryError.invalidDatabase
        }
        return value
    }

    func recordDeliveryAttempt(operationIDs: [UUID]) throws {
        guard !operationIDs.isEmpty else { return }
        try transaction {
            for operationID in Set(operationIDs) {
                try execute(
                    """
                    UPDATE operation_outbox
                    SET delivery_attempts = delivery_attempts + 1
                    WHERE operation_id = ? AND payload_format_version = ?
                    """,
                    bindings: [
                        .text(operationID.uuidString.lowercased()),
                        .integer(Int64(WorkspaceLocalOperationEnvelopeV2.formatVersion))
                    ],
                    operation: "record_delivery_attempt"
                )
            }
        }
    }

    func acknowledgeOperations(operationIDs: [UUID]) throws {
        guard !operationIDs.isEmpty else { return }
        try transaction {
            for operationID in Set(operationIDs) {
                try execute(
                    """
                    DELETE FROM operation_outbox
                    WHERE operation_id = ? AND payload_format_version = ?
                    """,
                    bindings: [
                        .text(operationID.uuidString.lowercased()),
                        .integer(Int64(WorkspaceLocalOperationEnvelopeV2.formatVersion))
                    ],
                    operation: "acknowledge_outbox"
                )
            }
        }
    }

    func syncBinding() throws -> WorkspaceSyncBinding? {
        let statement = try prepare(
            """
            SELECT account_id, remote_workspace_id, device_id, identity_provider, bound_at
            FROM sync_binding WHERE singleton = 1
            """,
            operation: "read_sync_binding"
        )
        guard try statement.step(operation: "read_sync_binding") else { return nil }
        guard let accountID = UUID(uuidString: try statement.requiredText(at: 0, operation: "read_sync_binding")),
              let workspaceID = UUID(uuidString: try statement.requiredText(at: 1, operation: "read_sync_binding")),
              let deviceID = UUID(uuidString: try statement.requiredText(at: 2, operation: "read_sync_binding")),
              let provider = AccountIdentityProvider(
                rawValue: try statement.requiredText(at: 3, operation: "read_sync_binding")
              ) else {
            throw WorkspaceSyncRepositoryError.invalidBinding
        }
        return try WorkspaceSyncBinding(
            accountID: FounderAccountID(rawValue: accountID),
            workspaceID: WorkspaceID(rawValue: workspaceID),
            deviceID: DeviceID(rawValue: deviceID),
            identityProvider: provider,
            boundAt: Date(timeIntervalSince1970: statement.double(at: 4))
        )
    }

    func bindSync(_ binding: WorkspaceSyncBinding) throws {
        try transaction {
            let local = try loadSnapshot()
            guard binding.workspaceID.rawValue == local.workspaceID else {
                throw WorkspaceSyncRepositoryError.bindingMismatch
            }
            if let existing = try syncBinding() {
                guard existing.accountID == binding.accountID,
                      existing.workspaceID == binding.workspaceID,
                      existing.deviceID == binding.deviceID,
                      existing.identityProvider == binding.identityProvider else {
                    throw WorkspaceSyncRepositoryError.identityReplacementRequiresDisposition
                }
                return
            }
            try execute(
                """
                INSERT INTO sync_binding (
                    singleton, account_id, remote_workspace_id, device_id,
                    identity_provider, bound_at
                ) VALUES (1, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .text(binding.accountID.rawValue.uuidString.lowercased()),
                    .text(binding.workspaceID.rawValue.uuidString.lowercased()),
                    .text(binding.deviceID.rawValue.uuidString.lowercased()),
                    .text(binding.identityProvider.rawValue),
                    .real(binding.boundAt.timeIntervalSince1970),
                ],
                operation: "bind_sync"
            )
            try execute(
                """
                UPDATE sync_state SET phase = 'idle', retry_attempt = 0,
                    next_retry_at = NULL, failure_code = NULL
                WHERE singleton = 1
                """,
                operation: "bind_sync"
            )
        }
    }

    func prepareExistingWorkspaceAttachment(
        bootstrap: WorkspaceBootstrap,
        pages: [SyncPullResponse]
    ) throws -> PreparedExistingWorkspaceAttachment {
        guard try syncBinding() == nil,
              !pages.isEmpty else {
            throw WorkspaceSyncRepositoryError.identityReplacementRequiresDisposition
        }
        let current = try loadSnapshot()
        let remoteWorkspaceID = bootstrap.session.workspaceID
        var expectedCursor = bootstrap.startingCursor
        var allChanges: [SyncChange] = []
        var operationIDs = Set<UUID>()

        for (index, page) in pages.enumerated() {
            guard page.workspaceID == remoteWorkspaceID,
                  page.fromCursor == expectedCursor,
                  page.changes.allSatisfy({ operationIDs.insert($0.operationID.rawValue).inserted }) else {
                throw WorkspaceSyncRepositoryError.invalidProvisioningFeed
            }
            allChanges.append(contentsOf: page.changes)
            expectedCursor = page.nextCursor
            if page.hasMore {
                guard index < pages.index(before: pages.endIndex) else {
                    throw WorkspaceSyncRepositoryError.invalidProvisioningFeed
                }
            } else {
                guard index == pages.index(before: pages.endIndex),
                      page.nextCursor == page.latestCursor else {
                    throw WorkspaceSyncRepositoryError.invalidProvisioningFeed
                }
            }
        }
        guard let finalPage = pages.last,
              !finalPage.hasMore,
              finalPage.nextCursor >= bootstrap.latestCursor else {
            throw WorkspaceSyncRepositoryError.invalidProvisioningFeed
        }

        guard case let .string(workspaceName)? = bootstrap.workspace["name"],
              case let .integer(workspaceRevision)? = bootstrap.workspace["revision"],
              workspaceRevision > 0,
              case let .string(workspaceUpdatedAt)? = bootstrap.workspace["updatedAt"] else {
            throw WorkspaceSyncRepositoryError.invalidProvisioningFeed
        }
        let baselineDate = try WorkspaceV2SyncAdapter.parseTimestamp(workspaceUpdatedAt)
        var replacement = FounderOfficeSnapshot(
            openLoops: OpenLoopsDocument(
                schemaVersion: Self.supportedOpenLoopsSchemaVersion,
                updatedAt: baselineDate,
                items: []
            ),
            personalization: PersonalizationDocument(
                schemaVersion: Self.supportedPersonalizationSchemaVersion,
                displayName: "Founder's Office",
                accent: .blue,
                iconStyle: .system,
                photoFileName: nil,
                primaryGoal: nil,
                milestones: [],
                updatedAt: baselineDate,
                preferredName: bootstrap.profile.displayName,
                workspaceName: workspaceName,
                appearance: .manish(),
                visionImageAsset: nil
            )
        )

        // bootstrap_workspace returns the latest workspace record. Replaying
        // older workspace-name changes over it would regress the name before
        // eventually arriving at the same revision, so only later concurrent
        // workspace revisions are applied. Other entity histories start empty.
        let applicableChanges = allChanges.filter {
            $0.entityType != .workspace || $0.revision > workspaceRevision
        }
        replacement = try WorkspaceRemoteChangeApplicator.apply(
            applicableChanges,
            to: replacement
        )

        struct RemoteKey: Hashable {
            let type: SyncEntityType
            let id: UUID
        }
        var revisions: [RemoteKey: PreparedRemoteEntityRevision] = [:]
        let workspaceClocks = try remoteFieldClocks(bootstrap.workspace)
        let workspaceKey = RemoteKey(type: .workspace, id: remoteWorkspaceID.rawValue)
        revisions[workspaceKey] = PreparedRemoteEntityRevision(
            entityType: .workspace,
            entityID: remoteWorkspaceID.rawValue,
            revision: workspaceRevision,
            fieldClocks: workspaceClocks
        )
        for change in allChanges {
            let key = RemoteKey(type: change.entityType, id: change.entityID)
            let clocks = try remoteFieldClocks(change.record)
            if let existing = revisions[key] {
                if change.revision < existing.revision {
                    guard change.entityType == .workspace else {
                        throw WorkspaceSyncRepositoryError.invalidProvisioningFeed
                    }
                    continue
                }
                guard change.revision > existing.revision
                        || clocks == existing.fieldClocks else {
                    throw WorkspaceSyncRepositoryError.invalidProvisioningFeed
                }
            }
            revisions[key] = PreparedRemoteEntityRevision(
                entityType: change.entityType,
                entityID: change.entityID,
                revision: change.revision,
                fieldClocks: clocks
            )
        }

        let binding = try WorkspaceSyncBinding(
            accountID: bootstrap.session.accountID,
            workspaceID: remoteWorkspaceID,
            deviceID: bootstrap.session.deviceID,
            identityProvider: bootstrap.session.identityProvider
        )
        return PreparedExistingWorkspaceAttachment(
            expectedLocalRevision: current.revision,
            binding: binding,
            cursor: finalPage.nextCursor,
            replacement: replacement,
            remoteRevisions: revisions.values.sorted {
                if $0.entityType.rawValue != $1.entityType.rawValue {
                    return $0.entityType.rawValue < $1.entityType.rawValue
                }
                return $0.entityID.uuidString < $1.entityID.uuidString
            },
            appliedChanges: allChanges
        )
    }

    func commitExistingWorkspaceAttachment(
        _ plan: PreparedExistingWorkspaceAttachment
    ) throws -> WorkspaceRepositorySnapshot {
        let canonical = try codec.canonicalizedWithData(plan.replacement)
        return try transaction {
            guard try syncBinding() == nil,
                  let stored = try readStoredState(),
                  stored.revision == plan.expectedLocalRevision else {
                throw WorkspaceSyncRepositoryError.identityReplacementRequiresDisposition
            }
            let replacement = WorkspaceRepositorySnapshot(
                workspaceID: stored.workspaceID,
                writerID: stored.writerID,
                revision: WorkspaceRevision(rawValue: stored.revision.rawValue + 1),
                content: canonical.snapshot
            )

            // The preserved export is already durable before this transaction.
            // Old receipts/outbox/sync evidence belong to the replaced local
            // authority and must not be delivered into the attached workspace.
            try execute("DELETE FROM operation_outbox", operation: "replace_workspace")
            try execute("DELETE FROM operation_receipts", operation: "replace_workspace")
            try execute("DELETE FROM sync_conflicts", operation: "replace_workspace")
            try execute("DELETE FROM sync_operation_acknowledgements", operation: "replace_workspace")
            try execute("DELETE FROM sync_applied_operations", operation: "replace_workspace")
            try execute("DELETE FROM sync_bootstrap_receipts", operation: "replace_workspace")
            try execute("DELETE FROM sync_entity_revisions", operation: "replace_workspace")
            try execute("DELETE FROM sync_quarantined_operations", operation: "replace_workspace")
            try updateState(
                replacement,
                snapshotData: canonical.data,
                expectedRevision: stored.revision
            )
            try execute("DELETE FROM sync_binding", operation: "replace_workspace")
            try execute(
                """
                INSERT INTO sync_binding (
                    singleton, account_id, remote_workspace_id, device_id,
                    identity_provider, bound_at
                ) VALUES (1, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .text(plan.binding.accountID.rawValue.uuidString.lowercased()),
                    .text(plan.binding.workspaceID.rawValue.uuidString.lowercased()),
                    .text(plan.binding.deviceID.rawValue.uuidString.lowercased()),
                    .text(plan.binding.identityProvider.rawValue),
                    .real(plan.binding.boundAt.timeIntervalSince1970),
                ],
                operation: "replace_workspace"
            )
            try execute(
                """
                UPDATE sync_state
                SET cursor = ?, phase = 'idle', retry_attempt = 0,
                    next_retry_at = NULL, last_success_at = NULL,
                    failure_code = NULL, bootstrap_complete = 1
                WHERE singleton = 1
                """,
                bindings: [.integer(plan.cursor.value)],
                operation: "replace_workspace"
            )
            guard sqlite3_changes(connection) == 1 else {
                throw WorkspaceSyncRepositoryError.invalidSyncState
            }
            for revision in plan.remoteRevisions {
                try upsertRemoteRevision(
                    entityType: revision.entityType,
                    entityID: revision.entityID,
                    revision: revision.revision,
                    fieldClocks: revision.fieldClocks
                )
            }
            for change in plan.appliedChanges {
                try execute(
                    """
                    INSERT INTO sync_applied_operations (operation_id, cursor, applied_at)
                    VALUES (?, ?, ?)
                    """,
                    bindings: [
                        .text(change.operationID.rawValue.uuidString.lowercased()),
                        .integer(change.cursor.value),
                        .real(Date().timeIntervalSince1970),
                    ],
                    operation: "replace_workspace"
                )
            }
            return replacement
        }
    }

    func syncCursor() throws -> SyncCursor {
        let statement = try prepare(
            "SELECT cursor FROM sync_state WHERE singleton = 1",
            operation: "read_sync_cursor"
        )
        guard try statement.step(operation: "read_sync_cursor") else {
            throw WorkspaceSyncRepositoryError.invalidSyncState
        }
        return try SyncCursor(value: statement.integer(at: 0))
    }

    func syncStatus() throws -> WorkspaceSyncStatus {
        let statement = try prepare(
            """
            SELECT phase, retry_attempt, next_retry_at, last_success_at, failure_code
            FROM sync_state WHERE singleton = 1
            """,
            operation: "read_sync_status"
        )
        guard try statement.step(operation: "read_sync_status"),
              let phase = WorkspaceSyncPhase(
                rawValue: try statement.requiredText(at: 0, operation: "read_sync_status")
              ) else {
            throw WorkspaceSyncRepositoryError.invalidSyncState
        }
        return try WorkspaceSyncStatus(
            phase: phase,
            retryAttempt: Int(statement.integer(at: 1)),
            nextRetryAt: statement.optionalDate(at: 2),
            lastSuccessAt: statement.optionalDate(at: 3),
            failureCode: try statement.optionalText(at: 4, operation: "read_sync_status")
        )
    }

    func setSyncStatus(_ status: WorkspaceSyncStatus) throws {
        try execute(
            """
            UPDATE sync_state
            SET phase = ?, retry_attempt = ?, next_retry_at = ?,
                last_success_at = ?, failure_code = ?
            WHERE singleton = 1
            """,
            bindings: [
                .text(status.phase.rawValue),
                .integer(Int64(status.retryAttempt)),
                status.nextRetryAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                status.lastSuccessAt.map { .real($0.timeIntervalSince1970) } ?? .null,
                status.failureCode.map(SQLiteWorkspaceValue.text) ?? .null,
            ],
            operation: "write_sync_status"
        )
        guard sqlite3_changes(connection) == 1 else {
            throw WorkspaceSyncRepositoryError.invalidSyncState
        }
    }

    func pendingSyncBatch(
        maximumCount: Int,
        maximumByteCount: Int
    ) throws -> WorkspacePendingSyncBatch {
        guard (1...100).contains(maximumCount),
              (1...2 * 1_024 * 1_024).contains(maximumByteCount) else {
            throw WorkspaceSyncRepositoryError.requestBoundsExceeded
        }
        guard try syncBinding() != nil else {
            return WorkspacePendingSyncBatch(
                operations: [],
                requiresCanonicalBootstrap: false,
                totalEncodedByteCount: 0
            )
        }
        let bootstrapComplete = try scalarCount(
            "SELECT bootstrap_complete FROM sync_state WHERE singleton = 1",
            operation: "inspect_bootstrap_state"
        ) == 1
        if !bootstrapComplete {
            return WorkspacePendingSyncBatch(
                operations: [],
                requiresCanonicalBootstrap: true,
                totalEncodedByteCount: 0
            )
        }
        let legacy = try scalarCount(
            "SELECT count(*) FROM operation_outbox WHERE payload_format_version = ?",
            bindings: [.integer(Int64(WorkspaceOutboxOperation.legacySnapshotPayloadFormatVersion))],
            operation: "inspect_sync_outbox"
        ) > 0
        if legacy {
            return WorkspacePendingSyncBatch(
                operations: [],
                requiresCanonicalBootstrap: true,
                totalEncodedByteCount: 0
            )
        }

        let candidates = try pendingOperations(limit: maximumCount)
        var selected: [WorkspaceOutboxOperation] = []
        var total = 0
        for operation in candidates {
            guard operation.payloadFormatVersion == WorkspaceLocalOperationEnvelopeV2.formatVersion else {
                throw WorkspaceRepositoryError.invalidDatabase
            }
            let encodedSize = operation.payload.count + 1_024
            if selected.isEmpty, encodedSize > maximumByteCount {
                throw WorkspaceSyncRepositoryError.requestBoundsExceeded
            }
            if total + encodedSize > maximumByteCount { break }
            selected.append(operation)
            total += encodedSize
        }
        return WorkspacePendingSyncBatch(
            operations: selected,
            requiresCanonicalBootstrap: false,
            totalEncodedByteCount: total
        )
    }

    func remoteRevision(entityType: SyncEntityType, entityID: UUID) throws -> Int64 {
        let statement = try prepare(
            """
            SELECT remote_revision FROM sync_entity_revisions
            WHERE entity_type = ? AND entity_id = ?
            """,
            operation: "read_remote_revision"
        )
        try statement.bind(
            [.text(entityType.rawValue), .text(entityID.uuidString.lowercased())],
            operation: "read_remote_revision"
        )
        guard try statement.step(operation: "read_remote_revision") else { return 0 }
        let revision = statement.integer(at: 0)
        guard revision > 0 else { throw WorkspaceSyncRepositoryError.invalidRemoteRevision }
        return revision
    }

    func canonicalBootstrapPlan() throws -> WorkspaceCanonicalBootstrapPlan {
        try transaction {
            guard let binding = try syncBinding() else {
                throw WorkspaceSyncRepositoryError.bindingRequired
            }
            if let attempt = try bootstrapAttempt() {
                guard attempt.accountID == binding.accountID,
                      attempt.remoteWorkspaceID == binding.workspaceID,
                      attempt.deviceID == binding.deviceID,
                      attempt.plan.localWorkspaceID == (try loadSnapshot()).workspaceID else {
                    throw WorkspaceSyncRepositoryError.bindingMismatch
                }
                return attempt.plan
            }

            let snapshot = try loadSnapshot()
            try failIfBootstrapWouldDropProtectedOutboxState()
            let plan = try WorkspaceV2SyncAdapter.canonicalBootstrapPlan(
                snapshot: snapshot,
                remoteWorkspaceID: binding.workspaceID
            )
            try execute(
                """
                INSERT INTO sync_bootstrap_attempt (
                    singleton, account_id, remote_workspace_id, device_id, plan, created_at
                ) VALUES (1, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .text(binding.accountID.rawValue.uuidString.lowercased()),
                    .text(binding.workspaceID.rawValue.uuidString.lowercased()),
                    .text(binding.deviceID.rawValue.uuidString.lowercased()),
                    .blob(try codec.encode(plan)),
                    .real(Date().timeIntervalSince1970),
                ],
                operation: "pin_canonical_bootstrap"
            )
            return plan
        }
    }

    func acknowledgeCanonicalBootstrap(
        plan: WorkspaceCanonicalBootstrapPlan,
        bootstrap: WorkspaceBootstrap,
        responses: [SyncPushResponse]
    ) throws -> WorkspaceCanonicalBootstrapReceipt {
        try transaction {
            guard let binding = try syncBinding(),
                  plan.remoteWorkspaceID == binding.workspaceID,
                  bootstrap.session == binding.session,
                  bootstrap.profile.accountID == binding.accountID,
                  bootstrap.profile.identityProvider == binding.identityProvider,
                  bootstrap.session.workspaceID == plan.remoteWorkspaceID,
                  !responses.isEmpty,
                  responses.allSatisfy({ $0.workspaceID == binding.workspaceID }),
                  plan.operations.allSatisfy({ $0.entityType != .workspace }),
                  case let .string(bootstrapWorkspaceName)? = bootstrap.workspace["name"],
                  bootstrapWorkspaceName == plan.workspaceName else {
                throw WorkspaceSyncRepositoryError.bootstrapResponseMismatch
            }
            if let expectedName = plan.profileDisplayName {
                guard bootstrap.profile.displayName == expectedName else {
                    throw WorkspaceSyncRepositoryError.bootstrapResponseMismatch
                }
            }
            let results = responses.flatMap(\.results)
            let expectedIDs = Set(plan.operations.map(\.operationID))
            guard Set(results.map(\.operationID)) == expectedIDs,
                  results.count == expectedIDs.count,
                  results.allSatisfy({
                      ($0.status == .accepted || $0.status == .duplicate)
                          && $0.revision != nil && $0.cursor != nil && $0.conflict == nil
                  }) else {
                throw WorkspaceSyncRepositoryError.bootstrapResponseMismatch
            }
            let acceptedCursor = try SyncCursor(
                value: max(
                    bootstrap.latestCursor.value,
                    responses.map(\.latestCursor.value).max() ?? 0
                )
            )
            let resultDigest = try digestBootstrapAcceptance(
                bootstrap: bootstrap,
                results: results
            )
            if let replay = try bootstrapReceipt(
                localWorkspaceID: plan.localWorkspaceID,
                remoteWorkspaceID: plan.remoteWorkspaceID,
                accountID: binding.accountID,
                deviceID: binding.deviceID,
                localRevision: plan.localRevision,
                snapshotDigest: plan.snapshotDigest
            ) {
                guard replay.acceptedCursor == acceptedCursor,
                      replay.operationsDigest == resultDigest else {
                    throw WorkspaceSyncRepositoryError.bootstrapResponseMismatch
                }
                return WorkspaceCanonicalBootstrapReceipt(
                    receiptID: replay.receiptID,
                    remoteWorkspaceID: plan.remoteWorkspaceID,
                    acceptedCursor: acceptedCursor
                )
            }

            guard let attempt = try bootstrapAttempt(),
                  attempt.accountID == binding.accountID,
                  attempt.remoteWorkspaceID == binding.workspaceID,
                  attempt.deviceID == binding.deviceID,
                  attempt.plan == plan,
                  (try loadSnapshot()).workspaceID == plan.localWorkspaceID else {
                throw WorkspaceSyncRepositoryError.bootstrapRevisionChanged
            }

            let workspaceBaseline = try bootstrapWorkspaceBaseline(bootstrap)
            try upsertRemoteRevision(
                entityType: .workspace,
                entityID: binding.workspaceID.rawValue,
                revision: workspaceBaseline.revision,
                fieldClocks: workspaceBaseline.fieldClocks
            )
            let resultsByID = Dictionary(uniqueKeysWithValues: results.map { ($0.operationID, $0) })
            for operation in plan.operations {
                guard let result = resultsByID[operation.operationID],
                      let revision = result.revision else {
                    throw WorkspaceSyncRepositoryError.bootstrapResponseMismatch
                }
                try upsertRemoteRevision(
                    entityType: operation.entityType,
                    entityID: operation.entityID,
                    revision: revision,
                    fieldClocks: operation.fieldClocks
                )
            }

            let receiptID = UUID()
            try execute(
                """
                INSERT INTO sync_bootstrap_receipts (
                    receipt_id, local_workspace_id, remote_workspace_id, account_id, device_id,
                    local_revision, snapshot_digest, accepted_cursor,
                    accepted_operations_digest, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .text(receiptID.uuidString.lowercased()),
                    .text(plan.localWorkspaceID.uuidString.lowercased()),
                    .text(plan.remoteWorkspaceID.rawValue.uuidString.lowercased()),
                    .text(binding.accountID.rawValue.uuidString.lowercased()),
                    .text(binding.deviceID.rawValue.uuidString.lowercased()),
                    .integer(plan.localRevision.rawValue),
                    .blob(plan.snapshotDigest),
                    .integer(acceptedCursor.value),
                    .blob(resultDigest),
                    .real(Date().timeIntervalSince1970),
                ],
                operation: "record_bootstrap_receipt"
            )
            // The receipt and deletion share one SQLite transaction. A crash
            // can leave both or neither, never an unproven acknowledgement.
            try execute(
                "DELETE FROM operation_outbox WHERE committed_revision <= ?",
                bindings: [.integer(plan.localRevision.rawValue)],
                operation: "acknowledge_canonical_bootstrap"
            )
            try execute(
                "UPDATE sync_state SET bootstrap_complete = 1 WHERE singleton = 1",
                operation: "acknowledge_canonical_bootstrap"
            )
            guard sqlite3_changes(connection) == 1 else {
                throw WorkspaceSyncRepositoryError.invalidSyncState
            }
            try execute(
                "DELETE FROM sync_bootstrap_attempt WHERE singleton = 1",
                operation: "acknowledge_canonical_bootstrap"
            )
            guard sqlite3_changes(connection) == 1 else {
                throw WorkspaceSyncRepositoryError.bootstrapResponseMismatch
            }
            return WorkspaceCanonicalBootstrapReceipt(
                receiptID: receiptID,
                remoteWorkspaceID: plan.remoteWorkspaceID,
                acceptedCursor: acceptedCursor
            )
        }
    }

    func acknowledgeRemoteOperations(
        _ acknowledgements: [WorkspaceRemoteOperationAcknowledgement],
        conflicts: [WorkspacePersistedSyncConflict]
    ) throws {
        try transaction {
            guard let binding = try syncBinding() else {
                throw WorkspaceSyncRepositoryError.bindingRequired
            }
            let acknowledgedIDs = Set(acknowledgements.map(\.localOperationID))
            let conflictIDs = Set(conflicts.map { $0.conflict.operationID.rawValue })
            guard acknowledgedIDs.isDisjoint(with: conflictIDs),
                  acknowledgedIDs.count == acknowledgements.count,
                  conflictIDs.count == conflicts.count,
                  conflicts.allSatisfy({ $0.workspaceID == binding.workspaceID }) else {
                throw WorkspaceSyncRepositoryError.invalidConflict
            }

            for acknowledgement in acknowledgements {
                guard let operation = try v2OutboxOperation(
                    operationID: acknowledgement.localOperationID
                ) else {
                    guard let stored = try remoteAcknowledgement(
                        operationID: acknowledgement.localOperationID
                    ),
                    stored.entityType == acknowledgement.entityType,
                    stored.entityID == acknowledgement.entityID,
                    stored.remoteRevision == acknowledgement.remoteRevision,
                    stored.fieldClocks == acknowledgement.fieldClocks else {
                        throw WorkspaceSyncRepositoryError.acknowledgementMismatch
                    }
                    continue
                }
                let expected = try remoteIdentity(
                    operation: operation,
                    workspaceID: binding.workspaceID
                )
                guard expected.type == acknowledgement.entityType,
                      expected.id == acknowledgement.entityID,
                      expected.fieldClocks == acknowledgement.fieldClocks else {
                    throw WorkspaceSyncRepositoryError.acknowledgementMismatch
                }
                try upsertRemoteRevision(
                    entityType: acknowledgement.entityType,
                    entityID: acknowledgement.entityID,
                    revision: acknowledgement.remoteRevision,
                    fieldClocks: acknowledgement.fieldClocks
                )
                try insertRemoteAcknowledgement(acknowledgement)
                try deleteV2Outbox(operationID: acknowledgement.localOperationID)
            }

            for persisted in conflicts {
                let operationID = persisted.conflict.operationID.rawValue
                if let existing = try persistedConflict(operationID: operationID) {
                    guard existing == persisted.conflict else {
                        throw WorkspaceSyncRepositoryError.invalidConflict
                    }
                    continue
                }
                guard let operation = try v2OutboxOperation(operationID: operationID) else {
                    throw WorkspaceSyncRepositoryError.invalidConflict
                }
                let expected = try remoteIdentity(
                    operation: operation,
                    workspaceID: binding.workspaceID
                )
                guard expected.type == persisted.conflict.entityType,
                      expected.id == persisted.conflict.entityID else {
                    throw WorkspaceSyncRepositoryError.invalidConflict
                }
                let data = try codec.encode(persisted.conflict)
                try execute(
                    """
                    INSERT OR IGNORE INTO sync_conflicts (
                        conflict_id, workspace_id, operation_id, conflict, recorded_at
                    ) VALUES (?, ?, ?, ?, ?)
                    """,
                    bindings: [
                        .text(persisted.id.uuidString.lowercased()),
                        .text(persisted.workspaceID.rawValue.uuidString.lowercased()),
                        .text(operationID.uuidString.lowercased()),
                        .blob(data),
                        .real(persisted.recordedAt.timeIntervalSince1970),
                    ],
                    operation: "persist_sync_conflict"
                )
                try deleteV2Outbox(operationID: operationID)
            }
            if !conflicts.isEmpty {
                try execute(
                    """
                    UPDATE sync_state SET phase = 'conflictReviewRequired',
                        retry_attempt = 0, next_retry_at = NULL,
                        failure_code = 'sync_conflict'
                    WHERE singleton = 1
                    """,
                    operation: "persist_sync_conflict"
                )
            }
        }
    }

    func applyRemotePage(_ response: SyncPullResponse) throws -> WorkspaceRepositorySnapshot? {
        try transaction {
            guard let binding = try syncBinding(), response.workspaceID == binding.workspaceID else {
                throw WorkspaceSyncRepositoryError.bindingMismatch
            }
            let cursor = try syncCursor()
            guard cursor == response.fromCursor else {
                throw WorkspaceSyncRepositoryError.cursorMismatch
            }
            guard response.changes.count <= 500 else {
                throw WorkspaceSyncRepositoryError.requestBoundsExceeded
            }

            let currentStored = try readStoredState()
            guard let currentStored else { throw WorkspaceRepositoryError.invalidDatabase }
            let current = try decodeState(currentStored)
            var freshChanges: [SyncChange] = []
            for change in response.changes {
                if let appliedCursor = try appliedCursor(operationID: change.operationID.rawValue) {
                    guard appliedCursor == change.cursor.value else {
                        throw WorkspaceSyncRepositoryError.invalidCursor
                    }
                } else {
                    freshChanges.append(change)
                }
            }
            let pendingFieldClocks = try pendingRemoteFieldClocks(
                workspaceID: binding.workspaceID
            )
            var preservedFields: [SyncOperationID: Set<String>] = [:]
            for change in freshChanges {
                let key = RemoteEntityKey(type: change.entityType, id: change.entityID)
                guard let localClocks = pendingFieldClocks[key] else { continue }
                let serverClocks = try remoteFieldClocks(change.record)
                let preserved = Set(change.changedFields.filter { field in
                    guard let localClock = localClocks[field],
                          let serverClock = serverClocks[field] else { return false }
                    // A still-pending local value is canonical until the
                    // server explicitly accepts or conflicts it. Equal clocks
                    // are preserved too because writer ordering is server-side.
                    return localClock >= serverClock
                })
                if !preserved.isEmpty {
                    preservedFields[change.operationID] = preserved
                }
            }
            let content = try WorkspaceRemoteChangeApplicator.apply(
                freshChanges,
                to: current.content,
                preservingLocalFields: preservedFields
            )
            let canonical = try codec.canonicalizedWithData(content)
            let changed = canonical.data != currentStored.snapshotData
            let nextSnapshot: WorkspaceRepositorySnapshot
            if changed {
                nextSnapshot = WorkspaceRepositorySnapshot(
                    workspaceID: current.workspaceID,
                    writerID: current.writerID,
                    revision: WorkspaceRevision(rawValue: current.revision.rawValue + 1),
                    content: canonical.snapshot
                )
                try updateState(
                    nextSnapshot,
                    snapshotData: canonical.data,
                    expectedRevision: current.revision
                )
            } else {
                nextSnapshot = current
            }

            for change in freshChanges {
                let fieldClocks = try remoteFieldClocks(change.record)
                try upsertRemoteRevision(
                    entityType: change.entityType,
                    entityID: change.entityID,
                    revision: change.revision,
                    fieldClocks: fieldClocks
                )
                try execute(
                    """
                    INSERT INTO sync_applied_operations (operation_id, cursor, applied_at)
                    VALUES (?, ?, ?)
                    """,
                    bindings: [
                        .text(change.operationID.rawValue.uuidString.lowercased()),
                        .integer(change.cursor.value),
                        .real(Date().timeIntervalSince1970),
                    ],
                    operation: "record_remote_operation"
                )
            }
            try execute(
                "UPDATE sync_state SET cursor = ? WHERE singleton = 1 AND cursor = ?",
                bindings: [.integer(response.nextCursor.value), .integer(response.fromCursor.value)],
                operation: "advance_sync_cursor"
            )
            guard sqlite3_changes(connection) == 1 else {
                throw WorkspaceSyncRepositoryError.cursorMismatch
            }
            return changed ? nextSnapshot : nil
        }
    }

    func persistedSyncConflicts(limit: Int) throws -> [WorkspacePersistedSyncConflict] {
        guard (1...500).contains(limit) else {
            throw WorkspaceSyncRepositoryError.requestBoundsExceeded
        }
        let statement = try prepare(
            """
            SELECT conflict_id, workspace_id, conflict, recorded_at
            FROM sync_conflicts ORDER BY recorded_at DESC, conflict_id ASC LIMIT ?
            """,
            operation: "read_sync_conflicts"
        )
        try statement.bind([.integer(Int64(limit))], operation: "read_sync_conflicts")
        var values: [WorkspacePersistedSyncConflict] = []
        while try statement.step(operation: "read_sync_conflicts") {
            guard let id = UUID(uuidString: try statement.requiredText(at: 0, operation: "read_sync_conflicts")),
                  let workspaceID = UUID(
                    uuidString: try statement.requiredText(at: 1, operation: "read_sync_conflicts")
                  ) else {
                throw WorkspaceSyncRepositoryError.invalidConflict
            }
            let conflict: SyncConflict
            do {
                conflict = try codec.decoder.decode(
                    SyncConflict.self,
                    from: try statement.requiredBlob(at: 2, operation: "read_sync_conflicts")
                )
            } catch {
                throw WorkspaceSyncRepositoryError.invalidConflict
            }
            values.append(
                try WorkspacePersistedSyncConflict(
                    id: id,
                    workspaceID: WorkspaceID(rawValue: workspaceID),
                    conflict: conflict,
                    recordedAt: Date(timeIntervalSince1970: statement.double(at: 3))
                )
            )
        }
        return values
    }

    private func configureConnection() throws {
        _ = sqlite3_limit(connection, SQLITE_LIMIT_LENGTH, 72 * 1_024 * 1_024)
        try execute("PRAGMA foreign_keys = ON", operation: "configure_database")
        try execute("PRAGMA busy_timeout = 5000", operation: "configure_database")
    }

    /// Persistent pragmas are applied only after the application ID and schema
    /// version pass validation. Opening an unrelated or newer SQLite file must
    /// not change that file before failing closed.
    private func configureDurability() throws {
        try execute("PRAGMA journal_mode = WAL", operation: "configure_database")
        try execute("PRAGMA synchronous = FULL", operation: "configure_database")
    }

    private func migrateIfNeeded() throws {
        let applicationID = try pragmaInteger("application_id")
        let schemaVersion = Int(try pragmaInteger("user_version"))

        if applicationID != 0, applicationID != Self.applicationID {
            throw WorkspaceRepositoryError.invalidDatabase
        }
        guard schemaVersion <= Self.currentSchemaVersion else {
            throw WorkspaceRepositoryError.schemaTooNew(
                found: schemaVersion,
                supported: Self.currentSchemaVersion
            )
        }

        if schemaVersion == 0 {
            if applicationID == 0, try hasUserTables() {
                throw WorkspaceRepositoryError.invalidDatabase
            }
            try transaction {
                try execute(
                    """
                    CREATE TABLE workspace_state (
                        singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                        workspace_id TEXT NOT NULL,
                        writer_id TEXT NOT NULL,
                        revision INTEGER NOT NULL CHECK (revision >= 0),
                        snapshot BLOB NOT NULL,
                        updated_at REAL NOT NULL
                    )
                    """,
                    operation: "migrate_database"
                )
                try execute(
                    """
                    CREATE TABLE operation_receipts (
                        idempotency_key TEXT PRIMARY KEY NOT NULL,
                        operation_id TEXT NOT NULL UNIQUE,
                        request_fingerprint BLOB NOT NULL,
                        fingerprint_version INTEGER NOT NULL CHECK (fingerprint_version IN (1, 2)),
                        result_revision INTEGER NOT NULL CHECK (result_revision >= 0),
                        produced_change INTEGER NOT NULL CHECK (produced_change IN (0, 1)),
                        created_at REAL NOT NULL
                    )
                    """,
                    operation: "migrate_database"
                )
                try execute(
                    """
                    CREATE TABLE operation_outbox (
                        operation_id TEXT PRIMARY KEY NOT NULL,
                        idempotency_key TEXT NOT NULL UNIQUE
                            REFERENCES operation_receipts(idempotency_key),
                        workspace_id TEXT NOT NULL,
                        writer_id TEXT NOT NULL,
                        base_revision INTEGER NOT NULL CHECK (base_revision >= 0),
                        committed_revision INTEGER NOT NULL UNIQUE CHECK (committed_revision > 0),
                        entity_kind TEXT NOT NULL,
                        entity_id TEXT NOT NULL,
                        changed_fields BLOB NOT NULL,
                        field_clocks BLOB NOT NULL,
                        payload_format_version INTEGER NOT NULL,
                        payload BLOB NOT NULL,
                        created_at REAL NOT NULL,
                        delivery_attempts INTEGER NOT NULL DEFAULT 0 CHECK (delivery_attempts >= 0)
                    )
                    """,
                    operation: "migrate_database"
                )
                try execute(
                    """
                    CREATE TABLE legacy_imports (
                        singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                        openloops_sha256 TEXT NOT NULL,
                        personalization_sha256 TEXT NOT NULL,
                        imported_at REAL NOT NULL
                    )
                    """,
                    operation: "migrate_database"
                )
                try createSyncTables(operation: "migrate_database")
                try execute(
                    "PRAGMA application_id = \(Self.applicationID)",
                    operation: "migrate_database"
                )
                try execute(
                    "PRAGMA user_version = \(Self.currentSchemaVersion)",
                    operation: "migrate_database"
                )
            }
        } else if applicationID != Self.applicationID {
            throw WorkspaceRepositoryError.invalidDatabase
        } else {
            if schemaVersion == 1 {
                try migrateVersionOneOutbox()
            }
            if schemaVersion <= 2 {
                try migrateSyncVersionThree()
            }
            if schemaVersion <= 3 {
                try migrateSyncVersionFour()
            }
        }
    }

    private func migrateSyncVersionThree() throws {
        try transaction {
            try createSyncTables(operation: "migrate_sync_v3")
            try quarantineMalformedV2Operations()
            try execute(
                "PRAGMA user_version = \(Self.currentSchemaVersion)",
                operation: "migrate_sync_v3"
            )
        }
    }

    private func migrateSyncVersionFour() throws {
        try transaction {
            try createSyncTables(operation: "migrate_sync_v4")
            try execute(
                "PRAGMA user_version = \(Self.currentSchemaVersion)",
                operation: "migrate_sync_v4"
            )
        }
    }

    private func createSyncTables(operation: String) throws {
        try execute(
            """
            CREATE TABLE IF NOT EXISTS sync_binding (
                singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                account_id TEXT NOT NULL,
                remote_workspace_id TEXT NOT NULL,
                device_id TEXT NOT NULL,
                identity_provider TEXT NOT NULL CHECK (identity_provider IN ('google', 'apple')),
                bound_at REAL NOT NULL
            )
            """,
            operation: operation
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS sync_state (
                singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                cursor INTEGER NOT NULL CHECK (cursor >= 0),
                phase TEXT NOT NULL,
                retry_attempt INTEGER NOT NULL CHECK (retry_attempt BETWEEN 0 AND 32),
                next_retry_at REAL,
                last_success_at REAL,
                failure_code TEXT,
                bootstrap_complete INTEGER NOT NULL DEFAULT 0
                    CHECK (bootstrap_complete IN (0, 1))
            )
            """,
            operation: operation
        )
        try execute(
            """
            INSERT OR IGNORE INTO sync_state (
                singleton, cursor, phase, retry_attempt,
                next_retry_at, last_success_at, failure_code, bootstrap_complete
            ) VALUES (1, 0, 'localOnly', 0, NULL, NULL, NULL, 0)
            """,
            operation: operation
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS sync_entity_revisions (
                entity_type TEXT NOT NULL,
                entity_id TEXT NOT NULL,
                remote_revision INTEGER NOT NULL CHECK (remote_revision > 0),
                field_clocks BLOB NOT NULL,
                PRIMARY KEY (entity_type, entity_id)
            )
            """,
            operation: operation
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS sync_conflicts (
                conflict_id TEXT PRIMARY KEY NOT NULL,
                workspace_id TEXT NOT NULL,
                operation_id TEXT NOT NULL UNIQUE,
                conflict BLOB NOT NULL,
                recorded_at REAL NOT NULL
            )
            """,
            operation: operation
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS sync_operation_acknowledgements (
                operation_id TEXT PRIMARY KEY NOT NULL,
                entity_type TEXT NOT NULL,
                entity_id TEXT NOT NULL,
                remote_revision INTEGER NOT NULL CHECK (remote_revision > 0),
                field_clocks BLOB NOT NULL,
                acknowledged_at REAL NOT NULL
            )
            """,
            operation: operation
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS sync_applied_operations (
                operation_id TEXT PRIMARY KEY NOT NULL,
                cursor INTEGER NOT NULL UNIQUE CHECK (cursor > 0),
                applied_at REAL NOT NULL
            )
            """,
            operation: operation
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS sync_bootstrap_receipts (
                receipt_id TEXT PRIMARY KEY NOT NULL,
                local_workspace_id TEXT NOT NULL,
                remote_workspace_id TEXT NOT NULL,
                account_id TEXT NOT NULL,
                device_id TEXT NOT NULL,
                local_revision INTEGER NOT NULL CHECK (local_revision >= 0),
                snapshot_digest BLOB NOT NULL,
                accepted_cursor INTEGER NOT NULL CHECK (accepted_cursor >= 0),
                accepted_operations_digest BLOB NOT NULL,
                created_at REAL NOT NULL,
                UNIQUE (
                    local_workspace_id, remote_workspace_id, account_id, device_id,
                    local_revision, snapshot_digest
                )
            )
            """,
            operation: operation
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS sync_bootstrap_attempt (
                singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                account_id TEXT NOT NULL,
                remote_workspace_id TEXT NOT NULL,
                device_id TEXT NOT NULL,
                plan BLOB NOT NULL,
                created_at REAL NOT NULL
            )
            """,
            operation: operation
        )
        try execute(
            """
            CREATE TABLE IF NOT EXISTS sync_quarantined_operations (
                operation_id TEXT PRIMARY KEY NOT NULL,
                idempotency_key TEXT NOT NULL,
                workspace_id TEXT NOT NULL,
                writer_id TEXT NOT NULL,
                base_revision INTEGER NOT NULL,
                committed_revision INTEGER NOT NULL,
                entity_kind TEXT NOT NULL,
                entity_id TEXT NOT NULL,
                changed_fields BLOB NOT NULL,
                field_clocks BLOB NOT NULL,
                payload_format_version INTEGER NOT NULL,
                payload BLOB NOT NULL,
                created_at REAL NOT NULL,
                delivery_attempts INTEGER NOT NULL,
                quarantine_reason TEXT NOT NULL,
                quarantined_at REAL NOT NULL
            )
            """,
            operation: operation
        )
    }

    private func quarantineMalformedV2Operations() throws {
        let statement = try prepare(
            """
            SELECT operation_id, changed_fields, field_clocks
            FROM operation_outbox
            WHERE payload_format_version = ?
            ORDER BY committed_revision ASC
            """,
            operation: "inspect_v2_clock_masks"
        )
        try statement.bind(
            [.integer(Int64(WorkspaceLocalOperationEnvelopeV2.formatVersion))],
            operation: "inspect_v2_clock_masks"
        )
        var malformedIDs: [String] = []
        while try statement.step(operation: "inspect_v2_clock_masks") {
            let fields: [String]
            let clocks: [String: Date]
            do {
                fields = try codec.decoder.decode(
                    [String].self,
                    from: try statement.requiredBlob(at: 1, operation: "inspect_v2_clock_masks")
                )
                clocks = try codec.decoder.decode(
                    [String: Date].self,
                    from: try statement.requiredBlob(at: 2, operation: "inspect_v2_clock_masks")
                )
            } catch {
                malformedIDs.append(try statement.requiredText(at: 0, operation: "inspect_v2_clock_masks"))
                continue
            }
            if Set(fields) != Set(clocks.keys) {
                malformedIDs.append(try statement.requiredText(at: 0, operation: "inspect_v2_clock_masks"))
            }
        }

        for operationID in malformedIDs {
            try execute(
                """
                INSERT INTO sync_quarantined_operations (
                    operation_id, idempotency_key, workspace_id, writer_id,
                    base_revision, committed_revision, entity_kind, entity_id,
                    changed_fields, field_clocks, payload_format_version, payload,
                    created_at, delivery_attempts, quarantine_reason, quarantined_at
                )
                SELECT operation_id, idempotency_key, workspace_id, writer_id,
                       base_revision, committed_revision, entity_kind, entity_id,
                       changed_fields, field_clocks, payload_format_version, payload,
                       created_at, delivery_attempts, 'clock_mask_mismatch', ?
                FROM operation_outbox WHERE operation_id = ?
                """,
                bindings: [.real(Date().timeIntervalSince1970), .text(operationID)],
                operation: "quarantine_v2_clock_mask"
            )
            try execute(
                "DELETE FROM operation_outbox WHERE operation_id = ?",
                bindings: [.text(operationID)],
                operation: "quarantine_v2_clock_mask"
            )
        }
        if !malformedIDs.isEmpty {
            try execute(
                """
                UPDATE sync_state
                SET phase = 'adapterBlocked', failure_code = 'legacy_clock_mask_mismatch'
                WHERE singleton = 1
                """,
                operation: "quarantine_v2_clock_mask"
            )
        }
    }

    /// Converts only legacy rows whose snapshot and metadata identify one
    /// bounded entity without ambiguity. Broad historical personalization rows
    /// stay at format 1 and require an explicit full bootstrap acknowledgement;
    /// they are never disguised as normal entity operations.
    private func migrateVersionOneOutbox() throws {
        try transaction {
            if try !table("operation_receipts", hasColumn: "fingerprint_version") {
                try execute(
                    """
                    ALTER TABLE operation_receipts
                    ADD COLUMN fingerprint_version INTEGER NOT NULL DEFAULT 1
                        CHECK (fingerprint_version IN (1, 2))
                    """,
                    operation: "migrate_outbox_v2"
                )
            }
            let statement = try prepare(
                """
                SELECT operation_id, entity_kind, entity_id, changed_fields,
                       payload_format_version, payload, created_at
                FROM operation_outbox
                ORDER BY committed_revision ASC, operation_id ASC
                """,
                operation: "migrate_outbox_v2"
            )
            var upgrades: [LegacyOutboxUpgrade] = []
            while try statement.step(operation: "migrate_outbox_v2") {
                let payloadFormatVersion = Int(statement.integer(at: 4))
                guard payloadFormatVersion == WorkspaceOutboxOperation.legacySnapshotPayloadFormatVersion
                        || payloadFormatVersion == WorkspaceLocalOperationEnvelopeV2.formatVersion else {
                    throw WorkspaceRepositoryError.invalidDatabase
                }
                guard payloadFormatVersion == WorkspaceOutboxOperation.legacySnapshotPayloadFormatVersion else {
                    continue
                }

                let payload = try statement.requiredBlob(at: 5, operation: "migrate_outbox_v2")
                guard !payload.isEmpty,
                      payload.count <= WorkspaceOutboxOperation.maximumLegacySnapshotPayloadByteCount else {
                    throw WorkspaceRepositoryError.invalidDatabase
                }
                let snapshot: FounderOfficeSnapshot
                let changedFields: [String]
                do {
                    snapshot = try codec.normalized(
                        codec.decoder.decode(FounderOfficeSnapshot.self, from: payload)
                    )
                    changedFields = try codec.decoder.decode(
                        [String].self,
                        from: try statement.requiredBlob(at: 3, operation: "migrate_outbox_v2")
                    )
                } catch let error as WorkspaceRepositoryError {
                    throw error
                } catch {
                    throw WorkspaceRepositoryError.invalidDatabase
                }

                do {
                    let envelope = try WorkspaceLocalOperationBuilder.makeEnvelope(
                        entityKind: try statement.requiredText(at: 1, operation: "migrate_outbox_v2"),
                        entityID: try statement.requiredText(at: 2, operation: "migrate_outbox_v2"),
                        changedFields: Array(Set(changedFields)).sorted(),
                        snapshot: snapshot,
                        createdAt: Date(timeIntervalSince1970: statement.double(at: 6))
                    )
                    upgrades.append(
                        LegacyOutboxUpgrade(
                            operationID: try statement.requiredText(at: 0, operation: "migrate_outbox_v2"),
                            entityKind: envelope.entityKind.rawValue,
                            entityID: envelope.entityID,
                            payload: try WorkspaceLocalOperationBuilder.encode(envelope)
                        )
                    )
                } catch is WorkspaceLocalOperationError {
                    // A decoded schema-1 row that cannot be represented by the
                    // stricter bounded shape stays byte-for-byte intact for a
                    // future canonical bootstrap. Never approximate it or turn
                    // a compatibility limitation into a launch failure.
                    continue
                }
            }

            for upgrade in upgrades {
                try execute(
                    """
                    UPDATE operation_outbox
                    SET entity_kind = ?, entity_id = ?, payload_format_version = ?, payload = ?
                    WHERE operation_id = ? AND payload_format_version = ?
                    """,
                    bindings: [
                        .text(upgrade.entityKind),
                        .text(upgrade.entityID),
                        .integer(Int64(WorkspaceLocalOperationEnvelopeV2.formatVersion)),
                        .blob(upgrade.payload),
                        .text(upgrade.operationID),
                        .integer(Int64(WorkspaceOutboxOperation.legacySnapshotPayloadFormatVersion))
                    ],
                    operation: "migrate_outbox_v2"
                )
                guard sqlite3_changes(connection) == 1 else {
                    throw WorkspaceRepositoryError.invalidDatabase
                }
            }
            try execute(
                "PRAGMA user_version = \(Self.currentSchemaVersion)",
                operation: "migrate_outbox_v2"
            )
        }
    }

    private func insertInitialState(
        _ snapshot: WorkspaceRepositorySnapshot,
        legacyImport: LegacyWorkspaceImport?
    ) throws {
        let snapshotData = try codec.encode(snapshot.content)
        try transaction {
            guard try readState() == nil else {
                throw WorkspaceRepositoryError.invalidDatabase
            }
            try execute(
                """
                INSERT INTO workspace_state (
                    singleton, workspace_id, writer_id, revision, snapshot, updated_at
                ) VALUES (1, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .text(snapshot.workspaceID.uuidString.lowercased()),
                    .text(snapshot.writerID.description),
                    .integer(snapshot.revision.rawValue),
                    .blob(snapshotData),
                    .real(Date().timeIntervalSince1970)
                ],
                operation: "bootstrap_workspace"
            )
            if let legacyImport {
                try execute(
                    """
                    INSERT INTO legacy_imports (
                        singleton, openloops_sha256, personalization_sha256, imported_at
                    ) VALUES (1, ?, ?, ?)
                    """,
                    bindings: [
                        .text(legacyImport.openLoopsDigest),
                        .text(legacyImport.personalizationDigest),
                        .real(Date().timeIntervalSince1970)
                    ],
                    operation: "record_legacy_import"
                )
            }
        }
    }

    private func readState() throws -> WorkspaceRepositorySnapshot? {
        guard let stored = try readStoredState() else { return nil }
        return try decodeState(stored)
    }

    /// Reads the exact canonical bytes without decoding the full workspace.
    /// A changed transaction already carries a canonical replacement, so this
    /// avoids another 10,000-Move decode and encode cycle on its hot path.
    private func readStoredState() throws -> StoredWorkspaceState? {
        let statement = try prepare(
            """
            SELECT workspace_id, writer_id, revision, snapshot
            FROM workspace_state
            WHERE singleton = 1
            """,
            operation: "read_snapshot"
        )
        guard try statement.step(operation: "read_snapshot") else { return nil }

        guard
            let workspaceID = UUID(uuidString: try statement.requiredText(at: 0, operation: "read_snapshot")),
            let writerUUID = UUID(uuidString: try statement.requiredText(at: 1, operation: "read_snapshot"))
        else {
            throw WorkspaceRepositoryError.invalidDatabase
        }
        let revisionValue = statement.integer(at: 2)
        guard revisionValue >= 0 else {
            throw WorkspaceRepositoryError.invalidDatabase
        }

        let data = try statement.requiredBlob(at: 3, operation: "read_snapshot")
        guard !data.isEmpty, data.count <= 64 * 1_024 * 1_024 else {
            throw WorkspaceRepositoryError.invalidDatabase
        }
        return StoredWorkspaceState(
            workspaceID: workspaceID,
            writerID: WorkspaceWriterID(rawValue: writerUUID),
            revision: WorkspaceRevision(rawValue: revisionValue),
            snapshotData: data
        )
    }

    private func decodeState(
        _ stored: StoredWorkspaceState
    ) throws -> WorkspaceRepositorySnapshot {
        let content: FounderOfficeSnapshot
        do {
            content = try codec.normalized(
                codec.decoder.decode(FounderOfficeSnapshot.self, from: stored.snapshotData)
            )
        } catch let error as WorkspaceRepositoryError {
            throw error
        } catch {
            throw WorkspaceRepositoryError.invalidDatabase
        }
        return WorkspaceRepositorySnapshot(
            workspaceID: stored.workspaceID,
            writerID: stored.writerID,
            revision: stored.revision,
            content: content
        )
    }

    private func validate(
        _ mutation: WorkspaceMutation,
        expectedRevision: WorkspaceRevision
    ) throws -> ValidatedWorkspaceMutation {
        guard expectedRevision.rawValue >= 0 else {
            throw WorkspaceRepositoryError.invalidMutation(reason: "revision cannot be negative")
        }

        let entityKind = mutation.entityKind.trimmingCharacters(in: .whitespacesAndNewlines)
        let entityID = mutation.entityID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entityKind.isEmpty, entityKind.utf8.count <= 128 else {
            throw WorkspaceRepositoryError.invalidMutation(reason: "entity kind is missing or too long")
        }
        guard !entityID.isEmpty, entityID.utf8.count <= 512 else {
            throw WorkspaceRepositoryError.invalidMutation(reason: "entity identifier is missing or too long")
        }
        guard mutation.createdAt.timeIntervalSinceReferenceDate.isFinite else {
            throw WorkspaceRepositoryError.invalidMutation(reason: "creation time is invalid")
        }

        let changedFields = Array(Set(mutation.changedFields)).sorted()
        guard !changedFields.isEmpty, changedFields.count <= 256 else {
            throw WorkspaceRepositoryError.invalidMutation(reason: "changed fields are missing or too numerous")
        }
        guard changedFields.allSatisfy({ field in
            !field.isEmpty
                && field == field.trimmingCharacters(in: .whitespacesAndNewlines)
                && field.utf8.count <= 128
        }) else {
            throw WorkspaceRepositoryError.invalidMutation(reason: "a changed field is invalid")
        }
        guard Set(mutation.fieldClocks.keys) == Set(changedFields) else {
            throw WorkspaceRepositoryError.invalidMutation(
                reason: "field clocks must match changed fields exactly"
            )
        }
        guard mutation.fieldClocks.values.allSatisfy({ $0.timeIntervalSinceReferenceDate.isFinite }) else {
            throw WorkspaceRepositoryError.invalidMutation(reason: "a field clock is invalid")
        }

        let canonical = try codec.canonicalizedWithData(mutation.replacement)
        let normalizedSnapshot = canonical.snapshot
        let normalizedMutation = WorkspaceMutation(
            operationID: mutation.operationID,
            idempotencyKey: mutation.idempotencyKey,
            entityKind: entityKind,
            entityID: entityID,
            changedFields: changedFields,
            fieldClocks: mutation.fieldClocks,
            replacement: normalizedSnapshot,
            createdAt: mutation.createdAt
        )
        let snapshotData = canonical.data
        guard snapshotData.count <= 64 * 1_024 * 1_024 else {
            throw WorkspaceRepositoryError.invalidMutation(reason: "snapshot exceeds the local safety limit")
        }

        struct FingerprintEnvelope: Codable {
            var expectedRevision: WorkspaceRevision
            var operationID: UUID
            var idempotencyKey: WorkspaceIdempotencyKey
            var entityKind: String
            var entityID: String
            var changedFields: [String]
            var fieldClocks: [String: Date]
            var snapshotDigest: Data
            var createdAt: Date
        }
        let fingerprintInput = try codec.encode(
            FingerprintEnvelope(
                expectedRevision: expectedRevision,
                operationID: normalizedMutation.operationID,
                idempotencyKey: normalizedMutation.idempotencyKey,
                entityKind: normalizedMutation.entityKind,
                entityID: normalizedMutation.entityID,
                changedFields: normalizedMutation.changedFields,
                fieldClocks: normalizedMutation.fieldClocks,
                snapshotDigest: Data(SHA256.hash(data: snapshotData)),
                createdAt: normalizedMutation.createdAt
            )
        )
        let fingerprint = Data(SHA256.hash(data: fingerprintInput))
        return ValidatedWorkspaceMutation(
            mutation: normalizedMutation,
            snapshotData: snapshotData,
            fingerprint: fingerprint
        )
    }

    private func updateState(
        _ snapshot: WorkspaceRepositorySnapshot,
        snapshotData: Data,
        expectedRevision: WorkspaceRevision
    ) throws {
        try execute(
            """
            UPDATE workspace_state
            SET revision = ?, snapshot = ?, updated_at = ?
            WHERE singleton = 1 AND revision = ?
            """,
            bindings: [
                .integer(snapshot.revision.rawValue),
                .blob(snapshotData),
                .real(Date().timeIntervalSince1970),
                .integer(expectedRevision.rawValue)
            ],
            operation: "commit_snapshot"
        )
        guard sqlite3_changes(connection) == 1 else {
            let actual = try readState()?.revision ?? expectedRevision
            throw WorkspaceRepositoryError.revisionConflict(
                expected: expectedRevision,
                actual: actual
            )
        }
    }

    private func scalarCount(
        _ sql: String,
        bindings: [SQLiteWorkspaceValue] = [],
        operation: String
    ) throws -> Int64 {
        let statement = try prepare(sql, operation: operation)
        try statement.bind(bindings, operation: operation)
        guard try statement.step(operation: operation) else {
            throw WorkspaceRepositoryError.invalidDatabase
        }
        return statement.integer(at: 0)
    }

    /// Bootstrap may supersede ordinary entity operations through one exact
    /// canonical snapshot. These local entities do not yet have a safe v1
    /// bootstrap representation, so their pending edits must never disappear
    /// under that acknowledgement.
    private func failIfBootstrapWouldDropProtectedOutboxState() throws {
        let profileStatement = try prepare(
            """
            SELECT entity_kind, changed_fields FROM operation_outbox
            WHERE entity_kind IN ('profile', 'personalization')
            """,
            operation: "inspect_bootstrap_profile_gate"
        )
        while try profileStatement.step(operation: "inspect_bootstrap_profile_gate") {
            let entityKind = try profileStatement.requiredText(
                at: 0,
                operation: "inspect_bootstrap_profile_gate"
            )
            let changedFields: [String]
            do {
                changedFields = try codec.decoder.decode(
                    [String].self,
                    from: try profileStatement.requiredBlob(
                        at: 1,
                        operation: "inspect_bootstrap_profile_gate"
                    )
                )
            } catch {
                throw WorkspaceV2SyncAdapterError.profileRequiresReviewedBootstrap
            }
            // The frozen bootstrap RPC owns only preferredName ->
            // profile.displayName. Product displayName and iconStyle have no
            // reviewed wire representation and therefore stay pending.
            guard entityKind == WorkspaceLocalEntityKind.profile.rawValue,
                  Set(changedFields).isSubset(of: ["preferredName", "updatedAt"]),
                  changedFields.contains("preferredName") else {
                throw WorkspaceV2SyncAdapterError.profileRequiresReviewedBootstrap
            }
        }
        let assetCount = try scalarCount(
            "SELECT count(*) FROM operation_outbox WHERE entity_kind = 'asset'",
            operation: "inspect_bootstrap_asset_gate"
        )
        if assetCount > 0 {
            throw WorkspaceV2SyncAdapterError.assetTransferDisabled
        }
    }

    private func upsertRemoteRevision(
        entityType: SyncEntityType,
        entityID: UUID,
        revision: Int64,
        fieldClocks: [String: Date]
    ) throws {
        guard revision > 0,
              fieldClocks.values.allSatisfy({ $0.timeIntervalSinceReferenceDate.isFinite }) else {
            throw WorkspaceSyncRepositoryError.invalidRemoteRevision
        }
        let existingStatement = try prepare(
            """
            SELECT remote_revision, field_clocks FROM sync_entity_revisions
            WHERE entity_type = ? AND entity_id = ?
            """,
            operation: "read_remote_revision"
        )
        let bindings: [SQLiteWorkspaceValue] = [
            .text(entityType.rawValue), .text(entityID.uuidString.lowercased()),
        ]
        try existingStatement.bind(bindings, operation: "read_remote_revision")
        var mergedClocks = fieldClocks
        if try existingStatement.step(operation: "read_remote_revision") {
            let existingRevision = existingStatement.integer(at: 0)
            guard revision >= existingRevision else {
                throw WorkspaceSyncRepositoryError.invalidRemoteRevision
            }
            let existingClocks: [String: Date]
            do {
                existingClocks = try codec.decoder.decode(
                    [String: Date].self,
                    from: try existingStatement.requiredBlob(at: 1, operation: "read_remote_revision")
                )
            } catch {
                throw WorkspaceSyncRepositoryError.invalidRemoteRevision
            }
            for (field, clock) in existingClocks where mergedClocks[field] == nil {
                mergedClocks[field] = clock
            }
        }
        let clocksData = try codec.encode(mergedClocks)
        try execute(
            """
            INSERT INTO sync_entity_revisions (
                entity_type, entity_id, remote_revision, field_clocks
            ) VALUES (?, ?, ?, ?)
            ON CONFLICT(entity_type, entity_id) DO UPDATE SET
                remote_revision = excluded.remote_revision,
                field_clocks = excluded.field_clocks
            """,
            bindings: bindings + [.integer(revision), .blob(clocksData)],
            operation: "write_remote_revision"
        )
    }

    private func digestBootstrapAcceptance(
        bootstrap: WorkspaceBootstrap,
        results: [SyncOperationResult]
    ) throws -> Data {
        struct DigestItem: Codable {
            let operationID: SyncOperationID
            let status: SyncOperationStatus
            let revision: Int64
            let cursor: SyncCursor
        }
        let items = try results.map { result -> DigestItem in
            guard let revision = result.revision, let cursor = result.cursor else {
                throw WorkspaceSyncRepositoryError.bootstrapResponseMismatch
            }
            return DigestItem(
                operationID: result.operationID,
                status: result.status,
                revision: revision,
                cursor: cursor
            )
        }
        .sorted { $0.operationID.rawValue.uuidString < $1.operationID.rawValue.uuidString }
        struct Acceptance: Codable {
            let bootstrap: WorkspaceBootstrap
            let results: [DigestItem]
        }
        return Data(
            SHA256.hash(
                data: try codec.encode(
                    Acceptance(bootstrap: bootstrap, results: items)
                )
            )
        )
    }

    private func bootstrapAttempt() throws -> StoredBootstrapAttempt? {
        let statement = try prepare(
            """
            SELECT account_id, remote_workspace_id, device_id, plan
            FROM sync_bootstrap_attempt WHERE singleton = 1
            """,
            operation: "read_bootstrap_attempt"
        )
        guard try statement.step(operation: "read_bootstrap_attempt") else { return nil }
        guard let accountID = UUID(
            uuidString: try statement.requiredText(at: 0, operation: "read_bootstrap_attempt")
        ),
        let remoteWorkspaceID = UUID(
            uuidString: try statement.requiredText(at: 1, operation: "read_bootstrap_attempt")
        ),
        let deviceID = UUID(
            uuidString: try statement.requiredText(at: 2, operation: "read_bootstrap_attempt")
        ) else {
            throw WorkspaceRepositoryError.invalidDatabase
        }
        let plan: WorkspaceCanonicalBootstrapPlan
        do {
            plan = try codec.decoder.decode(
                WorkspaceCanonicalBootstrapPlan.self,
                from: try statement.requiredBlob(at: 3, operation: "read_bootstrap_attempt")
            )
        } catch {
            throw WorkspaceRepositoryError.invalidDatabase
        }
        guard plan.remoteWorkspaceID.rawValue == remoteWorkspaceID,
              plan.snapshotDigest.count == SHA256.Digest.byteCount,
              plan.localRevision.rawValue >= 0,
              !plan.workspaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              plan.workspaceName.unicodeScalars.count <= 120,
              plan.operations.count <= 50_000,
              plan.operations.allSatisfy({ $0.entityType != .workspace }) else {
            throw WorkspaceRepositoryError.invalidDatabase
        }
        return StoredBootstrapAttempt(
            accountID: FounderAccountID(rawValue: accountID),
            remoteWorkspaceID: WorkspaceID(rawValue: remoteWorkspaceID),
            deviceID: DeviceID(rawValue: deviceID),
            plan: plan
        )
    }

    private func bootstrapWorkspaceBaseline(
        _ bootstrap: WorkspaceBootstrap
    ) throws -> (revision: Int64, fieldClocks: [String: Date]) {
        let revision: Int64
        switch bootstrap.workspace["revision"] {
        case let .integer(value): revision = value
        case let .number(value):
            let candidate = NSDecimalNumber(decimal: value).int64Value
            guard Decimal(candidate) == value else {
                throw WorkspaceSyncRepositoryError.bootstrapResponseMismatch
            }
            revision = candidate
        default:
            throw WorkspaceSyncRepositoryError.bootstrapResponseMismatch
        }
        let fieldClocks = try remoteFieldClocks(bootstrap.workspace)
        guard revision > 0, fieldClocks["name"] != nil else {
            throw WorkspaceSyncRepositoryError.bootstrapResponseMismatch
        }
        return (revision, fieldClocks)
    }

    private func bootstrapReceipt(
        localWorkspaceID: UUID,
        remoteWorkspaceID: WorkspaceID,
        accountID: FounderAccountID,
        deviceID: DeviceID,
        localRevision: WorkspaceRevision,
        snapshotDigest: Data
    ) throws -> StoredBootstrapReceipt? {
        let statement = try prepare(
            """
            SELECT receipt_id, accepted_cursor, accepted_operations_digest
            FROM sync_bootstrap_receipts
            WHERE local_workspace_id = ? AND remote_workspace_id = ?
              AND account_id = ? AND device_id = ?
              AND local_revision = ? AND snapshot_digest = ?
            """,
            operation: "read_bootstrap_receipt"
        )
        try statement.bind(
            [
                .text(localWorkspaceID.uuidString.lowercased()),
                .text(remoteWorkspaceID.rawValue.uuidString.lowercased()),
                .text(accountID.rawValue.uuidString.lowercased()),
                .text(deviceID.rawValue.uuidString.lowercased()),
                .integer(localRevision.rawValue),
                .blob(snapshotDigest),
            ],
            operation: "read_bootstrap_receipt"
        )
        guard try statement.step(operation: "read_bootstrap_receipt") else { return nil }
        guard let receiptID = UUID(
            uuidString: try statement.requiredText(at: 0, operation: "read_bootstrap_receipt")
        ) else {
            throw WorkspaceRepositoryError.invalidDatabase
        }
        return StoredBootstrapReceipt(
            receiptID: receiptID,
            acceptedCursor: try SyncCursor(value: statement.integer(at: 1)),
            operationsDigest: try statement.requiredBlob(at: 2, operation: "read_bootstrap_receipt")
        )
    }

    private func v2OutboxOperation(
        operationID: UUID
    ) throws -> WorkspaceOutboxOperation? {
        let statement = try prepare(
            """
            SELECT operation_id, idempotency_key, workspace_id, writer_id,
                   base_revision, committed_revision, entity_kind, entity_id,
                   changed_fields, field_clocks, payload_format_version,
                   payload, created_at, delivery_attempts
            FROM operation_outbox
            WHERE operation_id = ? AND payload_format_version = ?
            """,
            operation: "read_exact_outbox"
        )
        try statement.bind(
            [
                .text(operationID.uuidString.lowercased()),
                .integer(Int64(WorkspaceLocalOperationEnvelopeV2.formatVersion)),
            ],
            operation: "read_exact_outbox"
        )
        guard try statement.step(operation: "read_exact_outbox") else { return nil }
        return try decodeOutboxOperation(statement, operation: "read_exact_outbox")
    }

    private func remoteIdentity(
        operation: WorkspaceOutboxOperation,
        workspaceID: WorkspaceID
    ) throws -> (type: SyncEntityType, id: UUID, fieldClocks: [String: Date]) {
        guard case let .localEntity(envelope) = try operation.decodedLocalPayload() else {
            throw WorkspaceSyncRepositoryError.acknowledgementMismatch
        }
        let identity: (type: SyncEntityType, id: UUID)
        switch envelope.record {
        case let .move(move): identity = (.move, move.id)
        case .appearance: identity = (.appearance, workspaceID.rawValue)
        case .profile:
            throw WorkspaceV2SyncAdapterError.profileRequiresReviewedBootstrap
        case .workspace: identity = (.workspace, workspaceID.rawValue)
        case let .primaryGoal(goal): identity = (.primaryGoal, goal.id)
        case let .milestone(milestone): identity = (.milestone, milestone.id)
        case .asset:
            throw WorkspaceV2SyncAdapterError.assetTransferDisabled
        }
        let baseRevision = try remoteRevision(
            entityType: identity.type,
            entityID: identity.id
        )
        // A server acknowledgement or conflict cannot predate the canonical
        // bootstrap which establishes a positive server revision. Treat such
        // evidence as unbound rather than adapting a partial local update as a
        // remote create.
        guard baseRevision > 0 else {
            throw WorkspaceSyncRepositoryError.acknowledgementMismatch
        }
        let wire = try WorkspaceV2SyncAdapter.adapt(
            operation: operation,
            envelope: envelope,
            remoteBaseRevision: baseRevision,
            workspaceID: workspaceID
        )
        return (wire.entityType, wire.entityID, wire.fieldClocks)
    }

    private func insertRemoteAcknowledgement(
        _ acknowledgement: WorkspaceRemoteOperationAcknowledgement
    ) throws {
        try execute(
            """
            INSERT INTO sync_operation_acknowledgements (
                operation_id, entity_type, entity_id, remote_revision,
                field_clocks, acknowledged_at
            ) VALUES (?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .text(acknowledgement.localOperationID.uuidString.lowercased()),
                .text(acknowledgement.entityType.rawValue),
                .text(acknowledgement.entityID.uuidString.lowercased()),
                .integer(acknowledgement.remoteRevision),
                .blob(try codec.encode(acknowledgement.fieldClocks)),
                .real(Date().timeIntervalSince1970),
            ],
            operation: "record_remote_acknowledgement"
        )
    }

    private func remoteAcknowledgement(
        operationID: UUID
    ) throws -> StoredRemoteAcknowledgement? {
        let statement = try prepare(
            """
            SELECT entity_type, entity_id, remote_revision, field_clocks
            FROM sync_operation_acknowledgements WHERE operation_id = ?
            """,
            operation: "read_remote_acknowledgement"
        )
        try statement.bind(
            [.text(operationID.uuidString.lowercased())],
            operation: "read_remote_acknowledgement"
        )
        guard try statement.step(operation: "read_remote_acknowledgement"),
              let entityType = SyncEntityType(
                rawValue: try statement.requiredText(at: 0, operation: "read_remote_acknowledgement")
              ),
              let entityID = UUID(
                uuidString: try statement.requiredText(at: 1, operation: "read_remote_acknowledgement")
              ) else { return nil }
        let clocks: [String: Date]
        do {
            clocks = try codec.decoder.decode(
                [String: Date].self,
                from: try statement.requiredBlob(at: 3, operation: "read_remote_acknowledgement")
            )
        } catch {
            throw WorkspaceSyncRepositoryError.acknowledgementMismatch
        }
        return StoredRemoteAcknowledgement(
            entityType: entityType,
            entityID: entityID,
            remoteRevision: statement.integer(at: 2),
            fieldClocks: clocks
        )
    }

    private func persistedConflict(operationID: UUID) throws -> SyncConflict? {
        let statement = try prepare(
            "SELECT conflict FROM sync_conflicts WHERE operation_id = ?",
            operation: "read_exact_sync_conflict"
        )
        try statement.bind(
            [.text(operationID.uuidString.lowercased())],
            operation: "read_exact_sync_conflict"
        )
        guard try statement.step(operation: "read_exact_sync_conflict") else { return nil }
        do {
            return try codec.decoder.decode(
                SyncConflict.self,
                from: try statement.requiredBlob(at: 0, operation: "read_exact_sync_conflict")
            )
        } catch {
            throw WorkspaceSyncRepositoryError.invalidConflict
        }
    }

    private func deleteV2Outbox(operationID: UUID) throws {
        try execute(
            """
            DELETE FROM operation_outbox
            WHERE operation_id = ? AND payload_format_version = ?
            """,
            bindings: [
                .text(operationID.uuidString.lowercased()),
                .integer(Int64(WorkspaceLocalOperationEnvelopeV2.formatVersion)),
            ],
            operation: "acknowledge_remote_operation"
        )
    }

    private func appliedCursor(operationID: UUID) throws -> Int64? {
        let statement = try prepare(
            "SELECT cursor FROM sync_applied_operations WHERE operation_id = ?",
            operation: "read_applied_remote_operation"
        )
        try statement.bind(
            [.text(operationID.uuidString.lowercased())],
            operation: "read_applied_remote_operation"
        )
        guard try statement.step(operation: "read_applied_remote_operation") else { return nil }
        return statement.integer(at: 0)
    }

    private func pendingRemoteFieldClocks(
        workspaceID: WorkspaceID
    ) throws -> [RemoteEntityKey: [String: Date]] {
        // Keep all durable sources of locally protected remote fields behind
        // this one extension point. Retained unresolved-conflict payloads can
        // merge their clocks here without changing page application semantics.
        let statement = try prepare(
            """
            SELECT operation_id, idempotency_key, workspace_id, writer_id,
                   base_revision, committed_revision, entity_kind, entity_id,
                   changed_fields, field_clocks, payload_format_version,
                   payload, created_at, delivery_attempts
            FROM operation_outbox
            ORDER BY committed_revision ASC, operation_id ASC
            """,
            operation: "read_pending_field_clocks"
        )
        var result: [RemoteEntityKey: [String: Date]] = [:]
        while try statement.step(operation: "read_pending_field_clocks") {
            let operation = try decodeOutboxOperation(
                statement,
                operation: "read_pending_field_clocks"
            )
            guard case let .localEntity(envelope) = try operation.decodedLocalPayload() else {
                throw WorkspaceSyncRepositoryError.bootstrapResponseMismatch
            }
            let mapped: WorkspaceV2SyncAdapter.MappedMutation
            do {
                mapped = try WorkspaceV2SyncAdapter.mappedMutation(
                    envelope: envelope,
                    localClocks: operation.fieldClocks,
                    workspaceID: workspaceID
                )
            } catch WorkspaceV2SyncAdapterError.profileRequiresReviewedBootstrap {
                continue
            } catch WorkspaceV2SyncAdapterError.assetTransferDisabled {
                continue
            }
            let key = RemoteEntityKey(type: mapped.entityType, id: mapped.entityID)
            var clocks = result[key] ?? [:]
            for (field, clock) in mapped.fieldClocks {
                clocks[field] = max(clocks[field] ?? clock, clock)
            }
            result[key] = clocks
        }
        return result
    }

    private func remoteFieldClocks(
        _ record: [String: SyncJSONValue]
    ) throws -> [String: Date] {
        guard case let .object(values)? = record["fieldClocks"] else {
            throw WorkspaceSyncRepositoryError.invalidRemoteRevision
        }
        var result: [String: Date] = [:]
        for (field, value) in values {
            guard case let .string(string) = value else {
                throw WorkspaceSyncRepositoryError.invalidRemoteRevision
            }
            result[field] = try WorkspaceV2SyncAdapter.parseTimestamp(string)
        }
        return result
    }

    private func receipt(for key: WorkspaceIdempotencyKey) throws -> WorkspaceOperationReceipt? {
        let statement = try prepare(
            """
            SELECT request_fingerprint, fingerprint_version, result_revision
            FROM operation_receipts
            WHERE idempotency_key = ?
            """,
            operation: "read_idempotency_receipt"
        )
        try statement.bind([.text(key.description)], operation: "read_idempotency_receipt")
        guard try statement.step(operation: "read_idempotency_receipt") else { return nil }
        return WorkspaceOperationReceipt(
            fingerprint: try statement.requiredBlob(at: 0, operation: "read_idempotency_receipt"),
            fingerprintVersion: Int(statement.integer(at: 1)),
            resultRevision: WorkspaceRevision(rawValue: statement.integer(at: 2))
        )
    }

    /// Reproduces the schema-1 fingerprint exactly so retries written by a
    /// previous app build remain idempotent after the outbox migration.
    private func legacyFingerprint(
        mutation: WorkspaceMutation,
        expectedRevision: WorkspaceRevision
    ) throws -> Data {
        struct FingerprintEnvelope: Codable {
            var expectedRevision: WorkspaceRevision
            var mutation: WorkspaceMutation
        }
        let input = try codec.encode(
            FingerprintEnvelope(expectedRevision: expectedRevision, mutation: mutation)
        )
        return Data(SHA256.hash(data: input))
    }

    private func receiptExists(operationID: UUID) throws -> Bool {
        let statement = try prepare(
            "SELECT 1 FROM operation_receipts WHERE operation_id = ? LIMIT 1",
            operation: "read_operation_receipt"
        )
        try statement.bind(
            [.text(operationID.uuidString.lowercased())],
            operation: "read_operation_receipt"
        )
        return try statement.step(operation: "read_operation_receipt")
    }

    private func insertReceipt(
        mutation: WorkspaceMutation,
        fingerprint: Data,
        resultRevision: WorkspaceRevision,
        producedChange: Bool
    ) throws {
        try execute(
            """
            INSERT INTO operation_receipts (
                idempotency_key, operation_id, request_fingerprint,
                fingerprint_version, result_revision, produced_change, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .text(mutation.idempotencyKey.description),
                .text(mutation.operationID.uuidString.lowercased()),
                .blob(fingerprint),
                .integer(2),
                .integer(resultRevision.rawValue),
                .integer(producedChange ? 1 : 0),
                .real(mutation.createdAt.timeIntervalSince1970)
            ],
            operation: "insert_idempotency_receipt"
        )
    }

    private func insertOutbox(_ operation: WorkspaceOutboxOperation) throws {
        let changedFields = try codec.encode(operation.changedFields)
        let fieldClocks = try codec.encode(operation.fieldClocks)
        try execute(
            """
            INSERT INTO operation_outbox (
                operation_id, idempotency_key, workspace_id, writer_id,
                base_revision, committed_revision, entity_kind, entity_id,
                changed_fields, field_clocks, payload_format_version, payload,
                created_at, delivery_attempts
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .text(operation.operationID.uuidString.lowercased()),
                .text(operation.idempotencyKey.description),
                .text(operation.workspaceID.uuidString.lowercased()),
                .text(operation.writerID.description),
                .integer(operation.baseRevision.rawValue),
                .integer(operation.committedRevision.rawValue),
                .text(operation.entityKind),
                .text(operation.entityID),
                .blob(changedFields),
                .blob(fieldClocks),
                .integer(Int64(operation.payloadFormatVersion)),
                .blob(operation.payload),
                .real(operation.createdAt.timeIntervalSince1970),
                .integer(Int64(operation.deliveryAttempts))
            ],
            operation: "insert_outbox"
        )
    }

    private static func loadLegacyWorkspace(
        from directoryURL: URL
    ) throws -> LegacyWorkspaceImport? {
        let fileManager = FileManager.default
        let openLoopsURL = directoryURL.appendingPathComponent(WorkspaceProjection.openLoopsFileName)
        let personalizationURL = directoryURL.appendingPathComponent(
            WorkspaceProjection.personalizationFileName
        )
        let openLoopsExists = fileManager.fileExists(atPath: openLoopsURL.path)
        let personalizationExists = fileManager.fileExists(atPath: personalizationURL.path)

        guard openLoopsExists || personalizationExists else { return nil }
        guard openLoopsExists && personalizationExists else {
            throw WorkspaceRepositoryError.incompleteLegacyWorkspace
        }

        let openLoopsData: Data
        let personalizationData: Data
        do {
            openLoopsData = try Data(contentsOf: openLoopsURL, options: [.mappedIfSafe])
        } catch {
            throw WorkspaceRepositoryError.unreadableLegacyWorkspace(component: "Moves")
        }
        do {
            personalizationData = try Data(contentsOf: personalizationURL, options: [.mappedIfSafe])
        } catch {
            throw WorkspaceRepositoryError.unreadableLegacyWorkspace(component: "personalization")
        }

        let codec = WorkspaceJSONCodec()
        let openLoops: OpenLoopsDocument
        let personalization: PersonalizationDocument
        do {
            openLoops = try codec.decoder.decode(OpenLoopsDocument.self, from: openLoopsData)
        } catch {
            throw WorkspaceRepositoryError.unreadableLegacyWorkspace(component: "Moves")
        }
        do {
            personalization = try codec.decoder.decode(
                PersonalizationDocument.self,
                from: personalizationData
            )
        } catch {
            throw WorkspaceRepositoryError.unreadableLegacyWorkspace(component: "personalization")
        }

        let snapshot = try codec.normalized(
            FounderOfficeSnapshot(openLoops: openLoops, personalization: personalization)
        )
        return LegacyWorkspaceImport(
            snapshot: snapshot,
            openLoopsDigest: WorkspaceProjection.digest(openLoopsData),
            personalizationDigest: WorkspaceProjection.digest(personalizationData)
        )
    }

    private func hasUserTables() throws -> Bool {
        let statement = try prepare(
            """
            SELECT 1
            FROM sqlite_master
            WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
            LIMIT 1
            """,
            operation: "inspect_database"
        )
        return try statement.step(operation: "inspect_database")
    }

    private func table(_ tableName: String, hasColumn columnName: String) throws -> Bool {
        guard tableName == "operation_receipts", columnName == "fingerprint_version" else {
            throw WorkspaceRepositoryError.invalidDatabase
        }
        let statement = try prepare(
            "PRAGMA table_info(operation_receipts)",
            operation: "inspect_database"
        )
        while try statement.step(operation: "inspect_database") {
            if try statement.requiredText(at: 1, operation: "inspect_database") == columnName {
                return true
            }
        }
        return false
    }

    private func pragmaInteger(_ name: String) throws -> Int64 {
        let statement = try prepare("PRAGMA \(name)", operation: "inspect_database")
        guard try statement.step(operation: "inspect_database") else {
            throw WorkspaceRepositoryError.invalidDatabase
        }
        return statement.integer(at: 0)
    }

    private func transaction<Result>(_ body: () throws -> Result) throws -> Result {
        try execute("BEGIN IMMEDIATE", operation: "begin_transaction")
        do {
            let result = try body()
            try execute("COMMIT", operation: "commit_transaction")
            return result
        } catch {
            try? execute("ROLLBACK", operation: "rollback_transaction")
            throw error
        }
    }

    private func execute(
        _ sql: String,
        bindings: [SQLiteWorkspaceValue] = [],
        operation: String
    ) throws {
        let statement = try prepare(sql, operation: operation)
        try statement.bind(bindings, operation: operation)
        while true {
            switch sqlite3_step(statement.pointer) {
            case SQLITE_ROW:
                continue
            case SQLITE_DONE:
                return
            default:
                throw databaseError(operation: operation)
            }
        }
    }

    private func prepare(_ sql: String, operation: String) throws -> SQLiteWorkspaceStatement {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw databaseError(operation: operation)
        }
        return SQLiteWorkspaceStatement(database: connection, pointer: statement)
    }

    private func databaseError(operation: String) -> WorkspaceRepositoryError {
        WorkspaceRepositoryError.databaseUnavailable(
            operation: operation,
            code: sqlite3_errcode(connection)
        )
    }
}

private final class SQLiteWorkspaceStatement {
    let database: OpaquePointer
    let pointer: OpaquePointer

    init(database: OpaquePointer, pointer: OpaquePointer) {
        self.database = database
        self.pointer = pointer
    }

    deinit {
        sqlite3_finalize(pointer)
    }

    func bind(_ values: [SQLiteWorkspaceValue], operation: String) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case let .integer(value):
                result = sqlite3_bind_int64(pointer, index, value)
            case let .real(value):
                result = sqlite3_bind_double(pointer, index, value)
            case let .text(value):
                result = value.withCString { cString in
                    sqlite3_bind_text(pointer, index, cString, -1, sqliteTransientDestructor)
                }
            case let .blob(data):
                result = data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(
                        pointer,
                        index,
                        bytes.baseAddress,
                        Int32(bytes.count),
                        sqliteTransientDestructor
                    )
                }
            case .null:
                result = sqlite3_bind_null(pointer, index)
            }
            guard result == SQLITE_OK else {
                throw WorkspaceRepositoryError.databaseUnavailable(
                    operation: operation,
                    code: sqlite3_errcode(database)
                )
            }
        }
    }

    func step(operation: String) throws -> Bool {
        let result = sqlite3_step(pointer)
        switch result {
        case SQLITE_ROW:
            return true
        case SQLITE_DONE:
            return false
        default:
            throw WorkspaceRepositoryError.databaseUnavailable(
                operation: operation,
                code: sqlite3_errcode(database)
            )
        }
    }

    func integer(at index: Int32) -> Int64 {
        sqlite3_column_int64(pointer, index)
    }

    func double(at index: Int32) -> Double {
        sqlite3_column_double(pointer, index)
    }

    func requiredText(at index: Int32, operation: String) throws -> String {
        guard sqlite3_column_type(pointer, index) == SQLITE_TEXT,
              let text = sqlite3_column_text(pointer, index) else {
            throw WorkspaceRepositoryError.databaseUnavailable(
                operation: operation,
                code: Int32(SQLITE_CORRUPT)
            )
        }
        return String(cString: text)
    }

    func optionalText(at index: Int32, operation: String) throws -> String? {
        if sqlite3_column_type(pointer, index) == SQLITE_NULL { return nil }
        return try requiredText(at: index, operation: operation)
    }

    func optionalDate(at index: Int32) -> Date? {
        guard sqlite3_column_type(pointer, index) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: double(at: index))
    }

    func requiredBlob(at index: Int32, operation: String) throws -> Data {
        guard sqlite3_column_type(pointer, index) == SQLITE_BLOB else {
            throw WorkspaceRepositoryError.databaseUnavailable(
                operation: operation,
                code: Int32(SQLITE_CORRUPT)
            )
        }
        let byteCount = Int(sqlite3_column_bytes(pointer, index))
        guard byteCount > 0 else { return Data() }
        guard let bytes = sqlite3_column_blob(pointer, index) else {
            throw WorkspaceRepositoryError.databaseUnavailable(
                operation: operation,
                code: Int32(SQLITE_CORRUPT)
            )
        }
        return Data(bytes: bytes, count: byteCount)
    }
}

private final class WorkspaceJSONCodec {
    let encoder: JSONEncoder
    let decoder: JSONDecoder

    init() {
        encoder = Self.makeEncoder(prettyPrinted: false)
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    static func makeEncoder(prettyPrinted: Bool) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    func encode<Value: Encodable>(_ value: Value) throws -> Data {
        do {
            return try encoder.encode(value)
        } catch {
            throw WorkspaceRepositoryError.invalidMutation(reason: "data could not be encoded")
        }
    }

    func normalized(_ snapshot: FounderOfficeSnapshot) throws -> FounderOfficeSnapshot {
        guard snapshot.openLoops.schemaVersion <= SQLiteWorkspaceDatabase.supportedOpenLoopsSchemaVersion else {
            throw WorkspaceRepositoryError.snapshotSchemaTooNew(
                component: "Moves",
                found: snapshot.openLoops.schemaVersion,
                supported: SQLiteWorkspaceDatabase.supportedOpenLoopsSchemaVersion
            )
        }
        guard snapshot.personalization.schemaVersion <= SQLiteWorkspaceDatabase.supportedPersonalizationSchemaVersion else {
            throw WorkspaceRepositoryError.snapshotSchemaTooNew(
                component: "personalization",
                found: snapshot.personalization.schemaVersion,
                supported: SQLiteWorkspaceDatabase.supportedPersonalizationSchemaVersion
            )
        }
        return FounderOfficeSnapshot(
            openLoops: OpenLoopsMigration.upgradingPlanningSchema(snapshot.openLoops),
            personalization: snapshot.personalization
        )
    }

    /// Returns the exact representation that a subsequent database read will
    /// produce. This avoids exposing sub-second Date values that the existing
    /// ISO-8601 documents intentionally normalize during durable encoding.
    func canonicalized(_ snapshot: FounderOfficeSnapshot) throws -> FounderOfficeSnapshot {
        try canonicalizedWithData(snapshot).snapshot
    }

    /// Canonical content and the exact bytes persisted for it. Keeping these
    /// together avoids re-encoding a 10,000-Move workspace when one entity is
    /// committed to the bounded operation outbox.
    func canonicalizedWithData(
        _ snapshot: FounderOfficeSnapshot
    ) throws -> (snapshot: FounderOfficeSnapshot, data: Data) {
        let normalizedSnapshot = try normalized(snapshot)
        do {
            let data = try encoder.encode(normalizedSnapshot)
            return (
                try decoder.decode(FounderOfficeSnapshot.self, from: data),
                data
            )
        } catch let error as WorkspaceRepositoryError {
            throw error
        } catch {
            throw WorkspaceRepositoryError.invalidMutation(reason: "data could not be encoded")
        }
    }
}

private let sqliteTransientDestructor = unsafeBitCast(
    -1,
    to: sqlite3_destructor_type.self
)
