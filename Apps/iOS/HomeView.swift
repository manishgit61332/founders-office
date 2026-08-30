import FounderOfficeCore
import SwiftUI
import UIKit

struct HomeView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 2) {
                    Text(greeting)
                        .font(.founderDisplay)
                    Text("What moves the office forward today?")
                        .font(.headline)
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
                        .clipShape(.rect(cornerRadius: 18))
                        .listRowInsets(EdgeInsets())
                }
            }
        }
        .navigationTitle(model.personalization.resolvedWorkspaceName)
    }

    private var greeting: String {
        guard let name = model.personalization.resolvedPreferredName else { return "Welcome" }
        return "Hi \(name)!"
    }
}

private struct PrimaryGoalCard: View {
    let goal: PrimaryGoal

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
                .font(.title3.weight(.semibold))

            if let current = goal.currentValue, let target = goal.targetValue {
                HStack(alignment: .firstTextBaseline) {
                    Text(goal.unit.format(current))
                        .font(.title2.weight(.bold))
                    Text("of \(goal.unit.format(target)) \(goal.metric)")
                        .font(.body)
                    Spacer()
                    Text(goal.dueAt, style: .relative)
                        .font(.headline)
                }
            }

            if let progress {
                ProgressView(value: progress)
            }
        }
        .padding(.vertical, 4)
    }
}

struct TaskRow: View {
    let loop: OpenLoop

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(loop.title)
                    .font(.headline)
                Spacer()
                Text(loop.priority.rawValue)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }

            if !loop.details.isEmpty {
                Text(loop.details)
                    .font(.body)
                    .lineLimit(2)
            }

            if let dueAt = loop.dueAt {
                Label {
                    Text(dueAt, style: .relative)
                } icon: {
                    Image(systemName: "calendar")
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(
                    dueAt < .now && loop.status != .done
                        ? Color.red
                        : Color(uiColor: UIColor.secondaryLabel)
                )
            }
        }
        .padding(.vertical, 4)
    }
}
