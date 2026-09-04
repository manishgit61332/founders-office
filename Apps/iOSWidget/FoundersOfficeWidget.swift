import SwiftUI
import UIKit
import WidgetKit

@main
struct FoundersOfficeWidgetBundle: WidgetBundle {
    var body: some Widget {
        FoundersOfficeNextWidget()
    }
}

struct FoundersOfficeNextWidget: Widget {
    let kind = "com.manish.foundersoffice.ios.next"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NextProvider()) { entry in
            FoundersOfficeWidgetView(entry: entry)
                .containerBackground(for: .widget) { Color(uiColor: .systemBackground) }
        }
        .configurationDisplayName("Founder’s Office Next")
        .description("A private, glanceable view of one next Move, commitment, or primary goal.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular])
    }
}

private struct NextEntry: TimelineEntry {
    let date: Date
    let projection: IOSWidgetProjection
}

private struct NextProvider: TimelineProvider {
    func placeholder(in context: Context) -> NextEntry {
        NextEntry(date: .now, projection: .signedOut)
    }

    func getSnapshot(in context: Context, completion: @escaping (NextEntry) -> Void) {
        completion(NextEntry(date: .now, projection: IOSWidgetProjectionStore.load() ?? .signedOut))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NextEntry>) -> Void) {
        let now = Date()
        let entry = NextEntry(date: now, projection: IOSWidgetProjectionStore.load() ?? .signedOut)
        // App writes request immediate timeline reloads. This fallback merely
        // refreshes relative date labels; it does not poll the workspace.
        completion(Timeline(entries: [entry], policy: .after(now.addingTimeInterval(15 * 60))))
    }
}

private struct FoundersOfficeWidgetView: View {
    @Environment(\.widgetFamily) private var family

    let entry: NextEntry

    var body: some View {
        Group {
            if !entry.projection.isSignedIn {
                signedOut
            } else if let move = entry.projection.nextMove {
                moveView(move)
            } else if let commitment = entry.projection.nextCommitment {
                commitmentView(commitment)
            } else if let goal = entry.projection.primaryGoal {
                goalView(goal)
            } else {
                empty
            }
        }
        .privacySensitive()
    }

    private var signedOut: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Founder’s Office", systemImage: "lock.fill")
                .font(.headline)
            Text("Open the app to sign in and see your next Move.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .widgetURL(URL(string: "founders-office://home"))
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Founder’s Office", systemImage: "checklist")
                .font(.headline)
            Text("Add a Move in the app when you are ready.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .widgetURL(URL(string: "founders-office://moves"))
    }

    private func moveView(_ move: IOSWidgetProjection.Move) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Next Move", systemImage: "checkmark.circle.fill")
                .font(family == .accessoryRectangular ? .caption : .headline)
                .foregroundStyle(.tint)
            Text(move.title)
                .font(.body.weight(.semibold))
                .lineLimit(family == .systemMedium ? 3 : 2)
            if let dueAt = move.dueAt {
                Text(dueAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .widgetURL(URL(string: "founders-office://move/\(move.id.uuidString.lowercased())"))
    }

    private func commitmentView(_ commitment: IOSWidgetProjection.Commitment) -> some View {
        let pathComponent = commitment.id.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        ) ?? "event"
        VStack(alignment: .leading, spacing: 6) {
            Label("Up next", systemImage: "calendar")
                .font(family == .accessoryRectangular ? .caption : .headline)
                .foregroundStyle(.tint)
            Text(commitment.title)
                .font(.body.weight(.semibold))
                .lineLimit(family == .systemMedium ? 3 : 2)
            Text(commitment.startAt, style: .time)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .widgetURL(URL(string: "founders-office://calendar/\(pathComponent)"))
    }

    private func goalView(_ goal: IOSWidgetProjection.Goal) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Primary goal", systemImage: "scope")
                .font(family == .accessoryRectangular ? .caption : .headline)
                .foregroundStyle(.tint)
            Text(goal.title)
                .font(.body.weight(.semibold))
                .lineLimit(family == .systemMedium ? 3 : 2)
            if let progress = goal.progress {
                Text(progress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .widgetURL(URL(string: "founders-office://goal/\(goal.id.uuidString.lowercased())"))
    }
}
