import Foundation

/// The only data an iOS widget may read. This deliberately excludes the
/// workspace database, outbox, account/session details, connector grants, and
/// image assets. The containing app writes this one-item projection atomically.
struct IOSWidgetProjection: Codable, Equatable {
    static let schemaVersion = 1

    struct Move: Codable, Equatable {
        let id: UUID
        let title: String
        let dueAt: Date?
    }

    struct Commitment: Codable, Equatable {
        let id: String
        let title: String
        let startAt: Date
    }

    struct Goal: Codable, Equatable {
        let id: UUID
        let title: String
        let progress: String?
    }

    let version: Int
    let generatedAt: Date
    /// Signed-out projections intentionally contain no customer content.
    let isSignedIn: Bool
    let nextMove: Move?
    let nextCommitment: Commitment?
    let primaryGoal: Goal?

    init(
        generatedAt: Date = .now,
        isSignedIn: Bool,
        nextMove: Move? = nil,
        nextCommitment: Commitment? = nil,
        primaryGoal: Goal? = nil
    ) {
        version = Self.schemaVersion
        self.generatedAt = generatedAt
        self.isSignedIn = isSignedIn
        self.nextMove = isSignedIn ? nextMove : nil
        self.nextCommitment = isSignedIn ? nextCommitment : nil
        self.primaryGoal = isSignedIn ? primaryGoal : nil
    }

    static var signedOut: IOSWidgetProjection { IOSWidgetProjection(isSignedIn: false) }
}

enum IOSWidgetProjectionStore {
    static let appGroupID = "group.com.manish.foundersoffice"
    private static let directoryName = "FounderOffice"
    private static let fileName = "widget-projection-v1.json"

    static func load(fileManager: FileManager = .default) -> IOSWidgetProjection? {
        guard let url = projectionURL(fileManager: fileManager),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let projection = try? decoder.decode(IOSWidgetProjection.self, from: data),
              projection.version == IOSWidgetProjection.schemaVersion else {
            return nil
        }
        return projection
    }

    @discardableResult
    static func save(
        _ projection: IOSWidgetProjection,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let url = projectionURL(fileManager: fileManager) else { return false }
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            try encoder.encode(projection).write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    private static func projectionURL(fileManager: FileManager) -> URL? {
        fileManager
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(fileName)
    }
}
