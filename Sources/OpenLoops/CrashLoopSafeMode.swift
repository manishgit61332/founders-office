import Foundation

/// A preference-backed startup marker that is isolated from workspace data.
///
/// A launch is considered failed only when the previous process ended before
/// calling `markReady()`. Three such failures for the same build make the next
/// launch enter safe mode. Safe mode stays active until an explicit retry.
final class CrashLoopSafeModeMarker {
    struct LaunchDisposition: Equatable {
        let isSafeMode: Bool
        let consecutivePreReadyFailures: Int
        let incidentID: UUID?
    }

    private struct State: Codable {
        var buildIdentity: String
        var launchInProgress: Bool
        var consecutivePreReadyFailures: Int
        var safeModeEnabled: Bool
        var incidentID: UUID?
    }

    private static let stateKey = "FounderOffice.RuntimeHealth.CrashLoopState.v1"
    private static let failureThreshold = 3

    private let defaults: UserDefaults
    private let buildIdentity: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var state: State?
    private(set) var disposition = LaunchDisposition(
        isSafeMode: false,
        consecutivePreReadyFailures: 0,
        incidentID: nil
    )

    init(defaults: UserDefaults = .standard, bundle: Bundle = .main) {
        self.defaults = defaults
        buildIdentity = Self.buildIdentity(for: bundle)
    }

    func beginLaunch() -> LaunchDisposition {
        var current = loadState()
        if current.buildIdentity != buildIdentity {
            current = freshState()
        }

        if current.launchInProgress {
            current.consecutivePreReadyFailures = min(
                current.consecutivePreReadyFailures + 1,
                Self.failureThreshold
            )
        }

        if current.consecutivePreReadyFailures >= Self.failureThreshold {
            current.safeModeEnabled = true
            current.incidentID = current.incidentID ?? UUID()
        }

        current.launchInProgress = true
        state = current
        save(current)

        disposition = LaunchDisposition(
            isSafeMode: current.safeModeEnabled,
            consecutivePreReadyFailures: current.consecutivePreReadyFailures,
            incidentID: current.incidentID
        )
        return disposition
    }

    func markReady() {
        guard var current = state else { return }
        current.launchInProgress = false

        if !current.safeModeEnabled {
            current.consecutivePreReadyFailures = 0
            current.incidentID = nil
        }

        state = current
        save(current)
    }

    /// Records an AppKit-confirmed clean process exit without erasing crash
    /// evidence from earlier launches. A crash or force-quit never reaches this
    /// method, so its in-progress marker remains available to the next launch.
    func markCleanTermination() {
        guard var current = state else { return }
        current.launchInProgress = false
        state = current
        save(current)
    }

    func prepareExplicitRetry() {
        var current = state ?? loadState()
        current.launchInProgress = false
        current.consecutivePreReadyFailures = 0
        current.safeModeEnabled = false
        current.incidentID = nil
        state = current
        save(current)
        disposition = LaunchDisposition(
            isSafeMode: false,
            consecutivePreReadyFailures: 0,
            incidentID: nil
        )
    }

    private func loadState() -> State {
        guard let data = defaults.data(forKey: Self.stateKey),
              let decoded = try? decoder.decode(State.self, from: data) else {
            return freshState()
        }
        return decoded
    }

    private func save(_ state: State) {
        guard let data = try? encoder.encode(state) else { return }
        defaults.set(data, forKey: Self.stateKey)
        // This marker must survive a process that fails immediately after the
        // launch begins. It contains only derived health state, never content.
        defaults.synchronize()
    }

    private func freshState() -> State {
        State(
            buildIdentity: buildIdentity,
            launchInProgress: false,
            consecutivePreReadyFailures: 0,
            safeModeEnabled: false,
            incidentID: nil
        )
    }

    private static func buildIdentity(for bundle: Bundle) -> String {
        let identifier = bundle.bundleIdentifier ?? "unbundled"
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        return "\(identifier)|\(version)|\(build)"
    }
}
