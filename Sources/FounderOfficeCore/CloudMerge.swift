import Foundation

public struct FounderOfficeSnapshot: Codable, Sendable {
    public var openLoops: OpenLoopsDocument
    public var personalization: PersonalizationDocument

    public init(openLoops: OpenLoopsDocument, personalization: PersonalizationDocument) {
        self.openLoops = openLoops
        self.personalization = personalization
    }
}

public enum FounderOfficeMerge {
    public static func openLoops(local: OpenLoopsDocument, remote: OpenLoopsDocument) -> OpenLoopsDocument {
        let localDocument = OpenLoopsMigration.upgradingPlanningSchema(local)
        let remoteDocument = OpenLoopsMigration.upgradingPlanningSchema(remote)
        let localItems = Dictionary(uniqueKeysWithValues: localDocument.items.map { ($0.id, $0) })
        let remoteItems = Dictionary(uniqueKeysWithValues: remoteDocument.items.map { ($0.id, $0) })
        let allIDs = Set(localItems.keys).union(remoteItems.keys)

        let mergedItems = allIDs.compactMap { id -> OpenLoop? in
            switch (localItems[id], remoteItems[id]) {
            case let (localItem?, remoteItem?):
                return mergedOpenLoop(local: localItem, remote: remoteItem)
            case let (localItem?, nil): return localItem
            case let (nil, remoteItem?): return remoteItem
            case (nil, nil): return nil
            }
        }
        .sorted { $0.id.uuidString < $1.id.uuidString }

        return OpenLoopsDocument(
            schemaVersion: max(localDocument.schemaVersion, remoteDocument.schemaVersion),
            updatedAt: max(localDocument.updatedAt, remoteDocument.updatedAt),
            items: mergedItems
        )
    }

    private static func mergedOpenLoop(local: OpenLoop, remote: OpenLoop) -> OpenLoop {
        var merged = newer(
            local,
            remote,
            localDate: local.updatedAt,
            remoteDate: remote.updatedAt
        )

        merged.priority = mergedPlanningValue(
            local.priority,
            remote.priority,
            localDate: local.priorityUpdatedAt,
            remoteDate: remote.priorityUpdatedAt,
            fallback: merged.priority
        )
        merged.priorityUpdatedAt = latest(local.priorityUpdatedAt, remote.priorityUpdatedAt)

        merged.dueAt = mergedPlanningValue(
            local.dueAt,
            remote.dueAt,
            localDate: local.dueAtUpdatedAt,
            remoteDate: remote.dueAtUpdatedAt,
            fallback: merged.dueAt
        )
        merged.dueAtUpdatedAt = latest(local.dueAtUpdatedAt, remote.dueAtUpdatedAt)
        return merged
    }

    private static func mergedPlanningValue<Value: Encodable>(
        _ local: Value,
        _ remote: Value,
        localDate: Date?,
        remoteDate: Date?,
        fallback: Value
    ) -> Value {
        switch (localDate, remoteDate) {
        case let (localDate?, remoteDate?):
            return newer(
                local,
                remote,
                localDate: localDate,
                remoteDate: remoteDate
            )
        case (_?, nil):
            return local
        case (nil, _?):
            return remote
        case (nil, nil):
            return fallback
        }
    }

    private static func latest(_ lhs: Date?, _ rhs: Date?) -> Date? {
        switch (lhs, rhs) {
        case let (lhs?, rhs?): return max(lhs, rhs)
        case let (lhs?, nil): return lhs
        case let (nil, rhs?): return rhs
        case (nil, nil): return nil
        }
    }

    public static func personalization(
        local: PersonalizationDocument,
        remote: PersonalizationDocument
    ) -> PersonalizationDocument {
        newer(
            local,
            remote,
            localDate: local.updatedAt ?? .distantPast,
            remoteDate: remote.updatedAt ?? .distantPast
        )
    }

    private static func newer<Value: Encodable>(
        _ local: Value,
        _ remote: Value,
        localDate: Date,
        remoteDate: Date
    ) -> Value {
        if localDate != remoteDate {
            return localDate > remoteDate ? local : remote
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let localData = (try? encoder.encode(local)) ?? Data()
        let remoteData = (try? encoder.encode(remote)) ?? Data()
        return remoteData.lexicographicallyPrecedes(localData) ? local : remote
    }
}
