import AppKit
import FounderOfficeCore
import SwiftUI

private enum BoardSection: String, CaseIterable, Identifiable {
    case home
    case loops
    case calendar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .loops: return "Moves"
        case .calendar: return "Calendar"
        }
    }

    var icon: ClayIconName {
        switch self {
        case .home: return .home
        case .loops: return .loops
        case .calendar: return .calendar
        }
    }
}

private enum PersonalizePage: String, CaseIterable, Identifiable {
    case profile
    case appearance
    case finishLine
    case calendar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .profile: return "Profile"
        case .appearance: return "Appearance"
        case .finishLine: return "Finish line"
        case .calendar: return "Calendar"
        }
    }

    var systemImage: String {
        switch self {
        case .profile: return "person.crop.circle"
        case .appearance: return "paintpalette"
        case .finishLine: return "scope"
        case .calendar: return "calendar"
        }
    }
}

private struct DeadlineSignal: Identifiable {
    var id: String
    var title: String
    var dueAt: Date
    var source: String
}

private struct NotchMorphShape: InsettableShape {
    var width: CGFloat
    var topWidth: CGFloat
    var height: CGFloat
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    var shoulderDepth: CGFloat
    var bodyOffsetX: CGFloat
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let resolvedWidth = max(0, min(width, rect.width) - insetAmount * 2)
        let resolvedTopWidth = max(0, min(topWidth, width) - insetAmount * 2)
        let resolvedHeight = max(0, min(height, rect.height) - insetAmount * 2)
        let maximumRadius = max(0, min(resolvedWidth, resolvedHeight) / 2)
        let resolvedTopRadius = min(max(topRadius - insetAmount, 0), maximumRadius)
        let resolvedBottomRadius = min(max(bottomRadius - insetAmount, 0), maximumRadius)
        let resolvedShoulderDepth = min(
            max(shoulderDepth - insetAmount, resolvedTopRadius),
            max(resolvedHeight - resolvedBottomRadius, 0)
        )
        let top = rect.minY + insetAmount
        let bottom = top + resolvedHeight
        let bodyCenter = rect.midX + bodyOffsetX
        let left = bodyCenter - resolvedWidth / 2
        let right = bodyCenter + resolvedWidth / 2
        let topLeft = rect.midX - resolvedTopWidth / 2
        let topRight = rect.midX + resolvedTopWidth / 2
        let shoulderControl = 0.5523

        var path = Path()
        path.move(to: CGPoint(x: topLeft + resolvedTopRadius, y: top))
        path.addLine(to: CGPoint(x: topRight - resolvedTopRadius, y: top))
        path.addCurve(
            to: CGPoint(x: right, y: top + resolvedShoulderDepth),
            control1: CGPoint(
                x: topRight - resolvedTopRadius + (right - topRight + resolvedTopRadius) * shoulderControl,
                y: top
            ),
            control2: CGPoint(x: right, y: top + resolvedShoulderDepth * (1 - shoulderControl))
        )
        path.addLine(to: CGPoint(x: right, y: bottom - resolvedBottomRadius))
        path.addCurve(
            to: CGPoint(x: right - resolvedBottomRadius, y: bottom),
            control1: CGPoint(x: right, y: bottom - resolvedBottomRadius * (1 - shoulderControl)),
            control2: CGPoint(x: right - resolvedBottomRadius * (1 - shoulderControl), y: bottom)
        )
        path.addLine(to: CGPoint(x: left + resolvedBottomRadius, y: bottom))
        path.addCurve(
            to: CGPoint(x: left, y: bottom - resolvedBottomRadius),
            control1: CGPoint(x: left + resolvedBottomRadius * (1 - shoulderControl), y: bottom),
            control2: CGPoint(x: left, y: bottom - resolvedBottomRadius * (1 - shoulderControl))
        )
        path.addLine(to: CGPoint(x: left, y: top + resolvedShoulderDepth))
        path.addCurve(
            to: CGPoint(x: topLeft + resolvedTopRadius, y: top),
            control1: CGPoint(x: left, y: top + resolvedShoulderDepth * (1 - shoulderControl)),
            control2: CGPoint(
                x: topLeft + resolvedTopRadius - (topLeft - left + resolvedTopRadius) * shoulderControl,
                y: top
            )
        )
        path.closeSubpath()
        return path
    }

    func inset(by amount: CGFloat) -> NotchMorphShape {
        var copy = self
        copy.insetAmount += amount
        return copy
    }
}

struct NotchBoardView: View {
    @ObservedObject var store: OpenLoopStore
    @ObservedObject var codexRunner: CodexRunner
    @ObservedObject var personalization: PersonalizationStore
    @ObservedObject var calendarProvider: CalendarProvider
    @ObservedObject var presentation: NotchPresentationModel
    let onClose: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @State private var selectedSection: BoardSection = ProcessInfo.processInfo.environment["OPENLOOPS_PREVIEW_SECTION"]
        .flatMap(BoardSection.init(rawValue:)) ?? .home
    @State private var selectedStatus: LoopStatus = ProcessInfo.processInfo.environment["OPENLOOPS_PREVIEW_SELECTED_STATUS"]
        .flatMap(LoopStatus.init(rawValue:)) ?? .doing
    @State private var selectedCalendarDay = Calendar.current.startOfDay(for: Date())
    @State private var isAdding = false
    @State private var isSettingsPresented = ProcessInfo.processInfo.environment["OPENLOOPS_PREVIEW_SETTINGS"] == "1"
    @State private var personalizePage: PersonalizePage = ProcessInfo.processInfo.environment["OPENLOOPS_PREVIEW_PERSONALIZE_PAGE"]
        .flatMap(PersonalizePage.init(rawValue:)) ?? .profile
    @State private var isFinishDatePickerPresented = false
    @State private var finishDateInteractionLease: UUID?
    @State private var photoInteractionLease: UUID?
    @State private var newTitle = ""
    @State private var newPriority: LoopPriority = .p1
    @State private var newStatus: LoopStatus = .doing
    @State private var hoveredStatus: LoopStatus? = ProcessInfo.processInfo.environment["OPENLOOPS_PREVIEW_HOVER_STATUS"]
        .flatMap(LoopStatus.init(rawValue:))
    @State private var settingsPreferredName = ""
    @State private var settingsWorkspaceName = ""
    @State private var primaryGoalTitle = ""
    @State private var primaryGoalMetric = ""
    @State private var primaryGoalCurrent = ""
    @State private var primaryGoalTarget = ""
    @State private var primaryGoalUnit: GoalValueUnit = .usd
    @State private var primaryGoalDate = Calendar.current.date(byAdding: .day, value: 60, to: Date()) ?? Date()
    @State private var finishDateDraft = Calendar.current.date(byAdding: .day, value: 60, to: Date()) ?? Date()
    @Namespace private var statusSelection
    @FocusState private var addFieldFocused: Bool

    private var theme: FounderTheme {
        FounderTheme(appearance: personalization.appearance, reduceTransparency: reduceTransparency)
    }
    private var groupedBackground: Color { theme.groupedBackground }
    private let border = Color.white.opacity(0.085)
    private let primaryText = Color.white.opacity(0.96)
    private let secondaryText = Color.white.opacity(0.74)
    private var contentSurface: Color { theme.contentSurface }
    private var contentBorder: Color { theme.contentBorder }
    private var contentRadius: CGFloat { theme.nodeRadius }
    private var accent: Color { personalization.accentColor }
    private var secondaryAccent: Color { personalization.secondaryAccentColor }

    private func displayFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        theme.displayFont(size: size, weight: weight)
    }

    private func interfaceFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        theme.interfaceFont(size: size, weight: weight)
    }

    var body: some View {
        let metrics = NotchMorphMetrics(
            progress: presentation.progress,
            notchWidth: presentation.notchWidth,
            notchHeight: presentation.notchHeight
        )
        let shellShape = NotchMorphShape(
            width: metrics.shellWidth,
            topWidth: metrics.topWidth,
            height: metrics.shellHeight,
            topRadius: metrics.topRadius,
            bottomRadius: metrics.bottomRadius,
            shoulderDepth: metrics.shoulderDepth,
            bodyOffsetX: presentation.horizontalPull * metrics.pullEnvelope
        )

        ZStack(alignment: .top) {
            panelSurface

            boardContent
                .opacity(metrics.contentProgress)
                .scaleEffect(0.975 + metrics.contentProgress * 0.025, anchor: .top)
                .offset(y: -8 * (1 - metrics.contentProgress))
                .blur(radius: 3.5 * (1 - metrics.contentProgress))
        }
        .frame(width: 720, height: 350, alignment: .top)
        .mask(shellShape)
        .overlay(
            shellShape
                .inset(by: 1)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.105 * metrics.settledProgress),
                            Color.white.opacity(0.035 * metrics.settledProgress),
                            Color.clear
                        ],
                        startPoint: .top,
                        endPoint: UnitPoint(x: 0.5, y: 0.68)
                    ),
                    lineWidth: 0.8
                )
                .blur(radius: 0.55)
                .mask(shellShape)
        )
        .opacity(metrics.shellVisibility)
        .shadow(color: Color.black.opacity(0.44 * metrics.settledProgress), radius: 30, x: 0, y: 16)
        .allowsHitTesting(metrics.isInteractive)
        .accessibilityHidden(!metrics.isInteractive)
        .preferredColorScheme(.dark)
        .environment(\.founderTheme, theme)
        .onAppear {
            loadIdentityEditor()
            loadPrimaryGoalEditor()
        }
        .onExitCommand {
            if isFinishDatePickerPresented {
                closeFinishDatePicker()
            } else if isSettingsPresented {
                dismissSettings()
            } else {
                onClose()
            }
        }
        .onDisappear(perform: releaseTransientInteractions)
    }

    private var boardContent: some View {
        Group {
            if isEditorialHome {
                homeContent
            } else {
                VStack(spacing: 0) {
                    header

                    if isSettingsPresented {
                        settingsContent
                    } else {
                        sectionContent
                    }

                    if showsContextualFooter {
                        footer
                    }
                }
            }
        }
        .frame(width: 720, height: 350)
    }

    private var panelSurface: some View {
        ZStack {
            switch theme.effectiveSurfaceID {
            case .glass:
                Rectangle()
                    .fill(.ultraThinMaterial)
                Rectangle()
                    .fill(Color(red: 0.008, green: 0.010, blue: 0.014).opacity(0.30))
                Rectangle()
                    .fill(theme.accentGradient)
                    .opacity(0.10)
                    .mask(
                        LinearGradient(
                            colors: [.white, .clear],
                            startPoint: .top,
                            endPoint: UnitPoint(x: 0.5, y: 0.58)
                        )
                    )
            case .solidBlack:
                Rectangle()
                    .fill(Color(red: 0.008, green: 0.009, blue: 0.011))
            default:
                Rectangle()
                    .fill(.thinMaterial)
                Rectangle()
                    .fill(Color(red: 0.012, green: 0.014, blue: 0.018).opacity(0.54))
            }
        }
        .frame(width: 720, height: 350)
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(headerTitle)
                    .font(displayFont(size: 25))
                    .foregroundStyle(primaryText)

                if !isEditorialHome {
                    Text(headerSubtitle)
                        .font(interfaceFont(size: 12, weight: .semibold))
                        .foregroundStyle(secondaryText)
                        .lineLimit(1)
                }
            }
            .frame(width: isEditorialHome ? 220 : 188, alignment: .leading)

            Spacer(minLength: 8)

            sectionSwitcher

            AppleNavigationButton(
                icon: .settings,
                isSelected: isSettingsPresented,
                accent: accent,
                secondaryAccent: secondaryAccent,
                label: "Personalize",
                action: presentSettings
            )

            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(CloseButtonStyle())
            .help("Close")
        }
        .padding(.horizontal, 20)
        .frame(height: 66)
    }

    private var isEditorialHome: Bool {
        selectedSection == .home && !isSettingsPresented
    }

    private var headerTitle: String {
        if isSettingsPresented { return "Personalize" }
        if selectedSection != .home { return personalization.workspaceName }

        let name = personalization.preferredName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Welcome" : "Hi \(name)!"
    }

    private var headerSubtitle: String {
        if isSettingsPresented { return "Make the notch feel like yours" }
        switch selectedSection {
        case .home:
            return "\(personalization.workspaceName)  ·  \(store.activeCount) active"
        case .loops:
            return "\(store.activeCount) active"
        case .calendar:
            return calendarProvider.message
        }
    }

    private var sectionSwitcher: some View {
        HStack(spacing: 6) {
            ForEach(BoardSection.allCases) { section in
                AppleNavigationButton(
                    icon: section.icon,
                    isSelected: !isSettingsPresented && selectedSection == section,
                    accent: accent,
                    secondaryAccent: secondaryAccent,
                    label: section.title,
                    action: { select(section) }
                )
            }
        }
    }

    @ViewBuilder
    private var sectionContent: some View {
        switch selectedSection {
        case .home:
            homeContent
        case .loops:
            loopsSection
        case .calendar:
            calendarContent
        }
    }

    private var homeContent: some View {
        ZStack(alignment: .topLeading) {
            Text(headerTitle)
                .font(displayFont(size: 34))
                .foregroundStyle(primaryText)
                .offset(x: 32, y: 44)

            Text("Next move")
                .font(interfaceFont(size: 22, weight: .bold))
                .foregroundStyle(primaryText)
                .offset(x: 32, y: 106)

            Group {
                if let focusItem {
                    homeFocus(item: focusItem)
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Nothing is pulling at you")
                            .font(interfaceFont(size: 15, weight: .bold))
                            .foregroundStyle(primaryText)
                        Text("The board is clear.")
                            .font(interfaceFont(size: 12, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.84))
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(contentSurface, in: RoundedRectangle(cornerRadius: contentRadius, style: .continuous))
                }
            }
            .frame(width: 344, height: 76)
            .offset(x: 32, y: 137)

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Up next")
                        .font(interfaceFont(size: 18, weight: .bold))
                        .foregroundStyle(primaryText)
                    homeCalendarSignal
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Rectangle()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: 1, height: 76)
                    .padding(.top, 27)

                VStack(alignment: .leading, spacing: 5) {
                    Text("Primary goal")
                        .font(interfaceFont(size: 18, weight: .bold))
                        .foregroundStyle(primaryText)
                    homePrimaryGoal
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(width: 344)
            .offset(x: 32, y: 222)

            visionPhoto
                .frame(width: 294, height: 283)
                .offset(x: 410, y: 55)

            HStack(spacing: 10) {
                sectionSwitcher

                AppleNavigationButton(
                    icon: .settings,
                    isSelected: false,
                    accent: accent,
                    secondaryAccent: secondaryAccent,
                    label: "Personalize",
                    action: presentSettings
                )

                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(CloseButtonStyle())
                .help("Close")
            }
            .offset(x: 472, y: 19)
        }
        .frame(width: 720, height: 350, alignment: .topLeading)
    }

    private var focusItem: OpenLoop? {
        store.items(in: .doing).first ?? store.items(in: .next).first
    }

    private func homeFocus(item: OpenLoop) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Button {
                store.toggleCompletion(item)
            } label: {
                Image(systemName: "circle")
                    .font(interfaceFont(size: 19, weight: .medium))
                    .foregroundStyle(priorityColor(for: item.priority))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(RowControlButtonStyle())
            .accessibilityLabel("Complete \(item.title)")

            VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                    .font(interfaceFont(size: 15, weight: .bold))
                    .foregroundStyle(primaryText)
                    .lineLimit(1)

                if let dueAt = item.dueAt {
                    Text(homeDueLabel(dueAt))
                        .font(interfaceFont(size: 11.5, weight: .bold))
                        .foregroundStyle(dueAt < Calendar.current.startOfDay(for: Date()) ? Color.red.opacity(0.94) : Color.white.opacity(0.92))
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 76, maxHeight: 76, alignment: .topLeading)
        .background(contentSurface, in: RoundedRectangle(cornerRadius: contentRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: contentRadius, style: .continuous)
                .stroke(contentBorder, lineWidth: 1)
        )
    }

    private var homeCalendarSignal: some View {
        Button {
            select(.calendar)
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                if let event = calendarProvider.events.first {
                    Text(event.title)
                        .font(interfaceFont(size: 13, weight: .bold))
                        .foregroundStyle(primaryText)
                        .lineLimit(2)
                    Text(eventDateLabel(event))
                        .font(interfaceFont(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.82))
                } else {
                    Text(calendarProvider.isAuthorized ? "No meetings soon" : "Connect Calendar")
                        .font(interfaceFont(size: 13, weight: .bold))
                        .foregroundStyle(primaryText)
                    Text(calendarProvider.isAuthorized ? "Your time is clear" : "Only important dates")
                        .font(interfaceFont(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.82))
                }
            }
            .padding(11)
            .frame(maxWidth: .infinity, minHeight: 76, maxHeight: 76, alignment: .topLeading)
            .background(contentSurface, in: RoundedRectangle(cornerRadius: contentRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: contentRadius, style: .continuous)
                    .stroke(contentBorder, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(StatusTabButtonStyle())
        .help("Open Calendar")
    }

    private var homePrimaryGoal: some View {
        Button(action: presentSettings) {
            VStack(alignment: .leading, spacing: 4) {
                if let goal = personalization.primaryGoal {
                    if let target = goal.targetValue, target > 0 {
                        Text(primaryGoalTargetLabel(goal, target: target))
                            .font(displayFont(size: 21))
                            .foregroundStyle(primaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.74)
                            .allowsTightening(true)

                        HStack(spacing: 4) {
                            Text("\(goal.unit.format(goal.currentValue ?? 0)) now")
                            Spacer(minLength: 3)
                            Text(daysLeftLabel(goal.dueAt))
                        }
                        .font(interfaceFont(size: 10, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.84))

                        ProgressView(value: primaryGoalProgress(goal))
                            .progressViewStyle(.linear)
                            .tint(accent)
                            .controlSize(.mini)
                    } else {
                        Text(daysLeftLabel(goal.dueAt))
                            .font(displayFont(size: 21))
                            .foregroundStyle(primaryText)
                        Text(goal.title)
                            .font(interfaceFont(size: 11.5, weight: .bold))
                            .foregroundStyle(primaryText)
                            .lineLimit(1)
                    }
                } else {
                    Text("Set the finish line")
                        .font(displayFont(size: 21))
                        .foregroundStyle(primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.74)
                        .allowsTightening(true)
                    Text("Metric + deadline")
                        .font(interfaceFont(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.82))
                }
            }
            .padding(11)
            .frame(maxWidth: .infinity, minHeight: 76, maxHeight: 76, alignment: .topLeading)
            .background(contentSurface, in: RoundedRectangle(cornerRadius: contentRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: contentRadius, style: .continuous)
                    .stroke(contentBorder, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(StatusTabButtonStyle())
        .help("Edit the primary goal")
    }

    private var visionPhoto: some View {
        Group {
            if let url = personalization.photoURL,
               let image = NSImage(contentsOf: url) {
                Button(action: choosePhotoWithLease) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 294, height: 283)
                        .clipped()
                }
                .buttonStyle(StatusTabButtonStyle())
                .clipShape(RoundedRectangle(cornerRadius: theme.visionRadius, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: theme.visionRadius, style: .continuous)
                        .stroke(Color.white.opacity(0.14), lineWidth: 1)
                )
                .help("Choose a different image")
            } else {
                Button {
                    choosePhotoWithLease()
                } label: {
                    VStack(spacing: 8) {
                        ClayIconView(name: .photo, style: personalization.iconStyle, size: 34)
                        Text("Add a personal photo")
                            .font(interfaceFont(size: 14, weight: .bold))
                        Text("A dream, a person, a logo")
                            .font(interfaceFont(size: 12, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.82))
                    }
                    .foregroundStyle(primaryText)
                    .frame(width: 294, height: 283)
                    .background(contentSurface, in: RoundedRectangle(cornerRadius: theme.visionRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: theme.visionRadius, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(StatusTabButtonStyle())
            }
        }
    }

    private var loopsSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                statusTabs

                Button(action: toggleAddComposer) {
                    HStack(spacing: 5) {
                        Image(systemName: isAdding ? "xmark" : "plus")
                            .font(interfaceFont(size: 10.5, weight: .bold))
                        Text(isAdding ? "Cancel" : "New")
                    }
                }
                .buttonStyle(HeaderActionButtonStyle(isEmphasized: !isAdding, accent: accent))
                .keyboardShortcut("n", modifiers: .command)
                .help(isAdding ? "Cancel adding a move" : "Add a move")
            }
            .padding(.trailing, 16)

            Divider()
                .overlay(border)
                .padding(.horizontal, 20)

            loopsContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusTabs: some View {
        HStack(spacing: 4) {
            ForEach(LoopStatus.allCases) { status in
                let isSelected = selectedStatus == status
                let isHovered = hoveredStatus == status

                Button {
                    select(status)
                } label: {
                    HStack(spacing: 6) {
                        Text(status.title)
                            .font(interfaceFont(size: 11.5, weight: isSelected ? .semibold : .medium))

                        Text("\(store.count(in: status))")
                            .font(interfaceFont(size: 10.5, weight: .semibold))
                            .foregroundStyle(isSelected ? Color.white.opacity(0.70) : secondaryText.opacity(isHovered ? 1 : 0.76))
                            .contentTransition(.numericText())
                    }
                    .foregroundStyle(isSelected || isHovered ? primaryText : secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background {
                        ZStack {
                            Rectangle().fill(Color.white.opacity(0.001))
                            if isSelected {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(accent.opacity(0.13))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .stroke(accent.opacity(0.18), lineWidth: 1)
                                    )
                                    .shadow(color: accent.opacity(0.11), radius: 9, y: 4)
                                    .matchedGeometryEffect(id: "selected-status-surface", in: statusSelection)
                            } else if isHovered {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.white.opacity(0.065))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .stroke(Color.white.opacity(0.055), lineWidth: 1)
                                    )
                            }
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if isSelected {
                            Capsule()
                                .fill(accent)
                                .frame(width: 30, height: 2)
                                .offset(y: 1)
                                .matchedGeometryEffect(id: "selected-status-underline", in: statusSelection)
                        }
                    }
                    .contentShape(Rectangle())
                    .animation(.easeOut(duration: 0.14), value: isHovered)
                }
                .buttonStyle(StatusTabButtonStyle())
                .frame(maxWidth: .infinity, minHeight: 42)
                .contentShape(Rectangle())
                .onHover { hovering in
                    withAnimation(.easeOut(duration: 0.14)) {
                        if hovering {
                            hoveredStatus = status
                        } else if hoveredStatus == status {
                            hoveredStatus = nil
                        }
                    }
                }
                .accessibilityLabel("\(status.title), \(store.count(in: status)) items")
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
        .padding(.leading, 16)
        .padding(.bottom, 4)
    }

    private var loopsContent: some View {
        VStack(spacing: 7) {
            if isAdding {
                addComposer
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            let visibleItems = store.items(in: selectedStatus)
            if visibleItems.isEmpty {
                emptyState
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                            LoopRow(
                                item: item,
                                accent: accent,
                                onToggle: { store.toggleCompletion(item) },
                                onMove: { status in store.move(item, to: status) },
                                codexAction: codexRunner.action(for: item),
                                isCodexBusy: codexRunner.isRunning,
                                onRunWithCodex: { codexRunner.run(item) },
                                onDelete: {
                                    NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
                                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                                        store.delete(item)
                                    }
                                }
                            )

                            if index < visibleItems.count - 1 {
                                Divider()
                                    .overlay(Color.white.opacity(0.065))
                                    .padding(.leading, 46)
                            }
                        }
                    }
                    .background(contentSurface, in: RoundedRectangle(cornerRadius: contentRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: contentRadius, style: .continuous)
                            .stroke(contentBorder, lineWidth: 1)
                    )
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private var addComposer: some View {
        HStack(spacing: 10) {
            TextField("Capture a move…", text: $newTitle)
                .textFieldStyle(.plain)
                .font(interfaceFont(size: 13, weight: .regular))
                .foregroundStyle(primaryText)
                .focused($addFieldFocused)
                .onSubmit(addItem)

            Picker("Priority", selection: $newPriority) {
                ForEach(LoopPriority.allCases) { priority in
                    Text(priority.rawValue).tag(priority)
                }
            }
            .labelsHidden()
            .frame(width: 58)

            Picker("Status", selection: $newStatus) {
                ForEach(LoopStatus.allCases.filter { $0 != .done }) { status in
                    Text(status.title).tag(status)
                }
            }
            .labelsHidden()
            .frame(width: 86)

            Button("Add", action: addItem)
                .buttonStyle(HeaderActionButtonStyle(isEmphasized: true, accent: accent))
                .disabled(newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.horizontal, 13)
        .frame(height: 46)
        .background(contentSurface, in: RoundedRectangle(cornerRadius: contentRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: contentRadius, style: .continuous)
                .stroke(accent.opacity(0.38), lineWidth: 1)
        )
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text(emptyStateTitle)
                .font(interfaceFont(size: 13, weight: .semibold))
                .foregroundStyle(primaryText)
            Text(emptyStateMessage)
                .font(interfaceFont(size: 11, weight: .regular))
                .foregroundStyle(secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateTitle: String {
        switch selectedStatus {
        case .waiting: return "Nothing blocked"
        case .done: return "Nothing completed yet"
        case .doing, .next: return "No moves here"
        }
    }

    private var emptyStateMessage: String {
        switch selectedStatus {
        case .waiting:
            return "Moves held by a person, permission, or named dependency appear here."
        case .done:
            return "Finished work stays visible here."
        case .doing, .next:
            return "Choose New to capture the next one."
        }
    }

    private var calendarContent: some View {
        VStack(spacing: 0) {
            weekStrip

            Divider()
                .overlay(border)
                .padding(.horizontal, 20)

            if calendarProvider.isAuthorized {
                HStack(alignment: .top, spacing: 12) {
                    calendarEvents
                        .padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(contentSurface, in: RoundedRectangle(cornerRadius: contentRadius, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: contentRadius, style: .continuous)
                                .stroke(contentBorder, lineWidth: 1)
                        )

                    calendarDeadlines
                        .padding(12)
                        .frame(width: 244)
                        .frame(maxHeight: .infinity, alignment: .topLeading)
                        .background(contentSurface, in: RoundedRectangle(cornerRadius: contentRadius, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: contentRadius, style: .continuous)
                                .stroke(contentBorder, lineWidth: 1)
                        )
                }
                .padding(.horizontal, 20)
                .padding(.top, 9)
                .padding(.bottom, 8)
            } else {
                calendarPermissionState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var weekStrip: some View {
        HStack(spacing: 8) {
            ForEach(nextSevenDays, id: \.self) { day in
                let isSelected = Calendar.current.isDate(day, inSameDayAs: selectedCalendarDay)
                let isToday = Calendar.current.isDateInToday(day)
                Button {
                    withAnimation(.easeOut(duration: 0.16)) {
                        selectedCalendarDay = day
                    }
                } label: {
                    VStack(spacing: 3) {
                        Text(shortWeekday(day))
                            .font(interfaceFont(size: 8.5, weight: .semibold))
                        Text(dayNumber(day))
                            .font(interfaceFont(size: 11.5, weight: isSelected ? .semibold : .medium))
                    }
                    .foregroundStyle(isSelected ? primaryText : secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 43)
                    .background(
                        isSelected ? accent.opacity(0.14) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
                    .overlay {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(accent.opacity(0.22), lineWidth: 1)
                        } else if isToday {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(accent.opacity(0.32), lineWidth: 1)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(StatusTabButtonStyle())
            }

            Button {
                if calendarProvider.isAuthorized {
                    calendarProvider.refresh()
                } else {
                    calendarProvider.connectOrOpenSettings()
                }
            } label: {
                Group {
                    if calendarProvider.isAuthorized {
                        HStack(spacing: 5) {
                            Circle()
                                .fill(Color(nsColor: .systemGreen))
                                .frame(width: 5, height: 5)
                            Text("Live")
                        }
                    } else {
                        Text("Connect")
                    }
                }
                .font(interfaceFont(size: 9.5, weight: .semibold))
                .foregroundStyle(calendarProvider.isAuthorized ? primaryText : accent)
                .frame(width: 58, height: 43)
                .background(Color.white.opacity(calendarProvider.isAuthorized ? 0.045 : 0), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color.white.opacity(calendarProvider.isAuthorized ? 0.08 : 0), lineWidth: 1)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(StatusTabButtonStyle())
            .help(calendarProvider.isAuthorized ? "Synced automatically. Click to sync now." : "Connect Calendar")
            .accessibilityLabel(calendarProvider.isAuthorized ? "Calendar live. Sync now" : "Connect Calendar")
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    private var calendarEvents: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(Calendar.current.isDateInToday(selectedCalendarDay) ? "TODAY" : selectedDayTitle)
                .font(interfaceFont(size: 10, weight: .bold))
                .tracking(0.35)
                .foregroundStyle(accent)

            let events = selectedDayEvents
            if events.isEmpty {
                Text("Nothing scheduled")
                    .font(interfaceFont(size: 13, weight: .semibold))
                    .foregroundStyle(primaryText)
                Text("This day has room to breathe.")
                    .font(interfaceFont(size: 10.5))
                    .foregroundStyle(secondaryText)
            } else {
                ForEach(events.prefix(3)) { event in
                    HStack(spacing: 10) {
                        Capsule()
                            .fill(accent)
                            .frame(width: 3, height: 28)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(event.title)
                                .font(interfaceFont(size: 11.5, weight: .semibold))
                                .foregroundStyle(primaryText)
                                .lineLimit(1)
                            Text("\(eventTimeLabel(event))  ·  \(event.sourceLabel)")
                                .font(interfaceFont(size: 10, weight: .medium))
                                .foregroundStyle(secondaryText)
                                .lineLimit(1)
                        }
                    }
                    .frame(height: 37)
                }
            }
        }
    }

    private var calendarDeadlines: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("IMPORTANT DATES")
                .font(interfaceFont(size: 10, weight: .bold))
                .tracking(0.35)
                .foregroundStyle(secondaryText)

            if deadlineSignals.isEmpty {
                Text("No countdowns yet")
                    .font(interfaceFont(size: 11.5, weight: .semibold))
                    .foregroundStyle(primaryText)
                Button("Add one in Settings", action: presentSettings)
                    .buttonStyle(.plain)
                    .font(interfaceFont(size: 9.5, weight: .semibold))
                    .foregroundStyle(accent)
            } else {
                ForEach(deadlineSignals.prefix(3)) { deadline in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(countdownLabel(deadline.dueAt))
                            .font(interfaceFont(size: 14, weight: .semibold))
                            .foregroundStyle(accent)
                            .frame(width: 48, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(deadline.title)
                                .font(interfaceFont(size: 11, weight: .semibold))
                                .foregroundStyle(primaryText)
                                .lineLimit(1)
                            Text(deadline.source)
                                .font(interfaceFont(size: 9.5, weight: .medium))
                                .foregroundStyle(secondaryText)
                        }
                    }
                    .frame(height: 35)
                }
            }
        }
    }

    private var calendarPermissionState: some View {
        VStack(spacing: 9) {
            Text(calendarProvider.isDenied ? "Calendar access is off" : "See only what matters next")
                .font(interfaceFont(size: 14, weight: .semibold))
                .foregroundStyle(primaryText)
            Text(calendarProvider.isDenied ? "Open Privacy settings to allow upcoming event access." : "Connect once. Every iCloud and Google calendar enabled in Internet Accounts will appear here and stay live.")
                .font(interfaceFont(size: 10.5))
                .foregroundStyle(secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 390)
            Button(calendarProvider.isDenied ? "Open Privacy Settings" : "Connect Calendar") {
                calendarProvider.connectOrOpenSettings()
            }
            .buttonStyle(HeaderActionButtonStyle(isEmphasized: true, accent: accent))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var settingsContent: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 5) {
                ForEach(PersonalizePage.allCases) { page in
                    personalizePageButton(page)
                }
                Spacer(minLength: 0)
            }
            .frame(width: 140)

            Group {
                switch personalizePage {
                case .profile: profileSettingsPage
                case .appearance: appearanceSettingsPage
                case .finishLine: finishLineSettingsPage
                case .calendar: calendarSettingsPage
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(contentSurface, in: RoundedRectangle(cornerRadius: contentRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: contentRadius, style: .continuous)
                    .stroke(contentBorder, lineWidth: 1)
            )
        }
        .padding(.horizontal, 20)
        .padding(.top, 9)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func personalizePageButton(_ page: PersonalizePage) -> some View {
        let isSelected = personalizePage == page
        return Button {
            if page != .finishLine { closeFinishDatePicker() }
            withAnimation(.easeOut(duration: 0.16)) { personalizePage = page }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: page.systemImage)
                    .frame(width: 16)
                Text(page.title)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(interfaceFont(size: 9, weight: .bold))
                }
            }
            .font(interfaceFont(size: 11.5, weight: .semibold))
            .foregroundStyle(Color.white.opacity(isSelected ? 0.98 : 0.76))
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(
                isSelected ? accent.opacity(0.24) : groupedBackground,
                in: RoundedRectangle(cornerRadius: max(6, contentRadius - 4), style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: max(6, contentRadius - 4), style: .continuous)
                    .stroke(isSelected ? accent.opacity(0.48) : Color.white.opacity(0.06), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(StatusTabButtonStyle())
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var profileSettingsPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingsPageHeading("Make it yours", detail: "Your greeting, workspace, and vision image.")

            HStack(spacing: 8) {
                identityTextField("Your name", text: $settingsPreferredName)
                identityTextField("Workspace name", text: $settingsWorkspaceName)
                Button("Save", action: saveIdentity)
                    .buttonStyle(HeaderActionButtonStyle(isEmphasized: true, accent: accent))
            }

            HStack(spacing: 10) {
                if let url = personalization.photoURL,
                   let image = NSImage(contentsOf: url) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 74, height: 74)
                        .clipShape(RoundedRectangle(cornerRadius: contentRadius, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: contentRadius, style: .continuous)
                        .fill(groupedBackground)
                        .frame(width: 74, height: 74)
                        .overlay(Image(systemName: "photo").foregroundStyle(secondaryText))
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Keep the why close")
                        .font(interfaceFont(size: 13, weight: .bold))
                        .foregroundStyle(primaryText)
                    Text("Choose a person, place, dream, logo, or finish line that matters to you.")
                        .font(interfaceFont(size: 11, weight: .medium))
                        .foregroundStyle(secondaryText)
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        Button(personalization.photoURL == nil ? "Choose photo…" : "Replace…", action: choosePhotoWithLease)
                            .buttonStyle(HeaderActionButtonStyle(accent: accent))
                        if personalization.photoURL != nil {
                            Button("Remove", action: personalization.removePhoto)
                                .buttonStyle(HeaderActionButtonStyle(accent: accent))
                        }
                    }
                }
            }
        }
    }

    private var appearanceSettingsPage: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                settingsPageHeading("Style", detail: "Start somewhere, then mix anything.")

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 5) {
                    ForEach(AppearancePresetID.builtIns, id: \.rawValue) { preset in
                        appearanceOption(
                            preset.title,
                            isSelected: personalization.appearance.presetID == preset,
                            action: { personalization.applyPreset(preset) }
                        )
                    }
                }

                settingsSectionTitle("ACCENT")

                HStack(spacing: 6) {
                    appearanceOption("Solid", isSelected: personalization.appearance.accent.mode == .solid) {
                        personalization.updateAccentMode(.solid)
                    }
                    appearanceOption("Gradient", isSelected: personalization.appearance.accent.mode == .gradient) {
                        personalization.updateAccentMode(.gradient)
                    }
                }

                Text("Full spectrum · exact 8-bit RGB + hex")
                    .font(interfaceFont(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.78))

                HStack(spacing: 8) {
                    ColorPicker("First colour", selection: accentColorBinding(stopIndex: 0), supportsOpacity: false)
                        .labelsHidden()
                        .frame(width: 30)
                    Text(personalization.appearance.accent.primaryColor.hex)
                        .font(interfaceFont(size: 10.5, weight: .semibold))
                        .foregroundStyle(primaryText)

                    if personalization.appearance.accent.mode == .gradient {
                        ColorPicker("Second colour", selection: accentColorBinding(stopIndex: 1), supportsOpacity: false)
                            .labelsHidden()
                            .frame(width: 30)
                        Text(personalization.appearance.accent.secondaryColor.hex)
                            .font(interfaceFont(size: 10.5, weight: .semibold))
                            .foregroundStyle(primaryText)
                    }
                }

                if personalization.appearance.accent.mode == .gradient {
                    HStack(spacing: 8) {
                        Slider(value: accentAngleBinding, in: 0...359, step: 1)
                            .tint(accent)
                        Text("\(Int(personalization.appearance.accent.angleDegrees.rounded()))°")
                            .font(interfaceFont(size: 10.5, weight: .bold))
                            .foregroundStyle(primaryText)
                            .frame(width: 34, alignment: .trailing)
                        RoundedRectangle(cornerRadius: max(3, contentRadius - 5), style: .continuous)
                            .fill(theme.accentGradient)
                            .frame(width: 52, height: 18)
                    }
                } else {
                    RoundedRectangle(cornerRadius: max(3, contentRadius - 5), style: .continuous)
                        .fill(theme.accentGradient)
                        .frame(height: 18)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

            Divider().overlay(Color.white.opacity(0.10))

            VStack(alignment: .leading, spacing: 7) {
                settingsSectionTitle("MIX & MATCH")
                appearanceMenuRow(
                    "Display font",
                    options: FontChoiceID.builtIns,
                    selected: personalization.appearance.displayFontID,
                    title: { $0.title },
                    action: personalization.updateDisplayFont
                )
                appearanceMenuRow(
                    "UI font",
                    options: FontChoiceID.builtIns,
                    selected: personalization.appearance.interfaceFontID,
                    title: { $0.title },
                    action: personalization.updateInterfaceFont
                )
                appearanceMenuRow(
                    "Move cards",
                    options: NodeStyleID.builtIns,
                    selected: personalization.appearance.nodeStyleID,
                    title: { $0.title },
                    action: personalization.updateNodeStyle
                )
                appearanceMenuRow(
                    "Surface",
                    options: SurfaceStyleID.builtIns,
                    selected: personalization.appearance.surfaceStyleID,
                    title: { $0.title },
                    action: personalization.updateSurfaceStyle
                )
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var finishLineSettingsPage: some View {
        VStack(alignment: .leading, spacing: 11) {
            settingsPageHeading("Primary finish line", detail: "One measurable thing worth checking every day.")

            HStack(spacing: 7) {
                goalTextField("What are you making true?", text: $primaryGoalTitle)
                Button("Save", action: savePrimaryGoal)
                    .buttonStyle(HeaderActionButtonStyle(isEmphasized: true, accent: accent))
                    .disabled(primaryGoalTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if personalization.primaryGoal != nil {
                    Button {
                        personalization.clearPrimaryGoal()
                        resetPrimaryGoalEditor()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(CloseButtonStyle())
                    .help("Clear primary goal")
                }
            }

            HStack(spacing: 7) {
                HStack(spacing: 4) {
                    ForEach(GoalValueUnit.allCases) { unit in
                        appearanceOption(unit.title, isSelected: primaryGoalUnit == unit) {
                            primaryGoalUnit = unit
                        }
                    }
                }
                goalTextField("Now", text: $primaryGoalCurrent, width: 72)
                goalTextField("Target", text: $primaryGoalTarget, width: 82)
                goalTextField("Metric", text: $primaryGoalMetric)
            }

            HStack(spacing: 7) {
                Text("Target date")
                    .font(interfaceFont(size: 12, weight: .bold))
                    .foregroundStyle(primaryText)
                Spacer()
                Button("30 days") { setPrimaryGoalDays(30) }
                    .buttonStyle(HeaderActionButtonStyle(accent: accent))
                Button("60 days") { setPrimaryGoalDays(60) }
                    .buttonStyle(HeaderActionButtonStyle(accent: accent))
                Button(finishDateLabel, action: openFinishDatePicker)
                    .buttonStyle(HeaderActionButtonStyle(isEmphasized: true, accent: accent))
                    .popover(isPresented: $isFinishDatePickerPresented, arrowEdge: .top) {
                        finishDatePopover
                    }
            }

            if let goal = personalization.primaryGoal {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(theme.accentGradient)
                        .frame(width: 54, height: 6)
                    Text("\(goal.title) · \(daysLeftLabel(goal.dueAt))")
                        .font(interfaceFont(size: 11.5, weight: .semibold))
                        .foregroundStyle(primaryText)
                        .lineLimit(1)
                }
            }
        }
    }

    private var finishDatePopover: some View {
        VStack(spacing: 10) {
            DatePicker("Target date", selection: $finishDateDraft, in: Date()..., displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
            HStack {
                Button("Cancel", action: closeFinishDatePicker)
                Spacer()
                Button("Done") {
                    primaryGoalDate = finishDateDraft
                    savePrimaryGoal()
                    closeFinishDatePicker()
                }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
        .frame(width: 260)
        .onDisappear(perform: releaseFinishDateInteraction)
    }

    private var calendarSettingsPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingsPageHeading("Calendar", detail: "Connect once. Apple and every enabled Google account stay live.")

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(calendarProvider.isAuthorized ? "Calendar is connected" : "Calendar access")
                        .font(interfaceFont(size: 14, weight: .bold))
                        .foregroundStyle(primaryText)
                    Text(calendarProvider.isAuthorized ? calendarProvider.accountCountLabel : calendarProvider.message)
                        .font(interfaceFont(size: 11.5, weight: .semibold))
                        .foregroundStyle(secondaryText)
                }
                Spacer()
                Button(calendarProvider.isAuthorized ? "Manage accounts…" : calendarProvider.isDenied ? "Privacy settings" : "Connect") {
                    if calendarProvider.isDenied {
                        calendarProvider.openPrivacySettings()
                    } else if calendarProvider.isAuthorized {
                        calendarProvider.openInternetAccounts()
                    } else {
                        calendarProvider.connectOrOpenSettings()
                    }
                }
                .buttonStyle(HeaderActionButtonStyle(isEmphasized: !calendarProvider.isAuthorized, accent: accent))
            }

            if calendarProvider.isAuthorized {
                HStack(spacing: 6) {
                    ForEach(calendarProvider.accounts.prefix(4)) { account in
                        calendarAccountChip(account)
                    }
                }
            }

            Text("Founder’s Office reads upcoming event titles and times from the calendars already enabled in macOS. It does not reconnect each time the notch opens.")
                .font(interfaceFont(size: 11.5, weight: .medium))
                .foregroundStyle(secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func settingsPageHeading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(displayFont(size: 20))
                .foregroundStyle(primaryText)
            Text(detail)
                .font(interfaceFont(size: 11.5, weight: .semibold))
                .foregroundStyle(secondaryText)
        }
    }

    private func identityTextField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(interfaceFont(size: 12, weight: .medium))
            .foregroundStyle(primaryText)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(groupedBackground, in: RoundedRectangle(cornerRadius: max(6, contentRadius - 4), style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: max(6, contentRadius - 4), style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .onSubmit(saveIdentity)
    }

    private func appearanceOption(
        _ title: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                    .lineLimit(1)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(interfaceFont(size: 8.5, weight: .bold))
                }
            }
            .font(interfaceFont(size: 10.5, weight: .semibold))
            .foregroundStyle(Color.white.opacity(isSelected ? 0.98 : 0.78))
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 27)
            .background(
                isSelected ? accent.opacity(0.25) : groupedBackground,
                in: RoundedRectangle(cornerRadius: max(4, contentRadius - 6), style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: max(4, contentRadius - 6), style: .continuous)
                    .stroke(isSelected ? accent.opacity(0.50) : Color.white.opacity(0.07), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(StatusTabButtonStyle())
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func appearanceMenuRow<ID: AppearanceIdentifier>(
        _ label: String,
        options: [ID],
        selected: ID,
        title: @escaping (ID) -> String,
        action: @escaping (ID) -> Void
    ) -> some View {
        ZStack {
            HStack(spacing: 8) {
                Text(label)
                    .font(interfaceFont(size: 11.5, weight: .bold))
                    .foregroundStyle(primaryText)
                Spacer(minLength: 8)
                Text(title(selected))
                    .font(interfaceFont(size: 11.5, weight: .semibold))
                    .foregroundStyle(accent)
                Image(systemName: "chevron.up.chevron.down")
                    .font(interfaceFont(size: 9.5, weight: .bold))
                    .foregroundStyle(secondaryText)
            }

            Menu {
                ForEach(options, id: \.rawValue) { option in
                    Button {
                        action(option)
                    } label: {
                        HStack {
                            Text(title(option))
                            if option == selected {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel(label)
            .accessibilityValue(title(selected))
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 37)
        .background(
            groupedBackground,
            in: RoundedRectangle(cornerRadius: max(6, contentRadius - 4), style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: max(6, contentRadius - 4), style: .continuous)
                .stroke(Color.white.opacity(0.075), lineWidth: 1)
        )
        .contentShape(Rectangle())
    }

    private func accentColorBinding(stopIndex: Int) -> Binding<Color> {
        Binding(
            get: {
                let stops = personalization.appearance.accent.normalizedStops
                return stops[min(stopIndex, stops.count - 1)].color.swiftUIColor
            },
            set: { color in
                guard let rgb = RGB24Color(swiftUIColor: color) else { return }
                personalization.updateAccentColor(rgb, stopIndex: stopIndex)
            }
        )
    }

    private var accentAngleBinding: Binding<Double> {
        Binding(
            get: { personalization.appearance.accent.angleDegrees },
            set: personalization.updateAccentAngle
        )
    }

    private var finishDateLabel: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: primaryGoalDate)
    }

    private func openFinishDatePicker() {
        if finishDateInteractionLease == nil {
            finishDateInteractionLease = presentation.beginInteraction("finish-line-date")
        }
        finishDateDraft = primaryGoalDate
        isFinishDatePickerPresented = true
    }

    private func closeFinishDatePicker() {
        isFinishDatePickerPresented = false
        releaseFinishDateInteraction()
    }

    private func releaseFinishDateInteraction() {
        guard let lease = finishDateInteractionLease else { return }
        presentation.endInteraction(lease)
        finishDateInteractionLease = nil
    }

    private func choosePhotoWithLease() {
        if photoInteractionLease == nil {
            photoInteractionLease = presentation.beginInteraction("photo-picker")
        }
        personalization.choosePhoto {
            Task { @MainActor in
                guard let lease = photoInteractionLease else { return }
                presentation.endInteraction(lease)
                photoInteractionLease = nil
            }
        }
    }

    private func releaseTransientInteractions() {
        releaseFinishDateInteraction()
        if let lease = photoInteractionLease {
            presentation.endInteraction(lease)
            photoInteractionLease = nil
        }
    }

    private func settingsSectionTitle(_ title: String) -> some View {
        Text(title)
            .font(interfaceFont(size: 10.5, weight: .bold))
            .tracking(0.35)
            .foregroundStyle(secondaryText)
    }

    private func goalTextField(
        _ placeholder: String,
        text: Binding<String>,
        width: CGFloat? = nil
    ) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(interfaceFont(size: 11.5, weight: .medium))
            .foregroundStyle(primaryText)
            .padding(.horizontal, 8)
            .frame(width: width, height: 30)
            .background(groupedBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
    }

    private func calendarAccountChip(_ account: CalendarAccountSignal) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(account.providerTitle == "Google" ? Color(red: 0.26, green: 0.52, blue: 0.96) : accent)
                .frame(width: 5, height: 5)
            Text(account.title)
                .lineLimit(1)
        }
        .font(interfaceFont(size: 9.5, weight: .medium))
        .foregroundStyle(primaryText)
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(Color.white.opacity(0.045), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.07), lineWidth: 1))
        .help("\(account.providerTitle) · \(account.calendarCount) calendars")
    }

    private var showsContextualFooter: Bool {
        guard selectedSection == .loops, !isSettingsPresented else { return false }
        if store.recentlyDeleted != nil { return true }
        switch codexRunner.state {
        case .idle: return false
        case .running, .finished, .failed: return true
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            if store.recentlyDeleted != nil {
                Text("Task removed")
                Button("Undo") {
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) {
                        store.undoLastDelete()
                    }
                }
                .buttonStyle(FooterActionButtonStyle(accent: accent))
                .transition(.opacity.combined(with: .move(edge: .leading)))
            } else {
                CodexRunFooter(runner: codexRunner, accent: accent)
            }

            Spacer()
        }
        .font(interfaceFont(size: 10.5, weight: .medium))
        .foregroundStyle(secondaryText)
        .padding(.horizontal, 22)
        .frame(height: 38)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var deadlineSignals: [DeadlineSignal] {
        let primary = personalization.primaryGoal.map {
            DeadlineSignal(id: "primary-goal-\($0.id.uuidString)", title: $0.title, dueAt: $0.dueAt, source: "Primary goal")
        }.map { [$0] } ?? []

        let custom = personalization.milestones.map {
            DeadlineSignal(id: "milestone-\($0.id.uuidString)", title: $0.title, dueAt: $0.dueAt, source: "Goal")
        }

        let taskDeadlines = store.items
            .filter { $0.deletedAt == nil && $0.status != .done && $0.dueAt != nil }
            .compactMap { item -> DeadlineSignal? in
                guard let dueAt = item.dueAt else { return nil }
                return DeadlineSignal(id: "task-\(item.id.uuidString)", title: item.title, dueAt: dueAt, source: "Move")
            }

        return (primary + custom + taskDeadlines)
            .filter { Calendar.current.startOfDay(for: $0.dueAt) >= Calendar.current.startOfDay(for: Date()) }
            .sorted { $0.dueAt < $1.dueAt }
    }

    private var nextSevenDays: [Date] {
        let today = Calendar.current.startOfDay(for: Date())
        return (0..<7).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: today) }
    }

    private var selectedDayEvents: [CalendarSignal] {
        calendarProvider.events.filter { Calendar.current.isDate($0.startDate, inSameDayAs: selectedCalendarDay) }
    }

    private var selectedDayTitle: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "EEEE, d MMM"
        return formatter.string(from: selectedCalendarDay).uppercased()
    }

    private func presentSettings() {
        loadIdentityEditor()
        loadPrimaryGoalEditor()
        calendarProvider.syncOnOpen()
        withAnimation(.spring(response: 0.30, dampingFraction: 0.84)) {
            isSettingsPresented = true
            isAdding = false
        }
    }

    private func dismissSettings() {
        closeFinishDatePicker()
        saveIdentity()
        withAnimation(.spring(response: 0.30, dampingFraction: 0.84)) {
            isSettingsPresented = false
        }
    }

    private func select(_ section: BoardSection) {
        guard section != selectedSection || isSettingsPresented else { return }
        if isSettingsPresented {
            closeFinishDatePicker()
            saveIdentity()
        }
        if section == .calendar {
            calendarProvider.syncOnOpen()
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        withAnimation(.spring(response: 0.30, dampingFraction: 0.80, blendDuration: 0.08)) {
            selectedSection = section
            isSettingsPresented = false
            isAdding = false
        }
    }

    private func toggleAddComposer() {
        withAnimation(.easeOut(duration: 0.16)) {
            isAdding.toggle()
        }
        if isAdding {
            newStatus = selectedStatus == .done ? .doing : selectedStatus
            Task { @MainActor in addFieldFocused = true }
        }
    }

    private func loadPrimaryGoalEditor() {
        guard let goal = personalization.primaryGoal else {
            resetPrimaryGoalEditor()
            return
        }

        primaryGoalTitle = goal.title
        primaryGoalMetric = goal.metric
        primaryGoalCurrent = goal.currentValue.map(editingNumber) ?? ""
        primaryGoalTarget = goal.targetValue.map(editingNumber) ?? ""
        primaryGoalUnit = goal.unit
        primaryGoalDate = goal.dueAt
    }

    private func loadIdentityEditor() {
        settingsPreferredName = personalization.preferredName
        settingsWorkspaceName = personalization.workspaceName
    }

    private func saveIdentity() {
        personalization.updatePreferredName(settingsPreferredName)
        personalization.updateWorkspaceName(settingsWorkspaceName)
    }

    private func resetPrimaryGoalEditor() {
        primaryGoalTitle = ""
        primaryGoalMetric = ""
        primaryGoalCurrent = ""
        primaryGoalTarget = ""
        primaryGoalUnit = .usd
        primaryGoalDate = Calendar.current.date(byAdding: .day, value: 60, to: Date()) ?? Date()
    }

    private func savePrimaryGoal() {
        let cleanTitle = primaryGoalTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return }

        let parsedTarget = parsedGoalValue(primaryGoalTarget).flatMap { $0 > 0 ? $0 : nil }
        personalization.setPrimaryGoal(
            title: cleanTitle,
            metric: primaryGoalMetric,
            currentValue: parsedGoalValue(primaryGoalCurrent),
            targetValue: parsedTarget,
            unit: primaryGoalUnit,
            dueAt: primaryGoalDate
        )
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    private func setPrimaryGoalDays(_ days: Int) {
        primaryGoalDate = Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? primaryGoalDate
    }

    private func parsedGoalValue(_ text: String) -> Double? {
        let clean = text
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: "₹", with: "")
            .replacingOccurrences(of: "%", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : Double(clean)
    }

    private func editingNumber(_ value: Double) -> String {
        value.rounded() == value ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    private func select(_ status: LoopStatus) {
        guard status != selectedStatus else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        withAnimation(.spring(response: 0.30, dampingFraction: 0.78, blendDuration: 0.08)) {
            selectedStatus = status
        }
    }

    private func addItem() {
        store.add(title: newTitle, status: newStatus, priority: newPriority, dueAt: nil)
        selectedStatus = newStatus
        newTitle = ""
        isAdding = false
    }

    private func priorityColor(for priority: LoopPriority) -> Color {
        switch priority {
        case .p0: return Color(nsColor: .systemRed)
        case .p1: return Color(nsColor: .systemOrange)
        case .p2: return accent
        case .p3: return secondaryText
        }
    }

    private func homeDueLabel(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) { return "Due today" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "'Due' d MMM"
        return formatter.string(from: date)
    }

    private func primaryGoalTargetLabel(_ goal: PrimaryGoal, target: Double) -> String {
        let metric = goal.metric.trimmingCharacters(in: .whitespacesAndNewlines)
        return metric.isEmpty ? goal.unit.format(target) : "\(goal.unit.format(target)) \(metric)"
    }

    private func primaryGoalProgress(_ goal: PrimaryGoal) -> Double {
        guard let target = goal.targetValue, target > 0 else { return 0 }
        return min(max((goal.currentValue ?? 0) / target, 0), 1)
    }

    private func daysLeftLabel(_ date: Date) -> String {
        let start = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.startOfDay(for: date)
        let days = max(0, Calendar.current.dateComponents([.day], from: start, to: end).day ?? 0)
        if days == 0 { return "Today" }
        if days == 1 { return "1 day left" }
        return "\(days) days left"
    }

    private func countdownLabel(_ date: Date) -> String {
        let start = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.startOfDay(for: date)
        let days = max(0, Calendar.current.dateComponents([.day], from: start, to: end).day ?? 0)
        if days == 0 { return "Today" }
        return "\(days)d"
    }

    private func eventDateLabel(_ event: CalendarSignal) -> String {
        if Calendar.current.isDateInToday(event.startDate) { return eventTimeLabel(event) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = event.isAllDay ? "EEE d MMM" : "EEE d MMM · h:mm a"
        return formatter.string(from: event.startDate)
    }

    private func eventTimeLabel(_ event: CalendarSignal) -> String {
        if event.isAllDay { return "All day" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: event.startDate)
    }

    private func shortWeekday(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "EEE"
        return formatter.string(from: date).uppercased()
    }

    private func dayNumber(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "d"
        return formatter.string(from: date)
    }
}

private struct LoopRow: View {
    @Environment(\.founderTheme) private var theme
    let item: OpenLoop
    let accent: Color
    let onToggle: () -> Void
    let onMove: (LoopStatus) -> Void
    let codexAction: CodexTaskAction
    let isCodexBusy: Bool
    let onRunWithCodex: () -> Void
    let onDelete: () -> Void

    private let primaryText = Color.white.opacity(0.95)
    private let secondaryText = Color.white.opacity(0.64)
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onToggle) {
                Image(systemName: item.status == .done ? "checkmark.circle.fill" : "circle")
                    .font(theme.interfaceFont(size: 19, weight: .medium))
                    .foregroundStyle(item.status == .done ? Color.green : priorityColor)
                    .frame(width: 34, height: 34)
                    .background(isHovered ? priorityColor.opacity(0.09) : Color.clear, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(RowControlButtonStyle())
            .accessibilityLabel(item.status == .done ? "Reopen \(item.title)" : "Complete \(item.title)")

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(item.priority.rawValue)
                        .font(theme.interfaceFont(size: 9, weight: .semibold))
                        .foregroundStyle(priorityColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(priorityColor.opacity(0.12), in: Capsule())

                    Text(item.title)
                        .font(theme.interfaceFont(size: 13.5, weight: .semibold))
                        .foregroundStyle(primaryText.opacity(item.status == .done ? 0.55 : 1))
                        .strikethrough(item.status == .done, color: secondaryText)
                        .lineLimit(1)
                }

                if !item.details.isEmpty {
                    Text(item.details)
                        .font(theme.interfaceFont(size: 10.5, weight: .regular))
                        .foregroundStyle(secondaryText)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            if let dueAt = item.dueAt {
                Text(dueLabel(dueAt))
                    .font(theme.interfaceFont(size: 10, weight: .medium))
                    .foregroundStyle(isOverdue(dueAt) && item.status != .done ? Color.red.opacity(0.9) : secondaryText)
            }

            Menu {
                Button(codexAction.label, action: onRunWithCodex)
                    .disabled(isCodexBusy)

                Divider()

                ForEach(LoopStatus.allCases) { status in
                    if status != item.status {
                        Button("Move to \(status.title)") { onMove(status) }
                    }
                }

                Divider()

                Button("Delete task", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
                    .font(theme.interfaceFont(size: 13, weight: .bold))
                    .foregroundStyle(secondaryText)
                    .frame(width: 34, height: 34)
                    .background(isHovered ? Color.white.opacity(0.07) : Color.clear, in: Circle())
                    .contentShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .frame(height: 58)
        .background(isHovered ? Color.white.opacity(0.045) : Color.clear)
        .offset(x: isHovered ? 2 : 0)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
                isHovered = hovering
            }
        }
    }

    private var priorityColor: Color {
        switch item.priority {
        case .p0: return Color(nsColor: .systemRed)
        case .p1: return Color(nsColor: .systemOrange)
        case .p2: return accent
        case .p3: return secondaryText
        }
    }

    private func dueLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "'Today'" : "d MMM"
        return formatter.string(from: date)
    }

    private func isOverdue(_ date: Date) -> Bool {
        date < Calendar.current.startOfDay(for: Date())
    }
}

private struct CodexRunFooter: View {
    @ObservedObject var runner: CodexRunner
    let accent: Color

    var body: some View {
        switch runner.state {
        case .idle:
            EmptyView()
        case let .running(title):
            ProgressView()
                .controlSize(.mini)
                .tint(.white.opacity(0.7))
            Text("Codex is working on \(title)")
                .lineLimit(1)
        case let .finished(title, summaryURL):
            Text("Codex finished \(title)")
                .lineLimit(1)
            Button("Review") { NSWorkspace.shared.open(summaryURL) }
                .buttonStyle(FooterActionButtonStyle(accent: accent))
        case let .failed(_, message):
            Text(message)
                .lineLimit(1)
                .foregroundStyle(Color.red.opacity(0.88))
        }
    }
}

private struct AppleNavigationButton: View {
    @Environment(\.founderTheme) private var theme
    let icon: ClayIconName
    let isSelected: Bool
    let accent: Color
    var secondaryAccent: Color? = nil
    let label: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon.systemFallback)
                .symbolRenderingMode(.monochrome)
                .font(theme.interfaceFont(size: 13, weight: .semibold))
                .foregroundStyle(Color.white.opacity(isSelected ? 0.98 : (isHovered ? 0.92 : 0.68)))
                .frame(width: 42, height: 28)
                .background(
                    isSelected
                        ? accent.opacity(0.30)
                        : Color.white.opacity(isHovered ? 0.10 : 0.045),
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [accent, secondaryAccent ?? accent],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .opacity(0.20)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(
                            isSelected ? accent.opacity(0.50) : Color.white.opacity(isHovered ? 0.14 : 0.07),
                            lineWidth: 1
                        )
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(StatusTabButtonStyle())
        .scaleEffect(isHovered ? 1.035 : 1)
        .offset(y: isHovered ? -1 : 0)
        .shadow(color: Color.black.opacity(isHovered ? 0.32 : 0.12), radius: isHovered ? 8 : 3, y: isHovered ? 4 : 1)
        .onHover { hovering in
            withAnimation(.spring(response: 0.24, dampingFraction: 0.76)) {
                isHovered = hovering
            }
        }
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

private struct HeaderActionButtonStyle: ButtonStyle {
    @Environment(\.founderTheme) private var theme
    var isEmphasized = false
    var accent = Color(nsColor: .systemBlue)

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(theme.interfaceFont(size: 11, weight: .semibold))
            .foregroundStyle(isEmphasized ? Color.white : Color.white.opacity(configuration.isPressed ? 0.92 : 0.68))
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(
                isEmphasized ? accent : Color.white.opacity(configuration.isPressed ? 0.10 : 0.055),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        isEmphasized ? accent.opacity(0.58) : Color.white.opacity(configuration.isPressed ? 0.14 : 0.08),
                        lineWidth: 1
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.11), value: configuration.isPressed)
    }
}

private struct StatusTabButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.975 : 1)
            .brightness(configuration.isPressed ? 0.035 : 0)
            .animation(.spring(response: 0.20, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

private struct RowControlButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            .animation(.spring(response: 0.18, dampingFraction: 0.68), value: configuration.isPressed)
    }
}

private struct FooterActionButtonStyle: ButtonStyle {
    @Environment(\.founderTheme) private var theme
    let accent: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(theme.interfaceFont(size: 10, weight: .semibold))
            .foregroundStyle(accent.opacity(configuration.isPressed ? 0.72 : 1))
            .padding(.horizontal, 6)
            .frame(height: 24)
            .background(Color.white.opacity(configuration.isPressed ? 0.08 : 0.045), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.10), value: configuration.isPressed)
    }
}

private struct CloseButtonStyle: ButtonStyle {
    @Environment(\.founderTheme) private var theme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(theme.interfaceFont(size: 10.5, weight: .semibold))
            .foregroundStyle(Color.white.opacity(configuration.isPressed ? 0.94 : 0.6))
            .frame(width: 28, height: 28)
            .background(Color.white.opacity(configuration.isPressed ? 0.11 : 0.055), in: Circle())
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.11), value: configuration.isPressed)
    }
}
