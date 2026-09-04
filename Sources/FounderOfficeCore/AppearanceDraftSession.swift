import Foundation

public enum AppearanceSaveResult: Equatable, Sendable {
    case saved
    case unchanged
    case conflict
    case failed(String)
}

/// Controls whether an appearance commit must still match the revision that
/// was visible when editing began or may intentionally replace a newer value.
public enum AppearanceDraftCommitPolicy: String, Codable, Equatable, Sendable {
    case requireBaseline
    case overwriteLatest
}

/// Persistence-agnostic input for one atomic appearance commit.
///
/// The commit boundary must not report `.saved` until `appearance` is durable.
/// A platform adapter is responsible for assigning the committed revision and
/// returning it in `AppearanceDraftCommitResult.saved`.
public struct AppearanceDraftCommitRequest: Equatable, Sendable {
    public let appearance: AppearancePreferences
    public let baselineRevision: Date?
    public let policy: AppearanceDraftCommitPolicy

    public init(
        appearance: AppearancePreferences,
        baselineRevision: Date?,
        policy: AppearanceDraftCommitPolicy
    ) {
        self.appearance = appearance
        self.baselineRevision = baselineRevision
        self.policy = policy
    }
}

/// Result returned by a platform's atomic appearance commit boundary.
public enum AppearanceDraftCommitResult: Equatable, Sendable {
    /// The revision assigned to the exact requested appearance by storage.
    case saved(committedRevision: Date)
    /// The latest durable value that invalidated the request's baseline.
    case conflict(latest: AppearancePreferences)
    /// A customer-safe, retryable error. Raw storage errors must not cross this
    /// boundary because they can include private paths or implementation data.
    case failed(String)
}

/// Injected persistence seam for `AppearanceDraftSession.save`.
///
/// Implementations may be actors. This keeps the draft state machine Sendable
/// and independently testable without making FounderOfficeCore depend on
/// SQLite, Supabase, AppKit, or another platform persistence framework.
public protocol AppearanceDraftCommitBoundary: Sendable {
    func commit(
        _ request: AppearanceDraftCommitRequest
    ) async -> AppearanceDraftCommitResult
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
    public private(set) var conflictingCommitted: AppearancePreferences?

    public init(committed: AppearancePreferences) {
        baseline = committed
        draft = committed
        baselineRevision = committed.updatedAt
        saveError = nil
        hasConflict = false
        conflictingCommitted = nil
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
        conflictingCommitted = committed
        saveError = nil
    }

    public mutating func markSaved(_ committed: AppearancePreferences) {
        reset(to: committed)
    }

    public mutating func useLatest(_ committed: AppearancePreferences) {
        reset(to: committed)
    }

    /// Adopts the durable value retained from the most recent conflict.
    @discardableResult
    public mutating func useLatest() -> Bool {
        guard let conflictingCommitted else { return false }
        reset(to: conflictingCommitted)
        return true
    }

    public mutating func markFailed(_ message: String) {
        saveError = message
    }

    public mutating func clearFailure() {
        saveError = nil
    }

    public mutating func resolveConflictKeepingDraft() {
        hasConflict = false
        conflictingCommitted = nil
        saveError = nil
    }

    /// Atomically asks an injected platform adapter to commit the current
    /// draft and reconciles the returned durable result.
    ///
    /// Clean and unresolved-conflict sessions return without calling the
    /// boundary. A failed or conflicting commit keeps the preview intact.
    @discardableResult
    public mutating func save(
        policy: AppearanceDraftCommitPolicy = .requireBaseline,
        using boundary: any AppearanceDraftCommitBoundary
    ) async -> AppearanceSaveResult {
        guard isDirty else { return .unchanged }
        guard policy == .overwriteLatest || !hasConflict else {
            return .conflict
        }
        if policy == .overwriteLatest {
            resolveConflictKeepingDraft()
        }

        let request = AppearanceDraftCommitRequest(
            appearance: draft,
            baselineRevision: baselineRevision,
            policy: policy
        )
        switch await boundary.commit(request) {
        case let .saved(committedRevision):
            var committed = request.appearance
            committed.updatedAt = committedRevision
            markSaved(committed)
            return .saved
        case let .conflict(latest):
            observeCommitted(latest)
            return .conflict
        case let .failed(message):
            markFailed(message)
            return .failed(message)
        }
    }

    public mutating func discard() {
        draft = baseline
        saveError = nil
        hasConflict = false
        conflictingCommitted = nil
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
        conflictingCommitted = nil
    }
}
