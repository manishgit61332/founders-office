import Foundation
import FounderOfficeCore

@MainActor
final class WorkspaceSession: ObservableObject {
    static var freshSnapshot: FounderOfficeSnapshot {
        let now = Date()
        return FounderOfficeSnapshot(
            openLoops: OpenLoopsDocument(schemaVersion: 3, updatedAt: now, items: []),
            personalization: PersonalizationDocument(
                schemaVersion: 6,
                displayName: "Founder's Office",
                accent: .blue,
                iconStyle: .system,
                photoFileName: nil,
                primaryGoal: nil,
                milestones: [],
                updatedAt: now,
                preferredName: nil,
                workspaceName: "Founder's Office",
                appearance: .manish()
            )
        )
    }
    @Published private(set) var snapshot: WorkspaceRepositorySnapshot
    @Published private(set) var projectionURL: URL?
    @Published private(set) var lastErrorMessage: String?
    @Published private(set) var projectionRepairState: BoundedRepairCustomerState

    let repository: SQLiteWorkspaceRepository
    let rootURL: URL
    let databaseURL: URL
    let projectionsRootURL: URL
    let repairLedgerURL: URL

    private var changeTask: Task<Void, Never>?
    private var projectionTask: Task<Void, Never>?
    private let repairCoordinator: BoundedRepairCoordinator

    private init(
        rootURL: URL,
        databaseURL: URL,
        projectionsRootURL: URL,
        repairLedgerURL: URL,
        repository: SQLiteWorkspaceRepository,
        snapshot: WorkspaceRepositorySnapshot,
        projectionURL: URL?,
        projectionRepairState: BoundedRepairCustomerState,
        repairCoordinator: BoundedRepairCoordinator,
        eventStream: AsyncStream<WorkspaceRepositoryEvent>
    ) {
        self.rootURL = rootURL
        self.databaseURL = databaseURL
        self.projectionsRootURL = projectionsRootURL
        self.repairLedgerURL = repairLedgerURL
        self.repository = repository
        self.snapshot = snapshot
        self.projectionURL = projectionURL
        self.projectionRepairState = projectionRepairState
        self.repairCoordinator = repairCoordinator
        observeRepositoryChanges(eventStream)
    }

    static func open(
        rootURL: URL,
        workspaceID: UUID,
        initialSnapshot: FounderOfficeSnapshot
    ) async throws -> WorkspaceSession {
        let databaseURL = rootURL.appendingPathComponent("founders-office.sqlite3")
        let projectionsRootURL = rootURL.appendingPathComponent("Generated", isDirectory: true)
        let repairLedgerURL = rootURL
            .appendingPathComponent("RuntimeHealth", isDirectory: true)
            .appendingPathComponent("repair-ledger-v1.json")
        let repository = try await SQLiteWorkspaceRepository.open(
            configuration: WorkspaceRepositoryConfiguration(
                databaseURL: databaseURL,
                workspaceID: workspaceID,
                legacyDirectoryURL: rootURL,
                initialSnapshot: initialSnapshot
            )
        )
        // Subscribe before any potentially slow projection work. The stream
        // replays its current snapshot and buffers later commits, so opening a
        // session has no snapshot-to-subscription loss window.
        let eventStream = await repository.events()
        let snapshot = try await repository.snapshot()
        let repairCoordinator = BoundedRepairCoordinator(
            ledger: BoundedRepairLedger(fileURL: repairLedgerURL)
        )
        let projectionURL: URL?
        let projectionRepairState: BoundedRepairCustomerState
        do {
            projectionURL = try await repository.ensureProjection(in: projectionsRootURL)
            projectionRepairState = .ready
        } catch {
            let result = await repairCoordinator.run(
                key: Self.projectionRepairKey(for: snapshot.revision),
                isHealthy: {
                    await repository.currentProjectionURLIfHealthy(in: projectionsRootURL) != nil
                },
                repair: {
                    _ = try await repository.repairCurrentProjection(in: projectionsRootURL)
                }
            )
            projectionURL = await repository.currentProjectionURLIfHealthy(
                in: projectionsRootURL
            )
            projectionRepairState = result.customerState
            AppDiagnostics.failure(.moveStoreLoad, category: .storage, error: error)
        }
        let session = WorkspaceSession(
            rootURL: rootURL,
            databaseURL: databaseURL,
            projectionsRootURL: projectionsRootURL,
            repairLedgerURL: repairLedgerURL,
            repository: repository,
            snapshot: snapshot,
            projectionURL: projectionURL,
            projectionRepairState: projectionRepairState,
            repairCoordinator: repairCoordinator,
            eventStream: eventStream
        )
        if projectionURL == nil {
            switch projectionRepairState {
            case .needsUser:
                session.lastErrorMessage = "Workspace loaded; generated files need you in Health."
            case .ready, .retryAvailable:
                session.lastErrorMessage = "Workspace loaded; generated files need to be refreshed."
            }
        }
        return session
    }

    func stop() {
        changeTask?.cancel()
        changeTask = nil
        projectionTask?.cancel()
        projectionTask = nil
    }

    @discardableResult
    func commit(_ mutation: WorkspacePatchMutation) async throws -> WorkspaceTransactionResult {
        do {
            let result = try await repository.transact(patch: mutation)
            if apply(result.snapshot) {
                scheduleProjectionRefresh()
            }
            lastErrorMessage = nil
            return result
        } catch {
            lastErrorMessage = error.localizedDescription
            if let latest = try? await repository.snapshot() {
                _ = apply(latest)
            }
            throw error
        }
    }

    @discardableResult
    func refresh() async -> Bool {
        do {
            let latest = try await repository.snapshot()
            if apply(latest) {
                scheduleProjectionRefresh()
            }
            lastErrorMessage = nil
            return true
        } catch {
            lastErrorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func export(to destinationURL: URL) async throws -> WorkspaceExportManifest {
        try await repository.export(to: destinationURL)
    }

    @discardableResult
    func refreshProjectionNow() async -> Bool {
        projectionTask?.cancel()
        projectionTask = nil
        return await performProjectionRefresh()
    }

    private func performProjectionRefresh() async -> Bool {
        let repairKey = Self.projectionRepairKey(for: snapshot.revision)
        do {
            projectionURL = try await repository.ensureProjection(in: projectionsRootURL)
            await repairCoordinator.confirmHealthy(key: repairKey)
            projectionRepairState = .ready
            lastErrorMessage = nil
            return true
        } catch {
            let result = await repairCoordinator.run(
                key: repairKey,
                isHealthy: { [repository, projectionsRootURL] in
                    await repository.currentProjectionURLIfHealthy(in: projectionsRootURL) != nil
                },
                repair: { [repository, projectionsRootURL] in
                    _ = try await repository.repairCurrentProjection(in: projectionsRootURL)
                }
            )
            projectionRepairState = result.customerState
            projectionURL = await repository.currentProjectionURLIfHealthy(
                in: projectionsRootURL
            )
            if projectionURL != nil {
                lastErrorMessage = nil
                return true
            }
            switch projectionRepairState {
            case .needsUser:
                lastErrorMessage = "Workspace saved; generated files need you in Health."
            case .ready, .retryAvailable:
                lastErrorMessage = "Workspace saved; generated files need to be refreshed."
            }
            AppDiagnostics.failure(.moveStoreSave, category: .storage, error: error)
            return false
        }
    }

    private func observeRepositoryChanges(
        _ events: AsyncStream<WorkspaceRepositoryEvent>
    ) {
        changeTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    if self.apply(event.snapshot) {
                        self.scheduleProjectionRefresh()
                    }
                }
            }
        }
    }

    private func scheduleProjectionRefresh() {
        projectionTask?.cancel()
        projectionTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            _ = await performProjectionRefresh()
        }
    }

    @discardableResult
    private func apply(_ latest: WorkspaceRepositorySnapshot) -> Bool {
        // A local commit is applied synchronously by `commit` and then appears
        // on the repository event stream. Strict ordering avoids publishing
        // that same revision twice while still surfacing every remote commit.
        guard latest.revision > snapshot.revision else { return false }
        snapshot = latest
        return true
    }

    private static func projectionRepairKey(
        for revision: WorkspaceRevision
    ) -> BoundedRepairKey {
        BoundedRepairKey(
            kind: .generatedProjection,
            generation: UInt64(max(revision.rawValue, 0))
        )
    }
}
