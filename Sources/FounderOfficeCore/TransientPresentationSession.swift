import Foundation

public enum TransientPresentationPhase: String, Codable, Equatable, Sendable {
    case idle
    case suspending
    case presenting
    case restoring
}

/// Reference-counted state for overlapping native and in-app transient UI.
/// The AppKit coordinator owns windows and focus; this value type keeps the
/// lifecycle deterministic and independently testable.
public struct TransientPresentationSession: Sendable {
    public private(set) var phase: TransientPresentationPhase = .idle
    public private(set) var hostWasExpanded = false
    public private(set) var hostSuspensionRequested = false

    private var leases = InteractionLeaseRegistry()

    public init() {}

    public var isActive: Bool { leases.isActive }
    public var activeCount: Int { leases.count }

    @discardableResult
    public mutating func begin(
        _ reason: String,
        hostIsExpanded: Bool,
        suspendsHost: Bool = false
    ) -> UUID {
        if !leases.isActive {
            phase = .presenting
        }
        if suspendsHost, !hostSuspensionRequested {
            phase = .suspending
            hostWasExpanded = hostIsExpanded
            hostSuspensionRequested = true
        }

        let lease = leases.begin(reason)
        phase = .presenting
        return lease
    }

    /// Returns `true` exactly when the last active presentation ended and the
    /// host should restore its expansion and keyboard focus.
    @discardableResult
    public mutating func end(_ lease: UUID) -> Bool {
        let countBefore = leases.count
        leases.end(lease)
        guard countBefore > 0, !leases.isActive else { return false }
        phase = .restoring
        return true
    }

    public mutating func finishRestoring() {
        guard !leases.isActive else { return }
        phase = .idle
        hostWasExpanded = false
        hostSuspensionRequested = false
    }

    public mutating func cancelAll() {
        leases.clear()
        phase = .idle
        hostWasExpanded = false
        hostSuspensionRequested = false
    }
}
