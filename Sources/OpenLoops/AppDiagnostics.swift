import Foundation
import OSLog

/// Privacy-safe diagnostic logging for the macOS app.
///
/// Keep operation names finite and structural. Never pass task or calendar
/// titles, account names, file paths, prompts, message bodies, or other user
/// content to this layer.
enum AppDiagnostics {
    enum Category: String {
        case application
        case automation
        case calendar
        case lifecycle
        case resources
        case storage
        case update
    }

    enum Operation: String {
        case applicationLaunch = "application.launch"
        case applicationReady = "application.ready"
        case calendarAuthorizationRequest = "calendar.authorization.request"
        case calendarEventSave = "calendar.event.save"
        case cloudConfigurationLoad = "cloud.configuration.load"
        #if !FOUNDER_OFFICE_DISTRIBUTION
        case codexProcessStart = "codex.process.start"
        #endif
        case fontRegistration = "font.registration"
        case fontResourceLookup = "font.resource.lookup"
        case launchAtLoginRegister = "launch_at_login.register"
        case launchAtLoginUnregister = "launch_at_login.unregister"
        case diagnosticPayloadReceive = "metric.diagnostic.receive"
        case motionCaptureDirectoryCreate = "motion_capture.directory.create"
        case moveStoreLoad = "move_store.load"
        case moveStoreSave = "move_store.save"
        case personalizationLoad = "personalization.load"
        case personalizationPhotoImport = "personalization.photo.import"
        case personalizationPhotoExport = "personalization.photo.export"
        case personalizationPhotoCleanup = "personalization.photo.cleanup"
        case personalizationSave = "personalization.save"
        case reversalCaptureDirectoryCreate = "reversal_capture.directory.create"
        case safeModeEnter = "safe_mode.enter"
        case safeModeRetry = "safe_mode.retry"
        case snapshotCapture = "snapshot.capture"
        case supportReportSave = "support_report.save"
        case updateCheck = "update.check"
        case updateDownloadOpen = "update.download.open"
        case workspaceIdentitySave = "workspace_identity.save"
    }

    enum Outcome: String {
        case failure
        case safeMode = "safe_mode"
        case success
    }

    enum DurationBucket: String {
        case under16Milliseconds = "lt_16ms"
        case under100Milliseconds = "lt_100ms"
        case under250Milliseconds = "lt_250ms"
        case under1500Milliseconds = "lt_1500ms"
        case atLeast1500Milliseconds = "gte_1500ms"

        init(milliseconds: Double) {
            switch milliseconds {
            case ..<16: self = .under16Milliseconds
            case ..<100: self = .under100Milliseconds
            case ..<250: self = .under250Milliseconds
            case ..<1_500: self = .under1500Milliseconds
            default: self = .atLeast1500Milliseconds
            }
        }
    }

    enum Interval {
        case applicationLaunch
    }

    struct IntervalToken {
        fileprivate let interval: Interval
        fileprivate let state: OSSignpostIntervalState
        fileprivate let startedAt: TimeInterval
    }

    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.foundersoffice.app"

    private static let application = Logger(subsystem: subsystem, category: Category.application.rawValue)
    private static let automation = Logger(subsystem: subsystem, category: Category.automation.rawValue)
    private static let calendar = Logger(subsystem: subsystem, category: Category.calendar.rawValue)
    private static let lifecycle = Logger(subsystem: subsystem, category: Category.lifecycle.rawValue)
    private static let resources = Logger(subsystem: subsystem, category: Category.resources.rawValue)
    private static let storage = Logger(subsystem: subsystem, category: Category.storage.rawValue)
    private static let update = Logger(subsystem: subsystem, category: Category.update.rawValue)
    private static let lifecycleSignposter = OSSignposter(logger: lifecycle)

    static func beginInterval(_ interval: Interval) -> IntervalToken {
        let state: OSSignpostIntervalState
        switch interval {
        case .applicationLaunch:
            state = lifecycleSignposter.beginInterval("application.launch")
        }
        return IntervalToken(
            interval: interval,
            state: state,
            startedAt: ProcessInfo.processInfo.systemUptime
        )
    }

    static func endInterval(_ token: IntervalToken, outcome: Outcome) {
        switch token.interval {
        case .applicationLaunch:
            lifecycleSignposter.endInterval("application.launch", token.state)
        }

        let elapsedMilliseconds = max(
            0,
            (ProcessInfo.processInfo.systemUptime - token.startedAt) * 1_000
        )
        event(
            .applicationLaunch,
            category: .lifecycle,
            outcome: outcome,
            durationBucket: DurationBucket(milliseconds: elapsedMilliseconds)
        )
    }

    static func event(
        _ operation: Operation,
        category: Category,
        outcome: Outcome,
        durationBucket: DurationBucket? = nil,
        count: Int? = nil,
        recoveryAttempt: Int? = nil,
        correlationID: UUID? = nil
    ) {
        let duration = durationBucket?.rawValue ?? "none"
        let boundedCount = min(max(count ?? 0, 0), 9_999)
        let boundedAttempt = min(max(recoveryAttempt ?? 0, 0), 3)
        let correlation = correlationID?.uuidString.lowercased() ?? "none"
        logger(for: category).notice(
            "operation=\(operation.rawValue, privacy: .public) outcome=\(outcome.rawValue, privacy: .public) duration_bucket=\(duration, privacy: .public) count=\(boundedCount, privacy: .public) recovery_attempt=\(boundedAttempt, privacy: .public) correlation_id=\(correlation, privacy: .public)"
        )
    }

    static func failure(_ operation: Operation, category: Category, error: Error) {
        let error = error as NSError
        failure(operation, category: category, domain: error.domain, code: error.code)
    }

    static func failure(
        _ operation: Operation,
        category: Category,
        domain: String,
        code: Int
    ) {
        logger(for: category).error(
            "operation=\(operation.rawValue, privacy: .public) error_domain=\(domain, privacy: .public) error_code=\(code, privacy: .public)"
        )
    }

    private static func logger(for category: Category) -> Logger {
        switch category {
        case .application: application
        case .automation: automation
        case .calendar: calendar
        case .lifecycle: lifecycle
        case .resources: resources
        case .storage: storage
        case .update: update
        }
    }
}
