import Foundation
import FounderOfficeCore

/// Redacted result of activating the customer sync runtime. It contains only
/// opaque tenancy identifiers and a bounded coordinator outcome; credentials
/// and customer content never cross this boundary.
public struct FounderOfficeCloudSyncActivation: Sendable {
    public let binding: WorkspaceSyncBinding
    public let outcome: WorkspaceSyncRunOutcome

    public init(binding: WorkspaceSyncBinding, outcome: WorkspaceSyncRunOutcome) {
        self.binding = binding
        self.outcome = outcome
    }
}

public enum FounderOfficeCloudSyncRuntimeError: Error, Equatable, Sendable {
    case accountMismatch
    case unsupportedIdentityProvider
    case bindingRequired
}

extension FounderOfficeCloudSyncRuntimeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .accountMismatch:
            return "This workspace belongs to a different signed-in account. Local data was not changed."
        case .unsupportedIdentityProvider:
            return "Use Google or Apple to enable device sync."
        case .bindingRequired:
            return "Choose how this workspace should sync before continuing."
        }
    }
}

/// Composes the already-reviewed auth, provisioning, repository, transport,
/// and event-driven coordinator boundaries for a configured customer build.
/// Constructing this actor performs no network work. Provisioning remains an
/// explicit user action and ordinary sync starts only after a matching durable
/// workspace binding exists.
public actor FounderOfficeCloudSyncRuntime {
    private let repository: any WorkspaceSyncRepository
    private let provisioner: FounderWorkspaceProvisioner
    private let coordinator: WorkspaceSyncCoordinator
    private let deviceID: DeviceID

    public init<Repository>(
        repository: Repository,
        auth: any ProductAuthServing,
        transport: any WorkspaceSyncTransport,
        deviceID: DeviceID
    ) throws where Repository: WorkspaceSyncRepository & WorkspaceProvisioningRepository {
        self.repository = repository
        self.deviceID = deviceID
        provisioner = try FounderWorkspaceProvisioner(
            repository: repository,
            transport: transport
        )
        let sessionProvider = BoundProductAuthSessionProvider(
            auth: auth,
            repository: repository
        )
        coordinator = try WorkspaceSyncCoordinator(
            repository: repository,
            auth: sessionProvider,
            transport: transport
        )
    }

    public func currentBinding() async throws -> WorkspaceSyncBinding? {
        try await repository.syncBinding()
    }

    /// Resumes a previously approved binding after secure session restore.
    /// A provider/account mismatch stops before any network request.
    public func resume(
        account: ProductAccountSession
    ) async throws -> FounderOfficeCloudSyncActivation? {
        guard let binding = try await repository.syncBinding() else { return nil }
        try Self.validate(binding: binding, account: account)
        await coordinator.start()
        let outcome = await coordinator.synchronizeNow()
        return FounderOfficeCloudSyncActivation(binding: binding, outcome: outcome)
    }

    /// Performs one explicit claim/attachment decision, persists the resulting
    /// opaque binding transactionally, then starts the bounded live coordinator.
    public func provision(
        account: ProductAccountSession,
        disposition: WorkspaceProvisioningDisposition,
        workspaceName: String,
        reviewedDisplayName: ReviewedDisplayName?
    ) async throws -> FounderOfficeCloudSyncActivation {
        let result = try await provisioner.provision(
            account: account,
            deviceID: deviceID,
            disposition: disposition,
            workspaceName: workspaceName,
            reviewedDisplayName: reviewedDisplayName
        )
        let binding: WorkspaceSyncBinding
        switch result {
        case let .claimedLocalAsNew(value),
             let .attachedExisting(value, _),
             let .alreadyAttached(value):
            binding = value
        }
        try Self.validate(binding: binding, account: account)
        await coordinator.start()
        let outcome = await coordinator.synchronizeNow()
        return FounderOfficeCloudSyncActivation(binding: binding, outcome: outcome)
    }

    public func synchronizeNow() async -> WorkspaceSyncRunOutcome {
        await coordinator.synchronizeNow()
    }

    public func currentStatus() async throws -> WorkspaceSyncStatus {
        try await repository.syncStatus()
    }

    /// Stops network work but intentionally preserves the local binding and
    /// outbox. Signing back into the same account can safely resume them.
    public func stop() async {
        await coordinator.stop()
    }

    private static func validate(
        binding: WorkspaceSyncBinding,
        account: ProductAccountSession
    ) throws {
        guard binding.accountID.rawValue == account.accountID else {
            throw FounderOfficeCloudSyncRuntimeError.accountMismatch
        }
        let expectedProvider: AccountIdentityProvider
        switch account.provider {
        case .google: expectedProvider = .google
        case .apple: expectedProvider = .apple
        case .unknown:
            throw FounderOfficeCloudSyncRuntimeError.unsupportedIdentityProvider
        }
        guard binding.identityProvider == expectedProvider else {
            throw FounderOfficeCloudSyncRuntimeError.accountMismatch
        }
    }
}

/// Reconstructs the credential-free sync session only when the durable local
/// binding matches the currently restored product identity. Access tokens stay
/// inside `SupabaseProductAuthClient` and are fetched separately by transport.
private actor BoundProductAuthSessionProvider: AuthSessionProviding {
    private let auth: any ProductAuthServing
    private let repository: any WorkspaceSyncRepository
    private let now: @Sendable () -> Date

    init(
        auth: any ProductAuthServing,
        repository: any WorkspaceSyncRepository,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.auth = auth
        self.repository = repository
        self.now = now
    }

    func currentSession() async throws -> AuthSession? {
        guard case let .signedIn(account) = await auth.currentState(),
              account.expiresAt > now(),
              let binding = try await repository.syncBinding(),
              binding.accountID.rawValue == account.accountID else {
            return nil
        }

        let expectedProvider: AccountIdentityProvider
        switch account.provider {
        case .google: expectedProvider = .google
        case .apple: expectedProvider = .apple
        case .unknown: return nil
        }
        guard binding.identityProvider == expectedProvider else { return nil }
        return binding.session
    }
}
