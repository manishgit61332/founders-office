import FounderOfficeCore
import SwiftUI
import UIKit

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var calendar: CalendarProvider
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var appearance: AppearancePreferences { model.personalization.resolvedAppearance }
    private var activeMoveCount: Int {
        model.visibleLoops.lazy.filter { $0.status != .done }.count
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                header

                VStack(alignment: .leading, spacing: 10) {
                    SectionEyebrow(title: "Next Move", systemImage: "arrow.up.right")

                if let nextMove = model.nextMove {
                        NextMoveCard(loop: nextMove)
                } else {
                        EmptyNextMoveCard()
                }
            }

                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(spacing: 12) {
                            UpNextCard()
                            CountdownCard(goal: model.activePrimaryGoal)
                        }
                    } else {
                        HStack(alignment: .top, spacing: 12) {
                            UpNextCard()
                            CountdownCard(goal: model.activePrimaryGoal)
                        }
                    }
                }

                if let image = model.visionImage {
                    VisionCard(image: image)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
        .background(FounderIOSPalette.background.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .refreshable {
            calendar.refreshIfAuthorized()
            model.refreshWorkspace()
        }
        .onAppear { calendar.refreshIfAuthorized() }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(greeting)
                    .font(.custom("Instrument Serif", size: 28, relativeTo: .largeTitle))
                    .foregroundStyle(FounderIOSPalette.primaryText)

                Text("What moves the office forward today?")
                    .font(appearance.interfaceFont(.tertiary, weight: .semibold))
                    .foregroundStyle(FounderIOSPalette.secondaryText)
            }

            Spacer(minLength: 8)

            Text("\(activeMoveCount) ACTIVE")
                .font(appearance.interfaceFont(.tertiary, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(FounderIOSPalette.accent)
                .padding(.horizontal, 10)
                .frame(minHeight: 30)
                .background(FounderIOSPalette.accentWash, in: Capsule())
                .accessibilityLabel("\(activeMoveCount) active Moves")
        }
    }

    private var greeting: String {
        guard let name = model.personalization.resolvedPreferredName else { return "Welcome" }
        return "Hi \(name)!"
    }
}

private struct SectionEyebrow: View {
    @EnvironmentObject private var model: AppModel

    let title: String
    let systemImage: String

    private var appearance: AppearancePreferences { model.personalization.resolvedAppearance }

    var body: some View {
        Label(title.uppercased(), systemImage: systemImage)
            .font(appearance.interfaceFont(.tertiary, weight: .bold))
            .tracking(0.9)
            .foregroundStyle(FounderIOSPalette.secondaryText)
    }
}

private struct NextMoveCard: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.calendar) private var calendar

    let loop: OpenLoop

    private var appearance: AppearancePreferences { model.personalization.resolvedAppearance }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 8) {
                Circle()
                    .fill(loop.priority.laneColor)
                    .frame(width: 8, height: 8)
                    .accessibilityHidden(true)

                Text(loop.priority.customerTitle.uppercased())
                    .font(appearance.interfaceFont(.tertiary, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(FounderIOSPalette.secondaryText)

                Spacer()

                if let dueAt = loop.dueAt {
                    Text(dueLabel(dueAt))
                        .font(appearance.interfaceFont(.tertiary, weight: .bold))
                        .foregroundStyle(isOverdue(dueAt) ? Color.red : FounderIOSPalette.secondaryText)
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                Text(loop.title)
                    .font(appearance.interfaceFont(.secondary, weight: .bold))
                    .foregroundStyle(FounderIOSPalette.primaryText)
                    .fixedSize(horizontal: false, vertical: true)

                if !loop.details.isEmpty {
                    Text(loop.details)
                        .font(appearance.interfaceFont(.tertiary))
                        .foregroundStyle(FounderIOSPalette.secondaryText)
                        .lineLimit(2)
                }
            }

            Button {
                model.toggleCompletion(loop)
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "checkmark.circle")
                        .font(appearance.symbolFont(size: 18, weight: .semibold))
                    Text("Mark complete")
                        .font(appearance.interfaceFont(.tertiary, weight: .bold))
                    Spacer()
                    Image(systemName: "arrow.right")
                        .font(appearance.symbolFont(size: 12, weight: .bold))
                        .accessibilityHidden(true)
                }
                .foregroundStyle(FounderIOSPalette.accent)
                .frame(minHeight: 44)
                .padding(.horizontal, 13)
                .background(FounderIOSPalette.accentWash, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Mark \(loop.title) complete")
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 176, alignment: .topLeading)
        .founderHomeCard()
    }

    private func dueLabel(_ storedDate: Date) -> String {
        let dueDay = PlanningDate.day(fromStored: storedDate)
        let today = PlanningDate.day(fromLocal: Date(), calendar: calendar)
        if dueDay == today { return "Today" }
        return PlanningDate.localDate(fromStored: storedDate, calendar: calendar)
            .formatted(.dateTime.day().month(.abbreviated))
    }

    private func isOverdue(_ storedDate: Date) -> Bool {
        PlanningDate.day(fromStored: storedDate)
            < PlanningDate.day(fromLocal: Date(), calendar: calendar)
    }
}

private struct EmptyNextMoveCard: View {
    @EnvironmentObject private var model: AppModel

    private var appearance: AppearancePreferences { model.personalization.resolvedAppearance }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "checkmark.circle")
                .font(appearance.symbolFont(size: 28, weight: .medium))
                .foregroundStyle(FounderIOSPalette.accent)
                .accessibilityHidden(true)

            Text("The office is clear")
                .font(appearance.interfaceFont(.secondary, weight: .bold))
                .foregroundStyle(FounderIOSPalette.primaryText)

            Text("Choose the next meaningful Move when you are ready.")
                .font(appearance.interfaceFont(.tertiary))
                .foregroundStyle(FounderIOSPalette.secondaryText)

            Button("Open Moves") { model.navigate(to: .moves(nil)) }
                .font(appearance.interfaceFont(.tertiary, weight: .bold))
                .foregroundStyle(FounderIOSPalette.accent)
                .frame(minHeight: 44)
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 176, alignment: .topLeading)
        .founderHomeCard()
    }
}

private struct UpNextCard: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var calendar: CalendarProvider

    private var appearance: AppearancePreferences { model.personalization.resolvedAppearance }

    var body: some View {
        Button {
            model.navigate(to: .calendar(calendar.upNextEvent?.id))
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                cardHeader("Up Next", systemImage: "calendar")

                if let event = calendar.upNextEvent {
                    Text(event.title)
                        .font(appearance.interfaceFont(.secondary, weight: .bold))
                        .foregroundStyle(FounderIOSPalette.primaryText)
                        .lineLimit(2)

                    Text(eventDateLabel(event))
                        .font(appearance.interfaceFont(.tertiary, weight: .semibold))
                        .foregroundStyle(FounderIOSPalette.secondaryText)
                        .lineLimit(1)
                } else {
                    Text(calendar.hasReadAccess ? "Time is clear" : calendar.connectionTitle)
                        .font(appearance.interfaceFont(.secondary, weight: .bold))
                        .foregroundStyle(FounderIOSPalette.primaryText)
                        .lineLimit(2)

                    Text(calendar.hasReadAccess ? "No commitments soon" : "Calendar stays on this iPhone")
                        .font(appearance.interfaceFont(.tertiary, weight: .semibold))
                        .foregroundStyle(FounderIOSPalette.secondaryText)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)
            }
            .padding(15)
            .frame(maxWidth: .infinity, minHeight: 142, alignment: .topLeading)
            .founderHomeCard()
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens Calendar")
    }

    private func cardHeader(_ title: String, systemImage: String) -> some View {
        Label(title.uppercased(), systemImage: systemImage)
            .font(appearance.interfaceFont(.tertiary, weight: .bold))
            .tracking(0.7)
            .foregroundStyle(FounderIOSPalette.accent)
    }

    private func eventDateLabel(_ event: DeviceCalendarEvent) -> String {
        if event.isAllDay {
            return event.startDate.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        }
        return event.startDate.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }
}

private struct CountdownCard: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.calendar) private var calendar

    let goal: PrimaryGoal?

    private var appearance: AppearancePreferences { model.personalization.resolvedAppearance }

    var body: some View {
        Button {
            if let goal {
                model.navigate(to: .goal(goal.id))
            } else {
                model.navigate(to: .goal(UUID()))
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                Label("COUNTDOWN", systemImage: "scope")
                    .font(appearance.interfaceFont(.tertiary, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(FounderIOSPalette.accent)

                if let goal {
                    Text(daysLeftLabel(goal.dueAt))
                        .font(.custom("Instrument Serif", size: 28, relativeTo: .largeTitle))
                        .foregroundStyle(FounderIOSPalette.primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)

                    Text(goal.title)
                        .font(appearance.interfaceFont(.tertiary, weight: .bold))
                        .foregroundStyle(FounderIOSPalette.secondaryText)
                        .lineLimit(2)
                } else {
                    Text("Set the finish line")
                        .font(appearance.interfaceFont(.secondary, weight: .bold))
                        .foregroundStyle(FounderIOSPalette.primaryText)
                        .lineLimit(2)

                    Text("Goal + deadline")
                        .font(appearance.interfaceFont(.tertiary, weight: .semibold))
                        .foregroundStyle(FounderIOSPalette.secondaryText)
                }

                Spacer(minLength: 0)
            }
            .padding(15)
            .frame(maxWidth: .infinity, minHeight: 142, alignment: .topLeading)
            .founderHomeCard()
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the primary goal editor")
    }

    private func daysLeftLabel(_ dueAt: Date) -> String {
        let today = calendar.startOfDay(for: Date())
        let dueDay = calendar.startOfDay(for: dueAt)
        let days = calendar.dateComponents([.day], from: today, to: dueDay).day ?? 0
        switch days {
        case ..<0: return "Past due"
        case 0: return "Today"
        case 1: return "1 day"
        default: return "\(days) days"
        }
    }
}

private struct VisionCard: View {
    @EnvironmentObject private var model: AppModel

    let image: UIImage

    private var appearance: AppearancePreferences { model.personalization.resolvedAppearance }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity)
                .frame(height: 180)
                .clipped()

            LinearGradient(
                colors: [.clear, .black.opacity(0.72)],
                startPoint: .center,
                endPoint: .bottom
            )

            Label("Keep the why close", systemImage: "sparkles")
                .font(appearance.interfaceFont(.tertiary, weight: .bold))
                .foregroundStyle(.white)
                .padding(16)
        }
        .frame(height: 180)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(FounderIOSPalette.border, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Vision image. Keep the why close.")
    }
}

private struct FounderHomeCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                FounderIOSPalette.card,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(FounderIOSPalette.border, lineWidth: 1)
            }
    }
}

private extension View {
    func founderHomeCard() -> some View {
        modifier(FounderHomeCardModifier())
    }
}

struct TaskRow: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.calendar) private var calendar

    let loop: OpenLoop
    var showsStatus = false

    private var appearance: AppearancePreferences { model.personalization.resolvedAppearance }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Capsule()
                .fill(loop.priority.laneColor)
                .frame(width: 5, height: 48)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text(loop.title)
                    .font(appearance.interfaceFont(.secondary, weight: .semibold))

                if !loop.details.isEmpty {
                    Text(loop.details)
                        .font(appearance.interfaceFont(.secondary))
                        .lineLimit(2)
                }

                if showsStatus && loop.status != .done {
                    Text(loop.status.title)
                        .font(appearance.interfaceFont(.tertiary, weight: .semibold))
                        .foregroundStyle(.primary)
                }

                if loop.status == .done {
                    Label("Completed", systemImage: "checkmark.circle")
                        .font(appearance.interfaceFont(.tertiary, weight: .medium))
                        .foregroundStyle(Color(uiColor: UIColor.secondaryLabel))
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                Text(dateColumnLabel)
                    .font(appearance.interfaceFont(.secondary, weight: .semibold))
                    .foregroundStyle(dateColumnColor)
                    .lineLimit(1)

                Text(loop.priority.customerTitle)
                    .font(appearance.interfaceFont(.tertiary, weight: .medium))
                    .foregroundStyle(loop.priority.laneColor)
            }
            .frame(minWidth: 72, alignment: .trailing)
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
        .accessibilityElement(children: .combine)
        .accessibilityValue("\(loop.priority.customerTitle) priority, \(dateColumnAccessibilityLabel)")
    }

    private var dateColumnLabel: String {
        if loop.status == .done, let completedAt = loop.completedAt {
            return completedAt.formatted(.dateTime.day().month(.abbreviated))
        }
        guard let dueAt = loop.dueAt else { return "No date" }
        let dueDay = PlanningDate.day(fromStored: dueAt)
        if dueDay == PlanningDate.day(fromLocal: Date(), calendar: calendar) {
            return "Today"
        }
        let localDate = PlanningDate.localDate(fromStored: dueAt, calendar: calendar)
        return localDate.formatted(.dateTime.day().month(.abbreviated))
    }

    private var dateColumnAccessibilityLabel: String {
        if loop.status == .done, let completedAt = loop.completedAt {
            return "completed \(completedAt.formatted(date: .long, time: .omitted))"
        }
        guard let dueAt = loop.dueAt else { return "no deadline" }
        return "due \(PlanningDate.localDate(fromStored: dueAt, calendar: calendar).formatted(date: .long, time: .omitted))"
    }

    private var dateColumnColor: Color {
        guard loop.status != .done, let dueAt = loop.dueAt else {
            return Color(uiColor: UIColor.secondaryLabel)
        }
        return isOverdue(dueAt) ? .red : .primary
    }

    private func isOverdue(_ storedDate: Date) -> Bool {
        PlanningDate.day(fromStored: storedDate)
            < PlanningDate.day(fromLocal: Date(), calendar: calendar)
    }
}
