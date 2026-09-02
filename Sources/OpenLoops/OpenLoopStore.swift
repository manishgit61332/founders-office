import AppKit
import Combine
import Foundation
import FounderOfficeCore

enum PlanningPriorityChange {
    case unchanged
    case set(LoopPriority)
}

enum PlanningDeadlineChange {
    case unchanged
    case set(Date)
    case clear
}

enum PlanningUpdateResult {
    case saved
    case unchanged
    case failed(String)
}

@MainActor
final class OpenLoopStore: ObservableObject {
    @Published private(set) var items: [OpenLoop]
    @Published private(set) var lastSavedAt: Date?
    @Published private(set) var syncMessage = "Loaded"
    @Published private(set) var recentlyDeleted: OpenLoop?
    @Published private(set) var recoveryState: WorkspaceRecoveryState = .ready

    let session: WorkspaceSession
    let rootURL: URL

    var jsonURL: URL {
        (session.projectionURL ?? session.projectionsRootURL)
            .appendingPathComponent("openloops.json")
    }

    var contextURL: URL {
        (session.projectionURL ?? session.projectionsRootURL)
            .appendingPathComponent("OPEN_LOOPS_CONTEXT.md")
    }

    private struct PendingWrite {
        var document: OpenLoopsDocument
        var entityKind: String
        var entityID: String
        var changedFields: [String]
        var fieldClocks: [String: Date]
        var completion: ((Result<Void, Error>) -> Void)?
    }

    private var writes: [PendingWrite] = []
    private var isWriting = false
    private var lastWriteSucceeded = true
    private var cancellable: AnyCancellable?

    init(session: WorkspaceSession) {
        self.session = session
        rootURL = session.rootURL
        let document = session.snapshot.content.openLoops
        items = document.items
        lastSavedAt = document.updatedAt

        cancellable = session.$snapshot
            .dropFirst()
            .sink { [weak self] snapshot in
                guard let self, self.writes.isEmpty, !self.isWriting else { return }
                self.apply(snapshot.content.openLoops)
            }

        #if !FOUNDER_OFFICE_DISTRIBUTION
        applyPreviewOverrides()
        #endif
    }

    func stop() {
        for write in writes {
            write.completion?(.failure(CancellationError()))
        }
        writes.removeAll()
        cancellable?.cancel()
        cancellable = nil
    }

    var hasPendingWrites: Bool { isWriting || !writes.isEmpty }
    var hasUnresolvedWriteFailure: Bool { !lastWriteSucceeded }

    func waitForPendingWrites() async -> Bool {
        for _ in 0..<500 where hasPendingWrites {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return !hasPendingWrites && lastWriteSucceeded
    }

    var activeCount: Int {
        items.filter { $0.deletedAt == nil && $0.status != .done }.count
    }

    func items(in status: LoopStatus) -> [OpenLoop] {
        items
            .filter { $0.deletedAt == nil && $0.status == status }
            .sorted(by: OpenLoopRules.precedes)
    }

    func count(in status: LoopStatus) -> Int {
        items.filter { $0.deletedAt == nil && $0.status == status }.count
    }

    func toggleCompletion(_ item: OpenLoop) {
        guard canEdit, let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let now = Date()
        items[index] = OpenLoopRules.toggledCompletion(items[index], at: now)
        enqueueCurrentDocument(
            entityKind: "move",
            entityID: item.id.uuidString.lowercased(),
            changedFields: ["status", "previousStatus", "completedAt", "updatedAt"],
            at: now
        )
    }

    func move(_ item: OpenLoop, to status: LoopStatus) {
        guard canEdit, let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let now = Date()
        items[index] = OpenLoopRules.moved(items[index], to: status, at: now)
        enqueueCurrentDocument(
            entityKind: "move",
            entityID: item.id.uuidString.lowercased(),
            changedFields: ["status", "previousStatus", "completedAt", "updatedAt"],
            at: now
        )
    }

    func updatePlanning(
        id: UUID,
        priorityChange: PlanningPriorityChange,
        deadlineChange: PlanningDeadlineChange
    ) async -> PlanningUpdateResult {
        guard canEdit else { return .failed(recoveryState.message) }
        guard let index = items.firstIndex(where: { $0.id == id && $0.deletedAt == nil }) else {
            return .failed("This task is no longer available.")
        }

        let current = items[index]
        let resolvedPriority: LoopPriority
        switch priorityChange {
        case .unchanged: resolvedPriority = current.priority
        case let .set(priority): resolvedPriority = priority
        }

        let currentPlanningDay = current.dueAt.map(PlanningDate.day(fromStored:))
        let resolvedDueAt: Date?
        switch deadlineChange {
        case .unchanged:
            resolvedDueAt = current.dueAt
        case let .set(date):
            let selectedDay = PlanningDate.day(fromLocal: date)
            resolvedDueAt = currentPlanningDay == selectedDay
                ? current.dueAt
                : PlanningDate.storedDate(for: selectedDay)
        case .clear:
            resolvedDueAt = nil
        }

        guard current.priority != resolvedPriority || current.dueAt != resolvedDueAt else {
            return .unchanged
        }

        let now = Date()
        items[index] = OpenLoopRules.updatedPlanning(
            current,
            priority: resolvedPriority,
            dueAt: resolvedDueAt,
            at: now
        )
        let changedFields = [
            current.priority == resolvedPriority ? nil : "priority",
            current.priority == resolvedPriority ? nil : "priorityUpdatedAt",
            current.dueAt == resolvedDueAt ? nil : "dueAt",
            current.dueAt == resolvedDueAt ? nil : "dueAtUpdatedAt",
            "updatedAt"
        ].compactMap { $0 }

        let result = await persistCurrentDocument(
            entityKind: "move",
            entityID: id.uuidString.lowercased(),
            changedFields: changedFields,
            at: now
        )
        switch result {
        case .success:
            lastWriteSucceeded = true
            return .saved
        case .failure:
            return .failed("Couldn’t save those changes. Check the workspace and try again.")
        }
    }

    func updateContentAndPlanning(
        id: UUID,
        title: String,
        details: String,
        priorityChange: PlanningPriorityChange,
        deadlineChange: PlanningDeadlineChange
    ) async -> PlanningUpdateResult {
        guard canEdit else { return .failed(recoveryState.message) }
        guard let index = items.firstIndex(where: { $0.id == id && $0.deletedAt == nil }) else {
            return .failed("This Move is no longer available.")
        }

        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDetails = details.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return .failed("Add a title before saving.") }
        guard cleanTitle.unicodeScalars.count <= 500 else {
            return .failed("Keep the title under 500 characters.")
        }
        guard cleanDetails.unicodeScalars.count <= 20_000 else {
            return .failed("Keep the description under 20,000 characters.")
        }

        let current = items[index]
        let resolvedPriority: LoopPriority
        switch priorityChange {
        case .unchanged: resolvedPriority = current.priority
        case let .set(priority): resolvedPriority = priority
        }

        let currentPlanningDay = current.dueAt.map(PlanningDate.day(fromStored:))
        let resolvedDueAt: Date?
        switch deadlineChange {
        case .unchanged:
            resolvedDueAt = current.dueAt
        case let .set(date):
            let selectedDay = PlanningDate.day(fromLocal: date)
            resolvedDueAt = currentPlanningDay == selectedDay
                ? current.dueAt
                : PlanningDate.storedDate(for: selectedDay)
        case .clear:
            resolvedDueAt = nil
        }

        let contentChanged = current.title != cleanTitle || current.details != cleanDetails
        let priorityChanged = current.priority != resolvedPriority
        let deadlineChanged = current.dueAt != resolvedDueAt
        guard contentChanged || priorityChanged || deadlineChanged else { return .unchanged }

        let now = Date()
        var updated = OpenLoopRules.updatedPlanning(
            current,
            priority: resolvedPriority,
            dueAt: resolvedDueAt,
            at: now
        )
        updated = OpenLoopRules.updatedContent(
            updated,
            title: cleanTitle,
            details: cleanDetails,
            at: now
        )
        items[index] = updated

        var changedFields: [String] = []
        if current.title != cleanTitle { changedFields.append("title") }
        if current.details != cleanDetails { changedFields.append("details") }
        if priorityChanged { changedFields.append(contentsOf: ["priority", "priorityUpdatedAt"]) }
        if deadlineChanged { changedFields.append(contentsOf: ["dueAt", "dueAtUpdatedAt"]) }
        if contentChanged { changedFields.append("updatedAt") }

        let result = await persistCurrentDocument(
            entityKind: "move",
            entityID: id.uuidString.lowercased(),
            changedFields: changedFields,
            at: now
        )
        switch result {
        case .success:
            lastWriteSucceeded = true
            return .saved
        case .failure:
            return .failed("Couldn’t save those changes. Check the workspace and try again.")
        }
    }

    func add(
        title: String,
        details: String = "",
        status: LoopStatus,
        priority: LoopPriority,
        dueAt: Date?
    ) {
        guard canEdit else { return }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return }
        let now = Date()
        let id = UUID()
        items.append(
            OpenLoop(
                id: id,
                title: cleanTitle,
                details: details.trimmingCharacters(in: .whitespacesAndNewlines),
                status: status,
                previousStatus: nil,
                priority: priority,
                dueAt: dueAt,
                createdAt: now,
                updatedAt: now,
                completedAt: nil,
                deletedAt: nil,
                source: "notch-widget",
                priorityUpdatedAt: now,
                dueAtUpdatedAt: now
            )
        )
        enqueueCurrentDocument(
            entityKind: "move",
            entityID: id.uuidString.lowercased(),
            changedFields: ["title", "details", "status", "priority", "dueAt", "createdAt", "updatedAt"],
            at: now
        )
    }

    func delete(_ item: OpenLoop) {
        guard canEdit,
              let index = items.firstIndex(where: { $0.id == item.id && $0.deletedAt == nil }) else { return }
        let now = Date()
        items[index] = OpenLoopRules.softDeleted(items[index], at: now)
        recentlyDeleted = items[index]
        enqueueCurrentDocument(
            entityKind: "move",
            entityID: item.id.uuidString.lowercased(),
            changedFields: ["deletedAt", "updatedAt"],
            at: now
        )
    }

    func undoLastDelete() {
        guard canEdit,
              let deleted = recentlyDeleted,
              let index = items.firstIndex(where: { $0.id == deleted.id }) else { return }
        let now = Date()
        items[index] = OpenLoopRules.restored(items[index], at: now)
        recentlyDeleted = nil
        enqueueCurrentDocument(
            entityKind: "move",
            entityID: deleted.id.uuidString.lowercased(),
            changedFields: ["deletedAt", "updatedAt"],
            at: now
        )
    }

    func reload() {
        Task { [weak self] in
            guard let self else { return }
            _ = await session.refresh()
            guard writes.isEmpty, !isWriting else { return }
            apply(session.snapshot.content.openLoops)
        }
    }

    func openContextFile() {
        Task { [weak self] in
            guard let self, await session.refreshProjectionNow() else { return }
            NSWorkspace.shared.open(contextURL)
        }
    }

    func revealDataFolder() {
        NSWorkspace.shared.activateFileViewerSelecting([session.databaseURL])
    }

    private func enqueueCurrentDocument(
        entityKind: String,
        entityID: String,
        changedFields: [String],
        at date: Date
    ) {
        let document = OpenLoopsDocument(schemaVersion: 3, updatedAt: date, items: items)
        enqueue(
            PendingWrite(
                document: document,
                entityKind: entityKind,
                entityID: entityID,
                changedFields: changedFields,
                fieldClocks: Dictionary(uniqueKeysWithValues: changedFields.map { ($0, date) }),
                completion: nil
            )
        )
    }

    private func persistCurrentDocument(
        entityKind: String,
        entityID: String,
        changedFields: [String],
        at date: Date
    ) async -> Result<Void, Error> {
        let document = OpenLoopsDocument(schemaVersion: 3, updatedAt: date, items: items)
        return await withCheckedContinuation { continuation in
            enqueue(
                PendingWrite(
                    document: document,
                    entityKind: entityKind,
                    entityID: entityID,
                    changedFields: changedFields,
                    fieldClocks: Dictionary(uniqueKeysWithValues: changedFields.map { ($0, date) }),
                    completion: { continuation.resume(returning: $0) }
                )
            )
        }
    }

    private func enqueue(_ write: PendingWrite) {
        writes.append(write)
        processNextWriteIfNeeded()
    }

    private func processNextWriteIfNeeded() {
        guard !isWriting, let write = writes.first else { return }
        isWriting = true
        syncMessage = "Saving…"

        Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await session.commit(
                    WorkspacePatchMutation(
                        entityKind: write.entityKind,
                        entityID: write.entityID,
                        changedFields: write.changedFields,
                        fieldClocks: write.fieldClocks,
                        patch: .openLoops(write.document),
                        createdAt: write.document.updatedAt
                    )
                )
                finish(write: write, result: .success(()), snapshot: result.snapshot)
            } catch {
                finish(write: write, result: .failure(error), snapshot: session.snapshot)
            }
        }
    }

    private func finish(
        write: PendingWrite,
        result: Result<Void, Error>,
        snapshot: WorkspaceRepositorySnapshot
    ) {
        if !writes.isEmpty { writes.removeFirst() }
        isWriting = false

        switch result {
        case .success:
            lastWriteSucceeded = true
            lastSavedAt = snapshot.content.openLoops.updatedAt
            syncMessage = "Saved"
            write.completion?(.success(()))
        case let .failure(error):
            lastWriteSucceeded = false
            let abandoned = writes
            writes.removeAll()
            apply(snapshot.content.openLoops)
            syncMessage = "Save failed"
            write.completion?(.failure(error))
            for pending in abandoned {
                pending.completion?(.failure(error))
            }
            AppDiagnostics.failure(.moveStoreSave, category: .storage, error: error)
        }

        if writes.isEmpty {
            apply(session.snapshot.content.openLoops)
        }
        processNextWriteIfNeeded()
    }

    private func apply(_ document: OpenLoopsDocument) {
        items = document.items
        lastSavedAt = document.updatedAt
        recoveryState = .ready
    }

    private var canEdit: Bool {
        guard !recoveryState.requiresRecovery else {
            syncMessage = recoveryState.message
            return false
        }
        return true
    }

    #if !FOUNDER_OFFICE_DISTRIBUTION
    private func applyPreviewOverrides() {
        if ProcessInfo.processInfo.environment["OPENLOOPS_UI_TEST_LONG_PRIORITY_FIXTURE"] == "1",
           items.isEmpty {
            let now = Date()
            let criticalMoves = (0..<14).map { index in
                let timestamp = now.addingTimeInterval(-Double(index))
                return OpenLoop(
                    id: UUID(
                        uuidString: String(
                            format: "aaaaaaaa-bbbb-cccc-dddd-%012x",
                            index + 1
                        )
                    )!,
                    title: "Priority drag fixture \(index + 1)",
                    details: "Synthetic overflowing priority lane",
                    status: .doing,
                    previousStatus: nil,
                    priority: .p0,
                    dueAt: nil,
                    createdAt: timestamp,
                    updatedAt: timestamp,
                    completedAt: nil,
                    deletedAt: nil,
                    source: "ui-test",
                    priorityUpdatedAt: timestamp,
                    dueAtUpdatedAt: timestamp
                )
            }
            let lowerLaneMoves = LoopPriority.allCases.dropFirst().enumerated().map { index, priority in
                let timestamp = now.addingTimeInterval(-Double(100 + index))
                return OpenLoop(
                    id: UUID(
                        uuidString: String(
                            format: "eeeeeeee-ffff-cccc-dddd-%012x",
                            index + 1
                        )
                    )!,
                    title: "\(priority.title) lane anchor",
                    details: "Synthetic drop destination",
                    status: .doing,
                    previousStatus: nil,
                    priority: priority,
                    dueAt: nil,
                    createdAt: timestamp,
                    updatedAt: timestamp,
                    completedAt: nil,
                    deletedAt: nil,
                    source: "ui-test",
                    priorityUpdatedAt: timestamp,
                    dueAtUpdatedAt: timestamp
                )
            }
            items = criticalMoves + lowerLaneMoves
            // Keep synthetic setup in memory. The production drag mutation
            // persists the complete document in one real repository commit, so
            // the gate measures that commit instead of a queue of fixture writes.
        }

        if ProcessInfo.processInfo.environment["OPENLOOPS_UI_TEST_FIXTURE"] == "1",
           items.isEmpty {
            let now = Date()
            items = [
                OpenLoop(
                    id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                    title: "Prepare launch brief",
                    details: "Synthetic UI test fixture",
                    status: .doing,
                    previousStatus: nil,
                    priority: .p1,
                    dueAt: nil,
                    createdAt: now,
                    updatedAt: now,
                    completedAt: nil,
                    deletedAt: nil,
                    source: "ui-test",
                    priorityUpdatedAt: now,
                    dueAtUpdatedAt: now
                )
            ]
            enqueueCurrentDocument(
                entityKind: "move",
                entityID: items[0].id.uuidString.lowercased(),
                changedFields: [
                    "title", "details", "status", "priority", "dueAt", "createdAt", "updatedAt"
                ],
                at: now
            )
        }

        guard let rawID = ProcessInfo.processInfo.environment["OPENLOOPS_PREVIEW_DELETED_ID"],
              let id = UUID(uuidString: rawID),
              let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].deletedAt = Date()
        recentlyDeleted = items[index]
    }
    #endif
}

enum WorkspaceLocator {
    static var openLoopsRoot: URL {
        #if !FOUNDER_OFFICE_DISTRIBUTION
        if let override = ProcessInfo.processInfo.environment["OPENLOOPS_ROOT"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }

        if let configured = Bundle.main.object(forInfoDictionaryKey: "OpenLoopsWorkspace") as? String,
           !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        #endif

        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        return applicationSupport.appendingPathComponent("FoundersOffice", isDirectory: true)
    }
}
