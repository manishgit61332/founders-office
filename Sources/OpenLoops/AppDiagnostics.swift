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
    }

    enum Operation: String {
        case calendarAuthorizationRequest = "calendar.authorization.request"
        case codexProcessStart = "codex.process.start"
        case fontRegistration = "font.registration"
        case fontResourceLookup = "font.resource.lookup"
        case launchAtLoginRegister = "launch_at_login.register"
        case launchAtLoginUnregister = "launch_at_login.unregister"
        case motionCaptureDirectoryCreate = "motion_capture.directory.create"
        case moveStoreLoad = "move_store.load"
        case moveStoreSave = "move_store.save"
        case personalizationLoad = "personalization.load"
        case personalizationPhotoImport = "personalization.photo.import"
        case personalizationSave = "personalization.save"
        case reversalCaptureDirectoryCreate = "reversal_capture.directory.create"
        case snapshotCapture = "snapshot.capture"
    }

    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.foundersoffice.app"

    private static let application = Logger(subsystem: subsystem, category: Category.application.rawValue)
    private static let automation = Logger(subsystem: subsystem, category: Category.automation.rawValue)
    private static let calendar = Logger(subsystem: subsystem, category: Category.calendar.rawValue)
    private static let lifecycle = Logger(subsystem: subsystem, category: Category.lifecycle.rawValue)
    private static let resources = Logger(subsystem: subsystem, category: Category.resources.rawValue)
    private static let storage = Logger(subsystem: subsystem, category: Category.storage.rawValue)

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
        }
    }
}
