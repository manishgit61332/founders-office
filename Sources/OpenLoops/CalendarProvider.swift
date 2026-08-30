import Combine
import EventKit
import Foundation

#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

struct CalendarAccountSignal: Identifiable, Hashable {
    var id: String
    var title: String
    var providerTitle: String
    var calendarCount: Int
}

struct CalendarSignal: Identifiable, Hashable {
    var id: String
    var title: String
    var startDate: Date
    var isAllDay: Bool
    var calendarTitle: String
    var accountTitle: String
    var providerTitle: String

    var sourceLabel: String {
        if accountTitle.localizedCaseInsensitiveCompare(calendarTitle) == .orderedSame {
            return accountTitle
        }
        return "\(accountTitle) · \(calendarTitle)"
    }
}

@MainActor
final class CalendarProvider: ObservableObject {
    @Published private(set) var authorizationStatus: EKAuthorizationStatus
    @Published private(set) var events: [CalendarSignal] = []
    @Published private(set) var accounts: [CalendarAccountSignal] = []
    @Published private(set) var message = "Calendar is off"
    @Published private(set) var lastSyncedAt: Date?

    private let eventStore = EKEventStore()
    private var cancellables = Set<AnyCancellable>()

    init() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        startLiveSync()

        if ProcessInfo.processInfo.environment["OPENLOOPS_PREVIEW_CALENDAR"] == "1" {
            seedPreviewEvents()
        } else if isAuthorized {
            refresh()
        }
    }

    var isAuthorized: Bool {
        authorizationStatus == .fullAccess
    }

    var isDenied: Bool {
        authorizationStatus == .denied || authorizationStatus == .restricted
    }

    var accountCountLabel: String {
        switch accounts.count {
        case 0: return "No calendar accounts"
        case 1: return "1 account"
        default: return "\(accounts.count) accounts"
        }
    }

    func requestAccess() {
        guard authorizationStatus == .notDetermined || authorizationStatus == .writeOnly else {
            if isDenied { openPrivacySettings() }
            if isAuthorized { refresh() }
            return
        }

        Task {
            do {
                let granted = try await eventStore.requestFullAccessToEvents()
                authorizationStatus = EKEventStore.authorizationStatus(for: .event)
                message = granted ? "Calendar live" : "Calendar access denied"
                if granted { refresh() }
            } catch {
                authorizationStatus = EKEventStore.authorizationStatus(for: .event)
                message = "Couldn’t connect Calendar"
                AppDiagnostics.failure(.calendarAuthorizationRequest, category: .calendar, error: error)
            }
        }
    }

    func syncOnOpen() {
        guard ProcessInfo.processInfo.environment["OPENLOOPS_PREVIEW_CALENDAR"] != "1" else { return }
        refresh()
    }

    func connectOrOpenSettings() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        if isAuthorized {
            refresh()
        } else if isDenied || authorizationStatus == .writeOnly {
            openPrivacySettings()
        } else {
            requestAccess()
        }
    }

    /// EventKit is the native aggregation layer. It exposes every calendar
    /// enabled in macOS Internet Accounts, including multiple Google accounts
    /// and iCloud, through one permission and one event database.
    func refresh() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        guard isAuthorized else {
            events = []
            accounts = []
            lastSyncedAt = nil
            message = isDenied ? "Calendar access denied" : "Calendar is off"
            return
        }

        eventStore.refreshSourcesIfNecessary()
        refreshAccounts()

        let startDate = Calendar.current.startOfDay(for: Date())
        let endDate = Calendar.current.date(byAdding: .day, value: 30, to: startDate) ?? startDate
        let predicate = eventStore.predicateForEvents(withStart: startDate, end: endDate, calendars: nil)
        events = eventStore.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .enumerated()
            .map { index, event in
                let source = event.calendar.source
                return CalendarSignal(
                    id: event.eventIdentifier ?? "event-\(index)-\(event.startDate.timeIntervalSince1970)",
                    title: event.title?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? "Untitled event",
                    startDate: event.startDate,
                    isAllDay: event.isAllDay,
                    calendarTitle: event.calendar.title,
                    accountTitle: source.map(displayTitle(for:)) ?? event.calendar.title,
                    providerTitle: source.map(providerTitle(for:)) ?? "Calendar"
                )
            }

        lastSyncedAt = Date()
        if accounts.isEmpty {
            message = events.isEmpty ? "Calendar live · no events" : "Calendar live"
        } else {
            message = "Live · \(accountCountLabel)"
        }
    }

    func openPrivacySettings() {
#if os(macOS)
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") else { return }
        NSWorkspace.shared.open(url)
#elseif os(iOS)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
#endif
    }

    func openInternetAccounts() {
#if os(macOS)
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preferences.internetaccounts") else { return }
        NSWorkspace.shared.open(url)
#elseif os(iOS)
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
#endif
    }

    private func startLiveSync() {
        NotificationCenter.default.publisher(for: .EKEventStoreChanged)
            .debounce(for: .milliseconds(180), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.syncOnOpen()
            }
            .store(in: &cancellables)

#if os(macOS)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.syncOnOpen()
            }
            .store(in: &cancellables)
#elseif os(iOS)
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.syncOnOpen()
            }
            .store(in: &cancellables)
#endif

        Timer.publish(every: 60, tolerance: 5, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.syncOnOpen()
            }
            .store(in: &cancellables)
    }

    private func refreshAccounts() {
        let eventCalendars = eventStore.calendars(for: .event)
        let grouped = Dictionary(grouping: eventCalendars) { $0.source.sourceIdentifier }

        accounts = grouped.compactMap { sourceIdentifier, calendars in
            guard let source = calendars.first?.source else { return nil }
            return CalendarAccountSignal(
                id: sourceIdentifier,
                title: displayTitle(for: source),
                providerTitle: providerTitle(for: source),
                calendarCount: calendars.count
            )
        }
        .sorted {
            if $0.providerTitle == $1.providerTitle {
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            return $0.providerTitle.localizedCaseInsensitiveCompare($1.providerTitle) == .orderedAscending
        }
    }

    private func displayTitle(for source: EKSource) -> String {
        let cleanTitle = source.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleanTitle.nonEmpty ?? providerTitle(for: source)
    }

    private func providerTitle(for source: EKSource) -> String {
        let normalizedTitle = source.title.lowercased()
        if normalizedTitle.contains("google") || normalizedTitle.contains("gmail") {
            return "Google"
        }
        if normalizedTitle.contains("icloud") {
            return "iCloud"
        }

        switch source.sourceType {
        case .local: return "On My Mac"
        case .exchange: return "Exchange"
        case .calDAV: return "CalDAV"
        case .mobileMe: return "iCloud"
        case .subscribed: return "Subscribed"
        case .birthdays: return "Birthdays"
        @unknown default: return "Calendar"
        }
    }

    private func seedPreviewEvents() {
        let now = Date()
        authorizationStatus = .fullAccess
        accounts = [
            CalendarAccountSignal(id: "preview-google-work", title: "work@company.com", providerTitle: "Google", calendarCount: 3),
            CalendarAccountSignal(id: "preview-google-personal", title: "founder@example.com", providerTitle: "Google", calendarCount: 2),
            CalendarAccountSignal(id: "preview-icloud", title: "iCloud", providerTitle: "iCloud", calendarCount: 2)
        ]
        events = [
            CalendarSignal(
                id: "preview-1",
                title: "Product review",
                startDate: Calendar.current.date(byAdding: .hour, value: 3, to: now) ?? now,
                isAllDay: false,
                calendarTitle: "Work",
                accountTitle: "work@company.com",
                providerTitle: "Google"
            ),
            CalendarSignal(
                id: "preview-2",
                title: "Design partner call",
                startDate: Calendar.current.date(byAdding: .day, value: 2, to: now) ?? now,
                isAllDay: false,
                calendarTitle: "Founder",
                accountTitle: "founder@example.com",
                providerTitle: "Google"
            ),
            CalendarSignal(
                id: "preview-3",
                title: "Family dinner",
                startDate: Calendar.current.date(byAdding: .day, value: 4, to: now) ?? now,
                isAllDay: false,
                calendarTitle: "Home",
                accountTitle: "iCloud",
                providerTitle: "iCloud"
            )
        ]
        lastSyncedAt = now
        message = "Live · 3 accounts"
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
