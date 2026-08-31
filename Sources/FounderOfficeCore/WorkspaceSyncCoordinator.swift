import Foundation

public enum WorkspaceSyncTrigger: String, Sendable {
    case startup
    case localChange
    case foreground
    case networkAvailable
    case sessionChanged
    case retry
    case manual
}

public enum WorkspaceSyncRunOutcome: Equatable, Sendable {
    case localOnly
    case authenticationRequired
    case synchronized
    case conflicts(Int)
    case blocked(String)
    case retryScheduled(Date)
    case cancelled
}

public struct WorkspaceSyncCoordinatorConfiguration: Equatable, Sendable {
    public let pushOperationLimit: Int
    public let pushByteLimit: Int
    public let maximumPushBatchesPerRun: Int
    public let pullPageLimit: Int
    public let maximumPullPagesPerRun: Int
    public let maximumConsecutiveRunsPerTrigger: Int
    public let initialRetryDelay: TimeInterval
    public let maximumRetryDelay: TimeInterval

    public init(
        pushOperationLimit: Int = 100,
        pushByteLimit: Int = 2 * 1_024 * 1_024,
        maximumPushBatchesPerRun: Int = 128,
        pullPageLimit: Int = 200,
        maximumPullPagesPerRun: Int = 100,
        maximumConsecutiveRunsPerTrigger: Int = 2,
        initialRetryDelay: TimeInterval = 1,
        maximumRetryDelay: TimeInterval = 5 * 60
    ) throws {
        guard (1...100).contains(pushOperationLimit),
              (1...2 * 1_024 * 1_024).contains(pushByteLimit),
              (1...512).contains(maximumPushBatchesPerRun),
              (1...500).contains(pullPageLimit),
              (1...200).contains(maximumPullPagesPerRun),
              (1...4).contains(maximumConsecutiveRunsPerTrigger),
              initialRetryDelay.isFinite,
              maximumRetryDelay.isFinite,
              initialRetryDelay >= 0.1,
              maximumRetryDelay >= initialRetryDelay,
              maximumRetryDelay <= 30 * 60 else {
            throw WorkspaceSyncRepositoryError.requestBoundsExceeded
        }
        self.pushOperationLimit = pushOperationLimit
        self.pushByteLimit = pushByteLimit
        self.maximumPushBatchesPerRun = maximumPushBatchesPerRun
        self.pullPageLimit = pullPageLimit
        self.maximumPullPagesPerRun = maximumPullPagesPerRun
        self.maximumConsecutiveRunsPerTrigger = maximumConsecutiveRunsPerTrigger
        self.initialRetryDelay = initialRetryDelay
        self.maximumRetryDelay = maximumRetryDelay
    }
}

/// Event-driven coordinator. It never polls: work begins only after startup,
/// foreground/network/session notification, a committed local change, a manual
/// request, or one bounded retry timer following a retryable failure.
public actor WorkspaceSyncCoordinator {
    private let repository: any WorkspaceSyncRepository
    private let auth: any AuthSessionProviding
    private let transport: any WorkspaceSyncTransport
    private let configuration: WorkspaceSyncCoordinatorConfiguration
    private let now: @Sendable () -> Date
    private let jitter: @Sendable () -> Double

    private var localObservationTask: Task<Void, Never>?
    private var runTask: Task<WorkspaceSyncRunOutcome, Never>?
    private var activeRunnerID: UUID?
    private var retryTask: Task<Void, Never>?
    private var pendingRun = false
    private var continuationRequested = false
    private var stopped = true

    public init(
        repository: any WorkspaceSyncRepository,
        auth: any AuthSessionProviding,
        transport: any WorkspaceSyncTransport,
        configuration: WorkspaceSyncCoordinatorConfiguration? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        jitter: @escaping @Sendable () -> Double = { Double.random(in: 0.8...1.2) }
    ) throws {
        self.repository = repository
        self.auth = auth
        self.transport = transport
        self.configuration = try configuration ?? WorkspaceSyncCoordinatorConfiguration()
        self.now = now
        self.jitter = jitter
    }

    deinit {
        localObservationTask?.cancel()
        runTask?.cancel()
        retryTask?.cancel()
    }

    public func start() async {
        guard stopped else { return }
        stopped = false
        let stream = await repository.changes()
        localObservationTask = Task { [weak self] in
            for await _ in stream {
                guard !Task.isCancelled else { return }
                await self?.trigger(.localChange)
            }
        }
        trigger(.startup)
    }

    public func stop() {
        stopped = true
        pendingRun = false
        localObservationTask?.cancel()
        localObservationTask = nil
        runTask?.cancel()
        runTask = nil
        activeRunnerID = nil
        retryTask?.cancel()
        retryTask = nil
    }

    public func trigger(_ reason: WorkspaceSyncTrigger) {
        _ = reason // Reasons are intentionally not persisted or logged.
        guard !stopped else { return }
        pendingRun = true
        retryTask?.cancel()
        retryTask = nil
        launchAutomaticRunnerIfNeeded()
    }

    /// A bounded explicit pass. Manual calls coalesce with an active automatic
    /// or manual runner, so bootstrap, push, cursor, and status transactions
    /// cannot overlap through actor reentrancy.
    public func synchronizeNow() async -> WorkspaceSyncRunOutcome {
        if let runTask { return await runTask.value }
        let runnerID = UUID()
        let task = Task<WorkspaceSyncRunOutcome, Never> { [weak self] in
            guard let self else { return .cancelled }
            return await self.performManualRun(runnerID: runnerID)
        }
        activeRunnerID = runnerID
        runTask = task
        return await task.value
    }

    private func launchAutomaticRunnerIfNeeded() {
        guard runTask == nil, pendingRun, !stopped else { return }
        let runnerID = UUID()
        runTask = Task<WorkspaceSyncRunOutcome, Never> { [weak self] in
            guard let self else { return .cancelled }
            return await self.drainTriggeredRuns(runnerID: runnerID)
        }
        activeRunnerID = runnerID
    }

    private func performManualRun(runnerID: UUID) async -> WorkspaceSyncRunOutcome {
        let outcome = await performOneRun(scheduleRetry: false)
        finishRunner(runnerID: runnerID, launchPending: !outcome.isTerminalSyncBlock)
        return outcome
    }

    private func drainTriggeredRuns(runnerID: UUID) async -> WorkspaceSyncRunOutcome {
        var completedRuns = 0
        var shouldRun = pendingRun
        pendingRun = false
        var lastOutcome: WorkspaceSyncRunOutcome = .cancelled
        while shouldRun,
              completedRuns < configuration.maximumConsecutiveRunsPerTrigger,
              !stopped, !Task.isCancelled {
            pendingRun = false
            continuationRequested = false
            let outcome = await performOneRun(scheduleRetry: true)
            lastOutcome = outcome
            completedRuns += 1
            if outcome.isTerminalSyncBlock {
                finishRunner(runnerID: runnerID, launchPending: false)
                return outcome
            }
            guard completedRuns < configuration.maximumConsecutiveRunsPerTrigger else {
                break
            }
            // Consume both a real event that arrived across an await and one
            // internal page/batch continuation into a single next bounded run.
            shouldRun = pendingRun || continuationRequested
            pendingRun = false
        }
        // A page/batch cap is a yield boundary, not an invitation to spin.
        // Drop only the internal continuation. `pendingRun` remains true when
        // a real local/session/network event arrived during the final await;
        // finishRunner schedules that event as a fresh bounded drain.
        continuationRequested = false
        finishRunner(runnerID: runnerID, launchPending: true)
        return lastOutcome
    }

    private func finishRunner(runnerID: UUID, launchPending: Bool) {
        guard activeRunnerID == runnerID else { return }
        runTask = nil
        activeRunnerID = nil
        if launchPending { launchAutomaticRunnerIfNeeded() }
    }

    private func performOneRun(scheduleRetry: Bool) async -> WorkspaceSyncRunOutcome {
        do {
            try Task.checkCancellation()
            guard let binding = try await repository.syncBinding() else {
                try await repository.setSyncStatus(.localOnly)
                return .localOnly
            }
            guard let session = try await auth.currentSession() else {
                try await repository.setSyncStatus(
                    try WorkspaceSyncStatus(
                        phase: .authenticationRequired,
                        failureCode: "session_missing"
                    )
                )
                return .authenticationRequired
            }
            guard session == binding.session else {
                try await repository.setSyncStatus(
                    try WorkspaceSyncStatus(
                        phase: .authenticationRequired,
                        failureCode: "session_binding_mismatch"
                    )
                )
                return .authenticationRequired
            }
            try await repository.setSyncStatus(try WorkspaceSyncStatus(phase: .syncing))

            let conflictCount = try await pushPending(session: session)
            try await pullPages(session: session)
            let successTime = now()
            try await repository.setSyncStatus(
                try WorkspaceSyncStatus(
                    phase: conflictCount > 0 ? .conflictReviewRequired : .idle,
                    lastSuccessAt: successTime,
                    failureCode: conflictCount > 0 ? "sync_conflict" : nil
                )
            )
            return conflictCount > 0 ? .conflicts(conflictCount) : .synchronized
        } catch is CancellationError {
            return .cancelled
        } catch let error as WorkspaceSyncTransportFailure {
            return await handleTransport(error, scheduleRetry: scheduleRetry)
        } catch let error as WorkspaceV2SyncAdapterError {
            let code = adapterCode(error)
            try? await repository.setSyncStatus(
                try WorkspaceSyncStatus(phase: .adapterBlocked, failureCode: code)
            )
            return .blocked(code)
        } catch let error as SyncContractValidationError {
            let code = error == .futureClockSkew ? "clock_skew" : "contract_validation"
            try? await repository.setSyncStatus(
                try WorkspaceSyncStatus(phase: .contractBlocked, failureCode: code)
            )
            return .blocked(code)
        } catch let error as WorkspaceSyncRepositoryError {
            let code: String
            switch error {
            case .assetsDisabled: code = "assets_disabled"
            case .bootstrapRevisionChanged, .cursorMismatch:
                pendingRun = true
                code = "local_state_changed"
            default: code = "repository_boundary"
            }
            try? await repository.setSyncStatus(
                try WorkspaceSyncStatus(phase: .adapterBlocked, failureCode: code)
            )
            return .blocked(code)
        } catch let error as WorkspaceRepositoryError {
            switch error {
            case .databaseUnavailable, .exportFailed:
                if scheduleRetry {
                    return await scheduleRetryAfterFailure(code: "local_storage_unavailable")
                }
                return .blocked("local_storage_unavailable")
            default:
                try? await repository.setSyncStatus(
                    try WorkspaceSyncStatus(
                        phase: .contractBlocked,
                        failureCode: "local_repository_invalid"
                    )
                )
                return .blocked("local_repository_invalid")
            }
        } catch {
            if scheduleRetry {
                return await scheduleRetryAfterFailure(code: "network_or_storage")
            }
            return .blocked("network_or_storage")
        }
    }

    private func pushPending(session: AuthSession) async throws -> Int {
        var conflictCount = 0
        var batches = 0
        while batches < configuration.maximumPushBatchesPerRun {
            try Task.checkCancellation()
            let batch = try await repository.pendingSyncBatch(
                maximumCount: configuration.pushOperationLimit,
                maximumByteCount: configuration.pushByteLimit
            )
            if batch.requiresCanonicalBootstrap {
                let plan = try await repository.canonicalBootstrapPlan()
                let bootstrap = try await transport.bootstrapWorkspace(
                    deviceID: session.deviceID,
                    localWorkspaceID: WorkspaceID(rawValue: plan.localWorkspaceID),
                    workspaceName: plan.workspaceName,
                    displayName: plan.profileDisplayName
                )
                guard bootstrap.session == session else {
                    throw WorkspaceSyncTransportFailure.invalidResponse
                }
                let chunks = try operationChunks(plan.operations)
                guard !chunks.isEmpty,
                      chunks.count <= configuration.maximumPushBatchesPerRun else {
                    throw WorkspaceSyncRepositoryError.requestBoundsExceeded
                }
                var responses: [SyncPushResponse] = []
                for operations in chunks {
                    responses.append(
                        try await transport.pushOperations(session: session, operations: operations)
                    )
                }
                _ = try await repository.acknowledgeCanonicalBootstrap(
                    plan: plan,
                    bootstrap: bootstrap,
                    responses: responses
                )
                batches += max(1, chunks.count)
                continue
            }
            guard !batch.operations.isEmpty else { return conflictCount }

            var wireByID: [UUID: SyncOperation] = [:]
            var operations: [SyncOperation] = []
            for local in batch.operations {
                switch try local.decodedLocalPayload() {
                case .requiresBootstrap:
                    throw WorkspaceSyncRepositoryError.bootstrapResponseMismatch
                case let .localEntity(envelope):
                    let entity = try mappedIdentity(
                        local: local,
                        envelope: envelope,
                        workspaceID: session.workspaceID
                    )
                    let remoteRevision = try await repository.remoteRevision(
                        entityType: entity.type,
                        entityID: entity.id
                    )
                    let wire = try WorkspaceV2SyncAdapter.adapt(
                        operation: local,
                        envelope: envelope,
                        remoteBaseRevision: remoteRevision,
                        workspaceID: session.workspaceID
                    )
                    try wire.validateClockSkew(relativeTo: now())
                    wireByID[local.operationID] = wire
                    operations.append(wire)
                }
            }
            let chunks = try operationChunks(operations)
            guard chunks.count == 1 else {
                // pendingSyncBatch is already byte bounded. A mismatch means
                // the estimate no longer matches the wire contract.
                throw WorkspaceSyncRepositoryError.requestBoundsExceeded
            }
            try await repository.recordDeliveryAttempt(operationIDs: batch.operations.map(\.operationID))
            let response = try await transport.pushOperations(session: session, operations: operations)
            var acknowledgements: [WorkspaceRemoteOperationAcknowledgement] = []
            var conflicts: [WorkspacePersistedSyncConflict] = []
            for result in response.results {
                guard let wire = wireByID[result.operationID.rawValue] else {
                    throw WorkspaceSyncTransportFailure.invalidResponse
                }
                switch result.status {
                case .accepted, .duplicate:
                    guard let revision = result.revision else {
                        throw WorkspaceSyncTransportFailure.invalidResponse
                    }
                    acknowledgements.append(
                        try WorkspaceRemoteOperationAcknowledgement(
                            localOperationID: result.operationID.rawValue,
                            entityType: wire.entityType,
                            entityID: wire.entityID,
                            remoteRevision: revision,
                            fieldClocks: wire.fieldClocks
                        )
                    )
                case .conflict:
                    guard let conflict = result.conflict else {
                        throw WorkspaceSyncTransportFailure.invalidResponse
                    }
                    conflicts.append(
                        try WorkspacePersistedSyncConflict(
                            workspaceID: session.workspaceID,
                            conflict: conflict,
                            recordedAt: now()
                        )
                    )
                }
            }
            try await repository.acknowledgeRemoteOperations(
                acknowledgements,
                conflicts: conflicts
            )
            conflictCount += conflicts.count
            batches += 1
        }
        continuationRequested = true
        return conflictCount
    }

    private func pullPages(session: AuthSession) async throws {
        var pages = 0
        while pages < configuration.maximumPullPagesPerRun {
            try Task.checkCancellation()
            let cursor = try await repository.syncCursor()
            let page = try await transport.pullChanges(
                session: session,
                after: cursor,
                limit: configuration.pullPageLimit
            )
            try await repository.applyRemotePage(page)
            pages += 1
            if !page.hasMore { return }
        }
        continuationRequested = true
    }

    private func operationChunks(_ operations: [SyncOperation]) throws -> [[SyncOperation]] {
        guard !operations.isEmpty else { return [] }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var chunks: [[SyncOperation]] = []
        var current: [SyncOperation] = []
        let wrapperHeadroom = min(4 * 1_024, configuration.pushByteLimit / 4)
        var currentBytes = wrapperHeadroom
        for operation in operations {
            let bytes = try encoder.encode(operation).count + 1
            guard bytes + wrapperHeadroom <= configuration.pushByteLimit else {
                throw WorkspaceSyncRepositoryError.requestBoundsExceeded
            }
            if current.count == configuration.pushOperationLimit ||
                currentBytes + bytes > configuration.pushByteLimit {
                chunks.append(current)
                current = []
                currentBytes = wrapperHeadroom
            }
            current.append(operation)
            currentBytes += bytes
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private func mappedIdentity(
        local: WorkspaceOutboxOperation,
        envelope: WorkspaceLocalOperationEnvelopeV2,
        workspaceID: WorkspaceID
    ) throws -> (type: SyncEntityType, id: UUID) {
        switch envelope.record {
        case let .move(move): return (.move, move.id)
        case .appearance: return (.appearance, workspaceID.rawValue)
        case .profile: throw WorkspaceV2SyncAdapterError.profileRequiresReviewedBootstrap
        case .workspace: return (.workspace, workspaceID.rawValue)
        case let .primaryGoal(goal): return (.primaryGoal, goal.id)
        case let .milestone(milestone): return (.milestone, milestone.id)
        case .asset: throw WorkspaceV2SyncAdapterError.assetTransferDisabled
        }
    }

    private func handleTransport(
        _ error: WorkspaceSyncTransportFailure,
        scheduleRetry: Bool
    ) async -> WorkspaceSyncRunOutcome {
        switch error {
        case .unauthorized, .invalidAccessToken:
            try? await repository.setSyncStatus(
                try WorkspaceSyncStatus(
                    phase: .authenticationRequired,
                    failureCode: "session_revoked"
                )
            )
            return .authenticationRequired
        case .forbidden:
            try? await repository.setSyncStatus(
                try WorkspaceSyncStatus(
                    phase: .authenticationRequired,
                    failureCode: "workspace_forbidden"
                )
            )
            return .authenticationRequired
        case .rejected, .invalidResponse, .invalidContentType,
             .unexpectedEndpoint, .redirectRejected, .httpStatus:
            try? await repository.setSyncStatus(
                try WorkspaceSyncStatus(
                    phase: .contractBlocked,
                    failureCode: "transport_contract"
                )
            )
            return .blocked("transport_contract")
        case .requestTooLarge, .responseTooLarge, .invalidConfiguration:
            try? await repository.setSyncStatus(
                try WorkspaceSyncStatus(
                    phase: .contractBlocked,
                    failureCode: "transport_bounds"
                )
            )
            return .blocked("transport_bounds")
        case .cancelled:
            return .cancelled
        case .unavailable, .network:
            return scheduleRetry
                ? await scheduleRetryAfterFailure(code: "transport_unavailable")
                : .blocked("transport_unavailable")
        }
    }

    private func scheduleRetryAfterFailure(code: String) async -> WorkspaceSyncRunOutcome {
        let previousAttempt = (try? await repository.syncStatus())?.retryAttempt ?? 0
        let attempt = min(previousAttempt + 1, 32)
        let exponent = min(attempt - 1, 16)
        let base = min(
            configuration.maximumRetryDelay,
            configuration.initialRetryDelay * pow(2, Double(exponent))
        )
        let jitterFactor = min(max(jitter(), 0.5), 1.5)
        let delay = min(configuration.maximumRetryDelay, base * jitterFactor)
        let retryAt = now().addingTimeInterval(delay)
        try? await repository.setSyncStatus(
            try WorkspaceSyncStatus(
                phase: .retryScheduled,
                retryAttempt: attempt,
                nextRetryAt: retryAt,
                failureCode: code
            )
        )
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch { return }
            await self?.trigger(.retry)
        }
        return .retryScheduled(retryAt)
    }

    private func adapterCode(_ error: WorkspaceV2SyncAdapterError) -> String {
        switch error {
        case .profileRequiresReviewedBootstrap: return "profile_requires_reviewed_bootstrap"
        case .assetTransferDisabled: return "assets_disabled"
        case .unsupportedEntity, .unsupportedField: return "adapter_mapping_missing"
        case .missingFieldClock: return "field_clock_missing"
        case .invalidEntityIdentifier, .invalidValue, .emptyWireMutation: return "adapter_value_invalid"
        }
    }
}

private extension WorkspaceSyncRunOutcome {
    var isTerminalSyncBlock: Bool {
        switch self {
        case .authenticationRequired, .blocked, .retryScheduled, .cancelled:
            return true
        case .localOnly, .synchronized, .conflicts:
            return false
        }
    }
}
