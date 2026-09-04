import Foundation

/// Lossless upgrades for the shared move document.
public enum OpenLoopsMigration {
    public static func upgradingPlanningSchema(
        _ document: OpenLoopsDocument,
        calendar: Calendar = .current
    ) -> OpenLoopsDocument {
        guard document.schemaVersion < 3 else { return document }

        var upgraded = document
        for index in upgraded.items.indices {
            let original = upgraded.items[index]

            // Older iOS builds persisted the DatePicker instant rather than a
            // date-only value. Preserve the local day selected on that device.
            if original.source.caseInsensitiveCompare("ios") == .orderedSame,
               let dueAt = original.dueAt,
               !PlanningDate.isCanonicalStoredDate(dueAt) {
                upgraded.items[index].dueAt = PlanningDate.storedDate(
                    fromLocal: dueAt,
                    calendar: calendar
                )
            }

            // A schema-2 writer has only a whole-item clock. Use it as the
            // baseline for both planning fields so mixed-version merges remain
            // responsive instead of permanently ignoring the older client.
            upgraded.items[index].priorityUpdatedAt = original.priorityUpdatedAt
                ?? original.updatedAt
            upgraded.items[index].dueAtUpdatedAt = original.dueAtUpdatedAt
                ?? original.updatedAt
        }
        upgraded.schemaVersion = 3
        return upgraded
    }
}
