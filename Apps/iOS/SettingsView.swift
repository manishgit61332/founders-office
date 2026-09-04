import FounderOfficeCore
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var calendar: CalendarProvider
    @EnvironmentObject private var account: IOSAccountController

    @State private var workspaceNameDraft = ""
    @State private var isPresentingPrimaryGoal = false

    private var appearance: AppearancePreferences { model.personalization.resolvedAppearance }
    private var isRecoveryRequired: Bool { model.recoveryMessage != nil }

    private var accentMode: Binding<AccentMode> {
        Binding(
            get: { model.personalization.resolvedAppearance.accent.mode },
            set: model.updateAccentMode
        )
    }

    private var accentAngle: Binding<Double> {
        Binding(
            get: { model.personalization.resolvedAppearance.accent.angleDegrees },
            set: model.updateAccentAngle
        )
    }

    private func accentColor(stopIndex: Int) -> Binding<Color> {
        Binding(
            get: {
                let stops = model.personalization.resolvedAppearance.accent.normalizedStops
                return stops[min(stopIndex, stops.count - 1)].color.swiftUIColor
            },
            set: { color in
                guard let rgb = RGB24Color(swiftUIColor: color) else { return }
                model.updateAccentColor(rgb, stopIndex: stopIndex)
            }
        )
    }

    var body: some View {
        Form {
            Section("Profile") {
                TextField("Workspace name", text: $workspaceNameDraft)

                Button("Save workspace name") {
                    model.updateWorkspaceName(workspaceNameDraft)
                }

                if let image = model.visionImage {
                    HStack {
                        Label("Vision image", systemImage: "photo")
                        Spacer()
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 44, height: 44)
                            .clipShape(.rect(cornerRadius: 10))
                    }
                }

                Label(
                    "Vision images stay on this iPhone for now. Existing images are preserved and block workspace claim until private export and erasure are verified.",
                    systemImage: "lock.fill"
                )
                .font(appearance.interfaceFont(.secondary))
                .foregroundStyle(.secondary)
            }

            Section("Appearance") {
                Picker("Starting style", selection: Binding(
                    get: { model.personalization.resolvedAppearance.presetID },
                    set: model.applyAppearancePreset
                )) {
                    ForEach(AppearancePresetID.builtIns, id: \.rawValue) { preset in
                        Text(preset.title).tag(preset)
                    }
                    if model.personalization.resolvedAppearance.presetID == .custom {
                        Text("Custom").tag(AppearancePresetID.custom)
                    }
                }

                Picker("Accent", selection: accentMode) {
                    ForEach(AccentMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                ColorPicker("First colour", selection: accentColor(stopIndex: 0), supportsOpacity: false)
                if model.personalization.resolvedAppearance.accent.mode == .gradient {
                    ColorPicker("Second colour", selection: accentColor(stopIndex: 1), supportsOpacity: false)
                    LabeledContent("Direction") {
                        Slider(value: accentAngle, in: 0...359, step: 1)
                    }
                }

                Picker("Display font", selection: Binding(
                    get: { model.personalization.resolvedAppearance.displayFontID },
                    set: model.updateDisplayFont
                )) {
                    ForEach(FontChoiceID.builtIns, id: \.rawValue) { font in
                        Text(font.title).tag(font)
                    }
                }

                Picker("Interface font", selection: Binding(
                    get: { model.personalization.resolvedAppearance.interfaceFontID },
                    set: model.updateInterfaceFont
                )) {
                    ForEach(FontChoiceID.builtIns, id: \.rawValue) { font in
                        Text(font.title).tag(font)
                    }
                }

                Picker("Move cards", selection: Binding(
                    get: { model.personalization.resolvedAppearance.nodeStyleID },
                    set: model.updateNodeStyle
                )) {
                    ForEach(NodeStyleID.builtIns, id: \.rawValue) { style in
                        Text(style.title).tag(style)
                    }
                }

                Picker("Surface", selection: Binding(
                    get: { model.personalization.resolvedAppearance.surfaceStyleID },
                    set: model.updateSurfaceStyle
                )) {
                    ForEach(SurfaceStyleID.builtIns, id: \.rawValue) { surface in
                        Text(surface.title).tag(surface)
                    }
                }
            }

            Section("Primary goal") {
                NavigationLink {
                    PrimaryGoalEditor(goal: model.activePrimaryGoal)
                } label: {
                    Label(
                        model.activePrimaryGoal?.title ?? "Set a primary goal",
                        systemImage: "scope"
                    )
                }
            }

            AccountAndSyncSection(account: account, isRecoveryRequired: isRecoveryRequired)

            Section("Connections") {
                Label(
                    "Calendar access is local to this iPhone. Product sign-in is never reused as a calendar or tool grant.",
                    systemImage: "link.badge.plus"
                )
                .font(appearance.interfaceFont(.secondary))
                .foregroundStyle(.secondary)

                Button(calendar.connectionTitle) {
                    calendar.connectOrOpenSettings()
                }
            }
        }
        .founderSurface(appearance)
        .navigationTitle("Settings")
        .onAppear {
            workspaceNameDraft = model.personalization.resolvedWorkspaceName
            handleRoute(model.route)
        }
        .onChange(of: model.route) { _, route in handleRoute(route) }
        .sheet(isPresented: $isPresentingPrimaryGoal) {
            NavigationStack { PrimaryGoalEditor(goal: model.activePrimaryGoal) }
        }
    }

    private func handleRoute(_ route: IOSAppRoute?) {
        guard case .goal = route else { return }
        isPresentingPrimaryGoal = true
        model.consumeRoute()
    }
}

private struct AccountAndSyncSection: View {
    @ObservedObject var account: IOSAccountController

    let isRecoveryRequired: Bool

    var body: some View {
        Section("Account & Sync") {
            LabeledContent("Status", value: account.statusTitle)
            Text(account.statusDetail)
                .foregroundStyle(.secondary)

            if isRecoveryRequired {
                Label(
                    "Sync is paused until workspace recovery is complete.",
                    systemImage: "pause.circle.fill"
                )
                .foregroundStyle(.orange)
            }

            if account.availability == .available {
                accountActions
            }

            if case let .localOnly(message) = account.availability {
                Label(message, systemImage: "iphone")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var accountActions: some View {
        switch account.authState {
        case .localOnly, .failed:
            Button("Continue with Google") {
                account.signInWithGoogle()
            }
            .disabled(!account.isGoogleSignInAvailable || isRecoveryRequired)

            if account.isAppleSignInAvailable {
                Button("Continue with Apple") {
                    account.signInWithApple()
                }
                .disabled(isRecoveryRequired)
            } else {
                Text("Apple sign-in is retained for App Store parity and stays unavailable until this build is configured for it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

        case .restoring, .signingIn:
            ProgressView()

        case .signedIn:
            if account.setupStage == .reviewDisplayName {
                TextField("Name to use in this workspace", text: $account.reviewedDisplayNameDraft)
                    .textContentType(.name)
                if let error = account.displayNameError {
                    Text(error).foregroundStyle(.red)
                }
                Button("Save name and continue") {
                    account.saveReviewedDisplayName()
                }
                .disabled(account.isBusy || isRecoveryRequired)
            }

            if account.setupStage == .chooseWorkspace {
                Text("Sign-in does not upload local data. Choose one explicit action.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ForEach(account.availableWorkspaceChoices, id: \.rawValue) { choice in
                    Button(workspaceChoiceTitle(choice)) {
                        account.chooseWorkspace(choice)
                    }
                    .disabled(account.isBusy || isRecoveryRequired)
                }
            }

            if account.setupStage == .none {
                TextField("Account display name", text: $account.reviewedDisplayNameDraft)
                    .textContentType(.name)
                Button("Save account name") {
                    account.saveReviewedDisplayName()
                }
                .disabled(account.isBusy || isRecoveryRequired)
                Text("This updates your product account. A connected workspace keeps its reviewed bootstrap name.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button("Sync now") { account.syncNow() }
                    .disabled(account.isBusy || isRecoveryRequired)
                Button("Sign out on this iPhone", role: .destructive) {
                    account.signOut()
                }
                .disabled(account.isBusy)
            }

            ForEach(account.conflicts) { conflict in
                VStack(alignment: .leading, spacing: 8) {
                    Text("Review \(conflict.entityLabel.lowercased()) change")
                        .font(.headline)
                    Text("Overlapping fields: \(conflict.fields.joined(separator: ", ")).")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Keep my value") {
                        account.resolve(conflict, keepingLocalValue: true)
                    }
                    .disabled(account.isBusy)
                    Button("Use latest value") {
                        account.resolve(conflict, keepingLocalValue: false)
                    }
                    .disabled(account.isBusy)
                }
            }
        }
    }

    private func workspaceChoiceTitle(_ choice: LocalWorkspaceAccountChoice) -> String {
        switch choice {
        case .keepLocalOnly: return "Keep this iPhone local-only"
        case .claimAsNewWorkspace: return "Claim this local workspace"
        case .switchWorkspace: return "Use my existing workspace"
        case .exportAndReplace: return "Replace after export"
        }
    }
}

private struct PrimaryGoalEditor: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel

    private let existingID: UUID
    private let createdAt: Date

    @State private var title: String
    @State private var metric: String
    @State private var currentValue: String
    @State private var targetValue: String
    @State private var validationMessage: String?
    @State private var unit: GoalValueUnit
    @State private var dueAt: Date

    private var appearance: AppearancePreferences { model.personalization.resolvedAppearance }

    init(goal: PrimaryGoal?) {
        existingID = goal?.id ?? UUID()
        createdAt = goal?.createdAt ?? .now
        _title = State(initialValue: goal?.title ?? "")
        _metric = State(initialValue: goal?.metric ?? "")
        _currentValue = State(initialValue: goal?.currentValue?.canonicalString ?? "0")
        _targetValue = State(initialValue: goal?.targetValue?.canonicalString ?? "")
        _unit = State(initialValue: goal?.unit ?? .usd)
        _dueAt = State(
            initialValue: goal?.dueAt
                ?? Calendar.current.date(byAdding: .day, value: 60, to: .now)
                ?? .now
        )
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !targetValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Form {
            Section("Outcome") {
                TextField("Goal", text: $title)
                TextField("Metric", text: $metric)
                DatePicker("Target date", selection: $dueAt, displayedComponents: .date)
            }

            Section("Progress") {
                Picker("Unit", selection: $unit) {
                    ForEach(GoalValueUnit.allCases) { unit in
                        Text(unit.title).tag(unit)
                    }
                }
                TextField("Current", text: $currentValue)
                    .keyboardType(.decimalPad)
                TextField("Target", text: $targetValue)
                    .keyboardType(.decimalPad)
                if let validationMessage {
                    Text(validationMessage)
                        .foregroundStyle(.red)
                }
            }

            if model.activePrimaryGoal != nil {
                Section {
                    Button("Remove goal", role: .destructive) {
                        model.clearPrimaryGoal()
                        dismiss()
                    }
                }
            }
        }
        .founderSurface(appearance)
        .navigationTitle("Primary goal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    let parsedCurrent: GoalDecimal
                    let parsedTarget: GoalDecimal
                    do {
                        parsedCurrent = try GoalDecimal(userInput: currentValue)
                        parsedTarget = try GoalDecimal(userInput: targetValue)
                        guard parsedTarget > .zero else {
                            validationMessage = "Target must be greater than zero."
                            return
                        }
                    } catch let error as GoalDecimal.ValidationError {
                        switch error {
                        case .tooManyFractionDigits:
                            validationMessage = "Use no more than 8 decimal places."
                        case .outOfRange:
                            validationMessage = "That number is too large."
                        case .negative:
                            validationMessage = "Goal values cannot be negative."
                        default:
                            validationMessage = "Enter a valid number."
                        }
                        return
                    } catch {
                        validationMessage = "Enter a valid number."
                        return
                    }
                    model.setPrimaryGoal(
                        PrimaryGoal(
                            id: existingID,
                            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                            metric: metric.trimmingCharacters(in: .whitespacesAndNewlines),
                            currentValue: parsedCurrent,
                            targetValue: parsedTarget,
                            unit: unit,
                            dueAt: dueAt,
                            createdAt: createdAt,
                            updatedAt: .now
                        )
                    )
                    dismiss()
                } label: {
                    Image(systemName: "checkmark")
                }
                .founderProminentButton(appearance)
                .disabled(!canSave)
            }
        }
    }
}
