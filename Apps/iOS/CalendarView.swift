import EventKit
import SwiftUI

struct CalendarView: View {
    @EnvironmentObject private var calendar: CalendarProvider

    var body: some View {
        Group {
            if calendar.hasReadAccess {
                List {
                    Section("Calendar accounts") {
                        ForEach(calendar.accounts) { account in
                            LabeledContent(account.name) {
                                Text("\(account.calendarCount) calendars")
                            }
                        }
                    }

                    Section("Next 60 days") {
                        if calendar.events.isEmpty {
                            ContentUnavailableView(
                                "No upcoming events",
                                systemImage: "calendar.badge.checkmark"
                            )
                        } else {
                            ForEach(calendar.events) { event in
                                CalendarEventRow(event: event)
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("Connect Calendar", systemImage: "calendar")
                } description: {
                    Text("See upcoming events from the calendar accounts enabled on this iPhone. Event details stay on this device.")
                } actions: {
                    Button(calendar.connectionTitle) {
                        calendar.connectOrOpenSettings()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle("Calendar")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    if calendar.hasReadAccess {
                        calendar.refresh()
                    } else {
                        calendar.connectOrOpenSettings()
                    }
                } label: {
                    Label(
                        calendar.hasReadAccess ? "Refresh" : calendar.connectionTitle,
                        systemImage: calendar.hasReadAccess ? "arrow.clockwise" : "link"
                    )
                }
            }
        }
        .onAppear {
            calendar.refreshIfAuthorized()
        }
    }
}

private struct CalendarEventRow: View {
    let event: DeviceCalendarEvent

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Text(event.startDate, format: .dateTime.month(.abbreviated))
                    .font(.caption.weight(.bold))
                    .textCase(.uppercase)
                Text(event.startDate, format: .dateTime.day())
                    .font(.title3.weight(.semibold))
            }
            .frame(minWidth: 42)

            VStack(alignment: .leading, spacing: 4) {
                Text(event.title)
                    .font(.headline)

                Text(event.isAllDay ? "All day" : event.startDate.formatted(date: .omitted, time: .shortened))
                    .font(.body)

                Label("\(event.accountName) · \(event.calendarName)", systemImage: "calendar")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
