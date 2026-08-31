import Foundation

public enum LoopStatus: String, Codable, CaseIterable, Identifiable, Sendable {
    case doing
    case next
    case waiting
    case done

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .doing: return "Doing"
        case .next: return "Next"
        case .waiting: return "Blocked"
        case .done: return "Done"
        }
    }
}

public enum LoopPriority: String, Codable, CaseIterable, Identifiable, Sendable {
    case p0 = "P0"
    case p1 = "P1"
    case p2 = "P2"
    case p3 = "P3"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .p0: return "Critical"
        case .p1: return "High"
        case .p2: return "Medium"
        case .p3: return "Low"
        }
    }

    public var rank: Int {
        switch self {
        case .p0: return 0
        case .p1: return 1
        case .p2: return 2
        case .p3: return 3
        }
    }
}

public struct OpenLoop: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var details: String
    public var status: LoopStatus
    public var previousStatus: LoopStatus?
    public var priority: LoopPriority
    public var dueAt: Date?
    public var createdAt: Date
    public var updatedAt: Date
    /// Field-level clocks let offline devices merge a priority edit and a
    /// deadline edit without making either whole task overwrite the other.
    public var priorityUpdatedAt: Date?
    public var dueAtUpdatedAt: Date?
    public var completedAt: Date?
    public var deletedAt: Date?
    public var source: String

    public init(
        id: UUID,
        title: String,
        details: String,
        status: LoopStatus,
        previousStatus: LoopStatus?,
        priority: LoopPriority,
        dueAt: Date?,
        createdAt: Date,
        updatedAt: Date,
        completedAt: Date?,
        deletedAt: Date?,
        source: String,
        priorityUpdatedAt: Date? = nil,
        dueAtUpdatedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.details = details
        self.status = status
        self.previousStatus = previousStatus
        self.priority = priority
        self.dueAt = dueAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.priorityUpdatedAt = priorityUpdatedAt
        self.dueAtUpdatedAt = dueAtUpdatedAt
        self.completedAt = completedAt
        self.deletedAt = deletedAt
        self.source = source
    }
}

public struct OpenLoopsDocument: Codable, Sendable {
    public var schemaVersion: Int
    public var updatedAt: Date
    public var items: [OpenLoop]

    public init(schemaVersion: Int, updatedAt: Date, items: [OpenLoop]) {
        self.schemaVersion = schemaVersion
        self.updatedAt = updatedAt
        self.items = items
    }
}

public enum AccentPalette: String, Codable, CaseIterable, Identifiable, Sendable {
    case blue
    case green
    case terracotta
    case violet
    case graphite

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .blue: return "Blue"
        case .green: return "Green"
        case .terracotta: return "Terracotta"
        case .violet: return "Violet"
        case .graphite: return "Graphite"
        }
    }
}

public enum IconStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case clay
    case system

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .clay: return "Clay"
        case .system: return "System"
        }
    }
}

public struct Milestone: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var dueAt: Date
    public var createdAt: Date
    public var updatedAt: Date?
    public var deletedAt: Date?

    public init(
        id: UUID,
        title: String,
        dueAt: Date,
        createdAt: Date,
        updatedAt: Date? = nil,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.dueAt = dueAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

public enum GoalValueUnit: String, Codable, CaseIterable, Identifiable, Sendable {
    case usd
    case inr
    case number
    case percent

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .usd: return "$"
        case .inr: return "₹"
        case .number: return "#"
        case .percent: return "%"
        }
    }

    public func format(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.maximumFractionDigits = value.rounded() == value ? 0 : 1
        let number = formatter.string(from: NSNumber(value: value)) ?? String(format: "%.0f", value)

        switch self {
        case .usd: return "$\(number)"
        case .inr: return "₹\(number)"
        case .number: return number
        case .percent: return "\(number)%"
        }
    }
}

public struct PrimaryGoal: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var metric: String
    public var currentValue: Double?
    public var targetValue: Double?
    public var unit: GoalValueUnit
    public var dueAt: Date
    public var createdAt: Date
    public var updatedAt: Date?
    public var deletedAt: Date?

    public init(
        id: UUID,
        title: String,
        metric: String,
        currentValue: Double?,
        targetValue: Double?,
        unit: GoalValueUnit,
        dueAt: Date,
        createdAt: Date,
        updatedAt: Date? = nil,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.metric = metric
        self.currentValue = currentValue
        self.targetValue = targetValue
        self.unit = unit
        self.dueAt = dueAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

public struct PersonalizationDocument: Codable, Sendable {
    public var schemaVersion: Int
    /// Legacy field retained so existing version 1-4 documents keep decoding.
    /// New clients should use `preferredName` and `workspaceName` instead.
    public var displayName: String
    public var preferredName: String?
    public var workspaceName: String?
    public var accent: AccentPalette
    public var iconStyle: IconStyle?
    public var photoFileName: String?
    public var primaryGoal: PrimaryGoal?
    public var milestones: [Milestone]
    public var updatedAt: Date?
    public var appearance: AppearancePreferences?
    /// Bounded image metadata. `photoFileName` remains a display-variant
    /// compatibility field for older clients.
    public var visionImageAsset: PersonalizationImageAsset?

    public init(
        schemaVersion: Int,
        displayName: String,
        accent: AccentPalette,
        iconStyle: IconStyle?,
        photoFileName: String?,
        primaryGoal: PrimaryGoal?,
        milestones: [Milestone],
        updatedAt: Date? = nil,
        preferredName: String? = nil,
        workspaceName: String? = nil,
        appearance: AppearancePreferences? = nil,
        visionImageAsset: PersonalizationImageAsset? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.displayName = displayName
        self.preferredName = preferredName
        self.workspaceName = workspaceName
        self.accent = accent
        self.iconStyle = iconStyle
        self.photoFileName = photoFileName
        self.primaryGoal = primaryGoal
        self.milestones = milestones
        self.updatedAt = updatedAt
        self.appearance = appearance
        self.visionImageAsset = visionImageAsset
    }

    public var resolvedPreferredName: String? {
        Self.clean(preferredName)
    }

    public var resolvedWorkspaceName: String {
        if let workspaceName = Self.clean(workspaceName) {
            return workspaceName
        }

        if let legacy = Self.clean(displayName) {
            return legacy
        }

        return "Founder's Office"
    }

    public var resolvedAppearance: AppearancePreferences {
        appearance ?? .manish(accent: accent.rgb24)
    }

    public var resolvedPhotoFileName: String? {
        if let visionImageAsset {
            return AssetFileName.validated(visionImageAsset.displayFileName)
        }
        return photoFileName.flatMap(AssetFileName.validated)
    }

    public var resolvedSyncPhotoFileName: String? {
        if let visionImageAsset {
            return AssetFileName.validated(visionImageAsset.syncFileName)
        }
        return photoFileName.flatMap(AssetFileName.validated)
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleanValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleanValue.isEmpty ? nil : cleanValue
    }
}
