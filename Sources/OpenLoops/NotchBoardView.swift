import AppKit
import FounderOfficeCore
import FounderOfficeIdentity
import SwiftUI
import UniformTypeIdentifiers

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

    var icon: AppIconName {
        switch self {
        case .home: return .home
        case .loops: return .loops
        case .calendar: return .calendar
        }
    }
}

private enum PersonalizePage: String, CaseIterable, Identifiable {
    case profile
    case account
    case appearance
    case finishLine
    case calendar
    case health

    var id: String { rawValue }

    var title: String {
        switch self {
        case .profile: return "Profile"
        case .account: return "Account & Sync"
        case .appearance: return "Appearance"
        case .finishLine: return "Finish line"
        case .calendar: return "Calendar"
        case .health: return "Health"
        }
    }

    var systemImage: String {
        switch self {
        case .profile: return "person.crop.circle"
        case .account: return "person.badge.key"
        case .appearance: return "paintpalette"
        case .finishLine: return "scope"
        case .calendar: return "calendar"
        case .health: return "waveform.path.ecg.rectangle"
        }
    }
}

private enum AppearanceExitAction: Equatable {
    case page(PersonalizePage)
    case dismissSettings
    case section(BoardSection)
    case closeNotch
}

private struct DeadlineSignal: Identifiable {
    var id: String
    var title: String
    var dueAt: Date
    var source: String
}

private enum MoveGroupingLens: String, CaseIterable, Identifiable {
    case priority
    case due

    var id: String { rawValue }

    var title: String {
        switch self {
        case .priority: return "Priority"
        case .due: return "Due"
        }
    }
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
    #if !FOUNDER_OFFICE_DISTRIBUTION
    @ObservedObject var codexRunner: CodexRunner
    #endif
    @ObservedObject var personalization: PersonalizationStore
    @ObservedObject var calendarProvider: CalendarProvider
    @ObservedObject var account: FounderOfficeAccountController
    @ObservedObject var health: FounderOfficeHealthModel
    @ObservedObject var presentation: NotchPresentationModel
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @State private var selectedSection: BoardSection = {
        #if FOUNDER_OFFICE_DISTRIBUTION
        .home
        #else
        ProcessInfo.processInfo.environment["OPENLOOPS_PREVIEW_SECTION"]
            .flatMap(BoardSection.init(rawValue:)) ?? .home
        #endif
    }()
    @State private var selectedStatus: LoopStatus = {
        #if FOUNDER_OFFICE_DISTRIBUTION
        .doing
        #else
        ProcessInfo.processInfo.environment["OPENLOOPS_PREVIEW_SELECTED_STATUS"]
            .flatMap(LoopStatus.init(rawValue:)) ?? .doing
        #endif
    }()
    @State private var moveGroupingLens: MoveGroupingLens = {
        #if FOUNDER_OFFICE_DISTRIBUTION
        .priority
        #else
        ProcessInfo.processInfo.environment["OPENLOOPS_PREVIEW_MOVE_GROUPING"]
            .flatMap(MoveGroupingLens.init(rawValue:)) ?? .priority
        #endif
    }()
    @State private var moveGroupingErrorMessage: String?
    @State private var priorityDropTarget: LoopPriority? = {
        #if FOUNDER_OFFICE_DISTRIBUTION
        nil
        #else
        ProcessInfo.processInfo.environment["OPENLOOPS_PREVIEW_PRIORITY_DROP_TARGET"]
            .flatMap(LoopPriority.init(rawValue:))
        #endif
    }()
    @State private var priorityLaneFrames: [LoopPriority: CGRect] = [:]
    @State private var priorityMoveRowFrames: [UUID: CGRect] = [:]
    @State private var priorityDragOffset: CGSize = .zero
    @State private var priorityDragInteractionLease: UUID?
    @StateObject private var priorityDragAutoScroller = PriorityDragAutoScroller()
    @State private var selectedCalendarDay = Calendar.current.startOfDay(for: Date())
    @State private var isCreatingCalendarEvent = {
        #if FOUNDER_OFFICE_DISTRIBUTION
        false
        #else
        ProcessInfo.processInfo.environment["OPENLOOPS_PREVIEW_EVENT_EDITOR"] == "1"
        #endif
    }()
    @State private var calendarEventTitle = ""
    @State private var calendarEventStart = Date()
    @State private var calendarEventEnd = Date().addingTimeInterval(3_600)
    @State private var calendarEventIsAllDay = false
    @State private var calendarEventDestinationID: String?
    @State private var calendarEventErrorMessage: String?
    @State private var calendarEventInteractionLease: UUID?
    @State private var isAdding = {
        #if FOUNDER_OFFICE_DISTRIBUTION
        false
        #else
        ProcessInfo.processInfo.environment["OPENLOOPS_PREVIEW_ADDING"] == "1"
        #endif
    }()
    @State private var isShowingPreviousTasks = {
        #if FOUNDER_OFFICE_DISTRIBUTION
        false
        #else
        ProcessInfo.processInfo.environment["OPENLOOPS_PREVIEW_PREVIOUS_TASKS"] == "1"
        #endif
    }()
    @State private var isSettingsPresented = {
        #if FOUNDER_OFFICE_DISTRIBUTION
        false
        #else
        ProcessInfo.processInfo.environment["OPENLOOPS_PREVIEW_SETTINGS"] == "1"
        #endif
    }()
    @State private var personalizePage: PersonalizePage = {
        #if FOUNDER_OFFICE_DISTRIBUTION
        .profile
        #else
        ProcessInfo.processInfo.environment["OPENLOOPS_PREVIEW_PERSONALIZE_PAGE"]
            .flatMap(PersonalizePage.init(rawValue:)) ?? .profile
        #endif
    }()
    @State private var isFinishDatePickerPresented = false
    @State private var finishDateInteractionLease: UUID?
    @State private var accentSliderInteractionLease: UUID?
    @State private var supportReportPreview: RedactedSupportReport?
    @State private var supportReportSaveError: String?
    @State private var pendingAppearanceExit: AppearanceExitAction?
    @State private var planningItemID: UUID?
    @State private var planningTitle = ""
    @State private var planningInitialTitle = ""
    @State private var planningDetails = ""
    @State private var planningInitialDetails = ""
    @State private var planningPriority: LoopPriority = .p1
    @State private var planningInitialPriority: LoopPriority = .p1
    @State private var planningHasDeadline = false
    @State private var planningDeadline = Calendar.current.startOfDay(for: Date())
    @State private var planningInitialDueAt: Date?
    @State private var planningErrorMessage: String?
    @State private var planningInteractionLease: UUID?
    @State private var newTitle = {
        #if FOUNDER_OFFICE_DISTRIBUTION
        ""
        #else
        ProcessInfo.processInfo.environment["OPENLOOPS_PREVIEW_NEW_TITLE"] ?? ""
        #endif
    }()
    @State private var newDetails = ""
    @State private var newPriority: LoopPriority = .p1
    @State private var newStatus: LoopStatus = .doing
    @State private var hoveredStatus: LoopStatus? = {
        #if FOUNDER_OFFICE_DISTRIBUTION
        nil
        #else
        ProcessInfo.processInfo.environment["OPENLOOPS_PREVIEW_HOVER_STATUS"]
            .flatMap(LoopStatus.init(rawValue:))
        #endif
    }()
    @State private var settingsPreferredName = ""
    @State private var settingsWorkspaceName = ""
    @State private var primaryGoalTitle = ""
    @State private var primaryGoalMetric = ""
    @State private var primaryGoalCurrent = ""
    @State private var primaryGoalTarget = ""
    @State private var primaryGoalValidationMessage: String?
    @State private var primaryGoalUnit: GoalValueUnit = .usd
    @State private var primaryGoalDate = Calendar.current.date(byAdding: .day, value: 60, to: Date()) ?? Date()
    @State private var finishDateDraft = Calendar.current.date(byAdding: .day, value: 60, to: Date()) ?? Date()
    @Namespace private var statusSelection
    @FocusState private var addFieldFocused: Bool
    @FocusState private var addDescriptionFocused: Bool
    private let supportReportStorage = SupportReportStorage()

    private var theme: FounderTheme {
        FounderTheme(
            appearance: personalization.appearance,
            reduceTransparency: effectiveReduceTransparency
        )
    }
    private var effectiveReduceMotion: Bool {
        #if FOUNDER_OFFICE_DISTRIBUTION
        reduceMotion
        #else
        reduceMotion
            || ProcessInfo.processInfo.environment["OPENLOOPS_UI_TEST_REDUCE_MOTION"] == "1"
        #endif
    }
    private var effectiveReduceTransparency: Bool {
        #if FOUNDER_OFFICE_DISTRIBUTION
        reduceTransparency
        #else
        reduceTransparency
            || ProcessInfo.processInfo.environment["OPENLOOPS_UI_TEST_REDUCE_TRANSPARENCY"] == "1"
        #endif
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

    private func displayFont(_ role: FounderTextRole, weight: Font.Weight = .regular) -> Font {
        theme.displayFont(role, weight: weight)
    }

    private func interfaceFont(_ role: FounderTextRole, weight: Font.Weight = .regular) -> Font {
        theme.interfaceFont(role, weight: weight)
    }

    private func symbolFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        theme.symbolFont(size: size, weight: weight)
    }

    private func priorityColor(_ priority: LoopPriority) -> Color {
        switch priority {
        case .p0: return Color(nsColor: .systemRed)
        case .p1: return Color(nsColor: .systemOrange)
        case .p2: return Color(nsColor: .systemBlue)
        case .p3: return Color(nsColor: .systemGray)
        }
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
        // Keep depth inside the silhouette. An outer shadow is clipped by this
        // fixed-size transparent panel and reads as a rectangular container.
        .allowsHitTesting(metrics.isInteractive)
        .accessibilityHidden(!metrics.isInteractive)
        .preferredColorScheme(.dark)
        .environment(\.founderTheme, theme)
        .onAppear {
            loadIdentityEditor()
            loadPrimaryGoalEditor()
            if isSettingsPresented, personalizePage == .appearance {
                personalization.beginAppearanceEditing()
            }
            #if !FOUNDER_OFFICE_DISTRIBUTION
            if ProcessInfo.processInfo.environment["OPENLOOPS_PREVIEW_PLANNING_EDITOR"] == "1" {
                let previewItem: OpenLoop?
                if let rawID = ProcessInfo.processInfo.environment[
                    "OPENLOOPS_PREVIEW_PLANNING_EDITOR_ID"
                ], let id = UUID(uuidString: rawID) {
                    previewItem = store.items.first(where: {
                        $0.id == id && $0.deletedAt == nil
                    })
                } else {
                    previewItem = store.items(in: selectedStatus).first
                }
                if let previewItem {
                    presentPlanningEditor(for: previewItem)
                }
            }
            if isCreatingCalendarEvent {
                isCreatingCalendarEvent = false
                presentCalendarEventEditor()
            }
            if ProcessInfo.processInfo.environment["OPENLOOPS_PREVIEW_SUPPORT_REPORT"] == "1" {
                supportReportPreview = health.supportReport()
            }
            #endif
        }
        .onExitCommand(perform: handleExitCommand)
        .onChange(of: presentation.escapeSequence) { _, _ in
            handleExitCommand()
        }
        .onChange(of: store.items) { _, updatedItems in
            guard let planningItemID else { return }
            guard let currentItem = updatedItems.first(where: {
                $0.id == planningItemID && $0.deletedAt == nil
            }) else {
                closePlanningEditor()
                return
            }
            refreshPlanningEditor(from: currentItem)
        }
        .onChange(of: calendarProvider.writableDestinations) { _, destinations in
            guard isCreatingCalendarEvent else { return }
            if let calendarEventDestinationID,
               destinations.contains(where: { $0.id == calendarEventDestinationID }) {
                return
            }
            calendarEventDestinationID = calendarProvider.recommendedDestinationID
                ?? destinations.first?.id
        }
        .onChange(of: selectedSection) { _, _ in
            finishPriorityDrag()
        }
        .onChange(of: selectedStatus) { _, _ in
            finishPriorityDrag()
        }
        .onChange(of: moveGroupingLens) { _, _ in
            finishPriorityDrag()
        }
        .onDisappear(perform: releaseTransientInteractions)
    }

    private var boardContent: some View {
        ZStack {
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
            .disabled(isModalEditorPresented)
            .accessibilityHidden(isModalEditorPresented)

            if planningItemID != nil {
                Color.black.opacity(0.46)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: closePlanningEditor)
                    .accessibilityHidden(true)
                    .transition(.opacity)

                MovePlanningEditor(
                    title: $planningTitle,
                    details: $planningDetails,
                    priority: $planningPriority,
                    hasDeadline: $planningHasDeadline,
                    deadline: $planningDeadline,
                    errorMessage: planningErrorMessage,
                    canSave: planningHasChanges,
                    accent: accent,
                    onCancel: closePlanningEditor,
                    onSave: savePlanningEditor
                )
                .padding(17)
                .background {
                    let editorShape = RoundedRectangle(
                        cornerRadius: max(16, contentRadius),
                        style: .continuous
                    )
                    ZStack {
                        editorShape.fill(.regularMaterial)
                        editorShape.fill(
                            Color(red: 0.018, green: 0.020, blue: 0.026)
                                .opacity(effectiveReduceTransparency ? 0.98 : 0.84)
                        )
                        editorShape
                            .fill(theme.accentGradient)
                            .opacity(effectiveReduceTransparency ? 0 : 0.055)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: max(16, contentRadius), style: .continuous)
                        .stroke(contentBorder, lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.40), radius: 28, y: 12)
                .transition(.scale(scale: 0.96).combined(with: .opacity))
                .zIndex(1)
            }

            if isCreatingCalendarEvent {
                Color.black.opacity(0.46)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: closeCalendarEventEditor)
                    .accessibilityHidden(true)
                    .transition(.opacity)

                CalendarEventEditor(
                    title: $calendarEventTitle,
                    startDate: $calendarEventStart,
                    endDate: $calendarEventEnd,
                    isAllDay: $calendarEventIsAllDay,
                    destinationID: $calendarEventDestinationID,
                    destinations: calendarProvider.writableDestinations,
                    errorMessage: calendarEventErrorMessage,
                    canSave: canSaveCalendarEvent,
                    accent: accent,
                    onCancel: closeCalendarEventEditor,
                    onSave: saveCalendarEvent
                )
                .padding(17)
                .background {
                    let editorShape = RoundedRectangle(
                        cornerRadius: max(16, contentRadius),
                        style: .continuous
                    )
                    ZStack {
                        editorShape.fill(.regularMaterial)
                        editorShape.fill(
                            Color(red: 0.018, green: 0.020, blue: 0.026)
                                .opacity(effectiveReduceTransparency ? 0.98 : 0.84)
                        )
                        editorShape.fill(theme.accentGradient)
                            .opacity(effectiveReduceTransparency ? 0 : 0.055)
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: max(16, contentRadius), style: .continuous)
                        .stroke(contentBorder, lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.40), radius: 28, y: 12)
                .transition(.scale(scale: 0.96).combined(with: .opacity))
                .zIndex(2)
            }

            if pendingAppearanceExit != nil {
                Color.black.opacity(0.52)
                    .contentShape(Rectangle())
                    .accessibilityHidden(true)
                    .transition(.opacity)

                UnsavedAppearanceEditor(
                    accent: accent,
                    onKeepEditing: { pendingAppearanceExit = nil },
                    onDiscard: discardAppearanceAndContinue,
                    onSave: saveAppearanceAndContinue
                )
                .padding(17)
                .background {
                    let editorShape = RoundedRectangle(cornerRadius: max(16, contentRadius), style: .continuous)
                    ZStack {
                        editorShape.fill(.regularMaterial)
                        editorShape.fill(
                            Color(red: 0.018, green: 0.020, blue: 0.026)
                                .opacity(effectiveReduceTransparency ? 0.98 : 0.88)
                        )
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: max(16, contentRadius), style: .continuous)
                        .stroke(contentBorder, lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.42), radius: 28, y: 12)
                .transition(.scale(scale: 0.96).combined(with: .opacity))
                .zIndex(3)
            }

            if let report = supportReportPreview {
                Color.black.opacity(0.52)
                    .contentShape(Rectangle())
                    .accessibilityHidden(true)
                    .transition(.opacity)

                SupportReportPreview(
                    report: report,
                    errorMessage: supportReportSaveError,
                    accent: accent,
                    onCancel: closeSupportReportPreview,
                    onSave: { saveSupportReport(report) }
                )
                .padding(17)
                .background {
                    let editorShape = RoundedRectangle(cornerRadius: max(16, contentRadius), style: .continuous)
                    ZStack {
                        editorShape.fill(.regularMaterial)
                        editorShape.fill(
                            Color(red: 0.018, green: 0.020, blue: 0.026)
                                .opacity(effectiveReduceTransparency ? 0.98 : 0.88)
                        )
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: max(16, contentRadius), style: .continuous)
                        .stroke(contentBorder, lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(0.42), radius: 28, y: 12)
                .transition(.scale(scale: 0.96).combined(with: .opacity))
                .zIndex(4)
            }

            if account.requiresSetupOverlay {
                Color.black.opacity(0.54)
                    .contentShape(Rectangle())
                    .accessibilityHidden(true)
                    .transition(.opacity)

                AccountSetupEditor(account: account, accent: accent)
                    .padding(17)
                    .background {
                        let editorShape = RoundedRectangle(
                            cornerRadius: max(16, contentRadius),
                            style: .continuous
                        )
                        ZStack {
                            editorShape.fill(.regularMaterial)
                            editorShape.fill(
                                Color(red: 0.018, green: 0.020, blue: 0.026)
                                    .opacity(effectiveReduceTransparency ? 0.98 : 0.88)
                            )
                        }
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: max(16, contentRadius), style: .continuous)
                            .stroke(contentBorder, lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.42), radius: 28, y: 12)
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
                    .zIndex(5)
            }
        }
        .frame(width: 720, height: 350)
        .animation(effectiveReduceMotion ? nil : .spring(response: 0.27, dampingFraction: 0.84), value: planningItemID)
        .animation(effectiveReduceMotion ? nil : .spring(response: 0.27, dampingFraction: 0.84), value: isCreatingCalendarEvent)
        .animation(effectiveReduceMotion ? nil : .spring(response: 0.27, dampingFraction: 0.84), value: pendingAppearanceExit)
        .animation(effectiveReduceMotion ? nil : .spring(response: 0.27, dampingFraction: 0.84), value: supportReportPreview)
        .animation(effectiveReduceMotion ? nil : .spring(response: 0.27, dampingFraction: 0.84), value: account.setupStage)
    }

    private var isModalEditorPresented: Bool {
        planningItemID != nil
            || isCreatingCalendarEvent
            || pendingAppearanceExit != nil
            || supportReportPreview != nil
            || account.requiresSetupOverlay
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
                    .font(displayFont(.primaryTitle))
                    .foregroundStyle(primaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .allowsTightening(true)

                if !isEditorialHome {
                    Text(headerSubtitle)
                        .font(interfaceFont(.tertiary, weight: .semibold))
                        .foregroundStyle(secondaryText)
                        .lineLimit(1)
                }
            }
            .frame(width: isEditorialHome ? 220 : 208, alignment: .leading)

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
            .accessibilityIdentifier("nav.personalize")

            Button(action: { requestAppearanceExit(.closeNotch) }) {
                Image(systemName: "xmark")
            }
            .buttonStyle(CloseButtonStyle())
            .help("Close")
            .accessibilityIdentifier("notch.close")
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
                .accessibilityIdentifier("nav.\(section.rawValue)")
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
                .font(displayFont(.primaryTitle))
                .foregroundStyle(primaryText)
                .offset(x: 32, y: 44)

            Text("Next move")
                .font(interfaceFont(.secondary, weight: .bold))
                .foregroundStyle(primaryText)
                .offset(x: 32, y: 106)

            Group {
                if let focusItem {
                    homeFocus(item: focusItem)
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Nothing is pulling at you")
                            .font(interfaceFont(.secondary, weight: .bold))
                            .foregroundStyle(primaryText)
                        Text("The board is clear.")
                            .font(interfaceFont(.tertiary, weight: .semibold))
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
                        .font(interfaceFont(.secondary, weight: .bold))
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
                        .font(interfaceFont(.secondary, weight: .bold))
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
                .accessibilityIdentifier("nav.personalize")

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
                    .font(symbolFont(size: 19, weight: .medium))
                    .foregroundStyle(priorityColor(for: item.priority))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(RowControlButtonStyle())
            .accessibilityLabel("Complete \(item.title)")

            Button {
                presentPlanningEditor(for: item)
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.title)
                        .font(interfaceFont(.secondary, weight: .bold))
                        .foregroundStyle(primaryText)
                        .lineLimit(1)

                    if let dueAt = item.dueAt {
                        Text(homeDueLabel(dueAt))
                            .font(interfaceFont(.tertiary, weight: .bold))
                            .foregroundStyle(
                                PlanningDate.day(fromStored: dueAt) < PlanningDate.day(fromLocal: Date())
                                    ? Color.red.opacity(0.94)
                                    : Color.white.opacity(0.92)
                            )
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(StatusTabButtonStyle())
            .help("Edit priority and deadline")
            .accessibilityLabel("Edit \(item.title) priority and deadline")
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
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let nextEvent = CalendarEventPresentation.upNext(
                from: calendarProvider.events,
                at: context.date,
                startDate: \.startDate,
                endDate: \.endDate,
                kind: \.upNextKind
            )

            Button {
                select(.calendar)
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    if let event = nextEvent {
                        Text(event.title)
                            .font(interfaceFont(.secondary, weight: .bold))
                            .foregroundStyle(primaryText)
                            .lineLimit(2)
                        Text(eventDateLabel(event))
                            .font(interfaceFont(.tertiary, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.82))
                    } else {
                        Text(calendarProvider.isAuthorized ? "No meetings soon" : "Connect Calendar")
                            .font(interfaceFont(.secondary, weight: .bold))
                            .foregroundStyle(primaryText)
                        Text(calendarProvider.isAuthorized ? "Your time is clear" : "Only important dates")
                            .font(interfaceFont(.tertiary, weight: .semibold))
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
    }

    private var homePrimaryGoal: some View {
        Button(action: presentSettings) {
            VStack(alignment: .leading, spacing: 4) {
                if let goal = personalization.primaryGoal {
                    if let target = goal.targetValue, target > 0 {
                        Text(primaryGoalTargetLabel(goal, target: target))
                            .font(displayFont(.secondary))
                            .foregroundStyle(primaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.74)
                            .allowsTightening(true)

                        HStack(spacing: 4) {
                            Text("\(goal.unit.format(goal.currentValue ?? 0)) now")
                            Spacer(minLength: 3)
                            Text(daysLeftLabel(goal.dueAt))
                        }
                        .font(interfaceFont(.tertiary, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.84))

                        ProgressView(value: primaryGoalProgress(goal))
                            .progressViewStyle(.linear)
                            .tint(accent)
                            .controlSize(.mini)
                    } else {
                        Text(daysLeftLabel(goal.dueAt))
                            .font(displayFont(.secondary))
                            .foregroundStyle(primaryText)
                        Text(goal.title)
                            .font(interfaceFont(.tertiary, weight: .bold))
                            .foregroundStyle(primaryText)
                            .lineLimit(1)
                    }
                } else {
                    Text("Set the finish line")
                        .font(displayFont(.secondary))
                        .foregroundStyle(primaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.74)
                        .allowsTightening(true)
                    Text("Metric + deadline")
                        .font(interfaceFont(.tertiary, weight: .semibold))
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
                        SystemIconView(name: .photo, size: 34)
                        Text("Add a personal photo")
                            .font(interfaceFont(.secondary, weight: .bold))
                        Text("A dream, a person, a logo")
                            .font(interfaceFont(.tertiary, weight: .medium))
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
                            .font(symbolFont(size: 10.5, weight: .bold))
                        Text(isAdding ? "Cancel" : "New")
                    }
                }
                .buttonStyle(HeaderActionButtonStyle(isEmphasized: !isAdding))
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
                            .font(interfaceFont(.secondary, weight: isSelected ? .semibold : .medium))

                        Text("\(store.count(in: status))")
                            .font(interfaceFont(.tertiary, weight: .semibold))
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
        TimelineView(.periodic(from: .now, by: 60)) { context in
            groupedLoopsContent(
                MovePresentation(items: store.items, now: context.date, calendar: .current)
            )
        }
    }

    private func groupedLoopsContent(_ movePresentation: MovePresentation) -> some View {
        VStack(spacing: 7) {
            if isAdding {
                addComposer
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if selectedStatus == .done {
                doneLoopsContent(movePresentation)
            } else {
                activeLoopsContent(movePresentation)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 9)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    @ViewBuilder
    private func activeLoopsContent(_ movePresentation: MovePresentation) -> some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                moveGroupingControl
                Spacer()
                if let moveGroupingErrorMessage {
                    Text(moveGroupingErrorMessage)
                        .font(interfaceFont(.tertiary, weight: .semibold))
                        .foregroundStyle(Color(nsColor: .systemRed))
                        .lineLimit(1)
                }
            }

            if moveGroupingLens == .priority {
                ScrollView(showsIndicators: true) {
                    LazyVStack(spacing: 8) {
                        ForEach(LoopPriority.allCases) { priority in
                            priorityMoveSection(
                                priority: priority,
                                items: movePresentation.items(in: priority)
                                    .filter { $0.status == selectedStatus }
                            )
                        }
                    }
                    .background {
                        PriorityScrollViewResolver { scrollView in
                            priorityDragAutoScroller.attach(scrollView)
                        }
                        .frame(width: 1, height: 1)
                        .allowsHitTesting(false)
                    }
                    // The persistent document stack owns the gesture for its
                    // entire lifetime. Attaching it outside NSScrollView lets
                    // a row button consume the first synthesized or physical
                    // press; attaching it to a lazy row loses the release when
                    // that row is recycled during edge scrolling.
                    .highPriorityGesture(
                        DragGesture(
                            minimumDistance: 7,
                            coordinateSpace: .named("priority-move-scroll")
                        )
                        .onChanged { value in
                            let moveID = priorityDragAutoScroller.draggedMoveID
                                ?? PriorityDragSourcePolicy.source(
                                    at: value.startLocation,
                                    rows: priorityMoveRowFrames
                                )
                            guard let moveID else { return }
                            priorityDragOffset = value.translation
                            updatePriorityDrag(moveID, pointerY: value.location.y)
                        }
                        .onEnded { value in
                            guard let moveID = priorityDragAutoScroller.draggedMoveID else {
                                priorityDragOffset = .zero
                                return
                            }
                            endPriorityDrag(moveID, pointerY: value.location.y)
                        }
                    )
                }
                .coordinateSpace(name: "priority-move-scroll")
                .accessibilityIdentifier("moves.priority.scroll")
                .accessibilityValue(priorityDragAccessibilityValue)
                .onPreferenceChange(PriorityLaneFramePreferenceKey.self) { frames in
                    priorityLaneFrames = frames
                    guard let pointerY = priorityDragAutoScroller.pointerY else { return }
                    setPriorityDropTarget(
                        PriorityDropTargetPolicy.target(
                            pointerY: pointerY,
                            lanes: frames.map { priority, frame in
                                PriorityDropLane(
                                    priority: priority,
                                    minY: frame.minY,
                                    maxY: frame.maxY
                                )
                            },
                            current: priorityDropTarget
                        )
                    )
                }
                .onPreferenceChange(PriorityMoveRowFramePreferenceKey.self) { frames in
                    priorityMoveRowFrames = frames
                }
                .onDisappear(perform: finishPriorityDrag)
            } else {
                let groups = movePresentation.activeGroups.compactMap { group -> ActiveMoveGroup? in
                    let items = group.items.filter { $0.status == selectedStatus }
                    return items.isEmpty ? nil : ActiveMoveGroup(bucket: group.bucket, items: items)
                }

                if groups.isEmpty {
                    emptyState
                } else {
                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 10) {
                            ForEach(groups) { group in
                                moveSection(
                                    title: group.bucket.title,
                                    items: group.items,
                                    showsCompletionDate: false
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private var moveGroupingControl: some View {
        HStack(spacing: 3) {
            ForEach(MoveGroupingLens.allCases) { lens in
                let isSelected = moveGroupingLens == lens
                Button {
                    moveGroupingErrorMessage = nil
                    withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
                        moveGroupingLens = lens
                    }
                } label: {
                    Text(lens.title)
                        .font(interfaceFont(.tertiary, weight: isSelected ? .bold : .semibold))
                        .foregroundStyle(isSelected ? primaryText : secondaryText)
                        .frame(width: 70, height: 25)
                        .background(
                            isSelected ? Color.white.opacity(0.10) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(StatusTabButtonStyle())
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Group Moves")
    }

    private func priorityMoveSection(priority: LoopPriority, items: [OpenLoop]) -> some View {
        let laneColor = priorityColor(priority)
        let laneShape = RoundedRectangle(cornerRadius: contentRadius, style: .continuous)
        let isDropTarget = priorityDropTarget == priority

        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Text(priority.title)
                    .font(interfaceFont(.secondary, weight: .bold))
                    .foregroundStyle(primaryText)
                Text(priority.rawValue)
                    .font(interfaceFont(.tertiary, weight: .bold))
                    .foregroundStyle(laneColor)
                Text("\(items.count)")
                    .font(interfaceFont(.tertiary, weight: .semibold))
                    .foregroundStyle(secondaryText)
                    .contentTransition(.numericText())
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            if items.isEmpty {
                Text("Drop a Move here")
                    .font(interfaceFont(.tertiary, weight: .semibold))
                    .foregroundStyle(secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                    .padding(.horizontal, 12)
            } else {
                moveRowsCard(
                    items,
                    showsCompletionDate: false,
                    showsPriorityBadge: false,
                    isDraggable: true,
                    usesSurface: false
                )
            }
        }
        .background {
            ZStack {
                laneShape.fill(contentSurface)
                if isDropTarget {
                    laneShape.fill(laneColor.opacity(0.11))
                }
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: PriorityLaneFramePreferenceKey.self,
                    value: [
                        priority: proxy.frame(in: .named("priority-move-scroll"))
                    ]
                )
            }
        }
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(
                topLeadingRadius: contentRadius,
                bottomLeadingRadius: contentRadius,
                bottomTrailingRadius: 0,
                topTrailingRadius: 0,
                style: .continuous
            )
            .fill(laneColor)
            .frame(width: isDropTarget ? 7 : 5)
        }
        .overlay(
            laneShape.stroke(
                laneColor.opacity(isDropTarget ? 0.92 : 0.25),
                lineWidth: isDropTarget ? 1.6 : 1
            )
        )
        .overlay {
            if isDropTarget {
                laneShape
                    .inset(by: 3)
                    .stroke(Color.white.opacity(0.11), lineWidth: 0.8)
            }
        }
        .scaleEffect(isDropTarget && !effectiveReduceMotion ? 1.008 : 1)
        .shadow(
            color: isDropTarget ? laneColor.opacity(0.24) : Color.clear,
            radius: isDropTarget ? 13 : 0,
            y: isDropTarget ? 4 : 0
        )
        .zIndex(isDropTarget ? 1 : 0)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "\(priority.title) priority, \(items.count) Moves"
                + (isDropTarget ? ", Drop target" : "")
        )
        .accessibilityValue(isDropTarget ? "Drop target" : "")
        .accessibilityHint("Drop a Move here to set its priority to \(priority.title)")
        .accessibilityIdentifier("moves.priorityLane.\(priority.rawValue.lowercased())")
    }

    @ViewBuilder
    private func doneLoopsContent(_ movePresentation: MovePresentation) -> some View {
        if isShowingPreviousTasks {
            HistoryNavigationButton(
                title: "Back to recent",
                detail: nil,
                leadingSystemImage: "chevron.left",
                trailingSystemImage: nil,
                accent: accent
            ) {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                    isShowingPreviousTasks = false
                }
            }
            .accessibilityLabel("Back to completions from today and yesterday")

            if movePresentation.olderCompleted.isEmpty {
                compactHistoryEmptyState(
                    title: "No previous tasks",
                    message: "Older completed work will stay here."
                )
            } else {
                ScrollView(showsIndicators: false) {
                    moveRowsCard(movePresentation.olderCompleted, showsCompletionDate: true)
                }
            }
        } else {
            let today = movePresentation.recentCompleted.filter { item in
                item.completedAt.map(Calendar.current.isDateInToday) ?? false
            }
            let yesterday = movePresentation.recentCompleted.filter { item in
                item.completedAt.map(Calendar.current.isDateInYesterday) ?? false
            }

            if movePresentation.recentCompleted.isEmpty {
                compactHistoryEmptyState(
                    title: "Nothing completed recently",
                    message: "Today and yesterday will appear here."
                )
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 10) {
                        if !today.isEmpty {
                            moveSection(title: "Today", items: today, showsCompletionDate: true)
                        }
                        if !yesterday.isEmpty {
                            moveSection(title: "Yesterday", items: yesterday, showsCompletionDate: true)
                        }
                    }
                }
            }

            if !movePresentation.olderCompleted.isEmpty {
                HistoryNavigationButton(
                    title: "Previous tasks",
                    detail: "\(movePresentation.olderCompleted.count)",
                    leadingSystemImage: "clock.arrow.circlepath",
                    trailingSystemImage: "chevron.right",
                    accent: accent
                ) {
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                        isShowingPreviousTasks = true
                    }
                }
                .accessibilityLabel("Show \(movePresentation.olderCompleted.count) previous completed tasks")
            }
        }
    }

    private func moveSection(
        title: String,
        items: [OpenLoop],
        showsCompletionDate: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(title.uppercased())
                    .font(interfaceFont(.tertiary, weight: .bold))
                    .tracking(0.25)
                    .foregroundStyle(primaryText.opacity(0.86))

                Text("\(items.count)")
                    .font(interfaceFont(.tertiary, weight: .semibold))
                    .foregroundStyle(secondaryText.opacity(0.86))
                    .contentTransition(.numericText())

                Spacer()
            }
            .padding(.horizontal, 4)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(title), \(items.count) tasks")

            moveRowsCard(items, showsCompletionDate: showsCompletionDate)
        }
    }

    private func moveRowsCard(
        _ items: [OpenLoop],
        showsCompletionDate: Bool,
        showsPriorityBadge: Bool = true,
        isDraggable: Bool = false,
        usesSurface: Bool = true
    ) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                #if FOUNDER_OFFICE_DISTRIBUTION
                LoopRow(
                    item: item,
                    accent: accent,
                    trailingLabel: showsCompletionDate ? completedLabel(for: item) : nil,
                    showsPriorityBadge: showsPriorityBadge,
                    onToggle: { store.toggleCompletion(item) },
                    onMove: { status in store.move(item, to: status) },
                    onSetPriority: { priority in updatePriority(of: item, to: priority) },
                    onEditPlanning: { presentPlanningEditor(for: item) },
                    onDelete: { deleteMove(item) }
                )
                .modifier(
                    ConditionalMoveDragModifier(
                        id: isDraggable ? item.id : nil,
                        activeID: priorityDragAutoScroller.draggedMoveID,
                        dragOffset: priorityDragOffset
                    )
                )
                #else
                LoopRow(
                    item: item,
                    accent: accent,
                    trailingLabel: showsCompletionDate ? completedLabel(for: item) : nil,
                    showsPriorityBadge: showsPriorityBadge,
                    onToggle: { store.toggleCompletion(item) },
                    onMove: { status in store.move(item, to: status) },
                    onSetPriority: { priority in updatePriority(of: item, to: priority) },
                    onEditPlanning: { presentPlanningEditor(for: item) },
                    codexAction: codexRunner.action(for: item),
                    isCodexAvailable: codexRunner.isAvailable,
                    isCodexBusy: codexRunner.isRunning,
                    onRunWithCodex: { codexRunner.run(item) },
                    onDelete: { deleteMove(item) }
                )
                .modifier(
                    ConditionalMoveDragModifier(
                        id: isDraggable ? item.id : nil,
                        activeID: priorityDragAutoScroller.draggedMoveID,
                        dragOffset: priorityDragOffset
                    )
                )
                #endif

                if index < items.count - 1 {
                    Divider()
                        .overlay(Color.white.opacity(0.065))
                        .padding(.leading, 46)
                }
            }
        }
        .background(
            usesSurface ? contentSurface : Color.clear,
            in: RoundedRectangle(cornerRadius: contentRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: contentRadius, style: .continuous)
                .stroke(usesSurface ? contentBorder : Color.clear, lineWidth: 1)
        )
    }

    private func handlePriorityDrop(_ id: UUID, target: LoopPriority) -> Bool {
        guard let item = store.items.first(where: {
                  $0.id == id && $0.deletedAt == nil && $0.status == selectedStatus
              })
        else { return false }

        guard item.priority != target else { return true }
        return updatePriority(of: item, to: target)
    }

    private var priorityDragAccessibilityValue: String {
        let dragState = priorityDragInteractionLease == nil ? "Idle" : "Dragging"
        #if FOUNDER_OFFICE_DISTRIBUTION
        return dragState
        #else
        // The persistent ScrollView is a real accessibility element. Keeping
        // the store state here lets UI automation observe the same durable
        // commit state customers use without relying on a transparent probe
        // that AppKit omits from AXValue.
        return "\(dragState), \(store.syncMessage)"
        #endif
    }

    private func beginPriorityDrag(_ id: UUID) {
        guard store.items.contains(where: {
            $0.id == id && $0.deletedAt == nil && $0.status == selectedStatus
        }) else { return }

        finishPriorityDrag()
        priorityDragInteractionLease = presentation.beginInteraction("move-priority-drag")
        priorityDragAutoScroller.beginSession(
            moveID: id,
            onPointerUpdate: { pointerY in
                guard let pointerY else {
                    setPriorityDropTarget(nil)
                    return
                }
                setPriorityDropTarget(
                    PriorityDropTargetPolicy.target(
                        pointerY: pointerY,
                        lanes: priorityLaneFrames.map { priority, frame in
                            PriorityDropLane(
                                priority: priority,
                                minY: frame.minY,
                                maxY: frame.maxY
                            )
                        },
                        current: priorityDropTarget
                    )
                )
            },
            onRelease: { moveID, pointerY in
                let target = pointerY.flatMap(resolvePriorityDropTarget)
                    ?? priorityDropTarget
                guard let target else { return }
                _ = handlePriorityDrop(moveID, target: target)
            },
            onEnd: handlePriorityDragSessionEnded
        )
    }

    private func updatePriorityDrag(_ id: UUID, pointerY: CGFloat) {
        if priorityDragAutoScroller.draggedMoveID != id {
            beginPriorityDrag(id)
        }
        guard priorityDragAutoScroller.draggedMoveID == id else { return }

        priorityDragAutoScroller.update(pointerY: pointerY)
        setPriorityDropTarget(resolvePriorityDropTarget(pointerY))
    }

    private func endPriorityDrag(_ id: UUID, pointerY: CGFloat) {
        guard priorityDragAutoScroller.draggedMoveID == id else {
            finishPriorityDrag()
            return
        }

        priorityDragAutoScroller.update(pointerY: pointerY)
        let target = resolvePriorityDropTarget(pointerY) ?? priorityDropTarget

        if let target {
            _ = handlePriorityDrop(id, target: target)
        }
        finishPriorityDrag()
    }

    private func setPriorityDropTarget(_ target: LoopPriority?) {
        guard priorityDropTarget != target else { return }
        if effectiveReduceMotion {
            priorityDropTarget = target
        } else {
            withAnimation(.spring(response: 0.20, dampingFraction: 0.84)) {
                priorityDropTarget = target
            }
        }
        if target != nil {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    private func resolvePriorityDropTarget(_ pointerY: CGFloat) -> LoopPriority? {
        PriorityDropTargetPolicy.target(
            pointerY: pointerY,
            lanes: priorityLaneFrames.map { priority, frame in
                PriorityDropLane(
                    priority: priority,
                    minY: frame.minY,
                    maxY: frame.maxY
                )
            },
            current: priorityDropTarget
        )
    }

    private func finishPriorityDrag() {
        priorityDragAutoScroller.endSession()
        priorityDragAutoScroller.stop()
        priorityDragOffset = .zero
        priorityDropTarget = nil
        releasePriorityDragInteraction()
    }

    private func handlePriorityDragSessionEnded() {
        priorityDragOffset = .zero
        priorityDropTarget = nil
        releasePriorityDragInteraction()
    }

    private func releasePriorityDragInteraction() {
        guard let lease = priorityDragInteractionLease else { return }
        presentation.endInteraction(lease)
        priorityDragInteractionLease = nil
    }

    @discardableResult
    private func updatePriority(of item: OpenLoop, to priority: LoopPriority) -> Bool {
        Task {
            let result = await store.updatePlanning(
                id: item.id,
                priorityChange: .set(priority),
                deadlineChange: .unchanged
            )
            switch result {
            case .saved:
                moveGroupingErrorMessage = nil
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            case .unchanged:
                moveGroupingErrorMessage = nil
            case let .failed(message):
                moveGroupingErrorMessage = message
            }
        }
        return true
    }

    private func compactHistoryEmptyState(title: String, message: String) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(interfaceFont(.secondary, weight: .semibold))
                .foregroundStyle(primaryText)
            Text(message)
                .font(interfaceFont(.tertiary, weight: .regular))
                .foregroundStyle(secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var addComposer: some View {
        VStack(spacing: 7) {
            HStack(spacing: 10) {
                TextField("Title", text: $newTitle)
                    .textFieldStyle(.plain)
                    .font(interfaceFont(.secondary, weight: .semibold))
                    .foregroundStyle(primaryText)
                    .focused($addFieldFocused)
                    .onSubmit { addDescriptionFocused = true }
                    .accessibilityIdentifier("newMove.title")

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
                    .buttonStyle(HeaderActionButtonStyle(isEmphasized: true))
                    .disabled(!canAddMove)
                    .accessibilityIdentifier("newMove.add")
            }

            TextField("Description (optional)", text: $newDetails, axis: .vertical)
                .textFieldStyle(.plain)
                .font(interfaceFont(.tertiary, weight: .regular))
                .foregroundStyle(primaryText.opacity(0.88))
                .lineLimit(1...2)
                .focused($addDescriptionFocused)
                .onSubmit(addItem)
                .accessibilityIdentifier("newMove.description")
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .frame(minHeight: 72)
        .background(contentSurface, in: RoundedRectangle(cornerRadius: contentRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: contentRadius, style: .continuous)
                .stroke(accent.opacity(0.38), lineWidth: 1)
        )
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text(emptyStateTitle)
                .font(interfaceFont(.secondary, weight: .semibold))
                .foregroundStyle(primaryText)
            Text(emptyStateMessage)
                .font(interfaceFont(.tertiary, weight: .regular))
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

            HStack(alignment: .top, spacing: 12) {
                calendarEvents
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(contentSurface, in: RoundedRectangle(cornerRadius: contentRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: contentRadius, style: .continuous)
                            .stroke(contentBorder, lineWidth: 1)
                    )

                if calendarProvider.isAuthorized {
                    calendarDeadlines
                        .padding(12)
                        .frame(width: 264)
                        .frame(maxHeight: .infinity, alignment: .topLeading)
                        .background(contentSurface, in: RoundedRectangle(cornerRadius: contentRadius, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: contentRadius, style: .continuous)
                                .stroke(contentBorder, lineWidth: 1)
                        )
                } else {
                    calendarPermissionState
                        .padding(12)
                        .frame(width: 264)
                        .frame(maxHeight: .infinity, alignment: .topLeading)
                        .background(contentSurface, in: RoundedRectangle(cornerRadius: contentRadius, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: contentRadius, style: .continuous)
                                .stroke(contentBorder, lineWidth: 1)
                        )
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 9)
            .padding(.bottom, 8)
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
                            .font(interfaceFont(.tertiary, weight: .semibold))
                        Text(dayNumber(day))
                            .font(interfaceFont(.tertiary, weight: isSelected ? .semibold : .medium))
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
                .font(interfaceFont(.tertiary, weight: .semibold))
                .foregroundStyle(calendarProvider.isAuthorized ? primaryText : theme.readableAccentOnPanel)
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
            HStack(spacing: 8) {
                Text(Calendar.current.isDateInToday(selectedCalendarDay) ? "TODAY" : selectedDayTitle)
                    .font(interfaceFont(.tertiary, weight: .bold))
                    .tracking(0.35)
                    .foregroundStyle(primaryText.opacity(0.86))

                Spacer()

                Button(action: presentCalendarEventEditor) {
                    Label("New event", systemImage: "plus")
                        .font(interfaceFont(.tertiary, weight: .bold))
                }
                .buttonStyle(HeaderActionButtonStyle(isEmphasized: calendarProvider.isAuthorized))
                .help(calendarProvider.isAuthorized ? "Add an event" : "Connect Calendar to add an event")
            }

            let events = selectedDayEvents
            let dueMoves = selectedDayMoves
            if events.isEmpty && dueMoves.isEmpty {
                Text("Nothing scheduled")
                    .font(interfaceFont(.secondary, weight: .semibold))
                    .foregroundStyle(primaryText)
                Text("This day has room to breathe.")
                    .font(interfaceFont(.tertiary))
                    .foregroundStyle(secondaryText)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(dueMoves) { move in
                            HStack(spacing: 10) {
                                Capsule()
                                    .fill(priorityColor(move.priority))
                                    .frame(width: 3, height: 28)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(move.title)
                                        .font(interfaceFont(.secondary, weight: .semibold))
                                        .foregroundStyle(primaryText)
                                        .lineLimit(1)
                                    Text("Move  ·  \(move.priority.title)")
                                        .font(interfaceFont(.tertiary, weight: .medium))
                                        .foregroundStyle(secondaryText)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                Button { presentPlanningEditor(for: move) } label: {
                                    Image(systemName: "slider.horizontal.3")
                                        .font(symbolFont(size: 11, weight: .semibold))
                                        .frame(width: 28, height: 28)
                                        .contentShape(Circle())
                                }
                                .buttonStyle(StatusTabButtonStyle())
                                .foregroundStyle(secondaryText)
                                .help("Edit this Move")
                            }
                            .frame(height: 37)
                        }

                        ForEach(events) { event in
                            HStack(spacing: 10) {
                                Capsule()
                                    .fill(accent)
                                    .frame(width: 3, height: 28)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(event.title)
                                        .font(interfaceFont(.secondary, weight: .semibold))
                                        .foregroundStyle(primaryText)
                                        .lineLimit(1)
                                    Text("\(eventTimeLabel(event, on: selectedCalendarDay))  ·  \(event.sourceLabel)")
                                        .font(interfaceFont(.tertiary, weight: .medium))
                                        .foregroundStyle(secondaryText)
                                        .lineLimit(1)
                                }
                            }
                            .frame(height: 37)
                        }
                    }
                }
            }
        }
    }

    private var calendarDeadlines: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("IMPORTANT DATES")
                .font(interfaceFont(.tertiary, weight: .bold))
                .tracking(0.35)
                .foregroundStyle(secondaryText)

            if calendarDeadlineSignals.isEmpty {
                Text("No countdowns yet")
                    .font(interfaceFont(.secondary, weight: .semibold))
                    .foregroundStyle(primaryText)
                Button("Add one in Settings", action: presentSettings)
                    .buttonStyle(.plain)
                    .font(interfaceFont(.tertiary, weight: .semibold))
                    .foregroundStyle(theme.readableAccentOnPanel)
            } else {
                ForEach(calendarDeadlineSignals.prefix(3)) { deadline in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(countdownLabel(deadline.dueAt))
                            .font(interfaceFont(.secondary, weight: .semibold))
                            .foregroundStyle(primaryText)
                            .frame(width: 48, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(deadline.title)
                                .font(interfaceFont(.secondary, weight: .semibold))
                                .foregroundStyle(primaryText)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(deadline.source)
                                .font(interfaceFont(.tertiary, weight: .medium))
                                .foregroundStyle(secondaryText)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(1)
                    }
                    .frame(minHeight: 42, alignment: .top)
                }
            }
        }
    }

    private var calendarPermissionState: some View {
        VStack(spacing: 9) {
            Text(calendarProvider.isDenied ? "Calendar access is off" : "See only what matters next")
                .font(interfaceFont(.secondary, weight: .semibold))
                .foregroundStyle(primaryText)
            Text(calendarProvider.isDenied ? "Open Privacy settings to allow upcoming event access." : "Connect once. Every iCloud and Google calendar enabled in Internet Accounts will appear here and stay live.")
                .font(interfaceFont(.tertiary))
                .foregroundStyle(secondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 390)
            Button(calendarProvider.isDenied ? "Open Privacy Settings" : "Connect Calendar") {
                calendarProvider.connectOrOpenSettings()
            }
            .buttonStyle(HeaderActionButtonStyle(isEmphasized: true))
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
                case .account: accountSettingsPage
                case .appearance: appearanceSettingsPage
                case .finishLine: finishLineSettingsPage
                case .calendar: calendarSettingsPage
                case .health: healthSettingsPage
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
            requestAppearanceExit(.page(page))
        } label: {
            HStack(spacing: 8) {
                Image(systemName: page.systemImage)
                    .frame(width: 16)
                Text(page.title)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(symbolFont(size: 9, weight: .bold))
                }
            }
            .font(interfaceFont(.tertiary, weight: .semibold))
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
        .accessibilityIdentifier("personalize.\(page.rawValue)")
    }

    private var profileSettingsPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingsPageHeading("Make it yours", detail: "Your greeting, workspace, and vision image.")

            HStack(spacing: 8) {
                identityTextField("Your name", text: $settingsPreferredName)
                identityTextField("Workspace name", text: $settingsWorkspaceName)
                Button("Save", action: saveIdentity)
                    .buttonStyle(HeaderActionButtonStyle(isEmphasized: true))
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
                        .font(interfaceFont(.secondary, weight: .bold))
                        .foregroundStyle(primaryText)
                    Text("Choose a person, place, dream, logo, or finish line that matters to you.")
                        .font(interfaceFont(.tertiary, weight: .medium))
                        .foregroundStyle(secondaryText)
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        Button(personalization.photoURL == nil ? "Choose photo…" : "Replace…", action: choosePhotoWithLease)
                            .buttonStyle(HeaderActionButtonStyle())
                            .accessibilityIdentifier("personalize.photo.choose")
                        if personalization.hasExportableOriginalPhoto {
                            Button("Export original…", action: exportOriginalPhotoWithLease)
                                .buttonStyle(HeaderActionButtonStyle())
                        }
                        if personalization.photoURL != nil {
                            Button("Remove", action: personalization.removePhoto)
                                .buttonStyle(HeaderActionButtonStyle())
                        }
                    }
                }
            }
        }
    }

    private var accountSettingsPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingsPageHeading(
                "Account & Sync",
                detail: "Local-first. Sign-in never uploads or replaces this workspace by itself."
            )

            HStack(spacing: 10) {
                Image(systemName: accountStatusSymbol)
                    .font(symbolFont(size: 15, weight: .semibold))
                    .foregroundStyle(accountStatusColor)
                    .frame(width: 32, height: 32)
                    .background(accountStatusColor.opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(account.statusTitle)
                        .font(interfaceFont(.secondary, weight: .bold))
                        .foregroundStyle(primaryText)
                    Text(account.statusDetail)
                        .font(interfaceFont(.tertiary, weight: .semibold))
                        .foregroundStyle(secondaryText)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if account.isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Account action in progress")
                }
            }
            .padding(10)
            .background(groupedBackground, in: RoundedRectangle(cornerRadius: contentRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: contentRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("account.status")

            if account.isAuthenticationAvailable {
                switch account.authState {
                case .localOnly, .failed:
                    HStack(spacing: 8) {
                        Button(action: account.signInWithGoogle) {
                            Label("Continue with Google", systemImage: "g.circle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(HeaderActionButtonStyle(isEmphasized: true))
                        .disabled(account.isBusy)
                        .accessibilityIdentifier("account.signIn.google")

                        if account.isAppleSignInAvailable {
                            Button(action: account.signInWithApple) {
                                Label("Sign in with Apple", systemImage: "apple.logo")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(HeaderActionButtonStyle())
                            .disabled(account.isBusy)
                            .accessibilityIdentifier("account.signIn.apple")
                        }
                    }

                    Text("Your account identifies you. Calendar, Gmail, Notion, and other connections stay separate and are added only when you ask.")
                        .font(interfaceFont(.tertiary, weight: .medium))
                        .foregroundStyle(secondaryText)
                        .fixedSize(horizontal: false, vertical: true)

                case .restoring, .signingIn:
                    Text("Finish the secure provider window. Founder’s Office will return here without changing local data.")
                        .font(interfaceFont(.secondary, weight: .semibold))
                        .foregroundStyle(primaryText)

                case .signedIn:
                    HStack(spacing: 8) {
                        Text(account.statusDetail)
                            .font(interfaceFont(.tertiary, weight: .semibold))
                            .foregroundStyle(secondaryText)
                        Spacer(minLength: 6)
                        Button("Sign Out", action: account.signOut)
                            .buttonStyle(HeaderActionButtonStyle())
                            .disabled(account.isBusy)
                            .accessibilityIdentifier("account.signOut")
                    }
                }
            } else {
                Text("You can keep using every local feature. Sign-in appears only in a build with reviewed secure account settings.")
                    .font(interfaceFont(.secondary, weight: .semibold))
                    .foregroundStyle(primaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("account.localOnlyExplanation")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("account.page")
    }

    private var accountStatusSymbol: String {
        switch account.authState {
        case .signedIn: return "person.crop.circle.badge.checkmark"
        case .restoring, .signingIn: return "arrow.triangle.2.circlepath"
        case .failed: return "exclamationmark.triangle"
        case .localOnly: return "internaldrive"
        }
    }

    private var accountStatusColor: Color {
        switch account.authState {
        case .signedIn: return accent
        case .restoring, .signingIn: return accent
        case .failed: return Color(nsColor: .systemOrange)
        case .localOnly: return Color.white.opacity(0.72)
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
                        .accessibilityIdentifier("appearance.preset.\(preset.rawValue)")
                    }
                }

                accentControlModule
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

                Spacer(minLength: 3)

                if personalization.hasAppearanceConflict {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Appearance changed elsewhere")
                            .font(interfaceFont(.tertiary, weight: .semibold))
                            .foregroundStyle(primaryText)
                        HStack(spacing: 6) {
                            Button("Use Latest") {
                                presentation.closeNativeColorPanels()
                                personalization.useLatestAppearance()
                            }
                            .buttonStyle(HeaderActionButtonStyle())
                            .disabled(personalization.isSavingAppearance)
                            Button("Keep Mine") {
                                presentation.closeNativeColorPanels()
                                Task { _ = await personalization.keepMineAppearance() }
                            }
                            .buttonStyle(HeaderActionButtonStyle(isEmphasized: true))
                            .disabled(personalization.isSavingAppearance)
                        }
                    }
                    .accessibilityElement(children: .contain)
                } else {
                    if let saveError = personalization.appearanceSaveError {
                        Text(saveError)
                            .font(interfaceFont(.tertiary, weight: .semibold))
                            .foregroundStyle(Color(nsColor: .systemRed))
                            .lineLimit(1)
                            .accessibilityIdentifier("appearance.saveError")
                    }

                    HStack(spacing: 7) {
                        Spacer()
                        Button("Discard", action: discardAppearanceDraft)
                            .buttonStyle(HeaderActionButtonStyle())
                            .fixedSize(horizontal: true, vertical: false)
                            .disabled(!personalization.hasUnsavedAppearanceChanges || personalization.isSavingAppearance)
                            .accessibilityIdentifier("appearance.discard")
                        Button("Save Changes", action: saveAppearanceDraft)
                            .buttonStyle(HeaderActionButtonStyle(isEmphasized: true))
                            .fixedSize(horizontal: true, vertical: false)
                            .disabled(!personalization.hasUnsavedAppearanceChanges || personalization.isSavingAppearance)
                            .keyboardShortcut(.defaultAction)
                            .accessibilityIdentifier("appearance.save")
                    }
                }
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
                    .buttonStyle(HeaderActionButtonStyle(isEmphasized: true))
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

            if let primaryGoalValidationMessage {
                Text(primaryGoalValidationMessage)
                    .font(interfaceFont(.tertiary, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .accessibilityIdentifier("primaryGoal.validationError")
            }

            HStack(spacing: 7) {
                Text("Target date")
                    .font(interfaceFont(.tertiary, weight: .bold))
                    .foregroundStyle(primaryText)
                Spacer()
                Button("30 days") { setPrimaryGoalDays(30) }
                    .buttonStyle(HeaderActionButtonStyle())
                Button("60 days") { setPrimaryGoalDays(60) }
                    .buttonStyle(HeaderActionButtonStyle())
                Button(finishDateLabel, action: openFinishDatePicker)
                    .buttonStyle(HeaderActionButtonStyle(isEmphasized: true))
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
                        .font(interfaceFont(.tertiary, weight: .semibold))
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
                        .font(interfaceFont(.secondary, weight: .bold))
                        .foregroundStyle(primaryText)
                    Text(calendarProvider.isAuthorized ? calendarProvider.accountCountLabel : calendarProvider.message)
                        .font(interfaceFont(.tertiary, weight: .semibold))
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
                .buttonStyle(HeaderActionButtonStyle(isEmphasized: !calendarProvider.isAuthorized))
            }

            if calendarProvider.isAuthorized {
                HStack(spacing: 6) {
                    ForEach(calendarProvider.accounts.prefix(4)) { account in
                        calendarAccountChip(account)
                    }
                }
            }

            Text("Founder’s Office reads upcoming event titles and times from the calendars already enabled in macOS. It does not reconnect each time the notch opens.")
                .font(interfaceFont(.tertiary, weight: .medium))
                .foregroundStyle(secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var healthSettingsPage: some View {
        let snapshot = health.snapshot
        let columns = [
            GridItem(.flexible(), spacing: 7),
            GridItem(.flexible(), spacing: 7)
        ]

        return VStack(alignment: .leading, spacing: 8) {
            settingsPageHeading(
                "System health",
                detail: "Five checks. Personal content is never included."
            )

            LazyVGrid(columns: columns, alignment: .leading, spacing: 6) {
                ForEach(snapshot.components) { status in
                    healthStatusCard(status)
                }
            }

            HStack(spacing: 7) {
                Text("Repairs are limited to safe retries and reloads.")
                    .font(interfaceFont(.tertiary, weight: .semibold))
                    .foregroundStyle(secondaryText)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button("Preview support file") {
                    supportReportSaveError = nil
                    supportReportPreview = health.supportReport()
                }
                .buttonStyle(HeaderActionButtonStyle(isEmphasized: true))
                .accessibilityIdentifier("health.previewSupportReport")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("health.page")
    }

    private func healthStatusCard(_ status: HealthComponentStatus) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 7) {
                Image(systemName: healthSymbol(for: status.component))
                    .font(symbolFont(size: 11, weight: .semibold))
                    .foregroundStyle(healthColor(for: status.condition))
                    .frame(width: 18, height: 18)
                    .background(
                        healthColor(for: status.condition).opacity(0.13),
                        in: Circle()
                    )

                Text(status.component.title)
                    .font(interfaceFont(.secondary, weight: .bold))
                    .foregroundStyle(primaryText)
                    .lineLimit(1)

                Spacer(minLength: 2)

                if let actionTitle = status.remediation.title {
                    Button(actionTitle) {
                        health.perform(status.remediation)
                    }
                    .buttonStyle(StatusTabButtonStyle())
                    .font(interfaceFont(.tertiary, weight: .bold))
                    .foregroundStyle(accent)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("health.action.\(status.component.rawValue)")
                }
            }

            Text(healthDetail(status))
                .font(interfaceFont(.tertiary, weight: .semibold))
                .foregroundStyle(secondaryText)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 47, alignment: .leading)
        .background(
            groupedBackground,
            in: RoundedRectangle(cornerRadius: max(6, contentRadius - 4), style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: max(6, contentRadius - 4), style: .continuous)
                .stroke(healthColor(for: status.condition).opacity(0.22), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("health.status.\(status.component.rawValue)")
    }

    private func healthDetail(_ status: HealthComponentStatus) -> String {
        guard let date = status.lastSuccessAt else { return status.detail }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        let relative = formatter.localizedString(for: date, relativeTo: Date())
        return "\(status.detail) · \(relative)"
    }

    private func healthColor(for condition: HealthCondition) -> Color {
        switch condition {
        case .ready: return Color(nsColor: .systemGreen)
        case .working: return accent
        case .attention: return Color(nsColor: .systemOrange)
        case .needsYou: return Color(nsColor: .systemRed)
        case .off: return Color.white.opacity(0.58)
        }
    }

    private func healthSymbol(for component: HealthComponent) -> String {
        switch component {
        case .localData: return "internaldrive"
        case .sync: return "arrow.triangle.2.circlepath"
        case .calendar: return "calendar"
        case .startup: return "power"
        case .assistant: return "wand.and.stars"
        }
    }

    private func settingsPageHeading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(displayFont(.secondary))
                .foregroundStyle(primaryText)
            Text(detail)
                .font(interfaceFont(.tertiary, weight: .semibold))
                .foregroundStyle(secondaryText)
        }
    }

    private func identityTextField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(interfaceFont(.tertiary, weight: .medium))
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
                        .font(symbolFont(size: 8.5, weight: .bold))
                }
            }
            .font(interfaceFont(.tertiary, weight: .semibold))
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

    private var accentControlModule: some View {
        VStack(alignment: .leading, spacing: 6) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 10) {
                    Text("Accent")
                        .font(interfaceFont(.tertiary, weight: .bold))
                        .foregroundStyle(primaryText)

                    Spacer(minLength: 8)

                    Picker("Accent style", selection: accentModeBinding) {
                        ForEach(AccentMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .frame(width: 132)
                    .accessibilityLabel("Accent style")
                    .accessibilityIdentifier("appearance.accentStyle")
                }

                HStack(spacing: 10) {
                    accentColorControl(
                        name: "Accent colour",
                        hex: personalization.appearance.accent.primaryColor.hex,
                        stopIndex: 0
                    )

                    if personalization.appearance.accent.mode == .gradient {
                        Rectangle()
                            .fill(Color.white.opacity(0.10))
                            .frame(width: 1, height: 18)

                        accentColorControl(
                            name: "Second accent colour",
                            hex: personalization.appearance.accent.secondaryColor.hex,
                            stopIndex: 1
                        )
                    }
                }
                .frame(minHeight: 22)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                groupedBackground,
                in: RoundedRectangle(cornerRadius: max(7, contentRadius - 3), style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: max(7, contentRadius - 3), style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
            )

            if personalization.appearance.accent.mode == .gradient {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text("Direction")
                            .font(interfaceFont(.tertiary, weight: .bold))
                            .foregroundStyle(primaryText)

                        Spacer(minLength: 8)

                        Text("\(Int(personalization.appearance.accent.angleDegrees.rounded()))°")
                            .font(interfaceFont(.tertiary, weight: .bold))
                            .foregroundStyle(primaryText)
                            .monospacedDigit()

                        Capsule()
                            .fill(theme.accentGradient)
                            .frame(width: 34, height: 14)
                            .overlay(
                                Capsule()
                                    .stroke(Color.white.opacity(0.16), lineWidth: 0.5)
                            )
                            .accessibilityHidden(true)
                    }

                    HStack(spacing: 6) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(symbolFont(size: 9.5, weight: .bold))
                            .foregroundStyle(Color.white.opacity(0.68))

                        ControlCenterSlider(
                            value: accentAngleBinding,
                            range: 0...359,
                            step: 1,
                            tint: Color.white.opacity(0.88),
                            focusTint: accent,
                            onEditingChanged: setAccentAngleEditing
                        )
                            .accessibilityLabel("Gradient direction")
                            .accessibilityValue("\(Int(personalization.appearance.accent.angleDegrees.rounded())) degrees")
                            .accessibilityIdentifier("appearance.gradientDirection")

                        Image(systemName: "arrow.clockwise")
                            .font(symbolFont(size: 9.5, weight: .bold))
                            .foregroundStyle(Color.white.opacity(0.68))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    groupedBackground,
                    in: RoundedRectangle(cornerRadius: max(7, contentRadius - 3), style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: max(7, contentRadius - 3), style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 1)
                )
            }
        }
    }

    private func accentColorControl(name: String, hex: String, stopIndex: Int) -> some View {
        HStack(spacing: 5) {
            ColorPicker(name, selection: accentColorBinding(stopIndex: stopIndex), supportsOpacity: false)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 28)

            Text(hex)
                .font(interfaceFont(.tertiary, weight: .semibold))
                .foregroundStyle(primaryText)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(name)
        .accessibilityValue(hex)
        .accessibilityIdentifier("appearance.colour.\(stopIndex)")
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
                    .font(interfaceFont(.tertiary, weight: .bold))
                    .foregroundStyle(primaryText)
                Spacer(minLength: 8)
                Text(title(selected))
                    .font(interfaceFont(.tertiary, weight: .semibold))
                    .foregroundStyle(theme.readableAccentOnPanel)
                Image(systemName: "chevron.up.chevron.down")
                    .font(symbolFont(size: 9.5, weight: .bold))
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
        .frame(maxWidth: .infinity, minHeight: 34)
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
            set: { angle in
                personalization.updateAccentAngle(angle)
            }
        )
    }

    private var accentModeBinding: Binding<AccentMode> {
        Binding(
            get: { personalization.appearance.accent.mode },
            set: { personalization.updateAccentMode($0) }
        )
    }

    private func setAccentAngleEditing(_ isEditing: Bool) {
        if isEditing {
            if accentSliderInteractionLease == nil {
                accentSliderInteractionLease = presentation.beginInteraction("accent-angle")
            }
            return
        }

        guard let lease = accentSliderInteractionLease else { return }
        presentation.endInteraction(lease)
        accentSliderInteractionLease = nil
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
        personalization.choosePhoto(
            onPresent: { panel in
                presentation.transients.present(
                    panel,
                    request: TransientPresentationRequest(
                        kind: .fileChooser,
                        hostDisposition: .suspendExpandedHost
                    )
                )
            },
            onCompletion: { panel in
                Task { @MainActor in
                    presentation.transients.dismissAndEnd(panel)
                }
            }
        )
    }

    private func exportOriginalPhotoWithLease() {
        personalization.exportOriginalPhoto(
            onPresent: { panel in
                presentation.transients.present(
                    panel,
                    request: TransientPresentationRequest(
                        kind: .fileChooser,
                        hostDisposition: .suspendExpandedHost
                    )
                )
            },
            onCompletion: { panel in
                Task { @MainActor in
                    presentation.transients.dismissAndEnd(panel)
                }
            }
        )
    }

    private func presentCalendarEventEditor() {
        guard calendarProvider.isAuthorized else {
            calendarProvider.connectOrOpenSettings()
            return
        }

        calendarProvider.refresh()
        if calendarEventInteractionLease == nil {
            calendarEventInteractionLease = presentation.beginInteraction("calendar-event")
        }

        let start = suggestedCalendarEventStart
        calendarEventTitle = ""
        calendarEventStart = start
        calendarEventEnd = Calendar.current.date(byAdding: .hour, value: 1, to: start)
            ?? start.addingTimeInterval(3_600)
        calendarEventIsAllDay = false
        calendarEventDestinationID = calendarProvider.recommendedDestinationID
            ?? calendarProvider.writableDestinations.first?.id
        calendarEventErrorMessage = nil
        isCreatingCalendarEvent = true
    }

    private var suggestedCalendarEventStart: Date {
        CalendarEventDefaults.suggestedStart(for: selectedCalendarDay)
    }

    private var canSaveCalendarEvent: Bool {
        let hasValidDates: Bool
        if calendarEventIsAllDay {
            hasValidDates = Calendar.current.startOfDay(for: calendarEventEnd)
                >= Calendar.current.startOfDay(for: calendarEventStart)
        } else {
            hasValidDates = calendarEventEnd > calendarEventStart
        }

        return !calendarEventTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && calendarEventDestinationID != nil
            && hasValidDates
    }

    private func saveCalendarEvent() {
        switch calendarProvider.createEvent(
            title: calendarEventTitle,
            startDate: calendarEventStart,
            endDate: calendarEventEnd,
            isAllDay: calendarEventIsAllDay,
            calendarIdentifier: calendarEventDestinationID
        ) {
        case .success:
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            closeCalendarEventEditor()
        case let .failure(error):
            calendarEventErrorMessage = error.localizedDescription
        }
    }

    private func closeCalendarEventEditor() {
        isCreatingCalendarEvent = false
        calendarEventErrorMessage = nil
        guard let lease = calendarEventInteractionLease else { return }
        presentation.endInteraction(lease)
        calendarEventInteractionLease = nil
    }

    private func presentPlanningEditor(for item: OpenLoop) {
        guard item.deletedAt == nil else { return }
        if planningInteractionLease == nil {
            planningInteractionLease = presentation.beginInteraction("move-planning")
        }

        planningItemID = item.id
        planningTitle = item.title
        planningInitialTitle = item.title
        planningDetails = item.details
        planningInitialDetails = item.details
        planningPriority = item.priority
        planningInitialPriority = item.priority
        planningHasDeadline = item.dueAt != nil
        planningDeadline = item.dueAt.map { PlanningDate.localDate(fromStored: $0) }
            ?? Date()
        planningInitialDueAt = item.dueAt
        planningErrorMessage = nil
    }

    private func refreshPlanningEditor(from item: OpenLoop) {
        if planningTitle == planningInitialTitle {
            planningTitle = item.title
            planningInitialTitle = item.title
        }
        if planningDetails == planningInitialDetails {
            planningDetails = item.details
            planningInitialDetails = item.details
        }

        if planningPriority == planningInitialPriority {
            planningPriority = item.priority
            planningInitialPriority = item.priority
        }

        if planningDraftDueDay == planningInitialDueDay {
            let currentDueAt = item.dueAt
            planningInitialDueAt = currentDueAt
            planningHasDeadline = currentDueAt != nil
            if let currentDueAt {
                planningDeadline = PlanningDate.localDate(fromStored: currentDueAt)
            }
        }
    }

    private func savePlanningEditor() {
        Task { await savePlanningEditorAndWait() }
    }

    private func savePlanningEditorAndWait() async {
        guard let planningItemID else {
            closePlanningEditor()
            return
        }

        let priorityChange: PlanningPriorityChange = planningPriority == planningInitialPriority
            ? .unchanged
            : .set(planningPriority)
        let deadlineChange: PlanningDeadlineChange
        if planningDraftDueDay == planningInitialDueDay {
            deadlineChange = .unchanged
        } else if planningHasDeadline {
            deadlineChange = .set(planningDeadline)
        } else {
            deadlineChange = .clear
        }

        switch await store.updateContentAndPlanning(
            id: planningItemID,
            title: planningTitle,
            details: planningDetails,
            priorityChange: priorityChange,
            deadlineChange: deadlineChange
        ) {
        case .saved:
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            closePlanningEditor()
        case .unchanged:
            closePlanningEditor()
        case let .failed(message):
            planningErrorMessage = message
        }
    }

    private func closePlanningEditor() {
        planningItemID = nil
        planningTitle = ""
        planningInitialTitle = ""
        planningDetails = ""
        planningInitialDetails = ""
        planningInitialDueAt = nil
        planningErrorMessage = nil
        releasePlanningInteraction()
    }

    private var planningDraftDueDay: PlanningDay? {
        planningHasDeadline ? PlanningDate.day(fromLocal: planningDeadline) : nil
    }

    private var planningInitialDueDay: PlanningDay? {
        planningInitialDueAt.map(PlanningDate.day(fromStored:))
    }

    private var planningHasChanges: Bool {
        let cleanTitle = planningTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDetails = planningDetails.trimmingCharacters(in: .whitespacesAndNewlines)
        let contentIsValid = !cleanTitle.isEmpty
            && cleanTitle.unicodeScalars.count <= 500
            && cleanDetails.unicodeScalars.count <= 20_000
        return contentIsValid && (
            cleanTitle != planningInitialTitle
            || cleanDetails != planningInitialDetails
            || planningPriority != planningInitialPriority
            || planningDraftDueDay != planningInitialDueDay
        )
    }

    private func releasePlanningInteraction() {
        guard let lease = planningInteractionLease else { return }
        presentation.endInteraction(lease)
        planningInteractionLease = nil
    }

    private func releaseTransientInteractions() {
        finishPriorityDrag()
        closeCalendarEventEditor()
        closePlanningEditor()
        releaseFinishDateInteraction()
        setAccentAngleEditing(false)
    }

    private func settingsSectionTitle(_ title: String) -> some View {
        Text(title)
            .font(interfaceFont(.tertiary, weight: .bold))
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
            .font(interfaceFont(.tertiary, weight: .medium))
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
        .font(interfaceFont(.tertiary, weight: .medium))
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
        #if FOUNDER_OFFICE_DISTRIBUTION
        return false
        #else
        switch codexRunner.state {
        case .idle: return false
        case .running, .finished, .failed: return true
        }
        #endif
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
            }
            #if !FOUNDER_OFFICE_DISTRIBUTION
            if store.recentlyDeleted == nil {
                CodexRunFooter(runner: codexRunner, accent: accent)
            }
            #endif

            Spacer()
        }
        .font(interfaceFont(.tertiary, weight: .medium))
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
                return DeadlineSignal(
                    id: "task-\(item.id.uuidString)",
                    title: item.title,
                    dueAt: PlanningDate.localDate(fromStored: dueAt),
                    source: "Move"
                )
            }

        return (primary + custom + taskDeadlines)
            .filter { Calendar.current.startOfDay(for: $0.dueAt) >= Calendar.current.startOfDay(for: Date()) }
            .sorted { $0.dueAt < $1.dueAt }
    }

    private var calendarDeadlineSignals: [DeadlineSignal] {
        deadlineSignals.filter { signal in
            signal.source != "Move"
                || !Calendar.current.isDate(signal.dueAt, inSameDayAs: selectedCalendarDay)
        }
    }

    private var nextSevenDays: [Date] {
        let today = Calendar.current.startOfDay(for: Date())
        return (0..<7).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: today) }
    }

    private var selectedDayEvents: [CalendarSignal] {
        let dayStart = Calendar.current.startOfDay(for: selectedCalendarDay)
        let dayEnd = Calendar.current.date(byAdding: .day, value: 1, to: dayStart)
            ?? dayStart.addingTimeInterval(86_400)
        return calendarProvider.events.filter { event in
            event.startDate < dayEnd && event.endDate > dayStart
        }
    }

    private var selectedDayMoves: [OpenLoop] {
        MovePresentation(items: store.items)
            .activeItems(dueOn: selectedCalendarDay, calendar: .current)
    }

    private var selectedDayTitle: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "EEEE, d MMM"
        return formatter.string(from: selectedCalendarDay).uppercased()
    }

    private func presentSettings() {
        closeCalendarEventEditor()
        closePlanningEditor()
        loadIdentityEditor()
        loadPrimaryGoalEditor()
        calendarProvider.syncOnOpen()
        if personalizePage == .appearance {
            personalization.beginAppearanceEditing()
        }
        withAnimation(.spring(response: 0.30, dampingFraction: 0.84)) {
            isSettingsPresented = true
            isAdding = false
        }
    }

    private func dismissSettings() {
        requestAppearanceExit(.dismissSettings)
    }

    private func handleExitCommand() {
        if pendingAppearanceExit != nil {
            pendingAppearanceExit = nil
        } else if account.requiresSetupOverlay {
            account.cancelAccountSetup()
        } else if supportReportPreview != nil {
            closeSupportReportPreview()
        } else if isCreatingCalendarEvent {
            closeCalendarEventEditor()
        } else if planningItemID != nil {
            closePlanningEditor()
        } else if isFinishDatePickerPresented {
            closeFinishDatePicker()
        } else if isSettingsPresented {
            requestAppearanceExit(.dismissSettings)
        } else {
            requestAppearanceExit(.closeNotch)
        }
    }

    private func select(_ section: BoardSection) {
        guard section != selectedSection || isSettingsPresented else { return }
        requestAppearanceExit(.section(section))
    }

    private func requestAppearanceExit(_ action: AppearanceExitAction) {
        if case .page(.appearance) = action {
            personalization.beginAppearanceEditing()
            if personalizePage != .appearance {
                closeFinishDatePicker()
                withAnimation(.easeOut(duration: 0.16)) { personalizePage = .appearance }
            }
            return
        }

        presentation.closeNativeColorPanels()
        if action == .closeNotch {
            onClose()
            return
        }
        if personalizePage == .appearance,
           isSettingsPresented,
           personalization.hasUnsavedAppearanceChanges {
            pendingAppearanceExit = action
            return
        }
        performAppearanceExit(action)
    }

    private func performAppearanceExit(_ action: AppearanceExitAction) {
        switch action {
        case let .page(page):
            if page != .finishLine { closeFinishDatePicker() }
            withAnimation(.easeOut(duration: 0.16)) { personalizePage = page }
        case .dismissSettings:
            closePlanningEditor()
            closeFinishDatePicker()
            saveIdentity()
            withAnimation(.spring(response: 0.30, dampingFraction: 0.84)) {
                isSettingsPresented = false
            }
        case let .section(section):
            selectWithoutAppearancePrompt(section)
        case .closeNotch:
            onClose()
        }
    }

    private func selectWithoutAppearancePrompt(_ section: BoardSection) {
        closeCalendarEventEditor()
        closePlanningEditor()
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

    private func saveAppearanceDraft() {
        Task { await saveAppearanceDraftAndWait() }
    }

    private func saveAppearanceDraftAndWait() async {
        presentation.closeNativeColorPanels()
        switch await personalization.saveAppearanceChanges() {
        case .saved:
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        case .unchanged, .conflict, .failed:
            break
        }
    }

    private func discardAppearanceDraft() {
        presentation.closeNativeColorPanels()
        personalization.discardAppearanceChanges()
        personalization.beginAppearanceEditing()
    }

    private func discardAppearanceAndContinue() {
        guard let action = pendingAppearanceExit else { return }
        pendingAppearanceExit = nil
        personalization.discardAppearanceChanges()
        performAppearanceExit(action)
    }

    private func saveAppearanceAndContinue() {
        Task { await saveAppearanceAndContinueAfterCommit() }
    }

    private func saveAppearanceAndContinueAfterCommit() async {
        guard let action = pendingAppearanceExit else { return }
        switch await personalization.saveAppearanceChanges() {
        case .saved, .unchanged:
            pendingAppearanceExit = nil
            performAppearanceExit(action)
        case .conflict, .failed:
            pendingAppearanceExit = nil
        }
    }

    private func closeSupportReportPreview() {
        supportReportPreview = nil
        supportReportSaveError = nil
    }

    private func saveSupportReport(_ report: RedactedSupportReport) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "founders-office-support.json"
        panel.message = "Save the exact redacted fields shown in the preview."
        presentation.transients.present(
            panel,
            request: TransientPresentationRequest(
                kind: .fileChooser,
                hostDisposition: .suspendExpandedHost
            )
        )
        panel.begin { response in
            Task { @MainActor in
                defer { presentation.transients.dismissAndEnd(panel) }
                guard response == .OK, let destination = panel.url else { return }
                do {
                    try await supportReportStorage.save(report, to: destination)
                    closeSupportReportPreview()
                } catch {
                    supportReportSaveError = "Couldn’t save the support file. Try again."
                    AppDiagnostics.failure(.supportReportSave, category: .storage, error: error)
                }
            }
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
        primaryGoalCurrent = goal.currentValue?.canonicalString ?? ""
        primaryGoalTarget = goal.targetValue?.canonicalString ?? ""
        primaryGoalValidationMessage = nil
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
        primaryGoalValidationMessage = nil
        primaryGoalUnit = .usd
        primaryGoalDate = Calendar.current.date(byAdding: .day, value: 60, to: Date()) ?? Date()
    }

    private func savePrimaryGoal() {
        let cleanTitle = primaryGoalTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return }

        let currentValue: GoalDecimal?
        let targetValue: GoalDecimal?
        do {
            currentValue = try parsedGoalValue(primaryGoalCurrent)
            targetValue = try parsedGoalValue(primaryGoalTarget)
            if let targetValue, targetValue == .zero {
                primaryGoalValidationMessage = "Target must be greater than zero."
                return
            }
        } catch {
            primaryGoalValidationMessage = goalValidationMessage(for: error)
            return
        }

        personalization.setPrimaryGoal(
            title: cleanTitle,
            metric: primaryGoalMetric,
            currentValue: currentValue,
            targetValue: targetValue,
            unit: primaryGoalUnit,
            dueAt: primaryGoalDate
        )
        primaryGoalValidationMessage = nil
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

    private func setPrimaryGoalDays(_ days: Int) {
        primaryGoalDate = Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? primaryGoalDate
    }

    private func parsedGoalValue(_ text: String) throws -> GoalDecimal? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : try GoalDecimal(userInput: clean)
    }

    private func goalValidationMessage(for error: Error) -> String {
        switch error as? GoalDecimal.ValidationError {
        case .tooManyFractionDigits:
            return "Use no more than 8 digits after the decimal point."
        case .outOfRange:
            return "That number is too large. Use at most 22 digits before the decimal point."
        case .negative:
            return "Goal values cannot be negative."
        default:
            return "Enter a valid number, such as 3,000.12345678."
        }
    }

    private func select(_ status: LoopStatus) {
        guard status != selectedStatus else { return }
        closePlanningEditor()
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        withAnimation(.spring(response: 0.30, dampingFraction: 0.78, blendDuration: 0.08)) {
            selectedStatus = status
            isShowingPreviousTasks = false
        }
    }

    private func addItem() {
        guard canAddMove else { return }
        store.add(
            title: newTitle,
            details: newDetails,
            status: newStatus,
            priority: newPriority,
            dueAt: nil
        )
        selectedStatus = newStatus
        isShowingPreviousTasks = false
        newTitle = ""
        newDetails = ""
        isAdding = false
    }

    private var canAddMove: Bool {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let details = newDetails.trimmingCharacters(in: .whitespacesAndNewlines)
        return !title.isEmpty
            && title.unicodeScalars.count <= 500
            && details.unicodeScalars.count <= 20_000
    }

    private func deleteMove(_ item: OpenLoop) {
        if planningItemID == item.id {
            closePlanningEditor()
        }
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
            store.delete(item)
        }
    }

    private func completedLabel(for item: OpenLoop) -> String {
        guard let completedAt = item.completedAt else { return "Completed" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")

        if Calendar.current.isDateInToday(completedAt) {
            formatter.dateFormat = "h:mm a"
        } else if Calendar.current.isDateInYesterday(completedAt) {
            formatter.dateFormat = "'Yesterday'"
        } else {
            formatter.dateFormat = "d MMM"
        }

        return formatter.string(from: completedAt)
    }

    private func priorityColor(for priority: LoopPriority) -> Color {
        switch priority {
        case .p0: return Color(nsColor: .systemRed)
        case .p1: return Color(nsColor: .systemOrange)
        case .p2: return theme.readableAccentOnPanel
        case .p3: return secondaryText
        }
    }

    private func homeDueLabel(_ date: Date) -> String {
        let dueDay = PlanningDate.day(fromStored: date)
        if dueDay == PlanningDate.day(fromLocal: Date()) { return "Due today" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "'Due' d MMM"
        return formatter.string(from: PlanningDate.localDate(fromStored: date))
    }

    private func primaryGoalTargetLabel(_ goal: PrimaryGoal, target: GoalDecimal) -> String {
        let metric = goal.metric.trimmingCharacters(in: .whitespacesAndNewlines)
        return metric.isEmpty ? goal.unit.format(target) : "\(goal.unit.format(target)) \(metric)"
    }

    private func primaryGoalProgress(_ goal: PrimaryGoal) -> Double {
        guard let target = goal.targetValue, target > 0 else { return 0 }
        let ratio = (goal.currentValue ?? .zero).doubleValue / target.doubleValue
        return min(max(ratio, 0), 1)
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

    private func eventTimeLabel(_ event: CalendarSignal, on day: Date? = nil) -> String {
        if event.isAllDay { return "All day" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "h:mm a"

        if let day {
            let calendar = Calendar.current
            let dayStart = calendar.startOfDay(for: day)
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
                ?? dayStart.addingTimeInterval(86_400)
            if event.startDate < dayStart {
                if event.endDate < dayEnd {
                    return "Continues · ends \(formatter.string(from: event.endDate))"
                }
                return "Continues"
            }
            if event.endDate > dayEnd {
                return "\(formatter.string(from: event.startDate)) · continues"
            }
        }

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

private struct HistoryNavigationButton: View {
    @Environment(\.founderTheme) private var theme
    let title: String
    let detail: String?
    let leadingSystemImage: String
    let trailingSystemImage: String?
    let accent: Color
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: leadingSystemImage)
                    .font(theme.symbolFont(size: 11.5, weight: .semibold))
                    .foregroundStyle(theme.readableAccentOnPanel)
                    .frame(width: 18)

                Text(title)
                    .font(theme.interfaceFont(.secondary, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.94))

                Spacer(minLength: 8)

                if let detail {
                    Text(detail)
                        .font(theme.interfaceFont(.tertiary, weight: .semibold))
                        .foregroundStyle(Color.white.opacity(0.58))
                        .contentTransition(.numericText())
                }

                if let trailingSystemImage {
                    Image(systemName: trailingSystemImage)
                        .font(theme.symbolFont(size: 10, weight: .bold))
                        .foregroundStyle(Color.white.opacity(isHovered ? 0.88 : 0.52))
                }
            }
            .padding(.horizontal, 13)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(
                isHovered ? Color.white.opacity(0.075) : Color.white.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(isHovered ? accent.opacity(0.34) : Color.white.opacity(0.085), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(StatusTabButtonStyle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.14)) {
                isHovered = hovering
            }
        }
    }
}

private struct CalendarEventEditor: View {
    @Environment(\.founderTheme) private var theme

    @Binding var title: String
    @Binding var startDate: Date
    @Binding var endDate: Date
    @Binding var isAllDay: Bool
    @Binding var destinationID: String?
    let destinations: [CalendarDestinationSignal]
    let errorMessage: String?
    let canSave: Bool
    let accent: Color
    let onCancel: () -> Void
    let onSave: () -> Void

    @FocusState private var isTitleFocused: Bool

    private let primaryText = Color.white.opacity(0.96)
    private let secondaryText = Color.white.opacity(0.72)

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline) {
                Text("New event")
                    .font(theme.displayFont(.primaryTitle))
                    .foregroundStyle(primaryText)
                Spacer()
                Toggle("All day", isOn: $isAllDay)
                    .toggleStyle(.switch)
                    .font(theme.interfaceFont(.tertiary, weight: .bold))
                    .foregroundStyle(primaryText)
            }

            TextField("Event title", text: $title)
                .textFieldStyle(.plain)
                .font(theme.interfaceFont(.secondary, weight: .semibold))
                .foregroundStyle(primaryText)
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(
                            isTitleFocused ? accent.opacity(0.84) : Color.white.opacity(0.10),
                            lineWidth: isTitleFocused ? 1.5 : 1
                        )
                )
                .shadow(color: isTitleFocused ? accent.opacity(0.16) : .clear, radius: 5)
                .focused($isTitleFocused)
                .onSubmit { if canSave { onSave() } }
                .accessibilityIdentifier("calendarEvent.title")

            eventDateRow("Starts", selection: $startDate)
            eventDateRow("Ends", selection: $endDate)

            HStack(spacing: 10) {
                Text("Calendar")
                    .font(theme.interfaceFont(.tertiary, weight: .bold))
                    .foregroundStyle(primaryText)
                    .frame(width: 52, alignment: .leading)

                if destinations.isEmpty {
                    Text("No writable calendar")
                        .font(theme.interfaceFont(.secondary, weight: .semibold))
                        .foregroundStyle(Color(nsColor: .systemRed))
                } else {
                    Picker("Calendar", selection: $destinationID) {
                        ForEach(destinations) { destination in
                            Text(destination.displayLabel)
                                .tag(Optional(destination.id))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Calendar account and calendar")
                    .accessibilityIdentifier("calendarEvent.destination")
                }
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.circle.fill")
                    .font(theme.interfaceFont(.tertiary, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 9) {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(HeaderActionButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("calendarEvent.cancel")
                Button("Add event", action: onSave)
                    .buttonStyle(HeaderActionButtonStyle(isEmphasized: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
                    .accessibilityIdentifier("calendarEvent.save")
            }
        }
        .frame(width: 450)
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("New calendar event")
        .accessibilityIdentifier("calendarEvent.editor")
        .accessibilityAddTraits(.isModal)
        .onAppear {
            DispatchQueue.main.async { isTitleFocused = true }
        }
        .onChange(of: isAllDay) { _, allDay in
            if allDay {
                endDate = startDate
            } else if endDate <= startDate {
                endDate = Calendar.current.date(byAdding: .hour, value: 1, to: startDate)
                    ?? startDate.addingTimeInterval(3_600)
            }
        }
        .onChange(of: startDate) { _, newStart in
            if isAllDay {
                endDate = newStart
            } else if endDate <= newStart {
                endDate = Calendar.current.date(byAdding: .hour, value: 1, to: newStart)
                    ?? newStart.addingTimeInterval(3_600)
            }
        }
    }

    private func eventDateRow(_ label: String, selection: Binding<Date>) -> some View {
        HStack(spacing: 10) {
            Text(label)
                .font(theme.interfaceFont(.tertiary, weight: .bold))
                .foregroundStyle(primaryText)
                .frame(width: 52, alignment: .leading)
            DatePicker(
                label,
                selection: selection,
                displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute]
            )
            .datePickerStyle(.field)
            .labelsHidden()
            .accessibilityLabel(label)
            Spacer(minLength: 0)
        }
    }
}

private struct ConditionalMoveDragModifier: ViewModifier {
    let id: UUID?
    let activeID: UUID?
    let dragOffset: CGSize

    @ViewBuilder
    func body(content: Content) -> some View {
        if let id {
            content
                .contentShape(Rectangle())
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: PriorityMoveRowFramePreferenceKey.self,
                            value: [
                                id: proxy.frame(in: .named("priority-move-scroll"))
                            ]
                        )
                    }
                }
                .offset(activeID == id ? dragOffset : .zero)
                .scaleEffect(activeID == id ? 1.012 : 1)
                .shadow(
                    color: Color.black.opacity(activeID == id ? 0.34 : 0),
                    radius: activeID == id ? 14 : 0,
                    y: activeID == id ? 7 : 0
                )
                .zIndex(activeID == id ? 10 : 0)
                .animation(
                    .spring(response: 0.22, dampingFraction: 0.84),
                    value: activeID == id
                )
                .help("Drag to change priority")
        } else {
            content
        }
    }
}

private struct LoopRow: View {
    @Environment(\.founderTheme) private var theme
    let item: OpenLoop
    let accent: Color
    let trailingLabel: String?
    let showsPriorityBadge: Bool
    let onToggle: () -> Void
    let onMove: (LoopStatus) -> Void
    let onSetPriority: (LoopPriority) -> Void
    let onEditPlanning: () -> Void
    #if !FOUNDER_OFFICE_DISTRIBUTION
    let codexAction: CodexTaskAction
    let isCodexAvailable: Bool
    let isCodexBusy: Bool
    let onRunWithCodex: () -> Void
    #endif
    let onDelete: () -> Void

    private let primaryText = Color.white.opacity(0.95)
    private let secondaryText = Color.white.opacity(0.64)
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            completionButton
            planningButton
            trailingControl
            actionsMenu
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
        .accessibilityIdentifier("move.row.\(item.id.uuidString.lowercased())")
    }

    private var completionButton: some View {
        Button(action: onToggle) {
            Image(systemName: item.status == .done ? "checkmark.circle.fill" : "circle")
                .font(theme.symbolFont(size: 19, weight: .medium))
                .foregroundStyle(item.status == .done ? Color.green : readablePriorityColor)
                .frame(width: 34, height: 34)
                .background(isHovered ? priorityColor.opacity(0.09) : Color.clear, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(RowControlButtonStyle())
        .accessibilityLabel(item.status == .done ? "Reopen \(item.title)" : "Complete \(item.title)")
    }

    private var planningButton: some View {
        Button(action: onEditPlanning) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    if showsPriorityBadge {
                        Text(item.priority.rawValue)
                            .font(theme.interfaceFont(.tertiary, weight: .semibold))
                            .foregroundStyle(readablePriorityColor)
                            .padding(.horizontal, 7)
                            .frame(minHeight: 24)
                            .background(priorityColor.opacity(isHovered ? 0.19 : 0.12), in: Capsule())
                    }

                    Text(item.title)
                        .font(theme.interfaceFont(.secondary, weight: .semibold))
                        .foregroundStyle(primaryText.opacity(item.status == .done ? 0.55 : 1))
                        .strikethrough(item.status == .done, color: secondaryText)
                        .lineLimit(1)

                    Spacer(minLength: 0)
                }

                if !item.details.isEmpty {
                    Text(item.details)
                        .font(theme.interfaceFont(.tertiary, weight: .regular))
                        .foregroundStyle(secondaryText)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(StatusTabButtonStyle())
        .help(item.details.isEmpty ? "Edit this Move" : "Read or edit the full description")
        .accessibilityLabel("Edit \(item.title)")
        .accessibilityHint(
            item.details.isEmpty
                ? "Opens title, description, priority, and deadline"
                : "Opens the full description, priority, and deadline"
        )
        .accessibilityValue(planningAccessibilityValue)
    }

    @ViewBuilder
    private var trailingControl: some View {
        if let trailingLabel {
            Text(trailingLabel)
                .font(theme.interfaceFont(.tertiary, weight: .medium))
                .foregroundStyle(secondaryText)
                .frame(width: 72, alignment: .trailing)
        } else {
            Button(action: onEditPlanning) {
                HStack(spacing: 4) {
                    if let dueAt = item.dueAt {
                        Image(systemName: "calendar")
                            .font(theme.symbolFont(size: 10, weight: .semibold))
                        Text(dueLabel(dueAt))
                            .font(theme.interfaceFont(.tertiary, weight: .semibold))
                    } else {
                        Image(systemName: "calendar.badge.plus")
                            .font(theme.symbolFont(size: 10, weight: .semibold))
                            .opacity(isHovered ? 1 : 0)
                    }
                }
                .foregroundStyle(deadlineColor)
                .padding(.horizontal, 7)
                .frame(width: 72, height: 28, alignment: .trailing)
                .background(isHovered ? Color.white.opacity(0.065) : Color.clear, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(StatusTabButtonStyle())
            .help(item.dueAt == nil ? "Add a deadline" : "Edit deadline")
            .accessibilityLabel(
                item.dueAt == nil
                    ? "Add a deadline to \(item.title)"
                    : "Edit \(item.title) deadline"
            )
        }
    }

    private var actionsMenu: some View {
        Menu {
            #if !FOUNDER_OFFICE_DISTRIBUTION
            if isCodexAvailable {
                Button(codexAction.label, action: onRunWithCodex)
                    .disabled(isCodexBusy)
                Divider()
            }
            #endif

            Button("Edit Move…", action: onEditPlanning)

            Menu("Set priority") {
                ForEach(LoopPriority.allCases) { priority in
                    Button("\(priority.title) · \(priority.rawValue)") {
                        onSetPriority(priority)
                    }
                    .disabled(priority == item.priority)
                }
            }

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
                .font(theme.symbolFont(size: 13, weight: .bold))
                .foregroundStyle(secondaryText)
                .frame(width: 34, height: 34)
                .background(isHovered ? Color.white.opacity(0.07) : Color.clear, in: Circle())
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More actions for \(item.title)")
    }

    private var priorityColor: Color {
        switch item.priority {
        case .p0: return Color(nsColor: .systemRed)
        case .p1: return Color(nsColor: .systemOrange)
        case .p2: return Color(nsColor: .systemBlue)
        case .p3: return secondaryText
        }
    }

    private var readablePriorityColor: Color {
        priorityColor
    }

    private var deadlineColor: Color {
        guard let dueAt = item.dueAt else { return secondaryText.opacity(0.92) }
        return isOverdue(dueAt) && item.status != .done
            ? Color.red.opacity(0.92)
            : secondaryText
    }

    private var planningAccessibilityValue: String {
        if let dueAt = item.dueAt {
            return "\(item.priority.rawValue), due \(dueLabel(dueAt))"
        }
        return "\(item.priority.rawValue), no deadline"
    }

    private func dueLabel(_ date: Date) -> String {
        let dueDay = PlanningDate.day(fromStored: date)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = dueDay == PlanningDate.day(fromLocal: Date()) ? "'Today'" : "d MMM"
        return formatter.string(from: PlanningDate.localDate(fromStored: date))
    }

    private func isOverdue(_ date: Date) -> Bool {
        PlanningDate.day(fromStored: date) < PlanningDate.day(fromLocal: Date())
    }
}

private struct MovePlanningEditor: View {
    @Environment(\.founderTheme) private var theme
    @Binding var title: String
    @Binding var details: String
    @Binding var priority: LoopPriority
    @Binding var hasDeadline: Bool
    @Binding var deadline: Date
    let errorMessage: String?
    let canSave: Bool
    let accent: Color
    let onCancel: () -> Void
    let onSave: () -> Void

    @FocusState private var focusedPriority: LoopPriority?

    private let primaryText = Color.white.opacity(0.96)
    private let secondaryText = Color.white.opacity(0.70)
    private let priorityColumns = [
        GridItem(.flexible(), spacing: 7),
        GridItem(.flexible(), spacing: 7),
        GridItem(.flexible(), spacing: 7),
        GridItem(.flexible(), spacing: 7)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Edit Move")
                    .font(theme.displayFont(.primaryTitle))
                    .foregroundStyle(primaryText)

                TextField("Title", text: $title)
                    .textFieldStyle(.plain)
                    .font(theme.interfaceFont(.secondary, weight: .semibold))
                    .foregroundStyle(primaryText)
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(Color.white.opacity(0.10), lineWidth: 1)
                    )
                    .accessibilityIdentifier("movePlanning.title")

                TextField("Description (optional)", text: $details, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(theme.interfaceFont(.tertiary, weight: .regular))
                    .foregroundStyle(primaryText.opacity(0.88))
                    .lineLimit(2...3)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
                    .accessibilityIdentifier("movePlanning.description")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Priority")
                    .font(theme.interfaceFont(.tertiary, weight: .bold))
                    .foregroundStyle(primaryText)

                LazyVGrid(columns: priorityColumns, spacing: 7) {
                    ForEach(LoopPriority.allCases) { option in
                        priorityButton(option)
                    }
                }
            }

            Divider()
                .overlay(Color.white.opacity(0.10))

            HStack(spacing: 10) {
                Toggle("Deadline", isOn: $hasDeadline)
                    .toggleStyle(.switch)
                    .font(theme.interfaceFont(.tertiary, weight: .bold))
                    .foregroundStyle(primaryText)
                    .accessibilityIdentifier("movePlanning.deadlineEnabled")

                if hasDeadline {
                    Spacer()
                    DatePicker(
                        "Due date",
                        selection: $deadline,
                        displayedComponents: .date
                    )
                    .datePickerStyle(.field)
                    .labelsHidden()
                    .accessibilityLabel("Due date")
                }
            }

            if let displayedErrorMessage {
                Label(displayedErrorMessage, systemImage: "exclamationmark.circle.fill")
                    .font(theme.interfaceFont(.tertiary, weight: .semibold))
                    .foregroundStyle(Color.red.opacity(0.94))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(displayedErrorMessage)
            }

            HStack(spacing: 9) {
                if hasDeadline {
                    Button("Clear deadline") {
                        hasDeadline = false
                    }
                    .buttonStyle(HeaderActionButtonStyle())
                }

                Spacer()

                Button("Cancel", action: onCancel)
                    .buttonStyle(HeaderActionButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("movePlanning.cancel")

                Button("Save", action: onSave)
                    .buttonStyle(HeaderActionButtonStyle(isEmphasized: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
                    .accessibilityIdentifier("movePlanning.save")
            }
        }
        .frame(width: 520)
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Edit Move")
        .accessibilityIdentifier("movePlanning.editor")
        .accessibilityAddTraits(.isModal)
        .onAppear {
            DispatchQueue.main.async {
                focusedPriority = priority
            }
        }
    }

    private func priorityButton(_ option: LoopPriority) -> some View {
        let isSelected = priority == option
        let color = priorityColor(option)
        let selectedText = option == .p2 ? theme.primaryAccentText : Color.black

        return Button {
            priority = option
        } label: {
            HStack(spacing: 6) {
                Text(option.rawValue)
                    .font(theme.interfaceFont(.tertiary, weight: .bold))
                Text(option.title)
                    .font(theme.interfaceFont(.tertiary, weight: .semibold))
            }
            .foregroundStyle(isSelected ? selectedText : color)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(
                isSelected ? color : color.opacity(0.12),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(color.opacity(isSelected ? 0.95 : 0.28), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(StatusTabButtonStyle())
        .focused($focusedPriority, equals: option)
        .help("\(option.rawValue) · \(option.title)")
        .accessibilityLabel("\(option.rawValue), \(option.title) priority")
        .accessibilityIdentifier("movePlanning.priority.\(option.rawValue.lowercased())")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var displayedErrorMessage: String? {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDetails = details.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanTitle.isEmpty { return "Add a title before saving." }
        if cleanTitle.unicodeScalars.count > 500 { return "Keep the title under 500 characters." }
        if cleanDetails.unicodeScalars.count > 20_000 {
            return "Keep the description under 20,000 characters."
        }
        return errorMessage
    }

    private func priorityColor(_ value: LoopPriority) -> Color {
        switch value {
        case .p0: return Color(nsColor: .systemRed)
        case .p1: return Color(nsColor: .systemOrange)
        case .p2: return accent
        case .p3: return secondaryText
        }
    }

}

private struct AccountSetupEditor: View {
    @Environment(\.founderTheme) private var theme
    @ObservedObject var account: FounderOfficeAccountController
    let accent: Color

    private var nameBinding: Binding<String> {
        Binding(
            get: { account.reviewedDisplayNameDraft },
            set: { account.reviewedDisplayNameDraft = $0 }
        )
    }

    var body: some View {
        Group {
            switch account.setupStage {
            case .reviewDisplayName:
                reviewName
            case .chooseWorkspace:
                chooseWorkspace
            case .none:
                EmptyView()
            }
        }
        .frame(width: 570)
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("account.setup")
    }

    private var reviewName: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What should Founder’s Office call you?")
                .font(theme.displayFont(.secondary))
                .foregroundStyle(Color.white.opacity(0.97))
            Text("Google or Apple may suggest a name. Review it before it is saved to your account; this Mac’s workspace stays unchanged until its next step is safe.")
                .font(theme.interfaceFont(.secondary, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.76))

            TextField("Your name", text: nameBinding)
                .textFieldStyle(.plain)
                .font(theme.interfaceFont(.secondary, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.96))
                .padding(.horizontal, 11)
                .frame(height: 38)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
                .onSubmit(account.confirmReviewedDisplayName)
                .accessibilityIdentifier("account.reviewedName")

            if let error = account.displayNameError {
                Text(error)
                    .font(theme.interfaceFont(.tertiary, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .accessibilityIdentifier("account.reviewedName.error")
            }

            HStack(spacing: 8) {
                Button("Cancel", action: account.cancelAccountSetup)
                    .buttonStyle(HeaderActionButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("account.setup.cancel")
                Spacer()
                Button("Continue", action: account.confirmReviewedDisplayName)
                    .buttonStyle(HeaderActionButtonStyle(isEmphasized: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(account.isSavingReviewedName)
                    .accessibilityIdentifier("account.reviewedName.confirm")
            }
        }
    }

    private var chooseWorkspace: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What happens to this Mac’s workspace?")
                .font(theme.displayFont(.secondary))
                .foregroundStyle(Color.white.opacity(0.97))
            Text("Signing in did not upload, replace, or merge anything.")
                .font(theme.interfaceFont(.secondary, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.78))

            VStack(spacing: 5) {
                ForEach(LocalWorkspaceAccountChoice.allCases, id: \.rawValue) { choice in
                    workspaceChoiceRow(choice)
                }
            }

            if let message = account.operationMessage {
                Text(message)
                    .font(theme.interfaceFont(.tertiary, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.74))
                    .accessibilityIdentifier("account.workspaceChoice.message")
            }

            HStack {
                Text("Nothing is uploaded or replaced until you choose.")
                    .font(theme.interfaceFont(.tertiary, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.68))
                Spacer(minLength: 6)
                Button("Cancel Sign-in", action: account.cancelAccountSetup)
                    .buttonStyle(HeaderActionButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("account.setup.cancel")
            }
        }
    }

    private func workspaceChoiceRow(_ choice: LocalWorkspaceAccountChoice) -> some View {
        let enabled = account.isWorkspaceChoiceEnabled(choice)
        return Button {
            account.chooseWorkspaceDisposition(choice)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(workspaceChoiceTitle(choice))
                        .font(theme.interfaceFont(.secondary, weight: .bold))
                        .foregroundStyle(Color.white.opacity(enabled ? 0.96 : 0.55))
                    Text(workspaceChoiceDetail(choice))
                        .font(theme.interfaceFont(.tertiary, weight: .medium))
                        .foregroundStyle(Color.white.opacity(enabled ? 0.72 : 0.45))
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(enabled ? "Choose" : "Not yet")
                    .font(theme.interfaceFont(.tertiary, weight: .bold))
                    .foregroundStyle(enabled ? accent : Color.white.opacity(0.45))
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 39)
            .background(Color.white.opacity(enabled ? 0.065 : 0.025), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(enabled ? accent.opacity(0.36) : Color.white.opacity(0.05), lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(StatusTabButtonStyle())
        .disabled(!enabled)
        .accessibilityIdentifier("account.workspaceChoice.\(choice.rawValue)")
    }

    private func workspaceChoiceTitle(_ choice: LocalWorkspaceAccountChoice) -> String {
        switch choice {
        case .keepLocalOnly: return "Keep this workspace local-only"
        case .claimAsNewWorkspace: return "Claim it as a new synced workspace"
        case .switchWorkspace: return "Switch to the account workspace"
        case .exportAndReplace: return "Export, then replace this workspace"
        }
    }

    private func workspaceChoiceDetail(_ choice: LocalWorkspaceAccountChoice) -> String {
        switch choice {
        case .keepLocalOnly: return "Stay signed in without sending this Mac’s data."
        case .claimAsNewWorkspace: return "Upload this Mac’s Moves to a new private workspace."
        case .switchWorkspace: return "Use the private workspace already linked to this account."
        case .exportAndReplace: return "Create a local export before replacing this workspace."
        }
    }
}

private struct SupportReportPreview: View {
    @Environment(\.founderTheme) private var theme
    let report: RedactedSupportReport
    let errorMessage: String?
    let accent: Color
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Redacted support file")
                    .font(theme.displayFont(.secondary))
                    .foregroundStyle(Color.white.opacity(0.96))
                Text("\(report.fields.count) fields. Scroll to review every value before saving.")
                    .font(theme.interfaceFont(.tertiary, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.74))
            }

            ScrollView(showsIndicators: true) {
                VStack(spacing: 0) {
                    ForEach(Array(report.fields.enumerated()), id: \.element.id) { index, field in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(field.key)
                                .font(theme.interfaceFont(.tertiary, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.72))
                                .frame(width: 190, alignment: .leading)
                                .textSelection(.enabled)
                            Text(field.value)
                                .font(theme.interfaceFont(.tertiary, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.95))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .padding(.horizontal, 9)
                        .frame(minHeight: 27)

                        if index < report.fields.count - 1 {
                            Divider().overlay(Color.white.opacity(0.07))
                        }
                    }
                }
            }
            .frame(height: 164)
            .background(
                Color.white.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
            )
            .accessibilityIdentifier("health.supportReport.fields")

            if let errorMessage {
                Text(errorMessage)
                    .font(theme.interfaceFont(.tertiary, weight: .semibold))
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .accessibilityIdentifier("health.supportReport.error")
            }

            HStack(spacing: 8) {
                Text("No Moves, events, names, paths, prompts, or credentials.")
                    .font(theme.interfaceFont(.tertiary, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.72))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button("Cancel", action: onCancel)
                    .buttonStyle(HeaderActionButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("health.supportReport.cancel")
                Button("Save JSON…", action: onSave)
                    .buttonStyle(HeaderActionButtonStyle(isEmphasized: true))
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("health.supportReport.save")
            }
        }
        .frame(width: 570)
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Redacted support file preview")
        .accessibilityAddTraits(.isModal)
    }
}

private struct UnsavedAppearanceEditor: View {
    @Environment(\.founderTheme) private var theme
    let accent: Color
    let onKeepEditing: () -> Void
    let onDiscard: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "paintpalette.fill")
                .font(theme.symbolFont(size: 19, weight: .semibold))
                .foregroundStyle(accent)

            Text("Save your appearance?")
                .font(theme.displayFont(.secondary))
                .foregroundStyle(Color.white.opacity(0.96))

            Text("Your preview is only on this Mac until you save it.")
                .font(theme.interfaceFont(.tertiary, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.74))

            HStack(spacing: 8) {
                Button("Keep Editing", action: onKeepEditing)
                    .buttonStyle(HeaderActionButtonStyle())
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("appearance.unsaved.keepEditing")
                Spacer()
                Button("Discard", action: onDiscard)
                    .buttonStyle(HeaderActionButtonStyle())
                    .accessibilityIdentifier("appearance.unsaved.discard")
                Button("Save Changes", action: onSave)
                    .buttonStyle(HeaderActionButtonStyle(isEmphasized: true))
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("appearance.unsaved.save")
            }
        }
        .frame(width: 360)
        .preferredColorScheme(.dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Unsaved appearance changes")
        .accessibilityIdentifier("appearance.unsaved.editor")
        .accessibilityAddTraits(.isModal)
    }
}

#if !FOUNDER_OFFICE_DISTRIBUTION
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
#endif

private struct AppleNavigationButton: View {
    @Environment(\.founderTheme) private var theme
    let icon: AppIconName
    let isSelected: Bool
    let accent: Color
    var secondaryAccent: Color? = nil
    let label: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon.systemName)
                .symbolRenderingMode(.monochrome)
                .font(theme.symbolFont(size: 13, weight: .semibold))
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
    @Environment(\.isEnabled) private var isEnabled
    var isEmphasized = false

    private func resolvedColors(isPressed: Bool) -> (foreground: Color, background: Color, stroke: Color) {
        if isEmphasized && isEnabled {
            return (
                theme.primaryAccentText,
                theme.primaryAccent,
                theme.primaryAccent.opacity(0.58)
            )
        } else if isEmphasized {
            return (
                Color.white.opacity(0.58),
                Color.white.opacity(0.07),
                Color.white.opacity(0.10)
            )
        }

        return (
            Color.white.opacity(isEnabled ? (isPressed ? 0.92 : 0.68) : 0.34),
            Color.white.opacity(isEnabled ? (isPressed ? 0.10 : 0.055) : 0.028),
            Color.white.opacity(isEnabled ? (isPressed ? 0.14 : 0.08) : 0.04)
        )
    }

    func makeBody(configuration: Configuration) -> some View {
        let colors = resolvedColors(isPressed: configuration.isPressed)

        configuration.label
            .font(theme.interfaceFont(.secondary, weight: .semibold))
            .foregroundStyle(colors.foreground)
            .padding(.horizontal, 13)
            .frame(height: 34)
            .background(
                colors.background,
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(colors.stroke, lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed && isEnabled ? 0.97 : 1)
            .animation(.easeOut(duration: 0.11), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.14), value: isEnabled)
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
            .font(theme.interfaceFont(.tertiary, weight: .semibold))
            .foregroundStyle(theme.readableAccentOnPanel.opacity(configuration.isPressed ? 0.72 : 1))
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
            .font(theme.interfaceFont(.tertiary, weight: .semibold))
            .foregroundStyle(Color.white.opacity(configuration.isPressed ? 0.94 : 0.6))
            .frame(width: 28, height: 28)
            .background(Color.white.opacity(configuration.isPressed ? 0.11 : 0.055), in: Circle())
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.11), value: configuration.isPressed)
    }
}
