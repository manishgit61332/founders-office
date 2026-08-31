import Foundation

public struct WorkspaceRevision: RawRepresentable, Codable, Hashable, Comparable, Sendable {
    public let rawValue: Int64

    public init(rawValue: Int64) {
        self.rawValue = rawValue
    }

    public static let initial = WorkspaceRevision(rawValue: 0)

    public static func < (lhs: WorkspaceRevision, rhs: WorkspaceRevision) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct WorkspaceWriterID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        self.init(rawValue: UUID())
    }

    public var description: String { rawValue.uuidString.lowercased() }
}

public struct WorkspaceIdempotencyKey: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        self.init(rawValue: UUID())
    }

    public var description: String { rawValue.uuidString.lowercased() }
}

/// An optimistic replacement of one logical entity inside a workspace snapshot.
///
/// The replacement snapshot keeps this first repository slice compatible with
/// the existing JSON models. `entityKind`, `entityID`, `changedFields`, and
/// `fieldClocks` are durable sync preparation metadata; they are not the shared
/// HTTPS contract.
public struct WorkspaceMutation: Codable, Sendable {
    public var operationID: UUID
    public var idempotencyKey: WorkspaceIdempotencyKey
    public var entityKind: String
    public var entityID: String
    public var changedFields: [String]
    public var fieldClocks: [String: Date]
    public var replacement: FounderOfficeSnapshot
    public var createdAt: Date

    public init(
        operationID: UUID = UUID(),
        idempotencyKey: WorkspaceIdempotencyKey = WorkspaceIdempotencyKey(),
        entityKind: String,
        entityID: String,
        changedFields: [String],
        fieldClocks: [String: Date],
        replacement: FounderOfficeSnapshot,
        createdAt: Date = Date()
    ) {
        self.operationID = operationID
        self.idempotencyKey = idempotencyKey
        self.entityKind = entityKind
        self.entityID = entityID
        self.changedFields = changedFields
        self.fieldClocks = fieldClocks
        self.replacement = replacement
        self.createdAt = createdAt
    }
}

public struct WorkspaceRepositorySnapshot: Sendable {
    public var workspaceID: UUID
    public var writerID: WorkspaceWriterID
    public var revision: WorkspaceRevision
    public var content: FounderOfficeSnapshot

    public init(
        workspaceID: UUID,
        writerID: WorkspaceWriterID,
        revision: WorkspaceRevision,
        content: FounderOfficeSnapshot
    ) {
        self.workspaceID = workspaceID
        self.writerID = writerID
        self.revision = revision
        self.content = content
    }
}

public struct WorkspaceOutboxOperation: Codable, Sendable {
    public static let currentPayloadFormatVersion = 1

    public var operationID: UUID
    public var idempotencyKey: WorkspaceIdempotencyKey
    public var workspaceID: UUID
    public var writerID: WorkspaceWriterID
    public var baseRevision: WorkspaceRevision
    public var committedRevision: WorkspaceRevision
    public var entityKind: String
    public var entityID: String
    public var changedFields: [String]
    public var fieldClocks: [String: Date]
    public var payloadFormatVersion: Int
    public var payload: Data
    public var createdAt: Date
    public var deliveryAttempts: Int

    public init(
        operationID: UUID,
        idempotencyKey: WorkspaceIdempotencyKey,
        workspaceID: UUID,
        writerID: WorkspaceWriterID,
        baseRevision: WorkspaceRevision,
        committedRevision: WorkspaceRevision,
        entityKind: String,
        entityID: String,
        changedFields: [String],
        fieldClocks: [String: Date],
        payloadFormatVersion: Int = WorkspaceOutboxOperation.currentPayloadFormatVersion,
        payload: Data,
        createdAt: Date,
        deliveryAttempts: Int = 0
    ) {
        self.operationID = operationID
        self.idempotencyKey = idempotencyKey
        self.workspaceID = workspaceID
        self.writerID = writerID
        self.baseRevision = baseRevision
        self.committedRevision = committedRevision
        self.entityKind = entityKind
        self.entityID = entityID
        self.changedFields = changedFields
        self.fieldClocks = fieldClocks
        self.payloadFormatVersion = payloadFormatVersion
        self.payload = payload
        self.createdAt = createdAt
        self.deliveryAttempts = deliveryAttempts
    }
}

public struct WorkspaceChange: Sendable {
    public var snapshot: WorkspaceRepositorySnapshot
    public var operation: WorkspaceOutboxOperation

    public init(snapshot: WorkspaceRepositorySnapshot, operation: WorkspaceOutboxOperation) {
        self.snapshot = snapshot
        self.operation = operation
    }
}

public enum WorkspaceTransactionResult: Sendable {
    case committed(WorkspaceChange)
    case unchanged(WorkspaceRepositorySnapshot)
    case replayed(snapshot: WorkspaceRepositorySnapshot, committedRevision: WorkspaceRevision)

    public var snapshot: WorkspaceRepositorySnapshot {
        switch self {
        case let .committed(change):
            return change.snapshot
        case let .unchanged(snapshot):
            return snapshot
        case let .replayed(snapshot, _):
            return snapshot
        }
    }
}

public enum WorkspaceRepositoryError: Error, Equatable, Sendable {
    case databaseUnavailable(operation: String, code: Int32)
    case invalidDatabase
    case schemaTooNew(found: Int, supported: Int)
    case snapshotSchemaTooNew(component: String, found: Int, supported: Int)
    case workspaceMismatch
    case writerMismatch
    case missingBootstrapSnapshot
    case incompleteLegacyWorkspace
    case unreadableLegacyWorkspace(component: String)
    case invalidMutation(reason: String)
    case revisionConflict(expected: WorkspaceRevision, actual: WorkspaceRevision)
    case idempotencyKeyReused
    case operationIDReused
    case exportDestinationExists
    case exportFailed(operation: String)
}

extension WorkspaceRepositoryError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .databaseUnavailable:
            return "The workspace database is unavailable. Try again or open Health for recovery options."
        case .invalidDatabase:
            return "This file is not a Founder’s Office workspace database."
        case let .schemaTooNew(found, supported):
            return "This workspace needs a newer Founder’s Office version (schema \(found); supported \(supported))."
        case let .snapshotSchemaTooNew(component, found, supported):
            return "The \(component) data needs a newer Founder’s Office version (schema \(found); supported \(supported))."
        case .workspaceMismatch:
            return "The database belongs to a different workspace."
        case .writerMismatch:
            return "The database belongs to a different device writer."
        case .missingBootstrapSnapshot:
            return "No complete workspace was available to initialize the database."
        case .incompleteLegacyWorkspace:
            return "The legacy workspace is incomplete and was left unchanged for recovery."
        case .unreadableLegacyWorkspace:
            return "The legacy workspace could not be verified and was left unchanged for recovery."
        case let .invalidMutation(reason):
            return "The workspace change is invalid: \(reason)"
        case let .revisionConflict(expected, actual):
            return "The workspace changed while editing (expected revision \(expected.rawValue), current \(actual.rawValue))."
        case .idempotencyKeyReused:
            return "That retry key was already used for a different workspace change."
        case .operationIDReused:
            return "That operation identifier was already used for a different workspace change."
        case .exportDestinationExists:
            return "Choose a new folder for this export; existing exports are never overwritten."
        case .exportFailed:
            return "The workspace export could not be completed."
        }
    }
}

public struct WorkspaceRepositoryConfiguration: Sendable {
    public var databaseURL: URL
    public var workspaceID: UUID
    public var requestedWriterID: WorkspaceWriterID?
    public var legacyDirectoryURL: URL?
    public var initialSnapshot: FounderOfficeSnapshot?

    public init(
        databaseURL: URL,
        workspaceID: UUID,
        requestedWriterID: WorkspaceWriterID? = nil,
        legacyDirectoryURL: URL? = nil,
        initialSnapshot: FounderOfficeSnapshot? = nil
    ) {
        self.databaseURL = databaseURL
        self.workspaceID = workspaceID
        self.requestedWriterID = requestedWriterID
        self.legacyDirectoryURL = legacyDirectoryURL
        self.initialSnapshot = initialSnapshot
    }
}

public protocol WorkspaceRepository: Actor {
    func snapshot() throws -> WorkspaceRepositorySnapshot

    func transact(
        expectedRevision: WorkspaceRevision,
        mutation: WorkspaceMutation
    ) throws -> WorkspaceTransactionResult

    func changes() -> AsyncStream<WorkspaceChange>
}
