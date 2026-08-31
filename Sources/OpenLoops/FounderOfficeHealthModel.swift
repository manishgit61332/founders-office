import AppKit
import Combine
import FounderOfficeCloud
import FounderOfficeCore
import Foundation
import ServiceManagement

@MainActor
final class FounderOfficeHealthModel: ObservableObject {
    private let store: OpenLoopStore
    private let personalization: PersonalizationStore
    private let calendar: CalendarProvider
    private let assistant: CodexRunner
    private let cloud: CloudSyncBridge?
    private var cancellables = Set<AnyCancellable>()

    init(
        store: OpenLoopStore,
        personalization: PersonalizationStore,
        calendar: CalendarProvider,
        assistant: CodexRunner,
        cloud: CloudSyncBridge?
    ) {
        self.store = store
        self.personalization = personalization
        self.calendar = calendar
        self.assistant = assistant
        self.cloud = cloud

        observe(store.objectWillChange)
        observe(personalization.objectWillChange)
        observe(calendar.objectWillChange)
        observe(assistant.objectWillChange)
        if let cloud {
            observe(cloud.objectWillChange)
        }
    }

    var snapshot: HealthSnapshot {
        HealthSnapshot(
            capturedAt: Date(),
            components: [
                localDataStatus,
                syncStatus,
                calendarStatus,
                startupStatus,
                assistantStatus
            ]
        )
    }

    func supportReport() -> RedactedSupportReport {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return RedactedSupportReport(
            snapshot: snapshot,
            metadata: SupportReportMetadata(
                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                    ?? "development",
                buildNumber: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
                    ?? "development",
                operatingSystemMajor: version.majorVersion,
                operatingSystemMinor: version.minorVersion,
                operatingSystemPatch: version.patchVersion,
                architecture: Self.architecture
            )
        )
    }

    func perform(_ remediation: HealthRemediation) {
        switch remediation {
        case .none:
            break
        case .reloadLocalData:
            store.reload()
            personalization.reload()
        case .retrySync:
            guard let cloud else { return }
            Task { @MainActor [weak self] in
                await cloud.retrySync()
                self?.objectWillChange.send()
            }
        case .refreshCalendar:
            calendar.refresh()
        case .openCalendarSettings:
            calendar.openPrivacySettings()
        case .openLoginItemsSettings:
            guard let url = URL(
                string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
            ) else { return }
            NSWorkspace.shared.open(url)
        case .recheckAssistant:
            objectWillChange.send()
        }
    }

    private var localDataStatus: HealthComponentStatus {
        let recovery = store.recoveryState.merging(personalization.recoveryState)
        if recovery.requiresRecovery {
            return HealthComponentStatus(
                component: .localData,
                condition: .attention,
                detail: "Preserved data needs review"
            )
        }

        let latest = [store.lastSavedAt, personalization.document.updatedAt]
            .compactMap { $0 }
            .max()
        return HealthComponentStatus(
            component: .localData,
            condition: .ready,
            detail: "Workspace is readable",
            lastSuccessAt: latest,
            remediation: .reloadLocalData
        )
    }

    private var syncStatus: HealthComponentStatus {
        guard let cloud else {
            return HealthComponentStatus(
                component: .sync,
                condition: .off,
                detail: "Stored on this Mac"
            )
        }

        let condition: HealthCondition
        let detail: String
        let remediation: HealthRemediation
        switch cloud.status {
        case .preparing:
            condition = .working
            detail = "Preparing iCloud"
            remediation = .none
        case .syncing:
            condition = .working
            detail = "Uploading changes"
            remediation = .none
        case .ready:
            condition = .ready
            detail = "iCloud is current"
            remediation = .retrySync
        case .offline:
            condition = .attention
            detail = "Waiting for a connection"
            remediation = .retrySync
        case .accountReviewRequired:
            condition = .attention
            detail = "Review the iCloud account"
            remediation = .none
        case .error:
            condition = .attention
            detail = "iCloud needs another try"
            remediation = .retrySync
        }
        return HealthComponentStatus(
            component: .sync,
            condition: condition,
            detail: detail,
            lastSuccessAt: cloud.lastSuccessfulSyncAt,
            remediation: remediation
        )
    }

    private var calendarStatus: HealthComponentStatus {
        if calendar.isAuthorized {
            return HealthComponentStatus(
                component: .calendar,
                condition: .ready,
                detail: "System calendars are live",
                lastSuccessAt: calendar.lastSyncedAt,
                remediation: .refreshCalendar
            )
        }
        return HealthComponentStatus(
            component: .calendar,
            condition: calendar.isDenied ? .attention : .off,
            detail: calendar.isDenied ? "Access is turned off" : "Not connected",
            remediation: .openCalendarSettings
        )
    }

    private var startupStatus: HealthComponentStatus {
        guard #available(macOS 13.0, *) else {
            return HealthComponentStatus(
                component: .startup,
                condition: .off,
                detail: "Unavailable on this macOS"
            )
        }

        if SMAppService.mainApp.status == .enabled {
            return HealthComponentStatus(
                component: .startup,
                condition: .ready,
                detail: "Opens when you log in",
                remediation: .openLoginItemsSettings
            )
        }
        if SMAppService.mainApp.status == .requiresApproval {
            return HealthComponentStatus(
                component: .startup,
                condition: .attention,
                detail: "Approval is waiting in Settings",
                remediation: .openLoginItemsSettings
            )
        }
        return HealthComponentStatus(
            component: .startup,
            condition: .off,
            detail: "Launch at login is off",
            remediation: .openLoginItemsSettings
        )
    }

    private var assistantStatus: HealthComponentStatus {
        guard assistant.isAvailable else {
            return HealthComponentStatus(
                component: .assistant,
                condition: .off,
                detail: "Not included in this build"
            )
        }

        switch assistant.state {
        case .idle:
            return HealthComponentStatus(
                component: .assistant,
                condition: .ready,
                detail: "Ready for approved work",
                lastSuccessAt: assistant.lastSuccessfulRunAt,
                remediation: .recheckAssistant
            )
        case .running:
            return HealthComponentStatus(
                component: .assistant,
                condition: .working,
                detail: "Preparing a local result",
                lastSuccessAt: assistant.lastSuccessfulRunAt
            )
        case .finished:
            return HealthComponentStatus(
                component: .assistant,
                condition: .ready,
                detail: "Latest local run finished",
                lastSuccessAt: assistant.lastSuccessfulRunAt,
                remediation: .recheckAssistant
            )
        case .failed:
            return HealthComponentStatus(
                component: .assistant,
                condition: .attention,
                detail: "Latest local run stopped",
                lastSuccessAt: assistant.lastSuccessfulRunAt,
                remediation: .recheckAssistant
            )
        }
    }

    private func observe(_ publisher: ObservableObjectPublisher) {
        publisher
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    private static var architecture: SupportArchitecture {
        #if arch(arm64)
        .arm64
        #elseif arch(x86_64)
        .x86_64
        #else
        .unknown
        #endif
    }
}
