import CryptoKit
import Foundation

public enum WorkspaceV2SyncAdapterError: Error, Equatable, Sendable {
    case unsupportedEntity(String)
    case unsupportedField(entity: String, field: String)
    case missingFieldClock(String)
    case invalidEntityIdentifier
    case invalidValue(String)
    case emptyWireMutation
    case profileRequiresReviewedBootstrap
    case assetTransferDisabled
}

/// Exhaustive bridge from the bounded local-v2 durability shape to the frozen
/// public sync-v1 shape. It never forwards a local payload directly.
public enum WorkspaceV2SyncAdapter {
    private static let ignoredMoveFields: Set<String> = [
        "updatedAt", "priorityUpdatedAt", "dueAtUpdatedAt",
    ]
    private static let ignoredPersonalizationFields: Set<String> = ["updatedAt"]

    public static func adapt(
        operation: WorkspaceOutboxOperation,
        envelope: WorkspaceLocalOperationEnvelopeV2,
        remoteBaseRevision: Int64,
        workspaceID: WorkspaceID
    ) throws -> SyncOperation {
        guard remoteBaseRevision >= 0 else {
            throw WorkspaceV2SyncAdapterError.invalidValue("remoteRevision")
        }
        guard operation.operationID != UUID.zero else {
            throw WorkspaceV2SyncAdapterError.invalidEntityIdentifier
        }
        guard envelope.entityKind.rawValue == operation.entityKind,
              envelope.entityID == operation.entityID,
              envelope.changedFields == operation.changedFields else {
            throw WorkspaceLocalOperationError.invalidMetadata
        }

        let mapped = try mappedMutation(
            envelope: envelope,
            localClocks: operation.fieldClocks,
            workspaceID: workspaceID
        )

        return try SyncOperation(
            operationID: SyncOperationID(rawValue: operation.operationID),
            entityType: mapped.entityType,
            entityID: mapped.entityID,
            action: mapped.action,
            baseRevision: remoteBaseRevision,
            changedFields: mapped.changedFields,
            fieldClocks: mapped.fieldClocks,
            payload: mapped.payload,
            occurredAt: operation.createdAt
        )
    }

    public static func canonicalBootstrapPlan(
        snapshot: WorkspaceRepositorySnapshot,
        remoteWorkspaceID: WorkspaceID
    ) throws -> WorkspaceCanonicalBootstrapPlan {
        if snapshot.content.personalization.visionImageAsset != nil
            || snapshot.content.personalization.resolvedPhotoFileName != nil {
            throw WorkspaceV2SyncAdapterError.assetTransferDisabled
        }

        let workspaceID = remoteWorkspaceID
        var operations: [SyncOperation] = []

        // bootstrap_workspace creates (or returns) the singleton workspace and
        // its authoritative revision. Sending the name again as a base-0
        // operation would conflict with the record that the RPC just created.
        for move in snapshot.content.openLoops.items where move.deletedAt == nil {
            let fields = [
                "title", "details", "status", "previousStatus", "priority", "dueOn",
                "completedAt", "deletedAt", "source", "createdAt",
            ]
            let clock = safeClock(move.updatedAt, fallback: move.createdAt)
            operations.append(
                try bootstrapOperation(
                    workspaceID: workspaceID,
                    localRevision: snapshot.revision,
                    entityType: .move,
                    entityID: move.id,
                    changedFields: fields,
                    payload: movePayload(move, fields: Set(fields)),
                    clock: clock
                )
            )
        }

        let appearance = snapshot.content.personalization.resolvedAppearance
        let appearanceClock = safeClock(
            appearance.updatedAt,
            fallback: snapshot.content.personalization.updatedAt ?? Date(timeIntervalSince1970: 0)
        )
        operations.append(
            try bootstrapOperation(
                workspaceID: workspaceID,
                localRevision: snapshot.revision,
                entityType: .appearance,
                entityID: workspaceID.rawValue,
                changedFields: ["schemaVersion", "preferences"],
                payload: [
                    "schemaVersion": .integer(Int64(snapshot.content.personalization.schemaVersion)),
                    "preferences": .object(try jsonObject(appearance)),
                ],
                clock: appearanceClock
            )
        )

        if let goal = snapshot.content.personalization.primaryGoal,
           goal.deletedAt == nil {
            let fields = [
                "title", "metric", "currentValue", "targetValue", "unit", "dueOn",
                "deletedAt",
            ]
            let clock = safeClock(goal.updatedAt, fallback: goal.createdAt)
            operations.append(
                try bootstrapOperation(
                    workspaceID: workspaceID,
                    localRevision: snapshot.revision,
                    entityType: .primaryGoal,
                    entityID: goal.id,
                    changedFields: fields,
                    payload: primaryGoalPayload(goal, fields: Set(fields)),
                    clock: clock
                )
            )
        }

        for milestone in snapshot.content.personalization.milestones where milestone.deletedAt == nil {
            let fields = ["title", "dueAt", "deletedAt", "createdAt"]
            let clock = safeClock(milestone.updatedAt, fallback: milestone.createdAt)
            operations.append(
                try bootstrapOperation(
                    workspaceID: workspaceID,
                    localRevision: snapshot.revision,
                    entityType: .milestone,
                    entityID: milestone.id,
                    changedFields: fields,
                    payload: milestonePayload(milestone, fields: Set(fields)),
                    clock: clock
                )
            )
        }

        guard operations.count <= 50_000 else {
            throw WorkspaceSyncRepositoryError.requestBoundsExceeded
        }
        let digestEncoder = JSONEncoder()
        digestEncoder.dateEncodingStrategy = .iso8601
        digestEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let snapshotDigest = Data(SHA256.hash(data: try digestEncoder.encode(snapshot.content)))
        let workspaceName = snapshot.content.personalization.workspaceName ?? "Founder's Office"
        guard !workspaceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              workspaceName.utf8.count <= 480 else {
            throw WorkspaceV2SyncAdapterError.invalidValue("workspace.name")
        }
        let profileDisplayName: String?
        do {
            profileDisplayName = try FounderDisplayName.normalize(
                snapshot.content.personalization.preferredName
            )
        } catch {
            throw WorkspaceV2SyncAdapterError.invalidValue("profile.displayName")
        }
        return WorkspaceCanonicalBootstrapPlan(
            localWorkspaceID: snapshot.workspaceID,
            remoteWorkspaceID: workspaceID,
            localRevision: snapshot.revision,
            snapshotDigest: snapshotDigest,
            workspaceName: workspaceName,
            profileDisplayName: profileDisplayName,
            operations: operations
        )
    }

    struct MappedMutation {
        let entityType: SyncEntityType
        let entityID: UUID
        let action: SyncMutationAction
        let changedFields: [String]
        let fieldClocks: [String: Date]
        let payload: [String: SyncJSONValue]?
    }

    static func mappedMutation(
        envelope: WorkspaceLocalOperationEnvelopeV2,
        localClocks: [String: Date],
        workspaceID: WorkspaceID
    ) throws -> MappedMutation {
        switch envelope.record {
        case let .move(move):
            return try mapMove(
                move,
                action: envelope.action,
                localFields: envelope.changedFields,
                localClocks: localClocks
            )
        case let .appearance(appearance):
            return try mapAppearance(
                appearance,
                workspaceID: workspaceID,
                localFields: envelope.changedFields,
                localClocks: localClocks
            )
        case .profile:
            throw WorkspaceV2SyncAdapterError.profileRequiresReviewedBootstrap
        case let .workspace(workspace):
            return try mapWorkspace(
                workspace,
                workspaceID: workspaceID,
                localFields: envelope.changedFields,
                localClocks: localClocks
            )
        case let .primaryGoal(goal):
            return try mapPrimaryGoal(
                goal,
                action: envelope.action,
                localFields: envelope.changedFields,
                localClocks: localClocks
            )
        case let .milestone(milestone):
            return try mapMilestone(
                milestone,
                action: envelope.action,
                localFields: envelope.changedFields,
                localClocks: localClocks
            )
        case .asset:
            throw WorkspaceV2SyncAdapterError.assetTransferDisabled
        }
    }

    private static func mapMove(
        _ move: OpenLoop,
        action: WorkspaceLocalOperationAction,
        localFields: [String],
        localClocks: [String: Date]
    ) throws -> MappedMutation {
        if action == .tombstone {
            let clock = try requiredClock(for: "deletedAt", localClocks: localClocks)
            return MappedMutation(
                entityType: .move,
                entityID: move.id,
                action: .delete,
                changedFields: ["deletedAt"],
                fieldClocks: ["deletedAt": clock],
                payload: nil
            )
        }

        let translations: [String: String] = [
            "title": "title", "details": "details", "status": "status",
            "previousStatus": "previousStatus", "priority": "priority", "dueAt": "dueOn",
            "completedAt": "completedAt", "deletedAt": "deletedAt", "source": "source",
            "createdAt": "createdAt",
        ]
        let mapped = try mappedFields(
            localFields,
            translations: translations,
            ignored: ignoredMoveFields,
            entity: "move",
            localClocks: localClocks
        )
        return MappedMutation(
            entityType: .move,
            entityID: move.id,
            action: .upsert,
            changedFields: mapped.fields,
            fieldClocks: mapped.clocks,
            payload: movePayload(move, fields: Set(mapped.fields))
        )
    }

    private static func mapAppearance(
        _ appearance: AppearancePreferences,
        workspaceID: WorkspaceID,
        localFields: [String],
        localClocks: [String: Date]
    ) throws -> MappedMutation {
        let allowed = Set(["appearance", "accent", "updatedAt"])
        guard Set(localFields).isSubset(of: allowed) else {
            let field = Set(localFields).subtracting(allowed).sorted().first ?? "unknown"
            throw WorkspaceV2SyncAdapterError.unsupportedField(entity: "appearance", field: field)
        }
        let sources = localFields.filter { $0 != "updatedAt" }
        guard !sources.isEmpty else { throw WorkspaceV2SyncAdapterError.emptyWireMutation }
        let clock = try sources.map { try requiredClock(for: $0, localClocks: localClocks) }.max()
            ?? { throw WorkspaceV2SyncAdapterError.missingFieldClock("appearance") }()
        return MappedMutation(
            entityType: .appearance,
            entityID: workspaceID.rawValue,
            action: .upsert,
            changedFields: ["preferences", "schemaVersion"],
            fieldClocks: ["preferences": clock, "schemaVersion": clock],
            payload: [
                "preferences": .object(try jsonObject(appearance)),
                // Appearance schema belongs to Personalization v6 today.
                "schemaVersion": .integer(6),
            ]
        )
    }

    private static func mapWorkspace(
        _ workspace: WorkspaceLocalWorkspaceRecord,
        workspaceID: WorkspaceID,
        localFields: [String],
        localClocks: [String: Date]
    ) throws -> MappedMutation {
        let mapped = try mappedFields(
            localFields,
            translations: ["workspaceName": "name", "name": "name"],
            ignored: ignoredPersonalizationFields,
            entity: "workspace",
            localClocks: localClocks
        )
        guard mapped.fields == ["name"], let name = workspace.name else {
            throw WorkspaceV2SyncAdapterError.invalidValue("workspace.name")
        }
        return MappedMutation(
            entityType: .workspace,
            entityID: workspaceID.rawValue,
            action: .upsert,
            changedFields: mapped.fields,
            fieldClocks: mapped.clocks,
            payload: ["name": .string(name)]
        )
    }

    private static func mapMilestone(
        _ milestone: Milestone,
        action: WorkspaceLocalOperationAction,
        localFields: [String],
        localClocks: [String: Date]
    ) throws -> MappedMutation {
        if action == .tombstone {
            let clock = try requiredClock(for: "deletedAt", localClocks: localClocks)
            return MappedMutation(
                entityType: .milestone,
                entityID: milestone.id,
                action: .delete,
                changedFields: ["deletedAt"],
                fieldClocks: ["deletedAt": clock],
                payload: nil
            )
        }
        let mapped = try mappedFields(
            localFields,
            translations: [
                "title": "title", "dueAt": "dueAt", "deletedAt": "deletedAt",
                "createdAt": "createdAt",
            ],
            ignored: ignoredPersonalizationFields,
            entity: "milestone",
            localClocks: localClocks
        )
        return MappedMutation(
            entityType: .milestone,
            entityID: milestone.id,
            action: .upsert,
            changedFields: mapped.fields,
            fieldClocks: mapped.clocks,
            payload: milestonePayload(milestone, fields: Set(mapped.fields))
        )
    }

    private static func mapPrimaryGoal(
        _ goal: PrimaryGoal,
        action: WorkspaceLocalOperationAction,
        localFields: [String],
        localClocks: [String: Date]
    ) throws -> MappedMutation {
        if action == .tombstone {
            let clock = try requiredClock(for: "deletedAt", localClocks: localClocks)
            return MappedMutation(
                entityType: .primaryGoal,
                entityID: goal.id,
                action: .delete,
                changedFields: ["deletedAt"],
                fieldClocks: ["deletedAt": clock],
                payload: nil
            )
        }
        let mapped = try mappedFields(
            localFields,
            translations: [
                "title": "title", "metric": "metric", "currentValue": "currentValue",
                "targetValue": "targetValue", "unit": "unit", "dueAt": "dueOn",
                "deletedAt": "deletedAt",
            ],
            ignored: ["createdAt", "updatedAt"],
            entity: "primaryGoal",
            localClocks: localClocks
        )
        return MappedMutation(
            entityType: .primaryGoal,
            entityID: goal.id,
            action: .upsert,
            changedFields: mapped.fields,
            fieldClocks: mapped.clocks,
            payload: primaryGoalPayload(goal, fields: Set(mapped.fields))
        )
    }

    private static func mappedFields(
        _ localFields: [String],
        translations: [String: String],
        ignored: Set<String>,
        entity: String,
        localClocks: [String: Date]
    ) throws -> (fields: [String], clocks: [String: Date]) {
        var clocks: [String: Date] = [:]
        for localField in localFields {
            if ignored.contains(localField) { continue }
            guard let remoteField = translations[localField] else {
                throw WorkspaceV2SyncAdapterError.unsupportedField(entity: entity, field: localField)
            }
            let clock = try requiredClock(for: localField, localClocks: localClocks)
            if let existing = clocks[remoteField], existing != clock {
                throw WorkspaceV2SyncAdapterError.invalidValue("duplicate clock mapping")
            }
            clocks[remoteField] = clock
        }
        let fields = clocks.keys.sorted()
        guard !fields.isEmpty else { throw WorkspaceV2SyncAdapterError.emptyWireMutation }
        return (fields, clocks)
    }

    private static func requiredClock(
        for localField: String,
        localClocks: [String: Date]
    ) throws -> Date {
        guard let clock = localClocks[localField],
              clock.timeIntervalSinceReferenceDate.isFinite else {
            throw WorkspaceV2SyncAdapterError.missingFieldClock(localField)
        }
        return clock
    }

    private static func movePayload(
        _ move: OpenLoop,
        fields: Set<String>
    ) -> [String: SyncJSONValue] {
        var values: [String: SyncJSONValue] = [:]
        for field in fields {
            switch field {
            case "title": values[field] = .string(move.title)
            case "details": values[field] = .string(move.details)
            case "status": values[field] = .string(remoteStatus(move.status))
            case "previousStatus": values[field] = move.previousStatus.map { .string(remoteStatus($0)) } ?? .null
            case "priority": values[field] = .string(move.priority.rawValue)
            case "dueOn": values[field] = move.dueAt.map { .string(dateOnly($0)) } ?? .null
            case "completedAt": values[field] = move.completedAt.map { .string(timestamp($0)) } ?? .null
            case "deletedAt": values[field] = move.deletedAt.map { .string(timestamp($0)) } ?? .null
            case "source": values[field] = .string(move.source)
            case "createdAt": values[field] = .string(timestamp(move.createdAt))
            default: break
            }
        }
        return values
    }

    private static func milestonePayload(
        _ milestone: Milestone,
        fields: Set<String>
    ) -> [String: SyncJSONValue] {
        var values: [String: SyncJSONValue] = [:]
        for field in fields {
            switch field {
            case "title": values[field] = .string(milestone.title)
            case "dueAt": values[field] = .string(timestamp(milestone.dueAt))
            case "deletedAt": values[field] = milestone.deletedAt.map { .string(timestamp($0)) } ?? .null
            case "createdAt": values[field] = .string(timestamp(milestone.createdAt))
            default: break
            }
        }
        return values
    }

    private static func primaryGoalPayload(
        _ goal: PrimaryGoal,
        fields: Set<String>
    ) -> [String: SyncJSONValue] {
        var values: [String: SyncJSONValue] = [:]
        for field in fields {
            switch field {
            case "title": values[field] = .string(goal.title)
            case "metric": values[field] = .string(goal.metric)
            case "currentValue":
                values[field] = goal.currentValue.map { .number($0.decimalValue) } ?? .null
            case "targetValue":
                values[field] = goal.targetValue.map { .number($0.decimalValue) } ?? .null
            case "unit": values[field] = .string(goal.unit.rawValue)
            case "dueOn": values[field] = .string(dateOnly(goal.dueAt))
            case "deletedAt":
                values[field] = goal.deletedAt.map { .string(timestamp($0)) } ?? .null
            default: break
            }
        }
        return values
    }

    private static func bootstrapOperation(
        workspaceID: WorkspaceID,
        localRevision: WorkspaceRevision,
        entityType: SyncEntityType,
        entityID: UUID,
        changedFields: [String],
        payload: [String: SyncJSONValue],
        clock: Date
    ) throws -> SyncOperation {
        let operationID = deterministicOperationID(
            workspaceID: workspaceID,
            localRevision: localRevision,
            entityType: entityType,
            entityID: entityID
        )
        return try SyncOperation(
            operationID: SyncOperationID(rawValue: operationID),
            entityType: entityType,
            entityID: entityID,
            action: .upsert,
            baseRevision: 0,
            changedFields: changedFields,
            fieldClocks: Dictionary(uniqueKeysWithValues: changedFields.map { ($0, clock) }),
            payload: payload,
            occurredAt: clock
        )
    }

    private static func deterministicOperationID(
        workspaceID: WorkspaceID,
        localRevision: WorkspaceRevision,
        entityType: SyncEntityType,
        entityID: UUID
    ) -> UUID {
        let input = Data(
            "founders-office-bootstrap-v1:\(workspaceID.rawValue.uuidString.lowercased()):\(localRevision.rawValue):\(entityType.rawValue):\(entityID.uuidString.lowercased())".utf8
        )
        var bytes = Array(SHA256.hash(data: input).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func jsonObject<Value: Encodable>(_ value: Value) throws -> [String: SyncJSONValue] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let data = try encoder.encode(value)
        return try decoder.decode([String: SyncJSONValue].self, from: data)
    }

    private static func safeClock(_ preferred: Date?, fallback: Date) -> Date {
        let value = preferred ?? fallback
        return value.timeIntervalSinceReferenceDate.isFinite
            ? value
            : Date(timeIntervalSince1970: 0)
    }

    private static func remoteStatus(_ status: LoopStatus) -> String {
        status == .waiting ? "blocked" : status.rawValue
    }

    static func localStatus(_ value: String) throws -> LoopStatus {
        if value == "blocked" { return .waiting }
        guard let status = LoopStatus(rawValue: value) else {
            throw WorkspaceV2SyncAdapterError.invalidValue("move.status")
        }
        return status
    }

    static func timestamp(_ date: Date) -> String {
        TimestampFormatter.shared.string(from: date)
    }

    static func parseTimestamp(_ string: String) throws -> Date {
        guard let date = TimestampFormatter.shared.date(from: string),
              date.timeIntervalSinceReferenceDate.isFinite else {
            throw WorkspaceV2SyncAdapterError.invalidValue("timestamp")
        }
        return date
    }

    static func dateOnly(_ date: Date) -> String {
        let day = PlanningDate.day(fromStored: date)
        return String(format: "%04d-%02d-%02d", day.year, day.month, day.day)
    }

    static func parseDateOnly(_ string: String) throws -> Date {
        let pieces = string.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 3,
              let year = Int(pieces[0]), let month = Int(pieces[1]), let day = Int(pieces[2]),
              let planningDay = PlanningDay(year: year, month: month, day: day),
              String(format: "%04d-%02d-%02d", year, month, day) == string else {
            throw WorkspaceV2SyncAdapterError.invalidValue("date")
        }
        return PlanningDate.storedDate(for: planningDay)
    }
}

private extension UUID {
    static let zero = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
}

private final class TimestampFormatter: @unchecked Sendable {
    static let shared = TimestampFormatter()
    private let lock = NSLock()
    private let formatter: ISO8601DateFormatter

    private init() {
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
    }

    func string(from date: Date) -> String {
        lock.withLock { formatter.string(from: date) }
    }

    func date(from string: String) -> Date? {
        lock.withLock {
            formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
        }
    }
}
