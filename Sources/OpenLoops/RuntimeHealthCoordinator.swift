import Foundation
import MetricKit

/// Coordinates local-only runtime health signals for the macOS process.
/// MetricKit payload contents are never persisted or transmitted; only bounded
/// batch counts are recorded in Apple Unified Logging.
final class RuntimeHealthCoordinator: NSObject, MXMetricManagerSubscriber {
    private static let extendedLaunchTaskID = MXLaunchTaskID(
        rawValue: "com.foundersoffice.launch.readiness"
    )

    private let crashLoopMarker: CrashLoopSafeModeMarker
    private var launchInterval: AppDiagnostics.IntervalToken?
    private var tracksCrashLoop = false
    private var isSubscribed = false
    private var isExtendedLaunchMeasurementActive = false

    private(set) var disposition = CrashLoopSafeModeMarker.LaunchDisposition(
        isSafeMode: false,
        consecutivePreReadyFailures: 0,
        incidentID: nil
    )

    init(crashLoopMarker: CrashLoopSafeModeMarker = CrashLoopSafeModeMarker()) {
        self.crashLoopMarker = crashLoopMarker
        super.init()
    }

    func beginLaunch(trackCrashLoop: Bool) -> CrashLoopSafeModeMarker.LaunchDisposition {
        tracksCrashLoop = trackCrashLoop
        if trackCrashLoop {
            disposition = crashLoopMarker.beginLaunch()
        }

        // Persist the pre-ready marker before initializing any diagnostic
        // framework. A failure in optional instrumentation must still count.
        launchInterval = AppDiagnostics.beginInterval(.applicationLaunch)
        subscribeToMetricKit()
        startExtendedLaunchMeasurement()

        if disposition.isSafeMode {
            AppDiagnostics.event(
                .safeModeEnter,
                category: .lifecycle,
                outcome: .safeMode,
                recoveryAttempt: disposition.consecutivePreReadyFailures,
                correlationID: disposition.incidentID
            )
        }
        return disposition
    }

    func markReady() {
        if tracksCrashLoop {
            crashLoopMarker.markReady()
        }
        finishExtendedLaunchMeasurement()

        if let launchInterval {
            AppDiagnostics.endInterval(
                launchInterval,
                outcome: disposition.isSafeMode ? .safeMode : .success
            )
            self.launchInterval = nil
        }
        AppDiagnostics.event(
            .applicationReady,
            category: .lifecycle,
            outcome: disposition.isSafeMode ? .safeMode : .success,
            correlationID: disposition.incidentID
        )
    }

    func prepareExplicitRetry() {
        let incidentID = disposition.incidentID
        crashLoopMarker.prepareExplicitRetry()
        disposition = crashLoopMarker.disposition
        AppDiagnostics.event(
            .safeModeRetry,
            category: .lifecycle,
            outcome: .success,
            recoveryAttempt: 1,
            correlationID: incidentID
        )
    }

    func stop() {
        if isSubscribed {
            MXMetricManager.shared.remove(self)
            isSubscribed = false
        }
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        AppDiagnostics.event(
            .metricPayloadReceive,
            category: .lifecycle,
            outcome: .success,
            count: payloads.count
        )
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        AppDiagnostics.event(
            .diagnosticPayloadReceive,
            category: .lifecycle,
            outcome: .success,
            count: payloads.count
        )
    }

    private func subscribeToMetricKit() {
        guard !isSubscribed else { return }
        MXMetricManager.shared.add(self)
        isSubscribed = true
    }

    private func startExtendedLaunchMeasurement() {
        guard #available(macOS 13.0, *) else { return }
        do {
            try MXMetricManager.extendLaunchMeasurement(
                forTaskID: Self.extendedLaunchTaskID
            )
            isExtendedLaunchMeasurementActive = true
        } catch {
            let error = error as NSError
            AppDiagnostics.failure(
                .applicationLaunch,
                category: .lifecycle,
                domain: error.domain,
                code: error.code
            )
        }
    }

    private func finishExtendedLaunchMeasurement() {
        guard #available(macOS 13.0, *), isExtendedLaunchMeasurementActive else { return }
        defer { isExtendedLaunchMeasurementActive = false }
        do {
            try MXMetricManager.finishExtendedLaunchMeasurement(
                forTaskID: Self.extendedLaunchTaskID
            )
        } catch {
            let error = error as NSError
            AppDiagnostics.failure(
                .applicationReady,
                category: .lifecycle,
                domain: error.domain,
                code: error.code
            )
        }
    }
}
