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
        let localItems = Dictionary(uniqueKeysWithValues: local.items.map { ($0.id, $0) })
        let remoteItems = Dictionary(uniqueKeysWithValues: remote.items.map { ($0.id, $0) })
        let allIDs = Set(localItems.keys).union(remoteItems.keys)

        let mergedItems = allIDs.compactMap { id -> OpenLoop? in
            switch (localItems[id], remoteItems[id]) {
            case let (localItem?, remoteItem?):
                return newer(localItem, remoteItem, localDate: localItem.updatedAt, remoteDate: remoteItem.updatedAt)
            case let (localItem?, nil): return localItem
            case let (nil, remoteItem?): return remoteItem
            case (nil, nil): return nil
            }
        }
        .sorted { $0.id.uuidString < $1.id.uuidString }

        return OpenLoopsDocument(
            schemaVersion: max(local.schemaVersion, remote.schemaVersion),
            updatedAt: max(local.updatedAt, remote.updatedAt),
            items: mergedItems
        )
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
