import FounderOfficeCore
import SwiftUI
import UIKit

struct HomeView: View {
    @EnvironmentObject private var model: AppModel

    private var appearance: AppearancePreferences { model.personalization.resolvedAppearance }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 2) {
                    Text(greeting)
                        .font(model.personalization.resolvedAppearance.displayFont(.primaryTitle))
                    Text("What moves the office forward today?")
                        .font(appearance.interfaceFont(.secondary, weight: .semibold))
                }
                .padding(.vertical, 4)
            }

            if let goal = model.activePrimaryGoal {
                Section("Primary goal") {
                    PrimaryGoalCard(goal: goal)
                }
            }

            Section("Next move") {
                if let nextMove = model.nextMove {
                    TaskRow(loop: nextMove)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button {
                                model.toggleCompletion(nextMove)
                            } label: {
                                Label("Complete", systemImage: "checkmark")
                            }
                            .tint(.green)
                        }
                } else {
                    ContentUnavailableView(
                        "Office is clear",
                        systemImage: "checkmark.circle",
                        description: Text("Add the next meaningful move in Moves.")
                    )
                }
            }

            let chosenID = model.nextMove?.id
            let upcoming = model.visibleLoops
                .filter { $0.status == .next && $0.id != chosenID }
                .prefix(3)
            if !upcoming.isEmpty {
                Section("Up next") {
                    ForEach(upcoming) { loop in
                        TaskRow(loop: loop)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button {
                                    model.toggleCompletion(loop)
                                } label: {
                                    Label("Complete", systemImage: "checkmark")
                                }
                                .tint(.green)
                            }
                    }
                }
            }

            if let image = model.visionImage {
                Section("Keep the why close") {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(maxWidth: .infinity)
                        .frame(height: 220)
                        .clipShape(.rect(cornerRadius: appearance.visionCornerRadius))
                        .listRowInsets(EdgeInsets())
                }
            }
        }
        .founderSurface(appearance)
        .navigationTitle(model.personalization.resolvedWorkspaceName)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var greeting: String {
        guard let name = model.personalization.resolvedPreferredName else { return "Welcome" }
        return "Hi \(name)!"
    }
}

private struct PrimaryGoalCard: View {
    @EnvironmentObject private var model: AppModel

    let goal: PrimaryGoal

    private var appearance: AppearancePreferences { model.personalization.resolvedAppearance }

    private var progress: Double? {
        guard let current = goal.currentValue,
              let target = goal.targetValue,
              target > 0
        else { return nil }
        return min(max(current / target, 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(goal.title)
                .font(appearance.interfaceFont(.secondary, weight: .semibold))

            if let current = goal.currentValue, let target = goal.targetValue {
                HStack(alignment: .firstTextBaseline) {
                    Text(goal.unit.format(current))
                        .font(appearance.displayFont(.secondary, weight: .bold))
                    Text("of \(goal.unit.format(target)) \(goal.metric)")
                        .font(appearance.interfaceFont(.tertiary))
                    Spacer()
                    Text(goal.dueAt, style: .relative)
                        .font(appearance.interfaceFont(.tertiary, weight: .semibold))
                }
            }

            if let progress {
                ProgressView(value: progress)
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
