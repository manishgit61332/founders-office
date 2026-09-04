import Foundation

enum WorkspaceRemoteChangeApplicator {
    static func apply(
        _ changes: [SyncChange],
        to source: FounderOfficeSnapshot,
        preservingLocalFields: [SyncOperationID: Set<String>] = [:]
    ) throws -> FounderOfficeSnapshot {
        var snapshot = source
        for change in changes {
            let preservedFields = preservingLocalFields[change.operationID] ?? []
            switch change.entityType {
            case .workspace:
                try applyWorkspace(change, preserving: preservedFields, to: &snapshot)
            case .move:
                try applyMove(change, preserving: preservedFields, to: &snapshot)
            case .appearance:
                try applyAppearance(change, preserving: preservedFields, to: &snapshot)
            case .primaryGoal:
                try applyPrimaryGoal(change, preserving: preservedFields, to: &snapshot)
            case .milestone:
                try applyMilestone(change, preserving: preservedFields, to: &snapshot)
            case .asset:
                throw WorkspaceSyncRepositoryError.assetsDisabled
            }
        }
        return snapshot
    }

    private static func applyWorkspace(
        _ change: SyncChange,
        preserving preservedFields: Set<String>,
        to snapshot: inout FounderOfficeSnapshot
    ) throws {
        guard change.action == .upsert else {
            throw WorkspaceSyncRepositoryError.unsupportedRemoteEntity
        }
        if change.changedFields.contains("name"), !preservedFields.contains("name") {
            snapshot.personalization.workspaceName = try requiredString("name", in: change.record)
        }
        snapshot.personalization.updatedAt = latest(
            snapshot.personalization.updatedAt,
            try timestamp("updatedAt", in: change.record)
        )
    }

    private static func applyMove(
        _ change: SyncChange,
        preserving preservedFields: Set<String>,
        to snapshot: inout FounderOfficeSnapshot
    ) throws {
        let record = change.record
        let existingIndex = snapshot.openLoops.items.firstIndex { $0.id == change.entityID }
        var move: OpenLoop
        if let existingIndex {
            move = snapshot.openLoops.items[existingIndex]
        } else {
            move = OpenLoop(
                id: change.entityID,
                title: try requiredString("title", in: record),
                details: try requiredString("details", in: record),
                status: try WorkspaceV2SyncAdapter.localStatus(requiredString("status", in: record)),
                previousStatus: try optionalString("previousStatus", in: record).map(WorkspaceV2SyncAdapter.localStatus),
                priority: try priority(record),
                dueAt: try optionalDateOnly("dueOn", in: record),
                createdAt: try timestamp("createdAt", in: record),
                updatedAt: try timestamp("updatedAt", in: record),
                completedAt: try optionalTimestamp("completedAt", in: record),
                deletedAt: try optionalTimestamp("deletedAt", in: record),
                source: try requiredString("source", in: record)
            )
        }

        for field in change.changedFields where !preservedFields.contains(field) {
            switch field {
            case "title": move.title = try requiredString(field, in: record)
            case "details": move.details = try requiredString(field, in: record)
            case "status": move.status = try WorkspaceV2SyncAdapter.localStatus(requiredString(field, in: record))
            case "previousStatus":
                move.previousStatus = try optionalString(field, in: record).map(WorkspaceV2SyncAdapter.localStatus)
            case "priority":
                move.priority = try priority(record)
                move.priorityUpdatedAt = try fieldClock(field, in: record)
            case "dueOn":
                move.dueAt = try optionalDateOnly(field, in: record)
                move.dueAtUpdatedAt = try fieldClock(field, in: record)
            case "completedAt": move.completedAt = try optionalTimestamp(field, in: record)
            case "deletedAt": move.deletedAt = try optionalTimestamp(field, in: record)
            case "source": move.source = try requiredString(field, in: record)
            case "createdAt": move.createdAt = try timestamp(field, in: record)
            default: throw WorkspaceSyncRepositoryError.unsupportedRemoteEntity
            }
        }
        move.updatedAt = latest(move.updatedAt, try timestamp("updatedAt", in: record))

        if let existingIndex {
            snapshot.openLoops.items[existingIndex] = move
        } else {
            snapshot.openLoops.items.append(move)
        }
        snapshot.openLoops.updatedAt = latest(snapshot.openLoops.updatedAt, change.changedAt)
    }

    private static func applyAppearance(
        _ change: SyncChange,
        preserving preservedFields: Set<String>,
        to snapshot: inout FounderOfficeSnapshot
    ) throws {
        guard change.action == .upsert else {
            throw WorkspaceSyncRepositoryError.unsupportedRemoteEntity
        }
        if change.changedFields.contains("preferences"), !preservedFields.contains("preferences") {
            guard case let .object(object)? = change.record["preferences"] else {
                throw WorkspaceSyncRepositoryError.remoteRecordCannotBeRepresented
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let appearance: AppearancePreferences
            do {
                appearance = try decoder.decode(AppearancePreferences.self, from: encoder.encode(object))
            } catch {
                throw WorkspaceSyncRepositoryError.remoteRecordCannotBeRepresented
            }
            snapshot.personalization.appearance = appearance
            snapshot.personalization.accent = nearestLegacyAccent(appearance.accent.primaryColor)
        }
        if change.changedFields.contains("schemaVersion"), !preservedFields.contains("schemaVersion") {
            let version = try requiredInteger("schemaVersion", in: change.record)
            guard version > 0, version <= Int64(Int.max) else {
                throw WorkspaceSyncRepositoryError.remoteRecordCannotBeRepresented
            }
            snapshot.personalization.schemaVersion = max(
                snapshot.personalization.schemaVersion,
                Int(version)
            )
        }
        snapshot.personalization.updatedAt = latest(
            snapshot.personalization.updatedAt,
            try timestamp("updatedAt", in: change.record)
        )
    }

    private static func applyMilestone(
        _ change: SyncChange,
        preserving preservedFields: Set<String>,
        to snapshot: inout FounderOfficeSnapshot
    ) throws {
        let record = change.record
        let existingIndex = snapshot.personalization.milestones.firstIndex { $0.id == change.entityID }
        var milestone: Milestone
        if let existingIndex {
            milestone = snapshot.personalization.milestones[existingIndex]
        } else {
            milestone = Milestone(
                id: change.entityID,
                title: try requiredString("title", in: record),
                dueAt: try timestamp("dueAt", in: record),
                createdAt: try timestamp("createdAt", in: record),
                updatedAt: try timestamp("updatedAt", in: record),
                deletedAt: try optionalTimestamp("deletedAt", in: record)
            )
        }
        for field in change.changedFields where !preservedFields.contains(field) {
            switch field {
            case "title": milestone.title = try requiredString(field, in: record)
            case "dueAt": milestone.dueAt = try timestamp(field, in: record)
            case "deletedAt": milestone.deletedAt = try optionalTimestamp(field, in: record)
            case "createdAt": milestone.createdAt = try timestamp(field, in: record)
            default: throw WorkspaceSyncRepositoryError.unsupportedRemoteEntity
            }
        }
        milestone.updatedAt = latest(milestone.updatedAt, try timestamp("updatedAt", in: record))
        if let existingIndex {
            snapshot.personalization.milestones[existingIndex] = milestone
        } else {
            snapshot.personalization.milestones.append(milestone)
        }
        snapshot.personalization.updatedAt = latest(snapshot.personalization.updatedAt, change.changedAt)
    }

    private static func applyPrimaryGoal(
        _ change: SyncChange,
        preserving preservedFields: Set<String>,
        to snapshot: inout FounderOfficeSnapshot
    ) throws {
        let record = change.record
        let existing = snapshot.personalization.primaryGoal
        if change.action == .delete, existing?.id != change.entityID {
            snapshot.personalization.updatedAt = latest(
                snapshot.personalization.updatedAt,
                change.changedAt
            )
            return
        }

        var goal: PrimaryGoal
        if let existing, existing.id == change.entityID {
            goal = existing
        } else {
            goal = PrimaryGoal(
                id: change.entityID,
                title: try requiredString("title", in: record),
                metric: try requiredString("metric", in: record),
                currentValue: try optionalGoalDecimal("currentValue", in: record),
                targetValue: try optionalGoalDecimal("targetValue", in: record),
                unit: try goalUnit(record),
                dueAt: try requiredDateOnly("dueOn", in: record),
                createdAt: try timestamp("createdAt", in: record),
                updatedAt: try timestamp("updatedAt", in: record),
                deletedAt: try optionalTimestamp("deletedAt", in: record)
            )
        }

        for field in change.changedFields where !preservedFields.contains(field) {
            switch field {
            case "title": goal.title = try requiredString(field, in: record)
            case "metric": goal.metric = try requiredString(field, in: record)
            case "currentValue": goal.currentValue = try optionalGoalDecimal(field, in: record)
            case "targetValue": goal.targetValue = try optionalGoalDecimal(field, in: record)
            case "unit": goal.unit = try goalUnit(record)
            case "dueOn": goal.dueAt = try requiredDateOnly(field, in: record)
            case "deletedAt": goal.deletedAt = try optionalTimestamp(field, in: record)
            default: throw WorkspaceSyncRepositoryError.unsupportedRemoteEntity
            }
        }
        goal.updatedAt = latest(goal.updatedAt, try timestamp("updatedAt", in: record))
        snapshot.personalization.primaryGoal = goal
        snapshot.personalization.updatedAt = latest(snapshot.personalization.updatedAt, change.changedAt)
    }

    private static func requiredString(
        _ key: String,
        in record: [String: SyncJSONValue]
    ) throws -> String {
        guard case let .string(value)? = record[key] else {
            throw WorkspaceSyncRepositoryError.remoteRecordCannotBeRepresented
        }
        return value
    }

    private static func optionalString(
        _ key: String,
        in record: [String: SyncJSONValue]
    ) throws -> String? {
        guard let value = record[key] else {
            throw WorkspaceSyncRepositoryError.remoteRecordCannotBeRepresented
        }
        if case .null = value { return nil }
        guard case let .string(string) = value else {
            throw WorkspaceSyncRepositoryError.remoteRecordCannotBeRepresented
        }
        return string
    }

    private static func requiredInteger(
        _ key: String,
        in record: [String: SyncJSONValue]
    ) throws -> Int64 {
        guard case let .integer(value)? = record[key] else {
            throw WorkspaceSyncRepositoryError.remoteRecordCannotBeRepresented
        }
        return value
    }

    private static func timestamp(
        _ key: String,
        in record: [String: SyncJSONValue]
    ) throws -> Date {
        try WorkspaceV2SyncAdapter.parseTimestamp(requiredString(key, in: record))
    }

    private static func optionalTimestamp(
        _ key: String,
        in record: [String: SyncJSONValue]
    ) throws -> Date? {
        try optionalString(key, in: record).map(WorkspaceV2SyncAdapter.parseTimestamp)
    }

    private static func optionalDateOnly(
        _ key: String,
        in record: [String: SyncJSONValue]
    ) throws -> Date? {
        try optionalString(key, in: record).map(WorkspaceV2SyncAdapter.parseDateOnly)
    }

    private static func requiredDateOnly(
        _ key: String,
        in record: [String: SyncJSONValue]
    ) throws -> Date {
        try WorkspaceV2SyncAdapter.parseDateOnly(requiredString(key, in: record))
    }

    private static func optionalGoalDecimal(
        _ key: String,
        in record: [String: SyncJSONValue]
    ) throws -> GoalDecimal? {
        guard let value = record[key] else {
            throw WorkspaceSyncRepositoryError.remoteRecordCannotBeRepresented
        }
        if case .null = value { return nil }
        let decimal: Decimal
        switch value {
        case let .integer(integer): decimal = Decimal(integer)
        case let .number(number): decimal = number
        default: throw WorkspaceSyncRepositoryError.remoteRecordCannotBeRepresented
        }
        do {
            return try GoalDecimal(validating: decimal)
        } catch {
            throw WorkspaceSyncRepositoryError.remoteRecordCannotBeRepresented
        }
    }

    private static func goalUnit(
        _ record: [String: SyncJSONValue]
    ) throws -> GoalValueUnit {
        guard let unit = GoalValueUnit(rawValue: try requiredString("unit", in: record)) else {
            throw WorkspaceSyncRepositoryError.remoteRecordCannotBeRepresented
        }
        return unit
    }

    private static func priority(_ record: [String: SyncJSONValue]) throws -> LoopPriority {
        guard let priority = LoopPriority(rawValue: try requiredString("priority", in: record)) else {
            throw WorkspaceSyncRepositoryError.remoteRecordCannotBeRepresented
        }
        return priority
    }

    private static func fieldClock(
        _ field: String,
        in record: [String: SyncJSONValue]
    ) throws -> Date {
        guard case let .object(clocks)? = record["fieldClocks"] else {
            throw WorkspaceSyncRepositoryError.remoteRecordCannotBeRepresented
        }
        return try timestamp(field, in: clocks)
    }

    private static func latest(_ lhs: Date?, _ rhs: Date) -> Date {
        guard let lhs else { return rhs }
        return max(lhs, rhs)
    }

    private static func nearestLegacyAccent(_ color: RGB24Color) -> AccentPalette {
        AccentPalette.allCases.min { lhs, rhs in
            distance(lhs.rgb24, color) < distance(rhs.rgb24, color)
        } ?? .blue
    }

    private static func distance(_ lhs: RGB24Color, _ rhs: RGB24Color) -> Int {
        let red = Int(lhs.red) - Int(rhs.red)
        let green = Int(lhs.green) - Int(rhs.green)
        let blue = Int(lhs.blue) - Int(rhs.blue)
        return red * red + green * green + blue * blue
    }
}
