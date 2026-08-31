import Foundation

/// The five bounded checks shown by the Mac Health surface. These identifiers
/// are deliberately structural: they never contain a Move, event, person,
/// account, file, or workspace name.
public enum HealthComponent: String, CaseIterable, Codable, Hashable, Sendable {
    case localData = "local_data"
    case sync
    case calendar
    case startup
    case assistant

    public var title: String {
        switch self {
        case .localData: return "Local data"
        case .sync: return "Sync"
        case .calendar: return "Calendar"
        case .startup: return "Startup"
        case .assistant: return "Assistant"
        }
    }
}

public enum HealthCondition: String, Codable, Hashable, Sendable {
    case ready
    case working
    case attention
    case off
}

/// Only bounded, reversible actions can be surfaced from Health. Canonical
/// data repair, credential changes, permission grants, and code updates are
/// intentionally absent.
public enum HealthRemediation: String, CaseIterable, Codable, Hashable, Sendable {
    case none
    case reloadLocalData = "reload_local_data"
    case retrySync = "retry_sync"
    case refreshCalendar = "refresh_calendar"
    case openCalendarSettings = "open_calendar_settings"
    case openLoginItemsSettings = "open_login_items_settings"
    case recheckAssistant = "recheck_assistant"

    public var title: String? {
        switch self {
        case .none: return nil
        case .reloadLocalData: return "Reload"
        case .retrySync: return "Try again"
        case .refreshCalendar: return "Refresh"
        case .openCalendarSettings: return "Open Settings"
        case .openLoginItemsSettings: return "Login Items"
        case .recheckAssistant: return "Check again"
        }
    }
}

public struct HealthComponentStatus: Equatable, Codable, Sendable, Identifiable {
    public var id: HealthComponent { component }
    public var component: HealthComponent
    public var condition: HealthCondition
    public var detail: String
    public var lastSuccessAt: Date?
    public var remediation: HealthRemediation

    public init(
        component: HealthComponent,
        condition: HealthCondition,
        detail: String,
        lastSuccessAt: Date? = nil,
        remediation: HealthRemediation = .none
    ) {
        self.component = component
        self.condition = condition
        self.detail = detail
        self.lastSuccessAt = lastSuccessAt
        self.remediation = remediation
    }
}

public struct HealthSnapshot: Equatable, Codable, Sendable {
    public var capturedAt: Date
    public var components: [HealthComponentStatus]

    public init(capturedAt: Date, components: [HealthComponentStatus]) {
        self.capturedAt = capturedAt
        var byComponent: [HealthComponent: HealthComponentStatus] = [:]
        for component in components {
            byComponent[component.component] = component
        }
        self.components = HealthComponent.allCases.compactMap { byComponent[$0] }
    }

    public subscript(_ component: HealthComponent) -> HealthComponentStatus? {
        components.first { $0.component == component }
    }
}

public enum SupportArchitecture: String, Equatable, Sendable {
    case arm64
    case x86_64
    case unknown
}

public struct SupportReportMetadata: Equatable, Sendable {
    public let appVersion: String
    public let buildNumber: String
    public let operatingSystem: String
    public let architecture: String

    public init(
        appVersion: String,
        buildNumber: String,
        operatingSystemMajor: Int,
        operatingSystemMinor: Int,
        operatingSystemPatch: Int,
        architecture: SupportArchitecture
    ) {
        self.appVersion = Self.versionIdentifier(appVersion)
        self.buildNumber = Self.buildIdentifier(buildNumber)
        self.operatingSystem = "macOS-\(Self.bounded(operatingSystemMajor)).\(Self.bounded(operatingSystemMinor)).\(Self.bounded(operatingSystemPatch))"
        self.architecture = architecture.rawValue
    }

    private static func versionIdentifier(_ value: String) -> String {
        if value == "development" { return value }
        guard !value.isEmpty,
              value.count <= 32,
              value.contains(where: \.isNumber),
              value.allSatisfy({ $0.isNumber || $0 == "." }) else { return "unknown" }
        return value
    }

    private static func buildIdentifier(_ value: String) -> String {
        if value == "development" { return value }
        guard !value.isEmpty,
              value.count <= 20,
              value.allSatisfy(\.isNumber) else { return "unknown" }
        return value
    }

    private static func bounded(_ value: Int) -> Int {
        min(max(value, 0), 9_999)
    }
}

public struct SupportReportField: Equatable, Sendable, Identifiable {
    public var id: String { key }
    public let key: String
    public let value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}

/// A strict allow-list support report. It has no API for arbitrary log text or
/// metadata, so task/calendar titles, names, paths, prompts, and tokens cannot
/// enter the export accidentally.
public struct RedactedSupportReport: Equatable, Sendable {
    public static let fieldKeys = [
        "support_report_version",
        "incident_id",
        "captured_at_utc",
        "app_version",
        "build_number",
        "platform",
        "operating_system",
        "architecture",
        "local_data_state",
        "local_data_last_success_utc",
        "sync_state",
        "sync_last_success_utc",
        "calendar_state",
        "calendar_last_success_utc",
        "startup_state",
        "assistant_state"
    ]

    public let fields: [SupportReportField]

    public init(
        snapshot: HealthSnapshot,
        metadata: SupportReportMetadata,
        incidentID: UUID = UUID()
    ) {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime]

        func condition(_ component: HealthComponent) -> String {
            snapshot[component]?.condition.rawValue ?? "unknown"
        }

        func lastSuccess(_ component: HealthComponent) -> String {
            snapshot[component]?.lastSuccessAt.map(dateFormatter.string) ?? "never"
        }

        fields = [
            SupportReportField(key: "support_report_version", value: "1"),
            SupportReportField(key: "incident_id", value: incidentID.uuidString.lowercased()),
            SupportReportField(key: "captured_at_utc", value: dateFormatter.string(from: snapshot.capturedAt)),
            SupportReportField(key: "app_version", value: metadata.appVersion),
            SupportReportField(key: "build_number", value: metadata.buildNumber),
            SupportReportField(key: "platform", value: "macos"),
            SupportReportField(key: "operating_system", value: metadata.operatingSystem),
            SupportReportField(key: "architecture", value: metadata.architecture),
            SupportReportField(key: "local_data_state", value: condition(.localData)),
            SupportReportField(key: "local_data_last_success_utc", value: lastSuccess(.localData)),
            SupportReportField(key: "sync_state", value: condition(.sync)),
            SupportReportField(key: "sync_last_success_utc", value: lastSuccess(.sync)),
            SupportReportField(key: "calendar_state", value: condition(.calendar)),
            SupportReportField(key: "calendar_last_success_utc", value: lastSuccess(.calendar)),
            SupportReportField(key: "startup_state", value: condition(.startup)),
            SupportReportField(key: "assistant_state", value: condition(.assistant))
        ]
    }

    public func encodedJSON() throws -> Data {
        precondition(fields.map(\.key) == Self.fieldKeys)
        let object = Dictionary(uniqueKeysWithValues: fields.map { ($0.key, $0.value) })
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
    }
}
