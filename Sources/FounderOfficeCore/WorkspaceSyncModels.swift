import Foundation

/// Durable, credential-free association between one local database and one
/// authenticated Founder workspace. Tokens remain in platform secure storage.
public struct WorkspaceSyncBinding: Codable, Equatable, Sendable {
    public let accountID: FounderAccountID
    public let workspaceID: WorkspaceID
    public let deviceID: DeviceID
    public let identityProvider: AccountIdentityProvider
    public let boundAt: Date

    public init(
        accountID: FounderAccountID,
        workspaceID: WorkspaceID,
        deviceID: DeviceID,
        identityProvider: AccountIdentityProvider,
        boundAt: Date = Date()
    ) throws {
        guard boundAt.timeIntervalSinceReferenceDate.isFinite else {
            throw WorkspaceSyncRepositoryError.invalidBinding
        }
        self.accountID = accountID
        self.workspaceID = workspaceID
        self.deviceID = deviceID
        self.identityProvider = identityProvider
        self.boundAt = boundAt
    }

    public var session: AuthSession {
        AuthSession(
            accountID: accountID,
            workspaceID: workspaceID,
            deviceID: deviceID,
            identityProvider: identityProvider
        )
    }
}

public enum WorkspaceSyncPhase: String, Codable, Equatable, Sendable {
    case localOnly
    case idle
    case syncing
    case retryScheduled
    case authenticationRequired
    case conflictReviewRequired
    case adapterBlocked
    case contractBlocked
}

/// Redacted durable status. It intentionally contains no customer content,
/// endpoint, token, file path, or server response body.
public struct WorkspaceSyncStatus: Codable, Equatable, Sendable {
    public let phase: WorkspaceSyncPhase
    public let retryAttempt: Int
    public let nextRetryAt: Date?
    public let lastSuccessAt: Date?
    public let failureCode: String?

    public init(
        phase: WorkspaceSyncPhase,
        retryAttempt: Int = 0,
        nextRetryAt: Date? = nil,
        lastSuccessAt: Date? = nil,
        failureCode: String? = nil
    ) throws {
        guard retryAttempt >= 0,
              retryAttempt <= 32,
              nextRetryAt.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true,
              lastSuccessAt.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true,
              failureCode.map({ !$0.isEmpty && $0.utf8.count <= 80 }) ?? true else {
            throw WorkspaceSyncRepositoryError.invalidSyncState
        }
        self.phase = phase
        self.retryAttempt = retryAttempt
        self.nextRetryAt = nextRetryAt
        self.lastSuccessAt = lastSuccessAt
        self.failureCode = failureCode
    }

    public static var localOnly: WorkspaceSyncStatus {
        // Constant values are known valid.
        try! WorkspaceSyncStatus(phase: .localOnly)
    }
}

public struct WorkspacePersistedSyncConflict: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let workspaceID: WorkspaceID
    public let conflict: SyncConflict
    public let recordedAt: Date

    public init(
        id: UUID = UUID(),
        workspaceID: WorkspaceID,
        conflict: SyncConflict,
        recordedAt: Date = Date()
    ) throws {
        guard recordedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw WorkspaceSyncRepositoryError.invalidConflict
        }
        try conflict.validate(for: workspaceID)
        self.id = id
        self.workspaceID = workspaceID
        self.conflict = conflict
        self.recordedAt = recordedAt
    }
}

public struct WorkspacePendingSyncBatch: Sendable {
    public let operations: [WorkspaceOutboxOperation]
    public let requiresCanonicalBootstrap: Bool
    public let totalEncodedByteCount: Int

    public init(
        operations: [WorkspaceOutboxOperation],
        requiresCanonicalBootstrap: Bool,
        totalEncodedByteCount: Int
    ) {
        self.operations = operations
        self.requiresCanonicalBootstrap = requiresCanonicalBootstrap
        self.totalEncodedByteCount = totalEncodedByteCount
    }
}

public struct WorkspaceCanonicalBootstrapPlan: Codable, Equatable, Sendable {
    public let localWorkspaceID: UUID
    public let remoteWorkspaceID: WorkspaceID
    public let localRevision: WorkspaceRevision
    public let snapshotDigest: Data
    public let workspaceName: String
    public let profileDisplayName: String?
    public let operations: [SyncOperation]

    public init(
        localWorkspaceID: UUID,
        remoteWorkspaceID: WorkspaceID,
        localRevision: WorkspaceRevision,
        snapshotDigest: Data,
        workspaceName: String,
        profileDisplayName: String?,
        operations: [SyncOperation]
    ) {
        self.localWorkspaceID = localWorkspaceID
        self.remoteWorkspaceID = remoteWorkspaceID
        self.localRevision = localRevision
        self.snapshotDigest = snapshotDigest
        self.workspaceName = workspaceName
        self.profileDisplayName = profileDisplayName
        self.operations = operations
    }
}

/// Opaque evidence that the repository durably matched one exact local
/// snapshot to one authenticated remote workspace acceptance. Callers cannot
/// manufacture receipts or use a bare local revision to clear the outbox.
public struct WorkspaceCanonicalBootstrapReceipt: Equatable, Sendable {
    public let receiptID: UUID
    public let remoteWorkspaceID: WorkspaceID
    public let acceptedCursor: SyncCursor

    init(receiptID: UUID, remoteWorkspaceID: WorkspaceID, acceptedCursor: SyncCursor) {
        self.receiptID = receiptID
        self.remoteWorkspaceID = remoteWorkspaceID
        self.acceptedCursor = acceptedCursor
    }
}

public struct WorkspaceRemoteOperationAcknowledgement: Sendable {
    public let localOperationID: UUID
    public let entityType: SyncEntityType
    public let entityID: UUID
    public let remoteRevision: Int64
    public let fieldClocks: [String: Date]

    public init(
        localOperationID: UUID,
        entityType: SyncEntityType,
        entityID: UUID,
        remoteRevision: Int64,
        fieldClocks: [String: Date]
    ) throws {
        guard remoteRevision > 0,
              !fieldClocks.isEmpty,
              fieldClocks.values.allSatisfy({ $0.timeIntervalSinceReferenceDate.isFinite }) else {
            throw WorkspaceSyncRepositoryError.invalidRemoteRevision
        }
        self.localOperationID = localOperationID
        self.entityType = entityType
        self.entityID = entityID
        self.remoteRevision = remoteRevision
        self.fieldClocks = fieldClocks
    }
}

public enum WorkspaceSyncRepositoryError: Error, Equatable, Sendable {
    case invalidBinding
    case bindingRequired
    case bindingMismatch
    case identityReplacementRequiresDisposition
    case invalidSyncState
    case invalidConflict
    case invalidRemoteRevision
    case acknowledgementMismatch
    case invalidCursor
    case cursorMismatch
    case bootstrapRevisionChanged
    case bootstrapResponseMismatch
    case unsupportedRemoteEntity
    case remoteRecordCannotBeRepresented
    case assetsDisabled
    case requestBoundsExceeded
}

/// Redacted transport failures shared by the coordinator and concrete HTTPS
/// adapter. No case carries response bodies, request content, tokens, or URLs.
public enum WorkspaceSyncTransportFailure: Error, Equatable, Sendable {
    case invalidConfiguration
    case invalidAccessToken
    case requestTooLarge
    case responseTooLarge
    case redirectRejected
    case unexpectedEndpoint
    case invalidContentType
    case invalidResponse
    case unauthorized
    case forbidden
    case rejected
    case unavailable
    case httpStatus(Int)
    case cancelled
    case network
}

extension WorkspaceSyncTransportFailure: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "Device sync is not configured safely in this build."
        case .invalidAccessToken, .unauthorized:
            return "Sign in again to continue device sync."
        case .forbidden:
            return "This account cannot access the selected workspace."
        case .requestTooLarge, .responseTooLarge:
            return "The sync page exceeded its safety limit."
        case .redirectRejected, .unexpectedEndpoint, .invalidContentType, .invalidResponse:
            return "The sync service returned an invalid response."
        case .rejected:
            return "The sync service rejected this client contract."
        case .unavailable, .network:
            return "Device sync is temporarily unavailable."
        case .httpStatus:
            return "Device sync returned an unexpected status."
        case .cancelled:
            return "Device sync was cancelled."
        }
    }
}

extension WorkspaceSyncRepositoryError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidBinding:
            return "The sync binding is invalid. Local data was not changed."
        case .bindingRequired:
            return "This workspace is local-only until device sync is explicitly enabled."
        case .bindingMismatch:
            return "The account session does not match this local workspace."
        case .identityReplacementRequiresDisposition:
            return "Choose what to do with local data before switching accounts."
        case .invalidSyncState, .invalidConflict, .invalidRemoteRevision,
             .acknowledgementMismatch, .invalidCursor:
            return "The saved sync state is invalid. Device sync stopped safely."
        case .cursorMismatch:
            return "The sync cursor changed before this page could be applied."
        case .bootstrapRevisionChanged:
            return "The workspace changed during initial sync. It will be retried from the new revision."
        case .bootstrapResponseMismatch:
            return "Initial sync did not acknowledge the exact workspace snapshot."
        case .unsupportedRemoteEntity, .remoteRecordCannotBeRepresented:
            return "This version cannot safely apply part of the remote workspace."
        case .assetsDisabled:
            return "Photo sync stays disabled until private export and erasure are verified."
        case .requestBoundsExceeded:
            return "The sync batch exceeds the client safety limit."
        }
    }
}

public protocol WorkspaceSyncRepository: Actor {
    func syncBinding() throws -> WorkspaceSyncBinding?
    func bindSync(_ binding: WorkspaceSyncBinding) throws
    func syncCursor() throws -> SyncCursor
    func syncStatus() throws -> WorkspaceSyncStatus
    func setSyncStatus(_ status: WorkspaceSyncStatus) throws
    func pendingSyncBatch(maximumCount: Int, maximumByteCount: Int) throws -> WorkspacePendingSyncBatch
    func recordDeliveryAttempt(operationIDs: [UUID]) throws
    func remoteRevision(entityType: SyncEntityType, entityID: UUID) throws -> Int64
    func canonicalBootstrapPlan() throws -> WorkspaceCanonicalBootstrapPlan
    func acknowledgeCanonicalBootstrap(
        plan: WorkspaceCanonicalBootstrapPlan,
        bootstrap: WorkspaceBootstrap,
        responses: [SyncPushResponse]
    ) throws -> WorkspaceCanonicalBootstrapReceipt
    func acknowledgeRemoteOperations(
        _ acknowledgements: [WorkspaceRemoteOperationAcknowledgement],
        conflicts: [WorkspacePersistedSyncConflict]
    ) throws
    func applyRemotePage(_ response: SyncPullResponse) throws
    func persistedSyncConflicts(limit: Int) throws -> [WorkspacePersistedSyncConflict]
    func remoteChanges() -> AsyncStream<WorkspaceRepositorySnapshot>
    func changes() -> AsyncStream<WorkspaceChange>
}
