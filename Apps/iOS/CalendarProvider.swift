import Combine
import EventKit
import FounderOfficeCore
import Foundation
import UIKit

struct DeviceCalendarAccount: Identifiable, Hashable {
    var id: String
    var name: String
    var calendarCount: Int
}

struct DeviceCalendarEvent: Identifiable, Hashable {
    var id: String
    var title: String
    var startDate: Date
    var endDate: Date
    var isAllDay: Bool
    var calendarName: String
    var accountName: String
    var isReferenceCalendar: Bool
    var involvesCurrentUser: Bool

    var upNextKind: CalendarEventPresentation.Kind {
        CalendarEventPresentation.kind(
            isAllDay: isAllDay,
            isReferenceCalendar: isReferenceCalendar,
            involvesCurrentUser: involvesCurrentUser
        )
    }
}

@MainActor
final class CalendarProvider: ObservableObject {
    @Published private(set) var authorizationStatus: EKAuthorizationStatus
    @Published private(set) var events: [DeviceCalendarEvent] = []
    @Published private(set) var accounts: [DeviceCalendarAccount] = []
    @Published private(set) var lastRefreshedAt: Date?

    private let eventStore = EKEventStore()
    private var cancellables = Set<AnyCancellable>()

    init() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        observeCalendarChanges()
        refreshIfAuthorized()
    }

    var hasReadAccess: Bool {
        authorizationStatus == .fullAccess
    }

    var isDenied: Bool {
        authorizationStatus == .denied || authorizationStatus == .restricted
    }

    var connectionTitle: String {
        if hasReadAccess { return "Calendar connected" }
        if isDenied { return "Review Calendar access" }
        return "Connect Calendar"
    }

    var upNextEvent: DeviceCalendarEvent? {
        CalendarEventPresentation.upNext(
            from: events,
            at: .now,
            startDate: \.startDate,
            endDate: \.endDate,
            kind: \.upNextKind
        )
    }

    /// EventKit keeps the user's choice. This method requests access only for a
    /// first-time decision; later calls refresh or open the system settings.
    func connectOrOpenSettings() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)

        if hasReadAccess {
            refresh()
        } else if authorizationStatus == .notDetermined {
            requestFullAccess()
        } else {
            openSystemSettings()
        }
    }

    func refreshIfAuthorized() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        if hasReadAccess {
            refresh()
        }
    }

    func refresh() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        guard hasReadAccess else {
            events = []
            accounts = []
            lastRefreshedAt = nil
            return
        }

        eventStore.refreshSourcesIfNecessary()
        let calendars = eventStore.calendars(for: .event)
        refreshAccounts(from: calendars)

        let start = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: 60, to: start) ?? start
        let predicate = eventStore.predicateForEvents(
            withStart: start,
            end: end,
            calendars: nil
        )

        events = eventStore.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .enumerated()
            .map { index, event in
                let accountName = event.calendar.source.title
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return DeviceCalendarEvent(
                    id: event.eventIdentifier
                        ?? "event-\(index)-\(event.startDate.timeIntervalSince1970)",
                    title: event.title?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                        ?? "Untitled event",
                    startDate: event.startDate,
                    endDate: event.endDate,
                    isAllDay: event.isAllDay,
                    calendarName: event.calendar.title,
                    accountName: accountName.nonEmpty ?? event.calendar.title,
                    isReferenceCalendar: event.calendar.isSubscribed
                        || event.calendar.type == .subscription
                        || event.calendar.type == .birthday
                        || !event.calendar.allowsContentModifications,
                    involvesCurrentUser: event.organizer?.isCurrentUser == true
                        || event.attendees?.contains(where: \.isCurrentUser) == true
                )
            }
        lastRefreshedAt = .now
    }

    private func requestFullAccess() {
        // Keep EKEventStore on MainActor; the async EventKit overlay in the
        // supported Xcode 16.4 SDK is not concurrency-safe under Swift 6.
        eventStore.requestFullAccessToEvents { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                authorizationStatus = EKEventStore.authorizationStatus(for: .event)
                refreshIfAuthorized()
            }
        }
    }

    private func refreshAccounts(from calendars: [EKCalendar]) {
        accounts = Dictionary(grouping: calendars, by: { $0.source.sourceIdentifier })
            .compactMap { sourceID, calendars in
                guard let source = calendars.first?.source else { return nil }
                let sourceName = source.title.trimmingCharacters(in: .whitespacesAndNewlines)
                return DeviceCalendarAccount(
                    id: sourceID,
                    name: sourceName.nonEmpty ?? "Calendar",
                    calendarCount: calendars.count
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func observeCalendarChanges() {
        NotificationCenter.default.publisher(for: .EKEventStoreChanged)
            .debounce(for: .milliseconds(200), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshIfAuthorized()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.refreshIfAuthorized()
            }
            .store(in: &cancellables)
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
