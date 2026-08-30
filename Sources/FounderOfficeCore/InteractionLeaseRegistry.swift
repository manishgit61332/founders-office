import Foundation

/// Tracks overlapping transient interactions without allowing one control to
/// release another control's hold-open state.
public struct InteractionLeaseRegistry: Sendable {
    private var reasons: [UUID: String] = [:]

    public init() {}

    public var isActive: Bool { !reasons.isEmpty }
    public var count: Int { reasons.count }

    @discardableResult
    public mutating func begin(_ reason: String) -> UUID {
        let lease = UUID()
        reasons[lease] = reason
        return lease
    }

    public mutating func end(_ lease: UUID) {
        reasons.removeValue(forKey: lease)
    }

    public mutating func clear() {
        reasons.removeAll()
    }
}
