import Foundation

public enum AppearanceSaveResult: Equatable, Sendable {
    case saved
    case unchanged
    case conflict
    case failed(String)
}

public enum AppearanceTerminationChoice: Equatable, Sendable {
    case save
    case discard
    case cancel
}

public enum AppearanceTerminationDecision: Equatable, Sendable {
    case terminate
    case continueEditing
}

public enum AppearanceTerminationPolicy {
    public static func decision(
        for choice: AppearanceTerminationChoice,
        saveResult: AppearanceSaveResult? = nil
    ) -> AppearanceTerminationDecision {
        switch choice {
        case .discard:
            return .terminate
        case .cancel:
            return .continueEditing
        case .save:
            switch saveResult {
            case .saved, .unchanged:
                return .terminate
            case .conflict, .failed, nil:
                return .continueEditing
            }
        }
    }
}

/// Holds a live appearance preview separately from the last durable value.
///
/// `updatedAt` is intentionally kept at the baseline revision while the user
/// edits. The persistence layer assigns a new revision only after an atomic
/// save succeeds.
public struct AppearanceDraftSession: Equatable, Sendable {
    public private(set) var baseline: AppearancePreferences
    public private(set) var draft: AppearancePreferences
    public private(set) var baselineRevision: Date?
    public private(set) var saveError: String?
    public private(set) var hasConflict: Bool

    public init(committed: AppearancePreferences) {
        baseline = committed
        draft = committed
        baselineRevision = committed.updatedAt
        saveError = nil
        hasConflict = false
    }

    public var isDirty: Bool {
        !Self.hasSameContent(draft, baseline)
    }

    public mutating func update(_ transform: (inout AppearancePreferences) -> Void) {
        transform(&draft)
        draft.updatedAt = baselineRevision
        saveError = nil
    }

    /// Reconciles a newly loaded durable value without replacing an active
    /// preview. Clean sessions follow the durable value; dirty sessions surface
    /// a conflict only when its appearance content actually changed.
    public mutating func observeCommitted(_ committed: AppearancePreferences) {
        if Self.hasSameContent(committed, draft) {
            reset(to: committed)
            return
        }
        guard !Self.hasSameContent(committed, baseline) else {
            baselineRevision = committed.updatedAt
            baseline.updatedAt = committed.updatedAt
            draft.updatedAt = committed.updatedAt
            return
        }

        guard isDirty else {
            reset(to: committed)
            return
        }

        hasConflict = true
        saveError = nil
    }

    public mutating func markSaved(_ committed: AppearancePreferences) {
        reset(to: committed)
    }

    public mutating func useLatest(_ committed: AppearancePreferences) {
        reset(to: committed)
    }

    public mutating func markFailed(_ message: String) {
        saveError = message
    }

    public mutating func clearFailure() {
        saveError = nil
    }

    public mutating func resolveConflictKeepingDraft() {
        hasConflict = false
        saveError = nil
    }

    public mutating func discard() {
        draft = baseline
        saveError = nil
        hasConflict = false
    }

    public static func hasSameContent(
        _ lhs: AppearancePreferences,
        _ rhs: AppearancePreferences
    ) -> Bool {
        var lhs = lhs
        var rhs = rhs
        lhs.updatedAt = nil
        rhs.updatedAt = nil
        return lhs == rhs
    }

    private mutating func reset(to committed: AppearancePreferences) {
        baseline = committed
        draft = committed
        baselineRevision = committed.updatedAt
        saveError = nil
        hasConflict = false
    }
}
