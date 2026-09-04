import EventKit
import FounderOfficeCore
import SwiftUI

struct CalendarView: View {
    @EnvironmentObject private var calendar: CalendarProvider
    @EnvironmentObject private var model: AppModel
    @Environment(\.calendar) private var localeCalendar
    @State private var planningSelection: TaskPlanningSelection?
    @State private var highlightedEventID: String?

    private var appearance: AppearancePreferences { model.personalization.resolvedAppearance }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let movePresentation = MovePresentation(
                items: model.visibleLoops,
                now: context.date,
                calendar: localeCalendar
            )
            let dueToday = movePresentation.activeItems(
                dueOn: context.date,
                calendar: localeCalendar
            )

            List {
                Section {
                    if dueToday.isEmpty {
                        Label("No moves due today", systemImage: "checkmark.circle")
                            .font(appearance.interfaceFont(.secondary, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 6)
                    } else {
                        ForEach(dueToday) { loop in
                            ActionableTaskRow(
                                loop: loop,
                                showsStatus: true,
                                onEditPlanning: { planningSelection = .init(id: loop.id) }
                            )
                        }
                    }
                } header: {
                    Label("Today’s moves", systemImage: "checklist")
                        .font(appearance.interfaceFont(.secondary, weight: .bold))
                        .foregroundStyle(.primary)
                        .textCase(nil)
                }

                if calendar.hasReadAccess {
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
                                CalendarEventRow(
                                    event: event,
                                    isHighlighted: event.id == highlightedEventID
                                )
                            }
                        }
                    }
                } else {
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Connect Calendar", systemImage: "calendar")
                                .font(appearance.interfaceFont(.secondary, weight: .bold))

                            Text("See events from every Google and Apple calendar enabled on this iPhone. Move deadlines above remain available without access.")
                                .font(appearance.interfaceFont(.secondary))

                            Button(calendar.connectionTitle) {
                                calendar.connectOrOpenSettings()
                            }
                            .founderProminentButton(appearance)
                        }
                        .padding(.vertical, 8)
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
        }
        .founderSurface(appearance)
        .onAppear {
            calendar.refreshIfAuthorized()
            handleRoute(model.route)
        }
        .onChange(of: model.route) { _, route in handleRoute(route) }
        .taskPlanningSheet(selection: $planningSelection)
    }

    private func handleRoute(_ route: IOSAppRoute?) {
        guard case let .calendar(identifier) = route else { return }
        highlightedEventID = identifier
        model.consumeRoute()
    }
}

private struct CalendarEventRow: View {
    @EnvironmentObject private var model: AppModel

    let event: DeviceCalendarEvent
    let isHighlighted: Bool

    private var appearance: AppearancePreferences { model.personalization.resolvedAppearance }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Text(event.startDate, format: .dateTime.month(.abbreviated))
                    .font(appearance.interfaceFont(.tertiary, weight: .bold))
                    .textCase(.uppercase)
                Text(event.startDate, format: .dateTime.day())
                    .font(appearance.displayFont(.secondary, weight: .semibold))
            }
            .frame(minWidth: 42)

            VStack(alignment: .leading, spacing: 4) {
                Text(event.title)
                    .font(appearance.interfaceFont(.secondary, weight: .semibold))

                Text(event.isAllDay ? "All day" : event.startDate.formatted(date: .omitted, time: .shortened))
                    .font(appearance.interfaceFont(.secondary))

                Label("\(event.accountName) · \(event.calendarName)", systemImage: "calendar")
                    .font(appearance.interfaceFont(.tertiary))
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
                .stroke(
                    isHighlighted ? appearance.primaryAccentColor : appearance.nodeBorderColor,
                    lineWidth: isHighlighted ? 3 : 1
                )
        )
        .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }
}
