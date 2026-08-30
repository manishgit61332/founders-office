import FounderOfficeCore
import PhotosUI
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var calendar: CalendarProvider
    @EnvironmentObject private var cloudAccount: CloudAccountMonitor

    @State private var selectedPhoto: PhotosPickerItem?
    @State private var preferredNameDraft = ""
    @State private var workspaceNameDraft = ""

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
                TextField("Your name", text: $preferredNameDraft)
                    .textContentType(.name)
                TextField("Workspace name", text: $workspaceNameDraft)

                Button("Save identity") {
                    model.updatePreferredName(preferredNameDraft)
                    model.updateWorkspaceName(workspaceNameDraft)
                }

                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    HStack {
                        Label("Choose vision image", systemImage: "photo")
                        Spacer()
                        if let image = model.visionImage {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 44, height: 44)
                                .clipShape(.rect(cornerRadius: 10))
                        }
                    }
                }
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

            Section("Calendar") {
                Button {
                    calendar.connectOrOpenSettings()
                } label: {
                    Label(calendar.connectionTitle, systemImage: "calendar")
                }

                if calendar.hasReadAccess {
                    LabeledContent("Accounts", value: "\(calendar.accounts.count)")
                }
            }

            Section("Cloud") {
                LabeledContent("Private iCloud", value: cloudAccount.state.title)
                LabeledContent(
                    "Workspace",
                    value: isRecoveryRequired ? "Recovery required" : model.cloudStatus.title
                )

                if isRecoveryRequired {
                    Label(
                        "Sync is paused until workspace recovery is complete.",
                        systemImage: "pause.circle.fill"
                    )
                    .foregroundStyle(.orange)
                    .accessibilityLabel(
                        "iCloud sync is paused until workspace recovery is complete."
                    )
                }

                Button("Sync now") {
                    model.syncCloudNow()
                }
                .disabled(isRecoveryRequired)
                .accessibilityHint(
                    isRecoveryRequired
                        ? "Unavailable while workspace recovery is required."
                        : "Syncs this workspace with iCloud."
                )

                Button("Check iCloud again") {
                    cloudAccount.refresh()
                }

                if model.cloudStatus == .accountReviewRequired {
                    Button("Keep this workspace and sync") {
                        model.resumeCloudAfterAccountReview(uploadLocalWorkspace: true)
                    }
                    .disabled(isRecoveryRequired)

                    Button("Use the workspace from iCloud") {
                        model.resumeCloudAfterAccountReview(uploadLocalWorkspace: false)
                    }
                    .disabled(isRecoveryRequired)
                }
            }
        }
        .founderSurface(appearance)
        .navigationTitle("Settings")
        .onAppear {
            preferredNameDraft = model.personalization.resolvedPreferredName ?? ""
            workspaceNameDraft = model.personalization.resolvedWorkspaceName
        }
        .onChange(of: selectedPhoto) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    model.saveVisionImage(data)
                }
            }
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
    @State private var currentValue: Double
    @State private var targetValue: Double
    @State private var unit: GoalValueUnit
    @State private var dueAt: Date

    private var appearance: AppearancePreferences { model.personalization.resolvedAppearance }

    init(goal: PrimaryGoal?) {
        existingID = goal?.id ?? UUID()
        createdAt = goal?.createdAt ?? .now
        _title = State(initialValue: goal?.title ?? "")
        _metric = State(initialValue: goal?.metric ?? "")
        _currentValue = State(initialValue: goal?.currentValue ?? 0)
        _targetValue = State(initialValue: goal?.targetValue ?? 0)
        _unit = State(initialValue: goal?.unit ?? .usd)
        _dueAt = State(
            initialValue: goal?.dueAt
                ?? Calendar.current.date(byAdding: .day, value: 60, to: .now)
                ?? .now
        )
    }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && targetValue > 0
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
                TextField("Current", value: $currentValue, format: .number)
                    .keyboardType(.decimalPad)
                TextField("Target", value: $targetValue, format: .number)
                    .keyboardType(.decimalPad)
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
                    model.setPrimaryGoal(
                        PrimaryGoal(
                            id: existingID,
                            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                            metric: metric.trimmingCharacters(in: .whitespacesAndNewlines),
                            currentValue: currentValue,
                            targetValue: targetValue,
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
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
            }
        }
    }
}
