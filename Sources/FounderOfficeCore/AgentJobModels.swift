import Foundation

/// The agent chosen by the customer. Provider names stay separate from the
/// execution surface so the UI can describe where a job actually runs.
public enum AgentProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex
    case claude

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        }
    }
}

/// A truthful description of where execution and review take place.
public enum AgentExecutionSurface: String, Codable, CaseIterable, Identifiable, Sendable {
    case codexAppServer
    case claudeCloudSession
    case claudeLocalHelper

    public var id: String { rawValue }

    public var provider: AgentProvider {
        switch self {
        case .codexAppServer: return .codex
        case .claudeCloudSession, .claudeLocalHelper: return .claude
        }
    }

    public var title: String {
        switch self {
        case .codexAppServer: return "Codex session"
        case .claudeCloudSession: return "Claude cloud session"
        case .claudeLocalHelper: return "Claude local agent"
        }
    }
}

/// Agent execution is intentionally independent from a Move's lifecycle.
/// Reaching `reviewReady` or `succeeded` never completes the originating Move.
public enum AgentJobState: String, Codable, CaseIterable, Identifiable, Sendable {
    case notRequested
    case triaging
    case draftReady
    case queued
    case running
    case awaitingApproval
    case needsInput
    case reviewReady
    case succeeded
    case failed
    case canceled

    public var id: String { rawValue }

    public var isActive: Bool {
        switch self {
        case .triaging, .draftReady, .queued, .running, .awaitingApproval, .needsInput, .reviewReady:
            return true
        case .notRequested, .succeeded, .failed, .canceled:
            return false
        }
    }

    public var requiresUser: Bool {
        self == .awaitingApproval || self == .needsInput || self == .reviewReady
    }

    public var isTerminal: Bool {
        self == .succeeded || self == .failed || self == .canceled
    }

    public func canTransition(to next: AgentJobState) -> Bool {
        switch self {
        case .notRequested:
            return next == .triaging || next == .canceled
        case .triaging:
            return next == .draftReady || next == .needsInput || next == .failed || next == .canceled
        case .draftReady:
            return next == .queued || next == .needsInput || next == .canceled
        case .queued:
            return next == .running || next == .needsInput || next == .failed || next == .canceled
        case .running:
            return next == .awaitingApproval || next == .needsInput || next == .reviewReady || next == .failed || next == .canceled
        case .awaitingApproval:
            return next == .running || next == .failed || next == .canceled
        case .needsInput:
            return next == .triaging || next == .queued || next == .running || next == .failed || next == .canceled
        case .reviewReady:
            return next == .succeeded || next == .failed || next == .canceled
        case .succeeded, .failed, .canceled:
            return false
        }
    }
}

public enum AgentJobOrigin: String, Codable, Sendable {
    case explicitUserCommand
    case approvedSuggestion
}

public enum AgentJobTransitionError: Error, Equatable, Sendable {
    case invalid(from: AgentJobState, to: AgentJobState)
}

/// Content-free state that is safe to merge and sync. Prompts, paths,
/// transcripts, diffs, provider events, and session URLs belong in the local
/// job vault and must never be added to this envelope.
public struct AgentJobEnvelope: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var moveID: UUID
    public var attemptID: UUID
    public var parentAttemptID: UUID?
    public var provider: AgentProvider
    public var surface: AgentExecutionSurface
    public var origin: AgentJobOrigin
    public private(set) var state: AgentJobState
    public var createdAt: Date
    public private(set) var updatedAt: Date
    public private(set) var startedAt: Date?
    public private(set) var finishedAt: Date?
    public var eventCount: Int
    public var artifactCount: Int
    public var approvalRequestCount: Int

    public init(
        id: UUID = UUID(),
        moveID: UUID,
        attemptID: UUID = UUID(),
        parentAttemptID: UUID? = nil,
        provider: AgentProvider,
        surface: AgentExecutionSurface,
        origin: AgentJobOrigin,
        state: AgentJobState = .notRequested,
        createdAt: Date,
        updatedAt: Date? = nil,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        eventCount: Int = 0,
        artifactCount: Int = 0,
        approvalRequestCount: Int = 0
    ) {
        precondition(surface.provider == provider, "Execution surface must match its provider")
        self.id = id
        self.moveID = moveID
        self.attemptID = attemptID
        self.parentAttemptID = parentAttemptID
        self.provider = provider
        self.surface = surface
        self.origin = origin
        self.state = state
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.eventCount = eventCount
        self.artifactCount = artifactCount
        self.approvalRequestCount = approvalRequestCount
    }

    public mutating func transition(to next: AgentJobState, at timestamp: Date) throws {
        guard state.canTransition(to: next) else {
            throw AgentJobTransitionError.invalid(from: state, to: next)
        }

        state = next
        updatedAt = timestamp

        if next == .running, startedAt == nil {
            startedAt = timestamp
        }

        if next.isTerminal {
            finishedAt = timestamp
        }
    }
}
