import FounderOfficeCore
import SwiftUI

struct LoopsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isPresentingNewTask = false

    var body: some View {
        List {
            Section {
                Button {
                    isPresentingNewTask = true
                } label: {
                    Label("New task", systemImage: "plus.circle.fill")
                        .font(.headline)
                }
            }

            ForEach(LoopStatus.allCases) { status in
                let items = model.visibleLoops.filter { $0.status == status }
                if !items.isEmpty {
                    Section(status.title) {
                        ForEach(items) { loop in
                            TaskRow(loop: loop)
                                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                    Button {
                                        model.toggleCompletion(loop)
                                    } label: {
                                        Label(
                                            loop.status == .done ? "Reopen" : "Complete",
                                            systemImage: loop.status == .done
                                                ? "arrow.uturn.backward"
                                                : "checkmark"
                                        )
                                    }
                                    .tint(loop.status == .done ? .orange : .green)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button(role: .destructive) {
                                        model.softDelete(loop)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                .contextMenu {
                                    Menu("Move to") {
                                        ForEach(LoopStatus.allCases) { destination in
                                            Button(destination.title) {
                                                model.move(loop, to: destination)
                                            }
                                            .disabled(loop.status == destination)
                                        }
                                    }
                                }
                        }
                    }
                }
            }
        }
        .overlay {
            if model.visibleLoops.isEmpty {
                ContentUnavailableView {
                    Label("No moves yet", systemImage: "checklist")
                } description: {
                    Text("Capture the one thing you do not want to carry in your head.")
                } actions: {
                    Button("New task") {
                        isPresentingNewTask = true
                    }
                    .buttonStyle(.borderedProminent)
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
}

private struct NewTaskView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel

    @State private var title = ""
    @State private var details = ""
    @State private var status: LoopStatus = .next
    @State private var priority: LoopPriority = .p1
    @State private var hasDueDate = false
    @State private var dueAt = Date()

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
                        Text(priority.rawValue).tag(priority)
                    }
                }

                Toggle("Due date", isOn: $hasDueDate)
                if hasDueDate {
                    DatePicker("Due", selection: $dueAt)
                }
            }
        }
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
                        dueAt: hasDueDate ? dueAt : nil
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
