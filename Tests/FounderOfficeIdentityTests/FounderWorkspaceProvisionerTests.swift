import Foundation
import Testing
@testable import FounderOfficeCore
@testable import FounderOfficeIdentity

struct FounderWorkspaceProvisionerTests {
    @Test
    func secondDeviceAttachesDifferentRemoteWorkspaceAtomicallyAndSurvivesRelaunch() async throws {
        let fixture = try ProvisioningFixture()
        defer { fixture.remove() }
        let repository = try await fixture.open(initial: fixture.snapshot())
        let remote = fixture.remoteIdentity()
        let move = try fixture.moveChange(remote: remote, cursor: 1, title: "Remote Move")
        let transport = ProvisioningTransport(
            bootstrap: try fixture.bootstrap(remote: remote, latestCursor: 1),
            pages: [try fixture.page(remote: remote, from: 0, changes: [move])]
        )
        let provisioner = try FounderWorkspaceProvisioner(
            repository: repository,
            transport: transport
        )

        let result = try await provisioner.provision(
            account: fixture.productAccount(remote: remote),
            deviceID: remote.deviceID,
            disposition: .attachExisting(.freshDevice),
            workspaceName: "Ignored for existing",
            reviewedDisplayName: nil
        )
        guard case let .attachedExisting(binding, localExportCreated) = result else {
            Issue.record("Expected an existing-workspace attachment")
            return
        }
        #expect(!localExportCreated)
        #expect(binding.workspaceID == remote.workspaceID)
        #expect(binding.workspaceID.rawValue != fixture.localWorkspaceID)
        #expect(try await repository.snapshot().content.openLoops.items.map(\.title) == ["Remote Move"])
        #expect(try await repository.syncCursor() == SyncCursor(value: 1))
        #expect(try await repository.remoteRevision(entityType: .move, entityID: move.entityID) == 1)
        #expect(await transport.localWorkspaceIDs() == [nil])

        let relaunched = try await fixture.open(initial: nil)
        let relaunchedBinding = try #require(try await relaunched.syncBinding())
        #expect(relaunchedBinding.accountID == binding.accountID)
        #expect(relaunchedBinding.workspaceID == binding.workspaceID)
        #expect(relaunchedBinding.deviceID == binding.deviceID)
        #expect(relaunchedBinding.identityProvider == binding.identityProvider)
        #expect(try await relaunched.syncCursor() == SyncCursor(value: 1))
        #expect(try await relaunched.snapshot().content.openLoops.items.map(\.title) == ["Remote Move"])
    }

    @Test
    func dataBearingDeviceRequiresImmutableExportBeforeRemoteReplacement() async throws {
        let fixture = try ProvisioningFixture()
        defer { fixture.remove() }
        let repository = try await fixture.open(initial: fixture.snapshot(title: "Local Move"))
        let baseline = try await repository.snapshot()
        var locallyEdited = baseline.content
        locallyEdited.openLoops.items[0].title = "Local Move Edited"
        locallyEdited.openLoops.items[0].updatedAt = Date(timeIntervalSince1970: 20)
        locallyEdited.openLoops.updatedAt = Date(timeIntervalSince1970: 20)
        _ = try await repository.transact(
            expectedRevision: baseline.revision,
            mutation: WorkspaceMutation(
                entityKind: "move",
                entityID: locallyEdited.openLoops.items[0].id.uuidString.lowercased(),
                changedFields: ["title"],
                fieldClocks: ["title": Date(timeIntervalSince1970: 20)],
                replacement: locallyEdited,
                createdAt: Date(timeIntervalSince1970: 20)
            )
        )
        #expect(try await repository.pendingOperations().count == 1)
        let remote = fixture.remoteIdentity()
        let remoteMove = try fixture.moveChange(remote: remote, cursor: 1, title: "Remote Move")
        let transport = ProvisioningTransport(
            bootstrap: try fixture.bootstrap(remote: remote, latestCursor: 1),
            pages: [try fixture.page(remote: remote, from: 0, changes: [remoteMove])]
        )
        let provisioner = try FounderWorkspaceProvisioner(repository: repository, transport: transport)

        let rejected = await provisioningError {
            try await provisioner.provision(
                account: fixture.productAccount(remote: remote),
                deviceID: remote.deviceID,
                disposition: .attachExisting(.freshDevice),
                workspaceName: "Founder's Office",
                reviewedDisplayName: nil
            )
        }
        #expect(rejected.sync == .replacementExportRequired)
        #expect(try await repository.snapshot().content.openLoops.items.map(\.title) == ["Local Move Edited"])
        #expect(try await repository.syncBinding() == nil)

        let exportURL = fixture.rootURL.appendingPathComponent("before-remote-replacement", isDirectory: true)
        let result = try await provisioner.provision(
            account: fixture.productAccount(remote: remote),
            deviceID: remote.deviceID,
            disposition: .attachExisting(.exportAndReplace(destination: exportURL)),
            workspaceName: "Founder's Office",
            reviewedDisplayName: nil
        )
        guard case let .attachedExisting(_, localExportCreated) = result else {
            Issue.record("Expected an existing-workspace attachment")
            return
        }
        #expect(localExportCreated)
        #expect(FileManager.default.fileExists(
            atPath: exportURL.appendingPathComponent("workspace-export-manifest.json").path
        ))
        let exportedData = try Data(contentsOf: exportURL.appendingPathComponent("openloops.json"))
        let exported = try provisioningDecoder.decode(OpenLoopsDocument.self, from: exportedData)
        #expect(exported.items.map(\.title) == ["Local Move Edited"])
        #expect(try await repository.snapshot().content.openLoops.items.map(\.title) == ["Remote Move"])
        #expect(try await repository.pendingOperations().isEmpty)
    }

    @Test
    func failedPreservationExportLeavesCanonicalBindingAndCursorUntouched() async throws {
        let fixture = try ProvisioningFixture()
        defer { fixture.remove() }
        let repository = try await fixture.open(initial: fixture.snapshot(title: "Keep Me"))
        let remote = fixture.remoteIdentity()
        let transport = ProvisioningTransport(
            bootstrap: try fixture.bootstrap(remote: remote, latestCursor: 0),
            pages: [try fixture.page(remote: remote, from: 0, changes: [])]
        )
        let provisioner = try FounderWorkspaceProvisioner(repository: repository, transport: transport)
        let existingDestination = fixture.rootURL.appendingPathComponent("already-exists", isDirectory: true)
        try FileManager.default.createDirectory(at: existingDestination, withIntermediateDirectories: true)

        let error = await provisioningError {
            try await provisioner.provision(
                account: fixture.productAccount(remote: remote),
                deviceID: remote.deviceID,
                disposition: .attachExisting(.exportAndReplace(destination: existingDestination)),
                workspaceName: "Founder's Office",
                reviewedDisplayName: nil
            )
        }
        #expect(error.repository == .exportDestinationExists)
        #expect(try await repository.snapshot().revision == .initial)
        #expect(try await repository.snapshot().content.openLoops.items.map(\.title) == ["Keep Me"])
        #expect(try await repository.syncBinding() == nil)
        #expect(try await repository.syncCursor() == SyncCursor(value: 0))
    }

    @Test
    func emptyRemoteFeedReplacesOnlyAnExplicitlyAuthorizedFreshDevice() async throws {
        let fixture = try ProvisioningFixture()
        defer { fixture.remove() }
        let repository = try await fixture.open(initial: fixture.snapshot())
        let remote = fixture.remoteIdentity()
        let transport = ProvisioningTransport(
            bootstrap: try fixture.bootstrap(remote: remote, latestCursor: 0),
            pages: [try fixture.page(remote: remote, from: 0, changes: [])]
        )
        let provisioner = try FounderWorkspaceProvisioner(repository: repository, transport: transport)

        _ = try await provisioner.provision(
            account: fixture.productAccount(remote: remote),
            deviceID: remote.deviceID,
            disposition: .attachExisting(.freshDevice),
            workspaceName: "Founder's Office",
            reviewedDisplayName: nil
        )
        let snapshot = try await repository.snapshot()
        #expect(snapshot.content.openLoops.items.isEmpty)
        #expect(snapshot.content.personalization.resolvedWorkspaceName == "Remote Office")
        #expect(snapshot.content.personalization.resolvedPreferredName == "Remote Founder")
        #expect(try await repository.syncCursor() == SyncCursor(value: 0))
    }

    @Test
    func remoteAccountMismatchAndExistingOtherLocalIdentityFailBeforeReplacement() async throws {
        let fixture = try ProvisioningFixture()
        defer { fixture.remove() }
        let remote = fixture.remoteIdentity()

        let mismatchRepository = try await fixture.open(initial: fixture.snapshot())
        let wrongRemote = ProvisioningRemoteIdentity(
            accountID: FounderAccountID(rawValue: UUID()),
            workspaceID: remote.workspaceID,
            deviceID: remote.deviceID,
            provider: remote.provider
        )
        let mismatchTransport = ProvisioningTransport(
            bootstrap: try fixture.bootstrap(remote: wrongRemote, latestCursor: 0),
            pages: [try fixture.page(remote: wrongRemote, from: 0, changes: [])]
        )
        let mismatchProvisioner = try FounderWorkspaceProvisioner(
            repository: mismatchRepository,
            transport: mismatchTransport
        )
        let mismatch = await provisioningError {
            try await mismatchProvisioner.provision(
                account: fixture.productAccount(remote: remote),
                deviceID: remote.deviceID,
                disposition: .attachExisting(.freshDevice),
                workspaceName: "Founder's Office",
                reviewedDisplayName: nil
            )
        }
        #expect(mismatch.provisioning == .remoteIdentityMismatch)
        #expect(try await mismatchRepository.syncBinding() == nil)
        #expect(try await mismatchRepository.snapshot().revision == .initial)

        let otherFixture = try ProvisioningFixture()
        defer { otherFixture.remove() }
        let otherRepository = try await otherFixture.open(initial: otherFixture.snapshot())
        let otherBinding = try WorkspaceSyncBinding(
            accountID: FounderAccountID(rawValue: UUID()),
            workspaceID: WorkspaceID(rawValue: otherFixture.localWorkspaceID),
            deviceID: remote.deviceID,
            identityProvider: .google
        )
        try await otherRepository.bindSync(otherBinding)
        let untouchedTransport = ProvisioningTransport(
            bootstrap: try otherFixture.bootstrap(remote: remote, latestCursor: 0),
            pages: [try otherFixture.page(remote: remote, from: 0, changes: [])]
        )
        let otherProvisioner = try FounderWorkspaceProvisioner(
            repository: otherRepository,
            transport: untouchedTransport
        )
        let otherError = await provisioningError {
            try await otherProvisioner.provision(
                account: otherFixture.productAccount(remote: remote),
                deviceID: remote.deviceID,
                disposition: .attachExisting(.freshDevice),
                workspaceName: "Founder's Office",
                reviewedDisplayName: nil
            )
        }
        #expect(otherError.provisioning == .localIdentityMismatch)
        #expect(await untouchedTransport.bootstrapCallCount() == 0)
        let persistedOtherBinding = try #require(try await otherRepository.syncBinding())
        #expect(persistedOtherBinding.accountID == otherBinding.accountID)
        #expect(persistedOtherBinding.workspaceID == otherBinding.workspaceID)
        #expect(persistedOtherBinding.deviceID == otherBinding.deviceID)
        #expect(persistedOtherBinding.identityProvider == otherBinding.identityProvider)
    }

    @Test
    func claimAndAttachUseDistinctBootstrapRequestsWithoutImplicitReplacement() async throws {
        let fixture = try ProvisioningFixture()
        defer { fixture.remove() }
        let repository = try await fixture.open(initial: fixture.snapshot(title: "Claim Me"))
        let localRemote = ProvisioningRemoteIdentity(
            accountID: FounderAccountID(rawValue: fixture.accountID),
            workspaceID: WorkspaceID(rawValue: fixture.localWorkspaceID),
            deviceID: fixture.deviceID,
            provider: .google
        )
        let transport = ProvisioningTransport(
            bootstrap: try fixture.bootstrap(remote: localRemote, latestCursor: 0),
            pages: []
        )
        let provisioner = try FounderWorkspaceProvisioner(repository: repository, transport: transport)

        let result = try await provisioner.provision(
            account: fixture.productAccount(remote: localRemote),
            deviceID: localRemote.deviceID,
            disposition: .claimLocalAsNew,
            workspaceName: "Local Office",
            reviewedDisplayName: nil
        )
        guard case .claimedLocalAsNew = result else {
            Issue.record("Expected a local claim")
            return
        }
        #expect(await transport.localWorkspaceIDs() == [WorkspaceID(rawValue: fixture.localWorkspaceID)])
        #expect(try await repository.snapshot().revision == .initial)
        #expect(try await repository.snapshot().content.openLoops.items.map(\.title) == ["Claim Me"])
        #expect(try await repository.pendingSyncBatch().requiresCanonicalBootstrap)
    }
}

private struct ProvisioningRemoteIdentity: Sendable {
    let accountID: FounderAccountID
    let workspaceID: WorkspaceID
    let deviceID: DeviceID
    let provider: AccountIdentityProvider
}

private final class ProvisioningFixture: @unchecked Sendable {
    let rootURL: URL
    let databaseURL: URL
    let localWorkspaceID = UUID()
    let writerID = WorkspaceWriterID()
    let accountID = UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    let deviceID = DeviceID(rawValue: UUID(uuidString: "dddddddd-dddd-4ddd-8ddd-dddddddddddd")!)

    init() throws {
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "founder-provisioning-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        databaseURL = rootURL.appendingPathComponent("founders-office.sqlite3")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: rootURL) }

    func open(initial: FounderOfficeSnapshot?) async throws -> SQLiteWorkspaceRepository {
        try await SQLiteWorkspaceRepository.open(
            configuration: WorkspaceRepositoryConfiguration(
                databaseURL: databaseURL,
                workspaceID: localWorkspaceID,
                requestedWriterID: writerID,
                initialSnapshot: initial
            )
        )
    }

    func snapshot(title: String? = nil) -> FounderOfficeSnapshot {
        let now = Date(timeIntervalSince1970: 10)
        let moves: [OpenLoop] = title.map {
            [OpenLoop(
                id: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!,
                title: $0,
                details: "",
                status: .next,
                previousStatus: nil,
                priority: .p1,
                dueAt: nil,
                createdAt: now,
                updatedAt: now,
                completedAt: nil,
                deletedAt: nil,
                source: "test"
            )]
        } ?? []
        return FounderOfficeSnapshot(
            openLoops: OpenLoopsDocument(schemaVersion: 3, updatedAt: now, items: moves),
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

    func remoteIdentity() -> ProvisioningRemoteIdentity {
        ProvisioningRemoteIdentity(
            accountID: FounderAccountID(rawValue: accountID),
            workspaceID: WorkspaceID(rawValue: UUID(uuidString: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")!),
            deviceID: deviceID,
            provider: .google
        )
    }

    func productAccount(remote: ProvisioningRemoteIdentity) -> ProductAccountSession {
        ProductAccountSession(
            accountID: remote.accountID.rawValue,
            provider: remote.provider == .google ? .google : .apple,
            onboardingDisplayNameSuggestion: nil,
            expiresAt: Date(timeIntervalSinceNow: 3_600)
        )
    }

    func bootstrap(
        remote: ProvisioningRemoteIdentity,
        latestCursor: Int64
    ) throws -> WorkspaceBootstrap {
        struct Encoded: Encodable {
            let contractVersion = 1
            let session: AuthSession
            let profile: FounderProfile
            let workspace: [String: SyncJSONValue]
            let startingCursor: SyncCursor
            let latestCursor: SyncCursor
        }
        let timestamp = "2026-09-01T00:00:00Z"
        return try provisioningDecoder.decode(
            WorkspaceBootstrap.self,
            from: provisioningEncoder.encode(
                Encoded(
                    session: AuthSession(
                        accountID: remote.accountID,
                        workspaceID: remote.workspaceID,
                        deviceID: remote.deviceID,
                        identityProvider: remote.provider
                    ),
                    profile: try FounderProfile(
                        accountID: remote.accountID,
                        identityProvider: remote.provider,
                        displayName: "Remote Founder"
                    ),
                    workspace: [
                        "id": .string(remote.workspaceID.rawValue.uuidString.lowercased()),
                        "name": .string("Remote Office"),
                        "revision": .integer(1),
                        "fieldClocks": .object(["name": .string(timestamp)]),
                        "createdAt": .string(timestamp),
                        "updatedAt": .string(timestamp),
                    ],
                    startingCursor: try SyncCursor(value: 0),
                    latestCursor: try SyncCursor(value: latestCursor)
                )
            )
        )
    }

    func moveChange(
        remote: ProvisioningRemoteIdentity,
        cursor: Int64,
        title: String
    ) throws -> SyncChange {
        let moveID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let timestamp = "2026-09-01T00:00:01Z"
        let fields = ["title", "details", "status", "priority", "source", "createdAt"]
        return try SyncChange(
            cursor: SyncCursor(value: cursor),
            operationID: SyncOperationID(rawValue: UUID()),
            entityType: .move,
            entityID: moveID,
            action: .upsert,
            revision: 1,
            changedFields: fields,
            changedAt: Date(timeIntervalSince1970: 1_777_593_601),
            record: [
                "id": .string(moveID.uuidString.lowercased()),
                "title": .string(title),
                "details": .string("From another device"),
                "status": .string("next"),
                "previousStatus": .null,
                "priority": .string("P1"),
                "dueOn": .null,
                "completedAt": .null,
                "deletedAt": .null,
                "source": .string("sync"),
                "revision": .integer(1),
                "fieldClocks": .object(
                    Dictionary(uniqueKeysWithValues: fields.map { ($0, .string(timestamp)) })
                ),
                "createdAt": .string(timestamp),
                "updatedAt": .string(timestamp),
            ]
        )
    }

    func page(
        remote: ProvisioningRemoteIdentity,
        from: Int64,
        changes: [SyncChange]
    ) throws -> SyncPullResponse {
        struct Encoded: Encodable {
            let contractVersion = 1
            let workspaceId: WorkspaceID
            let fromCursor: SyncCursor
            let nextCursor: SyncCursor
            let latestCursor: SyncCursor
            let hasMore: Bool
            let changes: [SyncChange]
        }
        let next = changes.last?.cursor.value ?? from
        return try provisioningDecoder.decode(
            SyncPullResponse.self,
            from: provisioningEncoder.encode(
                Encoded(
                    workspaceId: remote.workspaceID,
                    fromCursor: try SyncCursor(value: from),
                    nextCursor: try SyncCursor(value: next),
                    latestCursor: try SyncCursor(value: next),
                    hasMore: false,
                    changes: changes
                )
            )
        )
    }
}

private actor ProvisioningTransport: WorkspaceSyncTransport {
    private let bootstrapResponse: WorkspaceBootstrap
    private let pages: [SyncPullResponse]
    private var requestedLocalWorkspaceIDs: [WorkspaceID?] = []

    init(bootstrap: WorkspaceBootstrap, pages: [SyncPullResponse]) {
        bootstrapResponse = bootstrap
        self.pages = pages
    }

    func localWorkspaceIDs() -> [WorkspaceID?] { requestedLocalWorkspaceIDs }
    func bootstrapCallCount() -> Int { requestedLocalWorkspaceIDs.count }

    func bootstrapWorkspace(
        deviceID: DeviceID,
        localWorkspaceID: WorkspaceID?,
        workspaceName: String,
        displayName: String?
    ) async throws -> WorkspaceBootstrap {
        _ = deviceID
        _ = workspaceName
        _ = displayName
        requestedLocalWorkspaceIDs.append(localWorkspaceID)
        return bootstrapResponse
    }

    func pushOperations(
        session: AuthSession,
        operations: [SyncOperation]
    ) async throws -> SyncPushResponse {
        _ = session
        _ = operations
        throw WorkspaceSyncTransportFailure.rejected
    }

    func pullChanges(
        session: AuthSession,
        after cursor: SyncCursor,
        limit: Int
    ) async throws -> SyncPullResponse {
        _ = session
        _ = cursor
        _ = limit
        guard let page = pages.first(where: { $0.fromCursor == cursor }) else {
            throw WorkspaceSyncTransportFailure.rejected
        }
        return page
    }

    func exportWorkspace(session: AuthSession) async throws -> WorkspaceExport {
        _ = session
        throw WorkspaceSyncTransportFailure.rejected
    }

    func eraseWorkspace(
        session: AuthSession,
        confirming workspaceID: WorkspaceID
    ) async throws -> WorkspaceEraseReceipt {
        _ = session
        _ = workspaceID
        throw WorkspaceSyncTransportFailure.rejected
    }
}

private struct CapturedProvisioningError {
    let provisioning: FounderWorkspaceProvisioningError?
    let sync: WorkspaceSyncRepositoryError?
    let repository: WorkspaceRepositoryError?
}

private func provisioningError<Result: Sendable>(
    _ body: @Sendable () async throws -> Result
) async -> CapturedProvisioningError {
    do {
        _ = try await body()
        Issue.record("Expected provisioning to fail")
        return CapturedProvisioningError(provisioning: nil, sync: nil, repository: nil)
    } catch let error as FounderWorkspaceProvisioningError {
        return CapturedProvisioningError(provisioning: error, sync: nil, repository: nil)
    } catch let error as WorkspaceSyncRepositoryError {
        return CapturedProvisioningError(provisioning: nil, sync: error, repository: nil)
    } catch let error as WorkspaceRepositoryError {
        return CapturedProvisioningError(provisioning: nil, sync: nil, repository: error)
    } catch {
        Issue.record("Unexpected error type: \(type(of: error))")
        return CapturedProvisioningError(provisioning: nil, sync: nil, repository: nil)
    }
}

private var provisioningEncoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return encoder
}

private var provisioningDecoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
}
