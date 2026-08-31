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

    let repository: SQLiteWorkspaceRepository
    let rootURL: URL
    let databaseURL: URL
    let projectionsRootURL: URL

    private var changeTask: Task<Void, Never>?
    private var projectionTask: Task<Void, Never>?

    private init(
        rootURL: URL,
        databaseURL: URL,
        projectionsRootURL: URL,
        repository: SQLiteWorkspaceRepository,
        snapshot: WorkspaceRepositorySnapshot,
        projectionURL: URL?,
        eventStream: AsyncStream<WorkspaceRepositoryEvent>
    ) {
        self.rootURL = rootURL
        self.databaseURL = databaseURL
        self.projectionsRootURL = projectionsRootURL
        self.repository = repository
        self.snapshot = snapshot
        self.projectionURL = projectionURL
        observeRepositoryChanges(eventStream)
    }

    static func open(
        rootURL: URL,
        workspaceID: UUID,
        initialSnapshot: FounderOfficeSnapshot
    ) async throws -> WorkspaceSession {
        let databaseURL = rootURL.appendingPathComponent("founders-office.sqlite3")
        let projectionsRootURL = rootURL.appendingPathComponent("Generated", isDirectory: true)
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
        let projectionURL: URL?
        do {
            projectionURL = try await repository.ensureProjection(in: projectionsRootURL)
        } catch {
            projectionURL = nil
            AppDiagnostics.failure(.moveStoreLoad, category: .storage, error: error)
        }
        let session = WorkspaceSession(
            rootURL: rootURL,
            databaseURL: databaseURL,
            projectionsRootURL: projectionsRootURL,
            repository: repository,
            snapshot: snapshot,
            projectionURL: projectionURL,
            eventStream: eventStream
        )
        if projectionURL == nil {
            session.lastErrorMessage = "Workspace loaded; generated files need to be refreshed."
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
        do {
            projectionURL = try await repository.ensureProjection(in: projectionsRootURL)
            lastErrorMessage = nil
            return true
        } catch {
            lastErrorMessage = "Workspace saved; generated files need to be refreshed."
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
}
