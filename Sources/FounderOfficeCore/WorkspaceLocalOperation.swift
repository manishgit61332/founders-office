import Foundation

/// Entity names used by the local SQLite outbox.
///
/// These names are deliberately not the public HTTPS sync contract. A transport
/// adapter must translate them, including `.waiting` to the remote `blocked`
/// status and the local personalization records to their separate remote
/// profile, workspace, Appearance, goal, milestone, and asset entities.
public enum WorkspaceLocalEntityKind: String, Codable, CaseIterable, Sendable {
    case move
    case appearance
    case profile
    case workspace
    case primaryGoal = "primary_goal"
    case milestone
    case asset

    init?(metadataValue: String) {
        switch metadataValue {
        case "move": self = .move
        case "appearance": self = .appearance
        case "profile": self = .profile
        case "workspace": self = .workspace
        case "primary_goal", "primaryGoal": self = .primaryGoal
        case "milestone": self = .milestone
        case "asset": self = .asset
        default: return nil
        }
    }
}

public enum WorkspaceLocalOperationAction: String, Codable, Sendable {
    case upsert
    case tombstone
}

/// The profile-shaped scalar subset of the legacy personalization document.
/// Goals, milestones, Appearance, workspace naming, and assets are intentionally
/// excluded so one local edit cannot recreate whole-personalization amplification.
public struct WorkspaceLocalProfileRecord: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let displayName: String
    public let preferredName: String?
    public let iconStyle: IconStyle?
    public let updatedAt: Date?

    public init(
        schemaVersion: Int,
        displayName: String,
        preferredName: String?,
        iconStyle: IconStyle?,
        updatedAt: Date?
    ) {
        self.schemaVersion = schemaVersion
        self.displayName = displayName
        self.preferredName = preferredName
        self.iconStyle = iconStyle
        self.updatedAt = updatedAt
    }
}

public struct WorkspaceLocalWorkspaceRecord: Codable, Equatable, Sendable {
    public let name: String?
    public let updatedAt: Date?

    public init(name: String?, updatedAt: Date?) {
        self.name = name
        self.updatedAt = updatedAt
    }
}

/// Sync-safe metadata for the selected image. The exact original filename and
/// bytes are never included in an outbox payload.
public struct WorkspaceLocalAssetRecord: Codable, Equatable, Sendable {
    public let id: UUID?
    public let syncFileName: String?
    public let importedAt: Date?
    public let removedAt: Date?

    public init(
        id: UUID?,
        syncFileName: String?,
        importedAt: Date?,
        removedAt: Date?
    ) {
        self.id = id
        self.syncFileName = syncFileName
        self.importedAt = importedAt
        self.removedAt = removedAt
    }
}

/// One typed entity record. The custom discriminator makes decoding fail
/// closed if a future entity type is read by an older client.
public enum WorkspaceLocalEntityRecord: Codable, Sendable {
    case move(OpenLoop)
    case appearance(AppearancePreferences)
    case profile(WorkspaceLocalProfileRecord)
    case workspace(WorkspaceLocalWorkspaceRecord)
    case primaryGoal(PrimaryGoal)
    case milestone(Milestone)
    case asset(WorkspaceLocalAssetRecord)

    private enum CodingKeys: String, CodingKey {
        case type
        case value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(WorkspaceLocalEntityKind.self, forKey: .type)
        switch kind {
        case .move:
            self = .move(try container.decode(OpenLoop.self, forKey: .value))
        case .appearance:
            self = .appearance(try container.decode(AppearancePreferences.self, forKey: .value))
        case .profile:
            self = .profile(try container.decode(WorkspaceLocalProfileRecord.self, forKey: .value))
        case .workspace:
            self = .workspace(try container.decode(WorkspaceLocalWorkspaceRecord.self, forKey: .value))
        case .primaryGoal:
            self = .primaryGoal(try container.decode(PrimaryGoal.self, forKey: .value))
        case .milestone:
            self = .milestone(try container.decode(Milestone.self, forKey: .value))
        case .asset:
            self = .asset(try container.decode(WorkspaceLocalAssetRecord.self, forKey: .value))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .move(value):
            try container.encode(WorkspaceLocalEntityKind.move, forKey: .type)
            try container.encode(value, forKey: .value)
        case let .appearance(value):
            try container.encode(WorkspaceLocalEntityKind.appearance, forKey: .type)
            try container.encode(value, forKey: .value)
        case let .profile(value):
            try container.encode(WorkspaceLocalEntityKind.profile, forKey: .type)
            try container.encode(value, forKey: .value)
        case let .workspace(value):
            try container.encode(WorkspaceLocalEntityKind.workspace, forKey: .type)
            try container.encode(value, forKey: .value)
        case let .primaryGoal(value):
            try container.encode(WorkspaceLocalEntityKind.primaryGoal, forKey: .type)
            try container.encode(value, forKey: .value)
        case let .milestone(value):
            try container.encode(WorkspaceLocalEntityKind.milestone, forKey: .type)
            try container.encode(value, forKey: .value)
        case let .asset(value):
            try container.encode(WorkspaceLocalEntityKind.asset, forKey: .type)
            try container.encode(value, forKey: .value)
        }
    }

    var kind: WorkspaceLocalEntityKind {
        switch self {
        case .move: return .move
        case .appearance: return .appearance
        case .profile: return .profile
        case .workspace: return .workspace
        case .primaryGoal: return .primaryGoal
        case .milestone: return .milestone
        case .asset: return .asset
        }
    }
}

/// Version 2 stores one bounded local entity rather than another copy of the
/// complete workspace snapshot. It remains a local durability format and must
/// be adapted explicitly before network delivery.
public struct WorkspaceLocalOperationEnvelopeV2: Codable, Sendable {
    public static let formatVersion = 2
    public static let maximumEncodedByteCount = 256 * 1_024

    public let formatVersion: Int
    public let action: WorkspaceLocalOperationAction
    public let entityKind: WorkspaceLocalEntityKind
    public let entityID: String
    public let changedFields: [String]
    public let record: WorkspaceLocalEntityRecord

    public init(
        action: WorkspaceLocalOperationAction,
        entityKind: WorkspaceLocalEntityKind,
        entityID: String,
        changedFields: [String],
        record: WorkspaceLocalEntityRecord
    ) throws {
        self.formatVersion = Self.formatVersion
        self.action = action
        self.entityKind = entityKind
        self.entityID = entityID
        self.changedFields = changedFields
        self.record = record
        try WorkspaceLocalOperationValidator.validate(self)
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case action
        case entityKind
        case entityID
        case changedFields
        case record
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        guard formatVersion == Self.formatVersion else {
            throw WorkspaceLocalOperationError.unsupportedFormat(formatVersion)
        }
        let action = try container.decode(WorkspaceLocalOperationAction.self, forKey: .action)
        let entityKind = try container.decode(WorkspaceLocalEntityKind.self, forKey: .entityKind)
        let entityID = try container.decode(String.self, forKey: .entityID)
        let changedFields = try container.decode([String].self, forKey: .changedFields)
        let record = try container.decode(WorkspaceLocalEntityRecord.self, forKey: .record)

        self.formatVersion = formatVersion
        self.action = action
        self.entityKind = entityKind
        self.entityID = entityID
        self.changedFields = changedFields
        self.record = record
        try WorkspaceLocalOperationValidator.validate(self)
    }
}

public enum WorkspaceDecodedOutboxPayload: Sendable {
    /// A pending operation written before format 2. It is deliberately not
    /// exposed as an entity operation: the sync coordinator must bootstrap the
    /// latest canonical workspace, durably acknowledge that bootstrap, and use
    /// the repository's explicit legacy acknowledgement boundary. New
    /// transactions never create this case.
    case requiresBootstrap
    case localEntity(WorkspaceLocalOperationEnvelopeV2)
}

public enum WorkspaceLocalOperationError: Error, Equatable, Sendable {
    case unsupportedFormat(Int)
    case unsupportedEntityKind
    case invalidMetadata
    case missingEntity
    case invalidRecord
    case payloadTooLarge
}

/// Adapter seam between local durability and any separately versioned HTTPS
/// contract. Implementations must perform product-specific mapping; in
/// particular, local `.waiting` means customer-facing Blocked, not a remote
/// status named `waiting`. `changedFields` is authoritative: record values
/// outside that set are context for typed validation and must never overwrite
/// a remote field. Personalization members are split into distinct local
/// profile, workspace, Appearance, goal, milestone, and asset operations.
public protocol WorkspaceLocalOperationTransportAdapter: Sendable {
    associatedtype TransportOperation: Sendable

    func adapt(
        operation: WorkspaceOutboxOperation,
        envelope: WorkspaceLocalOperationEnvelopeV2
    ) throws -> TransportOperation
}

public extension WorkspaceOutboxOperation {
    static let legacySnapshotPayloadFormatVersion = 1
    static let maximumLegacySnapshotPayloadByteCount = 64 * 1_024 * 1_024

    /// Decodes a local payload without assuming it is already a network
    /// operation. Format 1 remains readable only so pending work can be
    /// preserved until an acknowledged canonical bootstrap supersedes it.
    func decodedLocalPayload() throws -> WorkspaceDecodedOutboxPayload {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        switch payloadFormatVersion {
        case Self.legacySnapshotPayloadFormatVersion:
            guard !payload.isEmpty,
                  payload.count <= Self.maximumLegacySnapshotPayloadByteCount,
                  (try? decoder.decode(FounderOfficeSnapshot.self, from: payload)) != nil else {
                throw WorkspaceLocalOperationError.invalidRecord
            }
            return .requiresBootstrap
        case WorkspaceLocalOperationEnvelopeV2.formatVersion:
            guard !payload.isEmpty,
                  payload.count <= WorkspaceLocalOperationEnvelopeV2.maximumEncodedByteCount else {
                throw WorkspaceLocalOperationError.payloadTooLarge
            }
            let envelope: WorkspaceLocalOperationEnvelopeV2
            do {
                envelope = try decoder.decode(WorkspaceLocalOperationEnvelopeV2.self, from: payload)
            } catch let error as WorkspaceLocalOperationError {
                throw error
            } catch {
                throw WorkspaceLocalOperationError.invalidRecord
            }
            guard envelope.entityKind.rawValue == entityKind,
                  envelope.entityID == entityID,
                  envelope.changedFields == changedFields else {
                throw WorkspaceLocalOperationError.invalidMetadata
            }
            return .localEntity(envelope)
        default:
            throw WorkspaceLocalOperationError.unsupportedFormat(payloadFormatVersion)
        }
    }
}

enum WorkspaceLocalOperationBuilder {
    static func makeEnvelope(
        entityKind rawEntityKind: String,
        entityID: String,
        changedFields: [String],
        snapshot: FounderOfficeSnapshot,
        createdAt: Date
    ) throws -> WorkspaceLocalOperationEnvelopeV2 {
        guard let entityKind = WorkspaceLocalEntityKind(metadataValue: rawEntityKind) else {
            throw WorkspaceLocalOperationError.unsupportedEntityKind
        }

        let record: WorkspaceLocalEntityRecord
        let action: WorkspaceLocalOperationAction
        let canonicalEntityID: String
        switch entityKind {
        case .move:
            guard let identifier = UUID(uuidString: entityID) else {
                throw WorkspaceLocalOperationError.invalidMetadata
            }
            let matches = snapshot.openLoops.items.filter { $0.id == identifier }
            guard matches.count == 1, let move = matches.first else {
                throw WorkspaceLocalOperationError.missingEntity
            }
            record = .move(move)
            action = move.deletedAt == nil ? .upsert : .tombstone
            canonicalEntityID = move.id.uuidString.lowercased()

        case .appearance:
            guard entityID == WorkspaceLocalEntityKind.appearance.rawValue else {
                throw WorkspaceLocalOperationError.invalidMetadata
            }
            record = .appearance(snapshot.personalization.resolvedAppearance)
            action = .upsert
            canonicalEntityID = WorkspaceLocalEntityKind.appearance.rawValue

        case .profile:
            guard entityID == WorkspaceLocalEntityKind.profile.rawValue else {
                throw WorkspaceLocalOperationError.invalidMetadata
            }
            let personalization = snapshot.personalization
            record = .profile(
                WorkspaceLocalProfileRecord(
                    schemaVersion: personalization.schemaVersion,
                    displayName: personalization.displayName,
                    preferredName: personalization.preferredName,
                    iconStyle: personalization.iconStyle,
                    updatedAt: personalization.updatedAt
                )
            )
            action = .upsert
            canonicalEntityID = WorkspaceLocalEntityKind.profile.rawValue

        case .workspace:
            guard entityID == WorkspaceLocalEntityKind.workspace.rawValue else {
                throw WorkspaceLocalOperationError.invalidMetadata
            }
            record = .workspace(
                WorkspaceLocalWorkspaceRecord(
                    name: snapshot.personalization.workspaceName,
                    updatedAt: snapshot.personalization.updatedAt
                )
            )
            action = .upsert
            canonicalEntityID = WorkspaceLocalEntityKind.workspace.rawValue

        case .primaryGoal:
            guard let identifier = UUID(uuidString: entityID),
                  let goal = snapshot.personalization.primaryGoal,
                  goal.id == identifier else {
                throw WorkspaceLocalOperationError.missingEntity
            }
            record = .primaryGoal(goal)
            action = goal.deletedAt == nil ? .upsert : .tombstone
            canonicalEntityID = goal.id.uuidString.lowercased()

        case .milestone:
            guard let identifier = UUID(uuidString: entityID) else {
                throw WorkspaceLocalOperationError.invalidMetadata
            }
            let matches = snapshot.personalization.milestones.filter { $0.id == identifier }
            guard matches.count == 1, let milestone = matches.first else {
                throw WorkspaceLocalOperationError.missingEntity
            }
            record = .milestone(milestone)
            action = milestone.deletedAt == nil ? .upsert : .tombstone
            canonicalEntityID = milestone.id.uuidString.lowercased()

        case .asset:
            if let asset = snapshot.personalization.visionImageAsset {
                guard asset.id.uuidString.lowercased() == entityID else {
                    throw WorkspaceLocalOperationError.invalidMetadata
                }
                record = .asset(
                    WorkspaceLocalAssetRecord(
                        id: asset.id,
                        syncFileName: asset.syncFileName,
                        importedAt: asset.importedAt,
                        removedAt: nil
                    )
                )
                action = .upsert
                canonicalEntityID = asset.id.uuidString.lowercased()
            } else {
                let identifier = UUID(uuidString: entityID)
                guard identifier != nil || entityID == "vision-photo" else {
                    throw WorkspaceLocalOperationError.invalidMetadata
                }
                record = .asset(
                    WorkspaceLocalAssetRecord(
                        id: identifier,
                        syncFileName: nil,
                        importedAt: nil,
                        removedAt: createdAt
                    )
                )
                action = .tombstone
                canonicalEntityID = identifier?.uuidString.lowercased() ?? "vision-photo"
            }
        }

        return try WorkspaceLocalOperationEnvelopeV2(
            action: action,
            entityKind: entityKind,
            entityID: canonicalEntityID,
            changedFields: changedFields,
            record: record
        )
    }

    static func encode(_ envelope: WorkspaceLocalOperationEnvelopeV2) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data: Data
        do {
            data = try encoder.encode(envelope)
        } catch {
            throw WorkspaceLocalOperationError.invalidRecord
        }
        guard !data.isEmpty, data.count <= WorkspaceLocalOperationEnvelopeV2.maximumEncodedByteCount else {
            throw WorkspaceLocalOperationError.payloadTooLarge
        }
        return data
    }
}

private enum WorkspaceLocalOperationValidator {
    private static let maximumShortStringBytes = 16 * 1_024
    private static let maximumDetailsBytes = 128 * 1_024

    static func validate(_ envelope: WorkspaceLocalOperationEnvelopeV2) throws {
        guard envelope.formatVersion == WorkspaceLocalOperationEnvelopeV2.formatVersion,
              envelope.record.kind == envelope.entityKind,
              !envelope.entityID.isEmpty,
              envelope.entityID == envelope.entityID.trimmingCharacters(in: .whitespacesAndNewlines),
              validString(envelope.entityID, maximumBytes: 512),
              !envelope.changedFields.isEmpty,
              envelope.changedFields.count <= 64,
              envelope.changedFields == Array(Set(envelope.changedFields)).sorted(),
              envelope.changedFields.allSatisfy(validFieldName) else {
            throw WorkspaceLocalOperationError.invalidMetadata
        }

        let allowedFields: Set<String>
        switch envelope.record {
        case let .move(move):
            guard move.id.uuidString.lowercased() == envelope.entityID.lowercased(),
                  validString(move.title),
                  validString(
                      move.details,
                      maximumBytes: maximumDetailsBytes,
                      permitsMultilineWhitespace: true
                  ),
                  validString(move.source),
                  validDates([
                      move.createdAt, move.updatedAt, move.priorityUpdatedAt,
                      move.dueAtUpdatedAt, move.dueAt, move.completedAt, move.deletedAt
                  ]),
                  envelope.action == (move.deletedAt == nil ? .upsert : .tombstone) else {
                throw WorkspaceLocalOperationError.invalidRecord
            }
            allowedFields = [
                "title", "details", "status", "previousStatus", "priority", "dueAt",
                "createdAt", "updatedAt", "priorityUpdatedAt", "dueAtUpdatedAt",
                "completedAt", "deletedAt", "source"
            ]

        case let .appearance(appearance):
            let accentStops = appearance.accent.stops
            guard envelope.entityID == WorkspaceLocalEntityKind.appearance.rawValue,
                  envelope.action == .upsert,
                  appearance.accent.angleDegrees.isFinite,
                  (0..<360).contains(appearance.accent.angleDegrees),
                  (1...4).contains(accentStops.count),
                  accentStops == appearance.accent.normalizedStops,
                  accentStops.allSatisfy({
                      $0.location.isFinite && (0...1).contains($0.location)
                  }),
                  validIdentifier(appearance.presetID.rawValue),
                  validIdentifier(appearance.displayFontID.rawValue),
                  validIdentifier(appearance.interfaceFontID.rawValue),
                  validIdentifier(appearance.nodeStyleID.rawValue),
                  validIdentifier(appearance.surfaceStyleID.rawValue),
                  validDates([appearance.updatedAt]) else {
                throw WorkspaceLocalOperationError.invalidRecord
            }
            allowedFields = [
                "appearance", "presetID", "accent", "displayFontID", "interfaceFontID",
                "nodeStyleID", "surfaceStyleID", "updatedAt"
            ]

        case let .profile(profile):
            guard envelope.entityID == WorkspaceLocalEntityKind.profile.rawValue,
                  envelope.action == .upsert,
                  profile.schemaVersion >= 1,
                  validString(profile.displayName),
                  validOptionalString(profile.preferredName),
                  validDates([profile.updatedAt]) else {
                throw WorkspaceLocalOperationError.invalidRecord
            }
            allowedFields = ["displayName", "preferredName", "iconStyle", "updatedAt"]

        case let .workspace(workspace):
            guard envelope.entityID == WorkspaceLocalEntityKind.workspace.rawValue,
                  envelope.action == .upsert,
                  validOptionalString(workspace.name),
                  validDates([workspace.updatedAt]) else {
                throw WorkspaceLocalOperationError.invalidRecord
            }
            allowedFields = ["workspaceName", "updatedAt"]

        case let .primaryGoal(goal):
            guard goal.id.uuidString.lowercased() == envelope.entityID.lowercased(),
                  validString(goal.title),
                  validString(goal.metric),
                  goal.currentValue.map(\.isFinite) ?? true,
                  goal.targetValue.map(\.isFinite) ?? true,
                  validDates([goal.createdAt, goal.updatedAt, goal.dueAt, goal.deletedAt]),
                  envelope.action == (goal.deletedAt == nil ? .upsert : .tombstone) else {
                throw WorkspaceLocalOperationError.invalidRecord
            }
            allowedFields = [
                "title", "metric", "currentValue", "targetValue", "unit", "dueAt",
                "createdAt", "updatedAt", "deletedAt"
            ]

        case let .milestone(milestone):
            guard milestone.id.uuidString.lowercased() == envelope.entityID.lowercased(),
                  validString(milestone.title),
                  validDates([
                      milestone.createdAt, milestone.updatedAt, milestone.dueAt, milestone.deletedAt
                  ]),
                  envelope.action == (milestone.deletedAt == nil ? .upsert : .tombstone) else {
                throw WorkspaceLocalOperationError.invalidRecord
            }
            allowedFields = ["title", "dueAt", "createdAt", "updatedAt", "deletedAt"]

        case let .asset(asset):
            guard validOptionalString(asset.syncFileName),
                  validDates([asset.importedAt, asset.removedAt]),
                  (asset.syncFileName == nil || AssetFileName.validated(asset.syncFileName!) != nil),
                  (asset.id == nil || asset.id?.uuidString.lowercased() == envelope.entityID.lowercased()) else {
                throw WorkspaceLocalOperationError.invalidRecord
            }
            switch envelope.action {
            case .upsert:
                guard asset.id != nil, asset.syncFileName != nil,
                      asset.importedAt != nil, asset.removedAt == nil else {
                    throw WorkspaceLocalOperationError.invalidRecord
                }
            case .tombstone:
                guard asset.syncFileName == nil, asset.importedAt == nil,
                      asset.removedAt != nil else {
                    throw WorkspaceLocalOperationError.invalidRecord
                }
            }
            allowedFields = ["photoFileName", "visionImageAsset", "updatedAt"]
        }

        guard Set(envelope.changedFields).isSubset(of: allowedFields) else {
            throw WorkspaceLocalOperationError.invalidMetadata
        }
    }

    private static func validFieldName(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 128
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && validString(value, maximumBytes: 128)
    }

    private static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && validString(value, maximumBytes: 512)
    }

    private static func validString(
        _ value: String,
        maximumBytes: Int = maximumShortStringBytes,
        permitsMultilineWhitespace: Bool = false
    ) -> Bool {
        value.utf8.count <= maximumBytes
            && value.unicodeScalars.allSatisfy { scalar in
                let codePoint = scalar.value
                if permitsMultilineWhitespace,
                   codePoint == 0x0A || codePoint == 0x0D || codePoint == 0x09 {
                    return true
                }
                switch codePoint {
                case 0...0x1F, 0x7F...0x9F,
                     0x202A...0x202E, 0x2066...0x2069:
                    return false
                default:
                    // Preserve legitimate format scalars such as the zero-width
                    // joiner used by emoji and several writing systems.
                    return true
                }
            }
    }

    private static func validOptionalString(_ value: String?) -> Bool {
        value.map { validString($0) } ?? true
    }

    private static func validDates(_ dates: [Date?]) -> Bool {
        dates.allSatisfy { $0?.timeIntervalSinceReferenceDate.isFinite ?? true }
    }
}
