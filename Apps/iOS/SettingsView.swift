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

    private var accent: Binding<AccentPalette> {
        Binding(
            get: { model.personalization.accent },
            set: model.updateAccent
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
                Picker("Accent", selection: accent) {
                    ForEach(AccentPalette.allCases) { palette in
                        Text(palette.title).tag(palette)
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
                LabeledContent("Workspace", value: model.cloudStatus.title)
                Button("Sync now") {
                    model.syncCloudNow()
                }
                Button("Check iCloud again") {
                    cloudAccount.refresh()
                }

                if model.cloudStatus == .accountReviewRequired {
                    Button("Keep this workspace and sync") {
                        model.resumeCloudAfterAccountReview(uploadLocalWorkspace: true)
                    }
                    Button("Use the workspace from iCloud") {
                        model.resumeCloudAfterAccountReview(uploadLocalWorkspace: false)
                    }
                }
            }
        }
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
