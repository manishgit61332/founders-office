import Foundation

public enum OpenLoopRules {
    public static func precedes(_ lhs: OpenLoop, _ rhs: OpenLoop) -> Bool {
        if lhs.priority.rank != rhs.priority.rank {
            return lhs.priority.rank < rhs.priority.rank
        }

        switch (lhs.dueAt, rhs.dueAt) {
        case let (left?, right?): return left < right
        case (.some, .none): return true
        case (.none, .some): return false
        case (.none, .none): return lhs.updatedAt > rhs.updatedAt
        }
    }

    public static func toggledCompletion(_ item: OpenLoop, at date: Date) -> OpenLoop {
        var result = item
        if result.status == .done {
            result.status = result.previousStatus ?? .next
            result.previousStatus = nil
            result.completedAt = nil
        } else {
            result.previousStatus = result.status
            result.status = .done
            result.completedAt = date
        }
        result.updatedAt = date
        return result
    }

    public static func moved(_ item: OpenLoop, to status: LoopStatus, at date: Date) -> OpenLoop {
        var result = item
        result.status = status
        result.updatedAt = date

        if status == .done {
            result.previousStatus = item.status == .done ? item.previousStatus : item.status
            result.completedAt = date
        } else {
            result.previousStatus = nil
            result.completedAt = nil
        }
        return result
    }

    public static func updatedPlanning(
        _ item: OpenLoop,
        priority: LoopPriority,
        dueAt: Date?,
        at date: Date
    ) -> OpenLoop {
        let priorityChanged = item.priority != priority
        let deadlineChanged = item.dueAt != dueAt
        guard priorityChanged || deadlineChanged else { return item }

        var result = item
        result.priority = priority
        result.dueAt = dueAt
        if priorityChanged {
            result.priorityUpdatedAt = date
        }
        if deadlineChanged {
            result.dueAtUpdatedAt = date
        }
        // Planning fields have their own clocks. Keeping the whole-record clock
        // unchanged prevents an offline priority/deadline edit from winning the
        // status, completion, deletion, title, or details merge on another device.
        return result
    }

    public static func softDeleted(_ item: OpenLoop, at date: Date) -> OpenLoop {
        var result = item
        result.deletedAt = date
        result.updatedAt = date
        return result
    }

    public static func restored(_ item: OpenLoop, at date: Date) -> OpenLoop {
        var result = item
        result.deletedAt = nil
        result.updatedAt = date
        return result
    }
}
