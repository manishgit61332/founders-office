import EventKit
import FounderOfficeCore
import SwiftUI

struct CalendarView: View {
    @EnvironmentObject private var calendar: CalendarProvider
    @EnvironmentObject private var model: AppModel

    private var appearance: AppearancePreferences { model.personalization.resolvedAppearance }

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
        .founderSurface(appearance)
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
    @EnvironmentObject private var model: AppModel

    let event: DeviceCalendarEvent

    private var appearance: AppearancePreferences { model.personalization.resolvedAppearance }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Text(event.startDate, format: .dateTime.month(.abbreviated))
                    .font(appearance.interfaceFont(size: 12, weight: .bold))
                    .textCase(.uppercase)
                Text(event.startDate, format: .dateTime.day())
                    .font(appearance.displayFont(size: 20, weight: .semibold))
            }
            .frame(minWidth: 42)

            VStack(alignment: .leading, spacing: 4) {
                Text(event.title)
                    .font(appearance.interfaceFont(size: 17, weight: .semibold))

                Text(event.isAllDay ? "All day" : event.startDate.formatted(date: .omitted, time: .shortened))
                    .font(appearance.interfaceFont(size: 15))

                Label("\(event.accountName) · \(event.calendarName)", systemImage: "calendar")
                    .font(appearance.interfaceFont(size: 14))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(
            appearance.nodeBackgroundColor,
            in: RoundedRectangle(cornerRadius: appearance.nodeCornerRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: appearance.nodeCornerRadius, style: .continuous)
                .stroke(appearance.nodeBorderColor, lineWidth: 1)
        )
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}
