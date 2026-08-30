import Foundation

/// Deadline-first groupings for active Moves. The case order is the display
/// order used by every client.
public enum ActiveDeadlineBucket: String, CaseIterable, Hashable, Identifiable, Sendable {
    case overdue
    case today
    case upcoming
    case noDeadline

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .overdue: return "Overdue"
        case .today: return "Today"
        case .upcoming: return "Upcoming"
        case .noDeadline: return "No deadline"
        }
    }
}

public struct ActiveMoveGroup: Identifiable, Hashable, Sendable {
    public let bucket: ActiveDeadlineBucket
    public let items: [OpenLoop]

    public var id: ActiveDeadlineBucket { bucket }

    public init(bucket: ActiveDeadlineBucket, items: [OpenLoop]) {
        self.bucket = bucket
        self.items = items
    }
}

/// A deterministic, presentation-ready view of the Move store.
///
/// This type never mutates or removes source history. Soft-deleted Moves are
/// omitted from presentation, while every visible Done Move is retained in
/// either `recentCompleted` or `olderCompleted`.
public struct MovePresentation: Hashable, Sendable {
    public let activeGroups: [ActiveMoveGroup]
    public let recentCompleted: [OpenLoop]
    public let olderCompleted: [OpenLoop]

    public init(
        items: [OpenLoop],
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        let visibleItems = items.filter { $0.deletedAt == nil }
        let activeItems = visibleItems.filter { $0.status != .done }
        let completedItems = visibleItems.filter { $0.status == .done }
        let boundaries = Self.calendarBoundaries(now: now, calendar: calendar)

        var groupedActive = Dictionary(
            uniqueKeysWithValues: ActiveDeadlineBucket.allCases.map { ($0, [OpenLoop]()) }
        )

        for item in activeItems {
            let bucket = Self.deadlineBucket(
                for: item.dueAt,
                startOfToday: boundaries.startOfToday,
                startOfTomorrow: boundaries.startOfTomorrow
            )
            groupedActive[bucket, default: []].append(item)
        }

        activeGroups = ActiveDeadlineBucket.allCases.compactMap { bucket in
            guard let items = groupedActive[bucket], !items.isEmpty else { return nil }
            return ActiveMoveGroup(bucket: bucket, items: items.sorted(by: Self.activePrecedes))
        }

        recentCompleted = completedItems
            .filter { item in
                guard let completedAt = item.completedAt else { return false }
                return completedAt >= boundaries.startOfYesterday
                    && completedAt < boundaries.startOfTomorrow
            }
            .sorted(by: Self.completedPrecedes)

        olderCompleted = completedItems
            .filter { item in
                guard let completedAt = item.completedAt else { return true }
                return completedAt < boundaries.startOfYesterday
                    || completedAt >= boundaries.startOfTomorrow
            }
            .sorted(by: Self.completedPrecedes)
    }

    public func items(in bucket: ActiveDeadlineBucket) -> [OpenLoop] {
        activeGroups.first(where: { $0.bucket == bucket })?.items ?? []
    }

    public var allCompleted: [OpenLoop] {
        recentCompleted + olderCompleted
    }

    private struct CalendarBoundaries {
        var startOfYesterday: Date
        var startOfToday: Date
        var startOfTomorrow: Date
    }

    private static func calendarBoundaries(now: Date, calendar: Calendar) -> CalendarBoundaries {
        let startOfToday = calendar.startOfDay(for: now)
        let startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday)
            ?? startOfToday.addingTimeInterval(-86_400)
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday)
            ?? startOfToday.addingTimeInterval(86_400)
        return CalendarBoundaries(
            startOfYesterday: startOfYesterday,
            startOfToday: startOfToday,
            startOfTomorrow: startOfTomorrow
        )
    }

    private static func deadlineBucket(
        for dueAt: Date?,
        startOfToday: Date,
        startOfTomorrow: Date
    ) -> ActiveDeadlineBucket {
        guard let dueAt else { return .noDeadline }
        if dueAt < startOfToday { return .overdue }
        if dueAt < startOfTomorrow { return .today }
        return .upcoming
    }

    private static func activePrecedes(_ lhs: OpenLoop, _ rhs: OpenLoop) -> Bool {
        if lhs.dueAt != rhs.dueAt {
            switch (lhs.dueAt, rhs.dueAt) {
            case let (left?, right?): return left < right
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): break
            }
        }

        if lhs.priority.rank != rhs.priority.rank {
            return lhs.priority.rank < rhs.priority.rank
        }

        return titleAndIDPrecedes(lhs, rhs)
    }

    private static func completedPrecedes(_ lhs: OpenLoop, _ rhs: OpenLoop) -> Bool {
        if lhs.completedAt != rhs.completedAt {
            switch (lhs.completedAt, rhs.completedAt) {
            case let (left?, right?): return left > right
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): break
            }
        }

        if lhs.priority.rank != rhs.priority.rank {
            return lhs.priority.rank < rhs.priority.rank
        }

        if lhs.dueAt != rhs.dueAt {
            switch (lhs.dueAt, rhs.dueAt) {
            case let (left?, right?): return left < right
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): break
            }
        }

        return titleAndIDPrecedes(lhs, rhs)
    }

    private static func titleAndIDPrecedes(_ lhs: OpenLoop, _ rhs: OpenLoop) -> Bool {
        let leftKey = titleSortKey(lhs.title)
        let rightKey = titleSortKey(rhs.title)
        if leftKey != rightKey { return leftKey < rightKey }
        if lhs.title != rhs.title { return lhs.title < rhs.title }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func titleSortKey(_ title: String) -> String {
        title.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }
}
