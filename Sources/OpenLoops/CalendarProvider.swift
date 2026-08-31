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
    var endDate: Date
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

struct CalendarDestinationSignal: Identifiable, Hashable {
    var id: String
    var title: String
    var accountTitle: String
    var providerTitle: String

    /// Includes all three levels so two Google accounts with calendars that
    /// share a name remain distinguishable in a compact picker.
    var displayLabel: String {
        "\(providerTitle) · \(accountTitle) · \(title)"
    }
}

enum CalendarEventCreationError: LocalizedError, Equatable {
    case calendarAccessRequired
    case missingTitle
    case invalidDateRange
    case noWritableCalendar
    case calendarUnavailable
    case calendarReadOnly
    case saveFailed

    var errorDescription: String? {
        switch self {
        case .calendarAccessRequired:
            return "Allow full Calendar access before adding an event."
        case .missingTitle:
            return "Give the event a title."
        case .invalidDateRange:
            return "The event must end after it starts."
        case .noWritableCalendar:
            return "No calendar on this Mac can accept new events."
        case .calendarUnavailable:
            return "That calendar is no longer available. Choose another calendar."
        case .calendarReadOnly:
            return "That calendar is read-only. Choose another calendar."
        case .saveFailed:
            return "The event couldn’t be added. Try again."
        }
    }
}

@MainActor
final class CalendarProvider: ObservableObject {
    enum Mode {
        case live
        case syntheticPreview
    }

    @Published private(set) var authorizationStatus: EKAuthorizationStatus
    @Published private(set) var events: [CalendarSignal] = []
    @Published private(set) var accounts: [CalendarAccountSignal] = []
    @Published private(set) var writableDestinations: [CalendarDestinationSignal] = []
    @Published private(set) var recommendedDestinationID: String?
    @Published private(set) var message = "Calendar is off"
    @Published private(set) var lastSyncedAt: Date?

    private let eventStore = EKEventStore()
    private let mode: Mode
    private var cancellables = Set<AnyCancellable>()
    private let preferredDestinationDefaultsKey = "founders-office.calendar.preferred-destination"

    init(mode requestedMode: Mode = .live) {
        #if FOUNDER_OFFICE_DISTRIBUTION
        mode = requestedMode
        #else
        mode = ProcessInfo.processInfo.environment["OPENLOOPS_PREVIEW_CALENDAR"] == "1"
            ? .syntheticPreview
            : requestedMode
        #endif
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)

        if mode == .syntheticPreview {
            seedPreviewEvents()
        } else {
            startLiveSync()
        }

        if mode == .live, isAuthorized {
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

        // The completion API keeps the non-Sendable EKEventStore on the main
        // actor. Xcode 16.4's async overlay otherwise transfers it to a
        // nonisolated executor and correctly fails strict concurrency checks.
        eventStore.requestFullAccessToEvents { [weak self] granted, error in
            let failure = error.map {
                let value = $0 as NSError
                return (value.domain, value.code)
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                authorizationStatus = EKEventStore.authorizationStatus(for: .event)
                if let failure {
                    message = "Couldn’t connect Calendar"
                    AppDiagnostics.failure(
                        .calendarAuthorizationRequest,
                        category: .calendar,
                        domain: failure.0,
                        code: failure.1
                    )
                } else {
                    message = granted ? "Calendar live" : "Calendar access denied"
                    if granted { refresh() }
                }
            }
        }
    }

    func syncOnOpen() {
        guard mode == .live else { return }
        refresh()
    }

    /// Adds an event to one of EventKit's writable calendars. EventKit remains
    /// the source of truth, so Google, iCloud, Exchange, and local calendars
    /// keep using their existing system sync behavior.
    @discardableResult
    func createEvent(
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        calendarIdentifier: String?
    ) -> Result<Void, CalendarEventCreationError> {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else {
            return .failure(.missingTitle)
        }

        let normalizedDates: (start: Date, end: Date)
        if isAllDay {
            let calendar = Calendar.current
            let normalizedStart = calendar.startOfDay(for: startDate)
            let selectedEndDay = calendar.startOfDay(for: endDate)
            guard selectedEndDay >= normalizedStart,
                  let normalizedEnd = calendar.date(byAdding: .day, value: 1, to: selectedEndDay) else {
                return .failure(.invalidDateRange)
            }
            normalizedDates = (normalizedStart, normalizedEnd)
        } else {
            guard endDate > startDate else {
                return .failure(.invalidDateRange)
            }
            normalizedDates = (startDate, endDate)
        }

        if mode == .syntheticPreview {
            return createSyntheticPreviewEvent(
                title: cleanTitle,
                startDate: normalizedDates.start,
                endDate: normalizedDates.end,
                isAllDay: isAllDay,
                calendarIdentifier: calendarIdentifier
            )
        }

        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        guard isAuthorized else {
            return .failure(.calendarAccessRequired)
        }

        refreshWritableDestinations()
        let destinationID = calendarIdentifier ?? recommendedDestinationID
        guard let destinationID else {
            return .failure(.noWritableCalendar)
        }
        guard let selectedSignal = writableDestinations.first(where: { $0.id == destinationID }),
              let destination = eventStore.calendar(withIdentifier: selectedSignal.id) else {
            return .failure(.calendarUnavailable)
        }
        guard destination.allowsContentModifications else {
            refreshWritableDestinations()
            return .failure(.calendarReadOnly)
        }

        let event = EKEvent(eventStore: eventStore)
        event.title = cleanTitle
        event.startDate = normalizedDates.start
        event.endDate = normalizedDates.end
        event.isAllDay = isAllDay
        event.calendar = destination

        do {
            try eventStore.save(event, span: .thisEvent, commit: true)
            UserDefaults.standard.set(destinationID, forKey: preferredDestinationDefaultsKey)
            AppDiagnostics.event(.calendarEventSave, category: .calendar, outcome: .success)
            refresh()
            return .success(())
        } catch {
            AppDiagnostics.failure(.calendarEventSave, category: .calendar, error: error)
            return .failure(.saveFailed)
        }
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
        guard mode == .live else { return }
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        guard isAuthorized else {
            events = []
            accounts = []
            writableDestinations = []
            recommendedDestinationID = nil
            lastSyncedAt = nil
            message = isDenied ? "Calendar access denied" : "Calendar is off"
            return
        }

        eventStore.refreshSourcesIfNecessary()
        refreshAccounts()
        refreshWritableDestinations()

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
                    endDate: event.endDate ?? event.startDate,
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

    private func refreshWritableDestinations() {
        let calendars = eventStore.calendars(for: .event)
            .filter(\.allowsContentModifications)

        writableDestinations = calendars.map { calendar in
            let source = calendar.source
            return CalendarDestinationSignal(
                id: calendar.calendarIdentifier,
                title: calendar.title,
                accountTitle: source.map(displayTitle(for:)) ?? calendar.title,
                providerTitle: source.map(providerTitle(for:)) ?? "Calendar"
            )
        }
        .sorted {
            if $0.providerTitle != $1.providerTitle {
                return $0.providerTitle.localizedCaseInsensitiveCompare($1.providerTitle) == .orderedAscending
            }
            if $0.accountTitle != $1.accountTitle {
                return $0.accountTitle.localizedCaseInsensitiveCompare($1.accountTitle) == .orderedAscending
            }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }

        let savedIdentifier = UserDefaults.standard.string(forKey: preferredDestinationDefaultsKey)
        if let savedIdentifier,
           writableDestinations.contains(where: { $0.id == savedIdentifier }) {
            recommendedDestinationID = savedIdentifier
        } else if let systemDefault = eventStore.defaultCalendarForNewEvents,
                  systemDefault.allowsContentModifications,
                  writableDestinations.contains(where: { $0.id == systemDefault.calendarIdentifier }) {
            recommendedDestinationID = systemDefault.calendarIdentifier
        } else {
            recommendedDestinationID = writableDestinations.first?.id
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
        writableDestinations = [
            CalendarDestinationSignal(id: "preview-work", title: "Work", accountTitle: "work@company.com", providerTitle: "Google"),
            CalendarDestinationSignal(id: "preview-founder", title: "Founder", accountTitle: "founder@example.com", providerTitle: "Google"),
            CalendarDestinationSignal(id: "preview-home", title: "Home", accountTitle: "iCloud", providerTitle: "iCloud")
        ]
        recommendedDestinationID = "preview-work"
        events = [
            CalendarSignal(
                id: "preview-1",
                title: "Product review",
                startDate: Calendar.current.date(byAdding: .hour, value: 3, to: now) ?? now,
                endDate: Calendar.current.date(byAdding: .hour, value: 4, to: now) ?? now,
                isAllDay: false,
                calendarTitle: "Work",
                accountTitle: "work@company.com",
                providerTitle: "Google"
            ),
            CalendarSignal(
                id: "preview-2",
                title: "Design partner call",
                startDate: Calendar.current.date(byAdding: .day, value: 2, to: now) ?? now,
                endDate: Calendar.current.date(byAdding: .hour, value: 1, to: Calendar.current.date(byAdding: .day, value: 2, to: now) ?? now) ?? now,
                isAllDay: false,
                calendarTitle: "Founder",
                accountTitle: "founder@example.com",
                providerTitle: "Google"
            ),
            CalendarSignal(
                id: "preview-3",
                title: "Family dinner",
                startDate: Calendar.current.date(byAdding: .day, value: 4, to: now) ?? now,
                endDate: Calendar.current.date(byAdding: .hour, value: 2, to: Calendar.current.date(byAdding: .day, value: 4, to: now) ?? now) ?? now,
                isAllDay: false,
                calendarTitle: "Home",
                accountTitle: "iCloud",
                providerTitle: "iCloud"
            )
        ]
        lastSyncedAt = now
        message = "Live · 3 accounts"
    }

    private func createSyntheticPreviewEvent(
        title: String,
        startDate: Date,
        endDate: Date,
        isAllDay: Bool,
        calendarIdentifier: String?
    ) -> Result<Void, CalendarEventCreationError> {
        let destinationID = calendarIdentifier ?? recommendedDestinationID
        guard let destinationID,
              let destination = writableDestinations.first(where: { $0.id == destinationID }) else {
            return .failure(.calendarUnavailable)
        }

        // Preview builds mutate only this in-memory fixture. They never write
        // to a user's EventKit database.
        events.append(
            CalendarSignal(
                id: "preview-created-\(UUID().uuidString)",
                title: title,
                startDate: startDate,
                endDate: endDate,
                isAllDay: isAllDay,
                calendarTitle: destination.title,
                accountTitle: destination.accountTitle,
                providerTitle: destination.providerTitle
            )
        )
        events.sort { $0.startDate < $1.startDate }
        recommendedDestinationID = destinationID
        lastSyncedAt = Date()
        return .success(())
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
