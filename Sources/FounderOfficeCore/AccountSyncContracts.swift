import Foundation

/// Strong UUID wrappers prevent product accounts, workspaces, devices, and
/// optional connector accounts from being used interchangeably.
public protocol FounderOfficeUUIDIdentifier: Codable, Hashable, Sendable {
    var rawValue: UUID { get }
    init(rawValue: UUID)
}

public extension FounderOfficeUUIDIdentifier {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(rawValue: try container.decode(UUID.self))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct FounderAccountID: FounderOfficeUUIDIdentifier {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

public struct WorkspaceID: FounderOfficeUUIDIdentifier {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

public struct DeviceID: FounderOfficeUUIDIdentifier {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

public struct SyncOperationID: FounderOfficeUUIDIdentifier {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

public struct ActivityEventID: FounderOfficeUUIDIdentifier {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

/// Connector accounts are separately authorized resources. They are never a
/// Founder account, an authentication session, or a workspace tenancy key.
public struct ConnectorAccountID: FounderOfficeUUIDIdentifier {
    public let rawValue: UUID
    public init(rawValue: UUID) { self.rawValue = rawValue }
}

public enum ProductIdentityProvider: String, Codable, CaseIterable, Sendable {
    case google
    case apple
}

/// Opaque identifiers associated with an already authenticated Supabase
/// session. Tokens and refresh credentials intentionally do not belong here.
public struct AuthSession: Codable, Equatable, Sendable {
    public var accountID: FounderAccountID
    public var workspaceID: WorkspaceID
    public var deviceID: DeviceID
    public var identityProvider: ProductIdentityProvider

    public init(
        accountID: FounderAccountID,
        workspaceID: WorkspaceID,
        deviceID: DeviceID,
        identityProvider: ProductIdentityProvider
    ) {
        self.accountID = accountID
        self.workspaceID = workspaceID
        self.deviceID = deviceID
        self.identityProvider = identityProvider
    }

    enum CodingKeys: String, CodingKey {
        case accountID = "accountId"
        case workspaceID = "workspaceId"
        case deviceID = "deviceId"
        case identityProvider
    }
}

public struct FounderProfile: Codable, Equatable, Sendable {
    public var accountID: FounderAccountID
    public var identityProvider: ProductIdentityProvider
    public var displayName: String?

    public init(
        accountID: FounderAccountID,
        identityProvider: ProductIdentityProvider,
        displayName: String?
    ) {
        self.accountID = accountID
        self.identityProvider = identityProvider
        self.displayName = displayName
    }

    enum CodingKeys: String, CodingKey {
        case accountID = "accountId"
        case identityProvider
        case displayName
    }
}

public struct SyncCursor: Codable, Comparable, Hashable, Sendable {
    public let value: Int64

    public init(value: Int64) throws {
        guard value >= 0 else { throw SyncContractValidationError.negativeCursor }
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(value: container.decode(Int64.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.value < rhs.value
    }
}

public enum SyncEntityType: String, Codable, CaseIterable, Sendable {
    case workspace
    case move
    case appearance
    case primaryGoal
    case asset
}

public enum SyncMutationAction: String, Codable, Sendable {
    case upsert
    case delete
}

/// A language-neutral JSON value that preserves signed 64-bit integer tokens
/// without coercing them through binary floating-point.
public indirect enum SyncJSONValue: Codable, Equatable, Sendable {
    case object([String: SyncJSONValue])
    case array([SyncJSONValue])
    case string(String)
    case integer(Int64)
    case number(Double)
    case bool(Bool)
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: SyncJSONValue].self) {
            self = .object(value)
        } else if let value = try? container.decode([SyncJSONValue].self) {
            self = .array(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .integer(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

public enum SyncContractValidationError: Error, Equatable, Sendable {
    case unsupportedVersion
    case negativeRevision
    case negativeCursor
    case invalidChangedFields
    case fieldClockMismatch
    case payloadMismatch
    case futureClockSkew
}

public struct SyncOperation: Codable, Equatable, Sendable {
    public static let contractVersion = 1
    public static let maximumFutureClockSkew: TimeInterval = 5 * 60

    public var contractVersion: Int
    public var operationID: SyncOperationID
    public var entityType: SyncEntityType
    public var entityID: UUID
    public var action: SyncMutationAction
    public var baseRevision: Int64
    public var changedFields: [String]
    public var fieldClocks: [String: Date]
    public var payload: [String: SyncJSONValue]?
    public var occurredAt: Date

    public init(
        operationID: SyncOperationID,
        entityType: SyncEntityType,
        entityID: UUID,
        action: SyncMutationAction,
        baseRevision: Int64,
        changedFields: [String],
        fieldClocks: [String: Date],
        payload: [String: SyncJSONValue]?,
        occurredAt: Date,
        contractVersion: Int = SyncOperation.contractVersion
    ) throws {
        self.contractVersion = contractVersion
        self.operationID = operationID
        self.entityType = entityType
        self.entityID = entityID
        self.action = action
        self.baseRevision = baseRevision
        self.changedFields = changedFields
        self.fieldClocks = fieldClocks
        self.payload = payload
        self.occurredAt = occurredAt
        try validate()
    }

    public func validate() throws {
        guard contractVersion == Self.contractVersion else {
            throw SyncContractValidationError.unsupportedVersion
        }
        guard baseRevision >= 0 else {
            throw SyncContractValidationError.negativeRevision
        }
        guard (1...32).contains(changedFields.count),
              Set(changedFields).count == changedFields.count,
              changedFields.allSatisfy(Self.isValidFieldName) else {
            throw SyncContractValidationError.invalidChangedFields
        }
        guard Set(fieldClocks.keys) == Set(changedFields) else {
            throw SyncContractValidationError.fieldClockMismatch
        }

        switch action {
        case .upsert:
            guard let payload, Set(payload.keys) == Set(changedFields) else {
                throw SyncContractValidationError.payloadMismatch
            }
        case .delete:
            guard changedFields == ["deletedAt"], payload == nil else {
                throw SyncContractValidationError.payloadMismatch
            }
        }
    }

    public func validateClockSkew(relativeTo now: Date) throws {
        let latestAllowed = now.addingTimeInterval(Self.maximumFutureClockSkew)
        guard now.timeIntervalSinceReferenceDate.isFinite,
              occurredAt.timeIntervalSinceReferenceDate.isFinite,
              occurredAt <= latestAllowed,
              fieldClocks.values.allSatisfy({
                  $0.timeIntervalSinceReferenceDate.isFinite && $0 <= latestAllowed
              }) else {
            throw SyncContractValidationError.futureClockSkew
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            operationID: container.decode(SyncOperationID.self, forKey: .operationID),
            entityType: container.decode(SyncEntityType.self, forKey: .entityType),
            entityID: container.decode(UUID.self, forKey: .entityID),
            action: container.decode(SyncMutationAction.self, forKey: .action),
            baseRevision: container.decode(Int64.self, forKey: .baseRevision),
            changedFields: container.decode([String].self, forKey: .changedFields),
            fieldClocks: container.decode([String: Date].self, forKey: .fieldClocks),
            payload: container.decodeIfPresent(
                [String: SyncJSONValue].self,
                forKey: .payload
            ),
            occurredAt: container.decode(Date.self, forKey: .occurredAt),
            contractVersion: container.decode(Int.self, forKey: .contractVersion)
        )
    }

    private static func isValidFieldName(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...64).contains(bytes.count), let first = bytes.first,
              (65...90).contains(first) || (97...122).contains(first) else { return false }
        return bytes.dropFirst().allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        }
    }

    enum CodingKeys: String, CodingKey {
        case contractVersion
        case operationID = "operationId"
        case entityType
        case entityID = "entityId"
        case action
        case baseRevision
        case changedFields
        case fieldClocks
        case payload
        case occurredAt
    }
}

public enum SyncConflictReason: String, Codable, Sendable {
    case revisionMismatch
    case overlappingChanges
    case fieldClockLost
    case missingRecord
}

public struct SyncConflict: Codable, Equatable, Sendable {
    public var operationID: SyncOperationID
    public var entityType: SyncEntityType
    public var entityID: UUID
    public var baseRevision: Int64
    public var currentRevision: Int64
    public var reason: SyncConflictReason
    public var serverRecord: [String: SyncJSONValue]?

    public init(
        operationID: SyncOperationID,
        entityType: SyncEntityType,
        entityID: UUID,
        baseRevision: Int64,
        currentRevision: Int64,
        reason: SyncConflictReason,
        serverRecord: [String: SyncJSONValue]?
    ) {
        self.operationID = operationID
        self.entityType = entityType
        self.entityID = entityID
        self.baseRevision = baseRevision
        self.currentRevision = currentRevision
        self.reason = reason
        self.serverRecord = serverRecord
    }

    enum CodingKeys: String, CodingKey {
        case operationID = "operationId"
        case entityType
        case entityID = "entityId"
        case baseRevision
        case currentRevision
        case reason
        case serverRecord
    }
}

public enum SyncOperationStatus: String, Codable, Sendable {
    case accepted
    case duplicate
    case conflict
}

public struct SyncOperationResult: Codable, Equatable, Sendable {
    public var operationID: SyncOperationID
    public var status: SyncOperationStatus
    public var revision: Int64?
    public var cursor: SyncCursor?
    public var conflict: SyncConflict?

    enum CodingKeys: String, CodingKey {
        case operationID = "operationId"
        case status
        case revision
        case cursor
        case conflict
    }
}

public struct SyncChange: Codable, Equatable, Sendable {
    public var cursor: SyncCursor
    public var operationID: SyncOperationID
    public var entityType: SyncEntityType
    public var entityID: UUID
    public var action: SyncMutationAction
    public var revision: Int64
    public var changedFields: [String]
    public var changedAt: Date
    public var record: [String: SyncJSONValue]?

    enum CodingKeys: String, CodingKey {
        case cursor
        case operationID = "operationId"
        case entityType
        case entityID = "entityId"
        case action
        case revision
        case changedFields
        case changedAt
        case record
    }
}

public struct ActivityEvent: Codable, Equatable, Identifiable, Sendable {
    public var id: ActivityEventID
    public var workspaceID: WorkspaceID
    public var accountID: FounderAccountID
    public var deviceID: DeviceID?
    public var kind: String
    public var entityType: SyncEntityType?
    public var entityID: UUID?
    public var occurredAt: Date
    public var metadata: [String: SyncJSONValue]

    public init(
        id: ActivityEventID,
        workspaceID: WorkspaceID,
        accountID: FounderAccountID,
        deviceID: DeviceID?,
        kind: String,
        entityType: SyncEntityType?,
        entityID: UUID?,
        occurredAt: Date,
        metadata: [String: SyncJSONValue]
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.accountID = accountID
        self.deviceID = deviceID
        self.kind = kind
        self.entityType = entityType
        self.entityID = entityID
        self.occurredAt = occurredAt
        self.metadata = metadata
    }

    enum CodingKeys: String, CodingKey {
        case id
        case workspaceID = "workspaceId"
        case accountID = "accountId"
        case deviceID = "deviceId"
        case kind
        case entityType
        case entityID = "entityId"
        case occurredAt
        case metadata
    }
}

public struct WorkspaceBootstrap: Codable, Equatable, Sendable {
    public var contractVersion: Int
    public var session: AuthSession
    public var profile: FounderProfile
    public var workspace: [String: SyncJSONValue]
    public var latestCursor: SyncCursor
}

public struct SyncPushResponse: Codable, Equatable, Sendable {
    public var contractVersion: Int
    public var workspaceID: WorkspaceID
    public var latestCursor: SyncCursor
    public var results: [SyncOperationResult]

    enum CodingKeys: String, CodingKey {
        case contractVersion
        case workspaceID = "workspaceId"
        case latestCursor
        case results
    }
}

public struct SyncPullResponse: Codable, Equatable, Sendable {
    public var contractVersion: Int
    public var workspaceID: WorkspaceID
    public var fromCursor: SyncCursor
    public var nextCursor: SyncCursor
    public var latestCursor: SyncCursor
    public var hasMore: Bool
    public var changes: [SyncChange]

    enum CodingKeys: String, CodingKey {
        case contractVersion
        case workspaceID = "workspaceId"
        case fromCursor
        case nextCursor
        case latestCursor
        case hasMore
        case changes
    }
}

public struct WorkspaceExport: Codable, Equatable, Sendable {
    public var contractVersion: Int
    public var exportedAt: Date
    public var workspace: [String: SyncJSONValue]
    public var moves: [[String: SyncJSONValue]]
    public var appearance: [[String: SyncJSONValue]]
    public var primaryGoals: [[String: SyncJSONValue]]
    public var assets: [[String: SyncJSONValue]]
    public var activityEvents: [ActivityEvent]
}

public struct WorkspaceEraseReceipt: Codable, Equatable, Sendable {
    public var contractVersion: Int
    public var workspaceID: WorkspaceID
    public var erasedAt: Date

    enum CodingKeys: String, CodingKey {
        case contractVersion
        case workspaceID = "workspaceId"
        case erasedAt
    }
}

/// Session restoration is an adapter boundary. Implementations may use
/// Supabase Auth, but this core module neither stores credentials nor performs
/// network calls.
public protocol AuthSessionProviding: Sendable {
    func currentSession() async throws -> AuthSession?
}

/// Credential-free transport boundary matching the v1 RPC names. Concrete
/// HTTPS/Supabase adapters belong in a separately configured target.
public protocol WorkspaceSyncTransport: Sendable {
    func bootstrapWorkspace(
        deviceID: DeviceID,
        localWorkspaceID: WorkspaceID?,
        workspaceName: String,
        displayName: String?
    ) async throws -> WorkspaceBootstrap

    func pushOperations(
        session: AuthSession,
        operations: [SyncOperation]
    ) async throws -> SyncPushResponse

    func pullChanges(
        session: AuthSession,
        after cursor: SyncCursor,
        limit: Int
    ) async throws -> SyncPullResponse

    func exportWorkspace(session: AuthSession) async throws -> WorkspaceExport

    func eraseWorkspace(
        session: AuthSession,
        confirming workspaceID: WorkspaceID
    ) async throws -> WorkspaceEraseReceipt
}

public protocol ActivityEventReading: Sendable {
    func activityEvents(workspaceID: WorkspaceID) async throws -> [ActivityEvent]
}
