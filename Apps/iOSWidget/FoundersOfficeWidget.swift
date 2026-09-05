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
                .containerBackground(for: .widget) { WidgetPalette.background }
        }
        .configurationDisplayName("Founder’s Office Next")
        .description("See your next Move, then the commitment or goal behind it.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

private struct NextEntry: TimelineEntry {
    let date: Date
    let projection: IOSWidgetProjection
}

private struct NextProvider: TimelineProvider {
    func placeholder(in context: Context) -> NextEntry {
        NextEntry(date: .now, projection: Self.previewProjection)
    }

    func getSnapshot(in context: Context, completion: @escaping (NextEntry) -> Void) {
        let projection = context.isPreview
            ? Self.previewProjection
            : IOSWidgetProjectionStore.load() ?? .signedOut
        completion(NextEntry(date: .now, projection: projection))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NextEntry>) -> Void) {
        let now = Date()
        let entry = NextEntry(date: now, projection: IOSWidgetProjectionStore.load() ?? .signedOut)
        // App writes request immediate timeline reloads. This fallback merely
        // refreshes relative date labels; it does not poll the workspace.
        completion(Timeline(entries: [entry], policy: .after(now.addingTimeInterval(15 * 60))))
    }

    private static var previewProjection: IOSWidgetProjection {
        IOSWidgetProjection(
            isSignedIn: true,
            nextMove: .init(
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
                title: "Ship the onboarding polish",
                dueAt: .now.addingTimeInterval(2 * 60 * 60)
            ),
            nextCommitment: .init(
                id: "synthetic-design-review",
                title: "Design review",
                startAt: .now.addingTimeInterval(75 * 60)
            ),
            primaryGoal: .init(
                id: UUID(uuidString: "20000000-0000-0000-0000-000000000002")!,
                title: "Friend beta",
                progress: "12 of 20 ready"
            )
        )
    }
}

private struct FoundersOfficeWidgetView: View {
    @Environment(\.widgetFamily) private var family

    let entry: NextEntry

    var body: some View {
        Group {
            if !entry.projection.isSignedIn {
                signedOut
            } else if family == .systemMedium {
                mediumContent
            } else {
                smallContent
            }
        }
        .padding(family == .systemMedium ? 14 : 16)
        .privacySensitive()
    }

    private var signedOut: some View {
        VStack(alignment: .leading, spacing: 8) {
            WidgetBrandMark(symbol: "lock.fill")
            Spacer(minLength: 2)
            Text("Open Founder’s Office")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(WidgetPalette.primaryText)
                .lineLimit(2)
            Text("Sign in to reveal your private next Move.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(WidgetPalette.secondaryText)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(URL(string: "founders-office://home"))
    }

    @ViewBuilder
    private var smallContent: some View {
        if let move = entry.projection.nextMove {
            VStack(alignment: .leading, spacing: 8) {
                WidgetBrandMark(symbol: "arrow.up.right")
                Text("NEXT MOVE")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(WidgetPalette.accent)

                Text(move.title)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(WidgetPalette.primaryText)
                    .lineLimit(3)
                    .minimumScaleFactor(0.82)

                Spacer(minLength: 0)

                HStack(spacing: 6) {
                    if let dueAt = move.dueAt {
                        Image(systemName: "clock")
                            .accessibilityHidden(true)
                        Text(dueAt, style: .relative)
                    } else {
                        Text("Ready when you are")
                    }
                    Spacer(minLength: 3)
                    Image(systemName: "arrow.right")
                        .accessibilityHidden(true)
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(WidgetPalette.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .widgetURL(moveURL(move))
        } else if let commitment = entry.projection.nextCommitment {
            CompactFallback(
                eyebrow: "UP NEXT",
                symbol: "calendar",
                title: commitment.title,
                detail: commitment.startAt.formatted(date: .omitted, time: .shortened)
            )
            .widgetURL(commitmentURL(commitment))
        } else if let goal = entry.projection.primaryGoal {
            CompactFallback(
                eyebrow: "PRIMARY GOAL",
                symbol: "scope",
                title: goal.title,
                detail: goal.progress
            )
            .widgetURL(goalURL(goal))
        } else {
            empty
        }
    }

    @ViewBuilder
    private var mediumContent: some View {
        if let move = entry.projection.nextMove {
            HStack(spacing: 12) {
                Link(destination: moveURL(move)) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("NEXT MOVE")
                            .font(.system(size: 11, weight: .bold))
                            .tracking(0.7)
                            .foregroundStyle(WidgetPalette.accent)

                        Text(move.title)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(WidgetPalette.primaryText)
                            .lineLimit(3)
                            .minimumScaleFactor(0.82)

                        Spacer(minLength: 0)

                        HStack(spacing: 6) {
                            Image(systemName: "arrow.up.right")
                                .accessibilityHidden(true)
                            if let dueAt = move.dueAt {
                                Text(dueAt, style: .relative)
                            } else {
                                Text("Open Move")
                            }
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(WidgetPalette.secondaryText)
                    }
                    .padding(13)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .widgetPanel()
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                secondaryColumn
                    .frame(width: 142)
            }
        } else if let commitment = entry.projection.nextCommitment {
            mediumFallback(
                eyebrow: "UP NEXT",
                symbol: "calendar",
                title: commitment.title,
                detail: commitment.startAt.formatted(date: .omitted, time: .shortened),
                destination: commitmentURL(commitment)
            )
        } else if let goal = entry.projection.primaryGoal {
            mediumFallback(
                eyebrow: "PRIMARY GOAL",
                symbol: "scope",
                title: goal.title,
                detail: goal.progress,
                destination: goalURL(goal)
            )
        } else {
            empty
        }
    }

    private var secondaryColumn: some View {
        VStack(spacing: 8) {
            if let commitment = entry.projection.nextCommitment {
                Link(destination: commitmentURL(commitment)) {
                    WidgetSecondaryPanel(
                        eyebrow: "UP NEXT",
                        symbol: "calendar",
                        title: commitment.title,
                        detail: commitment.startAt.formatted(date: .omitted, time: .shortened)
                    )
                }
                .buttonStyle(.plain)
            }

            if let goal = entry.projection.primaryGoal {
                Link(destination: goalURL(goal)) {
                    WidgetSecondaryPanel(
                        eyebrow: "GOAL",
                        symbol: "scope",
                        title: goal.title,
                        detail: goal.progress
                    )
                }
                .buttonStyle(.plain)
            }

            if entry.projection.nextCommitment == nil, entry.projection.primaryGoal == nil {
                WidgetSecondaryPanel(
                    eyebrow: "OFFICE",
                    symbol: "checkmark.circle",
                    title: "Space protected",
                    detail: "Nothing else is pulling"
                )
            }
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: 8) {
            WidgetBrandMark(symbol: "checkmark.circle")
            Spacer(minLength: 0)
            Text("The office is clear")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(WidgetPalette.primaryText)
            Text("Add the next meaningful Move in the app.")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(WidgetPalette.secondaryText)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(URL(string: "founders-office://moves"))
    }

    private func mediumFallback(
        eyebrow: String,
        symbol: String,
        title: String,
        detail: String?,
        destination: URL
    ) -> some View {
        Link(destination: destination) {
            HStack(spacing: 14) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(WidgetPalette.accent)
                    .frame(width: 44, height: 44)
                    .background(WidgetPalette.accentWash, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                VStack(alignment: .leading, spacing: 5) {
                    Text(eyebrow)
                        .font(.system(size: 11, weight: .bold))
                        .tracking(0.7)
                        .foregroundStyle(WidgetPalette.accent)
                    Text(title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(WidgetPalette.primaryText)
                        .lineLimit(2)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(WidgetPalette.secondaryText)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .widgetPanel()
        }
        .buttonStyle(.plain)
    }

    private func moveURL(_ move: IOSWidgetProjection.Move) -> URL {
        URL(string: "founders-office://move/\(move.id.uuidString.lowercased())")!
    }

    private func commitmentURL(_ commitment: IOSWidgetProjection.Commitment) -> URL {
        let component = commitment.id.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        ) ?? "event"
        return URL(string: "founders-office://calendar/\(component)")!
    }

    private func goalURL(_ goal: IOSWidgetProjection.Goal) -> URL {
        URL(string: "founders-office://goal/\(goal.id.uuidString.lowercased())")!
    }
}

private struct WidgetBrandMark: View {
    let symbol: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
            Text("FO")
                .font(.system(size: 11, weight: .bold))
                .tracking(0.4)
        }
        .foregroundStyle(WidgetPalette.accent)
        .padding(.horizontal, 8)
        .frame(minHeight: 25)
        .background(WidgetPalette.accentWash, in: Capsule())
        .accessibilityLabel("Founder’s Office")
    }
}

private struct CompactFallback: View {
    let eyebrow: String
    let symbol: String
    let title: String
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            WidgetBrandMark(symbol: symbol)
            Text(eyebrow)
                .font(.system(size: 11, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(WidgetPalette.accent)
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(WidgetPalette.primaryText)
                .lineLimit(3)
            Spacer(minLength: 0)
            if let detail {
                Text(detail)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(WidgetPalette.secondaryText)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct WidgetSecondaryPanel: View {
    let eyebrow: String
    let symbol: String
    let title: String
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(eyebrow, systemImage: symbol)
                .font(.system(size: 10, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(WidgetPalette.accent)
                .lineLimit(1)
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(WidgetPalette.primaryText)
                .lineLimit(1)
            if let detail {
                Text(detail)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(WidgetPalette.secondaryText)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetPanel()
    }
}

private struct WidgetPanelModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                WidgetPalette.panel,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(WidgetPalette.border, lineWidth: 1)
            }
    }
}

private extension View {
    func widgetPanel() -> some View {
        modifier(WidgetPanelModifier())
    }
}

private enum WidgetPalette {
    static let background = Color(
        uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 14 / 255, green: 15 / 255, blue: 18 / 255, alpha: 1)
                : UIColor.white
        }
    )

    static let panel = Color(
        uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 1, alpha: 0.07)
                : UIColor(red: 245 / 255, green: 245 / 255, blue: 247 / 255, alpha: 1)
        }
    )

    static let border = Color(
        uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 1, alpha: 0.10)
                : UIColor(red: 17 / 255, green: 17 / 255, blue: 20 / 255, alpha: 0.08)
        }
    )

    static let primaryText = Color(
        uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 247 / 255, green: 247 / 255, blue: 247 / 255, alpha: 1)
                : UIColor(red: 17 / 255, green: 17 / 255, blue: 20 / 255, alpha: 1)
        }
    )

    static let secondaryText = Color(
        uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 1, alpha: 0.62)
                : UIColor(red: 17 / 255, green: 17 / 255, blue: 20 / 255, alpha: 0.58)
        }
    )

    static let accent = Color(
        uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 10 / 255, green: 132 / 255, blue: 1, alpha: 1)
                : UIColor(red: 0, green: 122 / 255, blue: 1, alpha: 1)
        }
    )

    static let accentWash = Color(
        uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 10 / 255, green: 132 / 255, blue: 1, alpha: 0.14)
                : UIColor(red: 0, green: 122 / 255, blue: 1, alpha: 0.10)
        }
    )
}
