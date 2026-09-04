import FounderOfficeCore
import SwiftUI
import UIKit

struct LoopsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.calendar) private var calendar
    @AppStorage("moves.groupingLens") private var groupingLensRawValue = MoveGroupingLens.priority.rawValue
    @State private var isPresentingNewTask = false
    @State private var planningSelection: TaskPlanningSelection?

    private var appearance: AppearancePreferences { model.personalization.resolvedAppearance }

    private var groupingLens: MoveGroupingLens {
        get { MoveGroupingLens(rawValue: groupingLensRawValue) ?? .priority }
        nonmutating set { groupingLensRawValue = newValue.rawValue }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let currentPresentation = MovePresentation(
                items: model.visibleLoops,
                now: context.date,
                calendar: calendar
            )

            List {
                Section {
                    VStack(spacing: 12) {
                        Picker(
                            "Group moves",
                            selection: Binding(
                                get: { groupingLens },
                                set: { groupingLens = $0 }
                            )
                        ) {
                            ForEach(MoveGroupingLens.allCases) { lens in
                                Text(lens.title).tag(lens)
                            }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityHint("Switches between priority lanes and deadline groups")

                        Button {
                            isPresentingNewTask = true
                        } label: {
                            Label("New task", systemImage: "plus.circle.fill")
                                .font(appearance.interfaceFont(.secondary, weight: .semibold))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                if groupingLens == .priority {
                    ForEach(LoopPriority.allCases) { priority in
                        PriorityMoveLane(
                            priority: priority,
                            items: currentPresentation.items(in: priority),
                            onEditPlanning: { planningSelection = .init(id: $0.id) },
                            onMove: { moveID in
                                move(moveID: moveID, to: priority)
                            }
                        )
                    }
                } else {
                    ForEach(currentPresentation.activeGroups) { group in
                        Section {
                            ForEach(group.items) { loop in
                                ActionableTaskRow(
                                    loop: loop,
                                    showsStatus: true,
                                    onEditPlanning: { planningSelection = .init(id: loop.id) }
                                )
                            }
                        } header: {
                            Label(group.bucket.title, systemImage: group.bucket.systemImage)
                                .font(appearance.interfaceFont(.secondary, weight: .bold))
                                .foregroundStyle(group.bucket.headerColor)
                                .textCase(nil)
                        }
                    }
                }

                recentCompletionSections(currentPresentation)

                if !currentPresentation.olderCompleted.isEmpty {
                    Section {
                        NavigationLink {
                            PreviousTasksView()
                        } label: {
                            HStack {
                                Label("Previous tasks", systemImage: "archivebox")
                                    .font(appearance.interfaceFont(.secondary, weight: .semibold))
                                Spacer()
                                Text(currentPresentation.olderCompleted.count, format: .number)
                                    .font(appearance.interfaceFont(.secondary, weight: .semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityLabel("Previous tasks")
                        .accessibilityValue("\(currentPresentation.olderCompleted.count) completed")
                        .accessibilityHint("Shows completed tasks from before yesterday")
                    }
                }
            }
            .founderSurface(appearance)
            .overlay {
                if currentPresentation.activeGroups.isEmpty && currentPresentation.allCompleted.isEmpty {
                    ContentUnavailableView {
                        Label("No moves yet", systemImage: "checklist")
                    } description: {
                        Text("Capture the one thing you do not want to carry in your head.")
                    } actions: {
                        Button("New task") {
                            isPresentingNewTask = true
                        }
                        .founderProminentButton(appearance)
                    }
                }
            }
            .navigationTitle("Moves")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isPresentingNewTask = true
                    } label: {
                        Label("New task", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $isPresentingNewTask) {
                NavigationStack {
                    NewTaskView()
                }
            }
        }
        .taskPlanningSheet(selection: $planningSelection)
    }

    private func move(moveID: UUID, to priority: LoopPriority) -> Bool {
        guard let loop = model.visibleLoops.first(where: {
            $0.id == moveID && $0.status != .done && $0.deletedAt == nil
        }) else { return false }
        guard loop.priority != priority else { return true }

        let result = model.updatePlanning(
            id: moveID,
            priority: priority,
            dueAt: nil,
            updatesPriority: true,
            updatesDeadline: false
        )
        if result != .failed {
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        }
        return result != .failed
    }

    @ViewBuilder
    private func recentCompletionSections(_ presentation: MovePresentation) -> some View {
        let completedToday = presentation.recentCompleted.filter { loop in
            loop.completedAt.map(calendar.isDateInToday) ?? false
        }
        let completedYesterday = presentation.recentCompleted.filter { loop in
            loop.completedAt.map(calendar.isDateInYesterday) ?? false
        }

        if !completedToday.isEmpty {
            completedSection(title: "Done today", items: completedToday)
        }

        if !completedYesterday.isEmpty {
            completedSection(title: "Done yesterday", items: completedYesterday)
        }
    }

    private func completedSection(title: String, items: [OpenLoop]) -> some View {
        Section {
            ForEach(items) { loop in
                ActionableTaskRow(
                    loop: loop,
                    onEditPlanning: { planningSelection = .init(id: loop.id) }
                )
            }
        } header: {
            Label(title, systemImage: "checkmark.circle.fill")
                .font(appearance.interfaceFont(.secondary, weight: .bold))
                .foregroundStyle(.primary)
                .textCase(nil)
        }
    }
}

private enum MoveGroupingLens: String, CaseIterable, Identifiable {
    case priority
    case deadline

    var id: String { rawValue }

    var title: String {
        switch self {
        case .priority: return "Priority"
        case .deadline: return "Due"
        }
    }
}

private struct PriorityMoveLane: View {
    @EnvironmentObject private var model: AppModel

    let priority: LoopPriority
    let items: [OpenLoop]
    let onEditPlanning: (OpenLoop) -> Void
    let onMove: (UUID) -> Bool

    private var appearance: AppearancePreferences { model.personalization.resolvedAppearance }

    var body: some View {
        Section {
            if items.isEmpty {
                HStack(spacing: 10) {
                    Capsule()
                        .fill(priority.laneColor)
                        .frame(width: 5, height: 28)
                    Text("Drop a move here")
                        .font(appearance.interfaceFont(.secondary, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6)
                .accessibilityLabel("Empty \(priority.customerTitle) priority lane")
            } else {
                ForEach(items) { loop in
                    ActionableTaskRow(
                        loop: loop,
                        showsStatus: true,
                        onEditPlanning: { onEditPlanning(loop) }
                    )
                    .draggable(loop.id.uuidString) {
                        MoveDragPreview(loop: loop)
                    }
                }
            }
        } header: {
            HStack(spacing: 8) {
                Capsule()
                    .fill(priority.laneColor)
                    .frame(width: 5, height: 18)
                    .accessibilityHidden(true)
                Text(priority.customerTitle)
                Text(items.count, format: .number)
                    .foregroundStyle(.secondary)
            }
            .font(appearance.interfaceFont(.secondary, weight: .bold))
            .foregroundStyle(.primary)
            .textCase(nil)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(priority.customerTitle) priority, \(items.count) moves")
        }
        .dropDestination(for: String.self) { payloads, _ in
            let moveIDs = payloads.compactMap(UUID.init(uuidString:))
            guard !moveIDs.isEmpty else { return false }
            return moveIDs.reduce(true) { result, moveID in
                onMove(moveID) && result
            }
        }
    }
}

private struct MoveDragPreview: View {
    @EnvironmentObject private var model: AppModel

    let loop: OpenLoop

    private var appearance: AppearancePreferences { model.personalization.resolvedAppearance }

    var body: some View {
        HStack(spacing: 10) {
            Capsule()
                .fill(loop.priority.laneColor)
                .frame(width: 5, height: 32)
            Text(loop.title)
                .font(appearance.interfaceFont(.secondary, weight: .semibold))
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

struct ActionableTaskRow: View {
    @EnvironmentObject private var model: AppModel
    @State private var isPresentingPriorityUpdateFailure = false

    let loop: OpenLoop
    var showsStatus = false
    let onEditPlanning: () -> Void

    private var completionActionTitle: String {
        loop.status == .done ? "Reopen" : "Complete"
    }

    private var completionActionSymbol: String {
        loop.status == .done ? "arrow.uturn.backward" : "checkmark"
    }

    var body: some View {
        Button {
            onEditPlanning()
        } label: {
            TaskRow(loop: loop, showsStatus: showsStatus)
        }
            .buttonStyle(.plain)
            .accessibilityHint("Edits priority and deadline")
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                Button {
                    model.toggleCompletion(loop)
                } label: {
                    Label(completionActionTitle, systemImage: completionActionSymbol)
                }
                .tint(loop.status == .done ? .orange : .green)
            }
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                Button {
                    onEditPlanning()
                } label: {
                    Label("Edit", systemImage: "slider.horizontal.3")
                }
                .tint(.blue)

                Button(role: .destructive) {
                    model.softDelete(loop)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            .contextMenu {
                Button {
                    onEditPlanning()
                } label: {
                    Label("Edit priority and deadline", systemImage: "slider.horizontal.3")
                }

                Menu("Move to") {
                    ForEach(LoopStatus.allCases) { destination in
                        Button(destination.title) {
                            model.move(loop, to: destination)
                        }
                        .disabled(loop.status == destination)
                    }
                }

                Menu("Priority") {
                    ForEach(LoopPriority.allCases) { priority in
                        Button {
                            setPriority(priority)
                        } label: {
                            Label(
                                priority.customerTitle,
                                systemImage: loop.priority == priority ? "checkmark" : "circle"
                            )
                        }
                        .disabled(loop.priority == priority || loop.status == .done)
                    }
                }
            }
            .accessibilityAction(named: Text(completionActionTitle)) {
                model.toggleCompletion(loop)
            }
            .accessibilityAction(named: Text("Delete")) {
                model.softDelete(loop)
            }
            .accessibilityAction(named: Text("Edit priority and deadline")) {
                onEditPlanning()
            }
            .accessibilityAction(named: Text("Raise priority")) {
                guard let previous = loop.priority.previousPriority else { return }
                setPriority(previous)
            }
            .accessibilityAction(named: Text("Lower priority")) {
                guard let next = loop.priority.nextPriority else { return }
                setPriority(next)
            }
            .alert("Couldn’t change priority", isPresented: $isPresentingPriorityUpdateFailure) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Nothing was changed. Check workspace recovery or storage, then try again.")
            }
    }

    private func setPriority(_ priority: LoopPriority) {
        guard loop.status != .done, loop.priority != priority else { return }
        let result = model.updatePlanning(
            id: loop.id,
            priority: priority,
            dueAt: nil,
            updatesPriority: true,
            updatesDeadline: false
        )
        if result == .failed {
            isPresentingPriorityUpdateFailure = true
        }
    }
}

struct TaskPlanningSelection: Identifiable {
    let id: UUID
}

extension View {
    func taskPlanningSheet(selection: Binding<TaskPlanningSelection?>) -> some View {
        sheet(item: selection) { selected in
            TaskPlanningSheetContent(taskID: selected.id)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }
}

private struct TaskPlanningSheetContent: View {
    @Environment(\.calendar) private var calendar
    @EnvironmentObject private var model: AppModel

    let taskID: UUID

    private var currentLoop: OpenLoop? {
        guard !model.recoveryState.requiresRecovery else { return nil }
        return model.openLoops.items.first {
            $0.id == taskID && $0.deletedAt == nil
        }
    }

    var body: some View {
        NavigationStack {
            if let currentLoop {
                EditTaskPlanningView(loop: currentLoop, calendar: calendar)
            } else {
                MissingTaskPlanningView()
            }
        }
    }
}

private struct MissingTaskPlanningView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel

    private var appearance: AppearancePreferences { model.personalization.resolvedAppearance }

    var body: some View {
        ContentUnavailableView {
            Label("Task unavailable", systemImage: "exclamationmark.triangle")
        } description: {
            Text("This task was removed or is waiting for workspace recovery.")
        } actions: {
            Button("Close") {
                dismiss()
            }
            .founderProminentButton(appearance)
        }
        .navigationTitle("Edit plan")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct EditTaskPlanningView: View {
    @Environment(\.calendar) private var calendar
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel

    let loopID: UUID
    let taskTitle: String

    @State private var initialPriority: LoopPriority
    @State private var initialDueAt: Date?
    @State private var priority: LoopPriority
    @State private var hasDueDate: Bool
    @State private var dueAt: Date
    @State private var saveResult: TaskPlanningSaveResult?

    private var appearance: AppearancePreferences { model.personalization.resolvedAppearance }

    init(loop: OpenLoop, calendar: Calendar) {
        loopID = loop.id
        taskTitle = loop.title
        _initialPriority = State(initialValue: loop.priority)
        _initialDueAt = State(initialValue: loop.dueAt)
        _priority = State(initialValue: loop.priority)
        _hasDueDate = State(initialValue: loop.dueAt != nil)
        _dueAt = State(
            initialValue: loop.dueAt.map {
                PlanningDate.localDate(fromStored: $0, calendar: calendar)
            } ?? Date()
        )
    }

    private var selectedDueAt: Date? {
        hasDueDate
            ? PlanningDate.storedDate(fromLocal: dueAt, calendar: calendar)
            : nil
    }

    private var updatesPriority: Bool {
        priority != initialPriority
    }

    private var updatesDeadline: Bool {
        let initialDay = initialDueAt.map(PlanningDate.day(fromStored:))
        let selectedDay = hasDueDate
            ? PlanningDate.day(fromLocal: dueAt, calendar: calendar)
            : nil
        return selectedDay != initialDay
    }

    private var saveResultTitle: String {
        switch saveResult {
        case .saved: return "Changes saved"
        case .unchanged: return "No changes"
        case .failed: return "Couldn’t save"
        case nil: return ""
        }
    }

    private var saveResultMessage: String {
        switch saveResult {
        case .saved:
            return "The latest task now has your priority and deadline changes."
        case .unchanged:
            return "The task already has these planning details."
        case .failed:
            return "Nothing was changed. Check workspace recovery or storage, then try again."
        case nil:
            return ""
        }
    }

    var body: some View {
        Form {
            Section {
                Text(taskTitle)
                    .font(appearance.interfaceFont(.secondary, weight: .semibold))
            }

            Section("Plan") {
                Picker("Priority", selection: $priority) {
                    ForEach(LoopPriority.allCases) { priority in
                        Text("\(priority.rawValue) · \(priority.title)").tag(priority)
                    }
                }
                .pickerStyle(.menu)

                Toggle("Deadline", isOn: $hasDueDate)

                if hasDueDate {
                    DatePicker(
                        "Due",
                        selection: $dueAt,
                        displayedComponents: .date
                    )
                    .datePickerStyle(.compact)

                    Button("Clear deadline", role: .destructive) {
                        hasDueDate = false
                    }
                }
            }
        }
        .founderSurface(appearance)
        .navigationTitle("Edit plan")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    dismiss()
                }
            }

            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    saveResult = model.updatePlanning(
                        id: loopID,
                        priority: priority,
                        dueAt: selectedDueAt,
                        updatesPriority: updatesPriority,
                        updatesDeadline: updatesDeadline
                    )
                }
                .fontWeight(.semibold)
                .disabled(!updatesPriority && !updatesDeadline)
            }
        }
        .alert(
            saveResultTitle,
            isPresented: Binding(
                get: { saveResult != nil },
                set: { if !$0 { saveResult = nil } }
            )
        ) {
            if saveResult == .failed {
                Button("OK") {
                    saveResult = nil
                }
            } else {
                Button("Done") {
                    saveResult = nil
                    dismiss()
                }
            }
        } message: {
            Text(saveResultMessage)
        }
    }
}

private struct PreviousTasksView: View {
    @Environment(\.calendar) private var calendar
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @State private var planningSelection: TaskPlanningSelection?

    private var appearance: AppearancePreferences { model.personalization.resolvedAppearance }

    private var previousTasks: [OpenLoop] {
        MovePresentation(items: model.visibleLoops, calendar: calendar).olderCompleted
    }

    var body: some View {
        List {
            ForEach(previousTasks) { loop in
                ActionableTaskRow(
                    loop: loop,
                    onEditPlanning: { planningSelection = .init(id: loop.id) }
                )
            }
        }
        .founderSurface(appearance)
        .overlay {
            if previousTasks.isEmpty {
                ContentUnavailableView {
                    Label("No previous tasks", systemImage: "archivebox")
                } description: {
                    Text("Completed tasks from today and yesterday stay on the main Moves screen.")
                } actions: {
                    Button("Back to Moves") {
                        dismiss()
                    }
                    .founderProminentButton(appearance)
                }
            }
        }
        .navigationTitle("Previous tasks")
        .taskPlanningSheet(selection: $planningSelection)
    }
}

private extension ActiveDeadlineBucket {
    var systemImage: String {
        switch self {
        case .overdue: return "exclamationmark.circle.fill"
        case .today: return "sun.max.fill"
        case .upcoming: return "calendar"
        case .noDeadline: return "tray"
        }
    }

    var headerColor: Color {
        switch self {
        case .overdue: return .red
        case .today: return .primary
        case .upcoming, .noDeadline: return .primary
        }
    }
}

private struct NewTaskView: View {
    @Environment(\.calendar) private var calendar
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel

    @State private var title = ""
    @State private var details = ""
    @State private var status: LoopStatus = .next
    @State private var priority: LoopPriority = .p1
    @State private var hasDueDate = false
    @State private var dueAt = Date()

    private var appearance: AppearancePreferences { model.personalization.resolvedAppearance }

    private var canSave: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Form {
            Section("Task") {
                TextField("What needs to happen?", text: $title)
                TextField("Useful context", text: $details, axis: .vertical)
                    .lineLimit(3...7)
            }

            Section("Plan") {
                Picker("Status", selection: $status) {
                    ForEach(LoopStatus.allCases.filter { $0 != .done }) { status in
                        Text(status.title).tag(status)
                    }
                }

                Picker("Priority", selection: $priority) {
                    ForEach(LoopPriority.allCases) { priority in
                        Text("\(priority.rawValue) · \(priority.title)").tag(priority)
                    }
                }

                Toggle("Due date", isOn: $hasDueDate)
                if hasDueDate {
                    DatePicker("Due", selection: $dueAt, displayedComponents: .date)
                }
            }
        }
        .founderSurface(appearance)
        .navigationTitle("New task")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
            }

            ToolbarItem(placement: .confirmationAction) {
                Button {
                    model.addLoop(
                        title: title,
                        details: details,
                        status: status,
                        priority: priority,
                        dueAt: hasDueDate
                            ? PlanningDate.storedDate(fromLocal: dueAt, calendar: calendar)
                            : nil
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
