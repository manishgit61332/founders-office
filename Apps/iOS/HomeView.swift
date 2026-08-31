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
                        .font(model.personalization.resolvedAppearance.displayFont(size: 40))
                    Text("What moves the office forward today?")
                        .font(appearance.interfaceFont(size: 17, weight: .semibold))
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
                .font(appearance.interfaceFont(size: 20, weight: .semibold))

            if let current = goal.currentValue, let target = goal.targetValue {
                HStack(alignment: .firstTextBaseline) {
                    Text(goal.unit.format(current))
                        .font(appearance.displayFont(size: 25, weight: .bold))
                    Text("of \(goal.unit.format(target)) \(goal.metric)")
                        .font(appearance.interfaceFont(size: 16))
                    Spacer()
                    Text(goal.dueAt, style: .relative)
                        .font(appearance.interfaceFont(size: 16, weight: .semibold))
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
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(loop.title)
                    .font(appearance.interfaceFont(size: 17, weight: .semibold))
                Spacer()
                Text(loop.priority.rawValue)
                    .font(appearance.interfaceFont(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
            }

            if !loop.details.isEmpty {
                Text(loop.details)
                    .font(appearance.interfaceFont(size: 15))
                    .lineLimit(2)
            }

            if showsStatus && loop.status != .done {
                Text(loop.status.title)
                    .font(appearance.interfaceFont(size: 14, weight: .semibold))
                    .foregroundStyle(appearance.primaryAccentColor)
            }

            if loop.status == .done, let completedAt = loop.completedAt {
                Label(
                    "Completed \(completedAt.formatted(date: .abbreviated, time: .omitted))",
                    systemImage: "checkmark.circle"
                )
                .font(appearance.interfaceFont(size: 14, weight: .medium))
                .foregroundStyle(Color(uiColor: UIColor.secondaryLabel))
            } else if let dueAt = loop.dueAt {
                Label {
                    Text(deadlineLabel(for: dueAt))
                } icon: {
                    Image(systemName: "calendar")
                }
                .font(appearance.interfaceFont(size: 14, weight: .medium))
                .foregroundStyle(
                    isOverdue(dueAt) && loop.status != .done
                        ? Color.red
                        : Color(uiColor: UIColor.secondaryLabel)
                )
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

    private func deadlineLabel(for storedDate: Date) -> String {
        let dueDay = PlanningDate.day(fromStored: storedDate)
        if dueDay == PlanningDate.day(fromLocal: Date(), calendar: calendar) {
            return "Due today"
        }
        let localDate = PlanningDate.localDate(fromStored: storedDate, calendar: calendar)
        return "Due \(localDate.formatted(date: .abbreviated, time: .omitted))"
    }

    private func isOverdue(_ storedDate: Date) -> Bool {
        PlanningDate.day(fromStored: storedDate)
            < PlanningDate.day(fromLocal: Date(), calendar: calendar)
    }
}
