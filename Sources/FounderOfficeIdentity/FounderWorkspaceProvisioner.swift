import Foundation
import FounderOfficeCore

public enum FounderWorkspaceProvisioningError: Error, Equatable, Sendable {
    case unsupportedIdentityProvider
    case localIdentityMismatch
    case remoteIdentityMismatch
    case remoteWorkspaceMismatch
    case feedLimitExceeded
    case cancelled
}

extension FounderWorkspaceProvisioningError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedIdentityProvider:
            return "Use Google or Apple to enable device sync."
        case .localIdentityMismatch:
            return "This local workspace is already connected to a different account or device."
        case .remoteIdentityMismatch, .remoteWorkspaceMismatch:
            return "The signed-in account did not match the discovered workspace. Local data was not changed."
        case .feedLimitExceeded:
            return "The existing workspace is too large to verify in one attachment pass. Local data was not changed."
        case .cancelled:
            return "Workspace setup was cancelled. Local data was not changed."
        }
    }
}

/// Explicit, one-shot product-account provisioning. It deliberately remains
/// separate from `WorkspaceSyncCoordinator`: signing in alone cannot invoke it,
/// and the customer runtime does not construct it until production sync gates
/// pass.
public actor FounderWorkspaceProvisioner {
    private let repository: any WorkspaceProvisioningRepository
    private let transport: any WorkspaceSyncTransport
    private let pullPageLimit: Int
    private let maximumPullPages: Int
    private let maximumFeedByteCount: Int

    public init(
        repository: any WorkspaceProvisioningRepository,
        transport: any WorkspaceSyncTransport,
        pullPageLimit: Int = 500,
        maximumPullPages: Int = 128,
        maximumFeedByteCount: Int = 64 * 1_024 * 1_024
    ) throws {
        guard (1...500).contains(pullPageLimit),
              (1...200).contains(maximumPullPages),
              (1...64 * 1_024 * 1_024).contains(maximumFeedByteCount) else {
            throw FounderWorkspaceProvisioningError.feedLimitExceeded
        }
        self.repository = repository
        self.transport = transport
        self.pullPageLimit = pullPageLimit
        self.maximumPullPages = maximumPullPages
        self.maximumFeedByteCount = maximumFeedByteCount
    }

    public func provision(
        account: ProductAccountSession,
        deviceID: DeviceID,
        disposition: WorkspaceProvisioningDisposition,
        workspaceName: String,
        reviewedDisplayName: ReviewedDisplayName?
    ) async throws -> WorkspaceProvisioningResult {
        guard !Task.isCancelled else {
            throw FounderWorkspaceProvisioningError.cancelled
        }
        let provider = try Self.provider(account.provider)
        let accountID = FounderAccountID(rawValue: account.accountID)
        if let existing = try await repository.syncBinding() {
            guard existing.accountID == accountID,
                  existing.deviceID == deviceID,
                  existing.identityProvider == provider else {
                throw FounderWorkspaceProvisioningError.localIdentityMismatch
            }
            return .alreadyAttached(existing)
        }

        switch disposition {
        case .claimLocalAsNew:
            let local = try await repository.snapshot()
            let bootstrap = try await transport.bootstrapWorkspace(
                deviceID: deviceID,
                localWorkspaceID: WorkspaceID(rawValue: local.workspaceID),
                workspaceName: workspaceName,
                displayName: reviewedDisplayName?.value
            )
            try Self.validate(
                bootstrap,
                expectedAccountID: accountID,
                provider: provider,
                deviceID: deviceID
            )
            guard bootstrap.session.workspaceID.rawValue == local.workspaceID else {
                throw FounderWorkspaceProvisioningError.remoteWorkspaceMismatch
            }
            let binding = try WorkspaceSyncBinding(
                accountID: accountID,
                workspaceID: bootstrap.session.workspaceID,
                deviceID: deviceID,
                identityProvider: provider
            )
            try await repository.bindSync(binding)
            return .claimedLocalAsNew(binding)

        case let .attachExisting(authorization):
            let bootstrap = try await transport.bootstrapWorkspace(
                deviceID: deviceID,
                localWorkspaceID: nil,
                workspaceName: workspaceName,
                displayName: reviewedDisplayName?.value
            )
            try Self.validate(
                bootstrap,
                expectedAccountID: accountID,
                provider: provider,
                deviceID: deviceID
            )
            let pages = try await completeFeed(for: bootstrap.session)
            let commit = try await repository.attachExistingWorkspace(
                bootstrap: bootstrap,
                pages: pages,
                authorization: authorization
            )
            let exported: Bool
            if case .exportAndReplace = authorization { exported = true } else { exported = false }
            return .attachedExisting(commit.binding, localExportCreated: exported)
        }
    }

    private func completeFeed(for session: AuthSession) async throws -> [SyncPullResponse] {
        var cursor = try SyncCursor(value: 0)
        var pages: [SyncPullResponse] = []
        var encodedByteCount = 0
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        for _ in 0..<maximumPullPages {
            do {
                try Task.checkCancellation()
            } catch {
                throw FounderWorkspaceProvisioningError.cancelled
            }
            let page = try await transport.pullChanges(
                session: session,
                after: cursor,
                limit: pullPageLimit
            )
            guard page.workspaceID == session.workspaceID,
                  page.fromCursor == cursor else {
                throw FounderWorkspaceProvisioningError.remoteWorkspaceMismatch
            }
            let pageByteCount: Int
            do {
                pageByteCount = try encoder.encode(page).count
            } catch {
                throw FounderWorkspaceProvisioningError.remoteWorkspaceMismatch
            }
            guard pageByteCount <= maximumFeedByteCount,
                  encodedByteCount <= maximumFeedByteCount - pageByteCount else {
                throw FounderWorkspaceProvisioningError.feedLimitExceeded
            }
            encodedByteCount += pageByteCount
            pages.append(page)
            cursor = page.nextCursor
            if !page.hasMore { return pages }
        }
        throw FounderWorkspaceProvisioningError.feedLimitExceeded
    }

    private static func provider(
        _ provider: ProductIdentityProvider
    ) throws -> AccountIdentityProvider {
        switch provider {
        case .google: return .google
        case .apple: return .apple
        case .unknown: throw FounderWorkspaceProvisioningError.unsupportedIdentityProvider
        }
    }

    private static func validate(
        _ bootstrap: WorkspaceBootstrap,
        expectedAccountID: FounderAccountID,
        provider: AccountIdentityProvider,
        deviceID: DeviceID
    ) throws {
        guard bootstrap.session.accountID == expectedAccountID,
              bootstrap.profile.accountID == expectedAccountID,
              bootstrap.session.identityProvider == provider,
              bootstrap.profile.identityProvider == provider,
              bootstrap.session.deviceID == deviceID else {
            throw FounderWorkspaceProvisioningError.remoteIdentityMismatch
        }
    }
}
