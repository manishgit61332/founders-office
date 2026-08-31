import Foundation

/// Reapplies only fields named by the exact local-v2 operation retained for a
/// reviewed conflict. Record values outside the changed-field mask are context
/// and can never overwrite a newer inbound field.
enum WorkspaceConflictLocalChangeApplicator {
    static func apply(
        _ operation: WorkspaceOutboxOperation,
        to source: FounderOfficeSnapshot
    ) throws -> FounderOfficeSnapshot {
        guard case let .localEntity(envelope) = try operation.decodedLocalPayload() else {
            throw WorkspaceSyncRepositoryError.conflictEvidenceUnavailable
        }
        var snapshot = source
        let fields = Set(envelope.changedFields)

        switch envelope.record {
        case let .move(proposed):
            guard let identifier = UUID(uuidString: envelope.entityID), identifier == proposed.id else {
                throw WorkspaceSyncRepositoryError.conflictEvidenceUnavailable
            }
            guard let index = snapshot.openLoops.items.firstIndex(where: { $0.id == identifier }) else {
                // Conflict evidence describes an update to a server record,
                // not a reviewed resurrection of a record removed meanwhile.
                throw WorkspaceSyncRepositoryError.conflictResolutionUnavailable
            }
            var move = snapshot.openLoops.items[index]
            for field in fields {
                switch field {
                case "title": move.title = proposed.title
                case "details": move.details = proposed.details
                case "status": move.status = proposed.status
                case "previousStatus": move.previousStatus = proposed.previousStatus
                case "priority": move.priority = proposed.priority
                case "dueAt": move.dueAt = proposed.dueAt
                case "createdAt": move.createdAt = proposed.createdAt
                case "updatedAt": move.updatedAt = proposed.updatedAt
                case "priorityUpdatedAt": move.priorityUpdatedAt = proposed.priorityUpdatedAt
                case "dueAtUpdatedAt": move.dueAtUpdatedAt = proposed.dueAtUpdatedAt
                case "completedAt": move.completedAt = proposed.completedAt
                case "deletedAt": move.deletedAt = proposed.deletedAt
                case "source": move.source = proposed.source
                default: throw WorkspaceSyncRepositoryError.conflictEvidenceUnavailable
                }
            }
            snapshot.openLoops.items[index] = move
            snapshot.openLoops.updatedAt = max(snapshot.openLoops.updatedAt, proposed.updatedAt)

        case let .appearance(proposed):
            var appearance = snapshot.personalization.resolvedAppearance
            for field in fields {
                switch field {
                case "appearance": appearance = proposed
                case "presetID": appearance.presetID = proposed.presetID
                case "accent": appearance.accent = proposed.accent
                case "displayFontID": appearance.displayFontID = proposed.displayFontID
                case "interfaceFontID": appearance.interfaceFontID = proposed.interfaceFontID
                case "nodeStyleID": appearance.nodeStyleID = proposed.nodeStyleID
                case "surfaceStyleID": appearance.surfaceStyleID = proposed.surfaceStyleID
                case "updatedAt": appearance.updatedAt = proposed.updatedAt
                default: throw WorkspaceSyncRepositoryError.conflictEvidenceUnavailable
                }
            }
            snapshot.personalization.appearance = appearance
            snapshot.personalization.accent = nearestLegacyAccent(appearance.accent.primaryColor)
            snapshot.personalization.updatedAt = latest(
                snapshot.personalization.updatedAt,
                proposed.updatedAt
            )

        case let .profile(proposed):
            for field in fields {
                switch field {
                case "displayName": snapshot.personalization.displayName = proposed.displayName
                case "preferredName": snapshot.personalization.preferredName = proposed.preferredName
                case "iconStyle": snapshot.personalization.iconStyle = proposed.iconStyle
                case "updatedAt": snapshot.personalization.updatedAt = proposed.updatedAt
                default: throw WorkspaceSyncRepositoryError.conflictEvidenceUnavailable
                }
            }

        case let .workspace(proposed):
            for field in fields {
                switch field {
                case "workspaceName": snapshot.personalization.workspaceName = proposed.name
                case "updatedAt": snapshot.personalization.updatedAt = proposed.updatedAt
                default: throw WorkspaceSyncRepositoryError.conflictEvidenceUnavailable
                }
            }

        case let .primaryGoal(proposed):
            guard let current = snapshot.personalization.primaryGoal, current.id == proposed.id else {
                throw WorkspaceSyncRepositoryError.conflictResolutionUnavailable
            }
            var goal = current
            for field in fields {
                switch field {
                case "title": goal.title = proposed.title
                case "metric": goal.metric = proposed.metric
                case "currentValue": goal.currentValue = proposed.currentValue
                case "targetValue": goal.targetValue = proposed.targetValue
                case "unit": goal.unit = proposed.unit
                case "dueAt": goal.dueAt = proposed.dueAt
                case "createdAt": goal.createdAt = proposed.createdAt
                case "updatedAt": goal.updatedAt = proposed.updatedAt
                case "deletedAt": goal.deletedAt = proposed.deletedAt
                default: throw WorkspaceSyncRepositoryError.conflictEvidenceUnavailable
                }
            }
            snapshot.personalization.primaryGoal = goal
            snapshot.personalization.updatedAt = latest(
                snapshot.personalization.updatedAt,
                proposed.updatedAt
            )

        case let .milestone(proposed):
            guard let index = snapshot.personalization.milestones.firstIndex(
                where: { $0.id == proposed.id }
            ) else {
                throw WorkspaceSyncRepositoryError.conflictResolutionUnavailable
            }
            var milestone = snapshot.personalization.milestones[index]
            for field in fields {
                switch field {
                case "title": milestone.title = proposed.title
                case "dueAt": milestone.dueAt = proposed.dueAt
                case "createdAt": milestone.createdAt = proposed.createdAt
                case "updatedAt": milestone.updatedAt = proposed.updatedAt
                case "deletedAt": milestone.deletedAt = proposed.deletedAt
                default: throw WorkspaceSyncRepositoryError.conflictEvidenceUnavailable
                }
            }
            snapshot.personalization.milestones[index] = milestone
            snapshot.personalization.updatedAt = latest(
                snapshot.personalization.updatedAt,
                proposed.updatedAt
            )

        case .asset:
            // Asset transfer is disabled, so no reviewed server conflict can
            // safely reach this seam in the current contract.
            throw WorkspaceSyncRepositoryError.conflictResolutionUnavailable
        }
        return snapshot
    }

    private static func latest(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (.some(lhs), .some(rhs)): return max(lhs, rhs)
        case let (.some(lhs), nil): return lhs
        case let (nil, .some(rhs)): return rhs
        case (nil, nil): return nil
        }
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
