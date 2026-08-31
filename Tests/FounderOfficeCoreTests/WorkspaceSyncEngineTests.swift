import Foundation
import SQLite3
import Testing
@testable import FounderOfficeCore

struct WorkspaceSyncRepositoryBoundaryTests {
    @Test
    func localOnlyOutboxIsInvisibleToSyncUntilExplicitBindingAndIdentityCannotBeReplaced() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let repository = try await fixture.open(initial: fixture.snapshot(title: "Before"))
        let baseline = try await repository.snapshot()
        var replacement = baseline.content
        replacement.openLoops.items[0].title = "Pending"
        _ = try await repository.transact(
            expectedRevision: baseline.revision,
            mutation: fixture.mutation(replacement: replacement)
        )

        let localOnly = try await repository.pendingSyncBatch()
        #expect(localOnly.operations.isEmpty)
        #expect(!localOnly.requiresCanonicalBootstrap)
        #expect(try await repository.pendingOperations().count == 1)

        let binding = try fixture.syncBinding()
        try await repository.bindSync(binding)
        let firstBoundBatch = try await repository.pendingSyncBatch()
        #expect(firstBoundBatch.requiresCanonicalBootstrap)

        let replacementBinding = try WorkspaceSyncBinding(
            accountID: FounderAccountID(rawValue: UUID()),
            workspaceID: binding.workspaceID,
            deviceID: binding.deviceID,
            identityProvider: .apple,
            boundAt: fixture.date(30)
        )
        let error = await captureSyncError {
            try await repository.bindSync(replacementBinding)
        }
        #expect(error == .identityReplacementRequiresDisposition)
        #expect(try await repository.syncBinding() == binding)

        let reopened = try await fixture.open(initial: nil)
        #expect(try await reopened.syncBinding() == binding)
        #expect(try await reopened.pendingSyncBatch().requiresCanonicalBootstrap)
    }

    @Test
    func missingAndExtraFieldClocksFailBeforeSnapshotOrOutboxMutation() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let repository = try await fixture.open(initial: fixture.snapshot(title: "Before"))
        let baseline = try await repository.snapshot()
        var replacement = baseline.content
        replacement.openLoops.items[0].title = "After"
        replacement.openLoops.items[0].updatedAt = fixture.date(20)
        replacement.openLoops.updatedAt = fixture.date(20)

        let missing = WorkspaceMutation(
            entityKind: "move",
            entityID: replacement.openLoops.items[0].id.uuidString.lowercased(),
            changedFields: ["title", "updatedAt"],
            fieldClocks: ["title": fixture.date(20)],
            replacement: replacement,
            createdAt: fixture.date(20)
        )
        #expect(
            await captureRepositoryError {
                try await repository.transact(expectedRevision: baseline.revision, mutation: missing)
            } == .invalidMutation(reason: "field clocks must match changed fields exactly")
        )

        let extra = WorkspaceMutation(
            entityKind: "move",
            entityID: replacement.openLoops.items[0].id.uuidString.lowercased(),
            changedFields: ["title"],
            fieldClocks: ["title": fixture.date(20), "updatedAt": fixture.date(20)],
            replacement: replacement,
            createdAt: fixture.date(20)
        )
        #expect(
            await captureRepositoryError {
                try await repository.transact(expectedRevision: baseline.revision, mutation: extra)
            } == .invalidMutation(reason: "field clocks must match changed fields exactly")
        )
        #expect(try await repository.snapshot().revision == .initial)
        #expect(try await repository.pendingOperations().isEmpty)
    }

    @Test
    func schemaTwoMalformedV2ClockMaskIsQuarantinedAndBlockPersistsAcrossRelaunch() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let repository = try await fixture.open(initial: fixture.snapshot(title: "Before"))
        let baseline = try await repository.snapshot()
        var replacement = baseline.content
        replacement.openLoops.items[0].title = "After"
        replacement.openLoops.items[0].updatedAt = fixture.date(20)
        replacement.openLoops.updatedAt = fixture.date(20)
        let mutation = WorkspaceMutation(
            entityKind: "move",
            entityID: replacement.openLoops.items[0].id.uuidString.lowercased(),
            changedFields: ["title", "updatedAt"],
            fieldClocks: ["title": fixture.date(20), "updatedAt": fixture.date(20)],
            replacement: replacement,
            createdAt: fixture.date(20)
        )
        _ = try await repository.transact(expectedRevision: .initial, mutation: mutation)
        try rewriteClockMaskForMigration(
            databaseURL: fixture.databaseURL,
            fieldClocks: ["title": fixture.date(20)],
            schemaVersion: 2
        )

        let migrated = try await fixture.open(initial: nil)
        #expect(try await migrated.pendingOperations().isEmpty)
        let status = try await migrated.syncStatus()
        #expect(status.phase == .adapterBlocked)
        #expect(status.failureCode == "legacy_clock_mask_mismatch")

        let relaunched = try await fixture.open(initial: nil)
        #expect(try await relaunched.pendingOperations().isEmpty)
        #expect(try await relaunched.syncStatus().failureCode == "legacy_clock_mask_mismatch")
    }

    @Test
    func inboundAndStaleLocalPatchesMergeByEntityAndCreateNoRemoteEcho() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        var initial = fixture.snapshot(title: "Move A")
        let moveB = TestFixtures.loop(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            title: "Move B",
            details: "Local B",
            createdAt: fixture.date(10),
            updatedAt: fixture.date(10)
        )
        initial.openLoops.items.append(moveB)
        let repository = try await fixture.open(initial: initial)
        let binding = try fixture.syncBinding()
        try await repository.bindSync(binding)

        let remote = try makeMoveChange(
            cursor: 1,
            operationID: UUID(),
            moveID: moveB.id,
            revision: 1,
            changedFields: ["details"],
            title: moveB.title,
            details: "Remote B",
            priority: moveB.priority,
            dueOn: nil,
            clock: fixture.date(40)
        )
        try await repository.applyRemotePage(
            try makePullResponse(workspaceID: binding.workspaceID, from: 0, changes: [remote])
        )
        #expect(try await repository.pendingOperations().isEmpty)

        var staleDocument = initial.openLoops
        staleDocument.items[0].title = "Local A"
        staleDocument.items[0].updatedAt = fixture.date(50)
        staleDocument.updatedAt = fixture.date(50)
        _ = try await repository.transact(
            patch: WorkspacePatchMutation(
                entityKind: "move",
                entityID: staleDocument.items[0].id.uuidString.lowercased(),
                changedFields: ["title", "updatedAt"],
                fieldClocks: ["title": fixture.date(50), "updatedAt": fixture.date(50)],
                patch: .openLoops(staleDocument),
                createdAt: fixture.date(50)
            )
        )

        let merged = try await repository.snapshot()
        #expect(merged.content.openLoops.items[0].title == "Local A")
        #expect(merged.content.openLoops.items[1].details == "Remote B")
        #expect(try await repository.pendingOperations().count == 1)
        #expect(try await repository.syncCursor() == SyncCursor(value: 1))
    }

    @Test
    func offlineDeadlineAndInboundPriorityConvergeWithoutReenqueueingRemoteField() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let repository = try await fixture.open(initial: fixture.snapshot(title: "Move"))
        let binding = try fixture.syncBinding()
        try await repository.bindSync(binding)
        let baseline = try await repository.snapshot()
        let dueAt = PlanningDate.storedDate(for: PlanningDay(year: 2026, month: 10, day: 30)!)
        var local = baseline.content
        local.openLoops.items[0].dueAt = dueAt
        local.openLoops.items[0].dueAtUpdatedAt = fixture.date(20)
        local.openLoops.items[0].updatedAt = fixture.date(20)
        local.openLoops.updatedAt = fixture.date(20)
        let localMutation = WorkspaceMutation(
            entityKind: "move",
            entityID: local.openLoops.items[0].id.uuidString.lowercased(),
            changedFields: ["dueAt", "dueAtUpdatedAt", "updatedAt"],
            fieldClocks: [
                "dueAt": fixture.date(20),
                "dueAtUpdatedAt": fixture.date(20),
                "updatedAt": fixture.date(20),
            ],
            replacement: local,
            createdAt: fixture.date(20)
        )
        _ = try await repository.transact(expectedRevision: baseline.revision, mutation: localMutation)
        let beforePullCount = try await repository.pendingOperations().count

        let remote = try makeMoveChange(
            cursor: 1,
            operationID: UUID(),
            moveID: local.openLoops.items[0].id,
            revision: 1,
            changedFields: ["priority"],
            title: local.openLoops.items[0].title,
            details: local.openLoops.items[0].details,
            priority: .p0,
            dueOn: nil,
            clock: fixture.date(40)
        )
        try await repository.applyRemotePage(
            try makePullResponse(workspaceID: binding.workspaceID, from: 0, changes: [remote])
        )

        let merged = try await repository.snapshot()
        #expect(merged.content.openLoops.items[0].dueAt == dueAt)
        #expect(merged.content.openLoops.items[0].priority == .p0)
        #expect(try await repository.pendingOperations().count == beforePullCount)
    }

    @Test
    func inboundPageIsAtomicPersistsCursorAndDedupeAndNeverCreatesOutboxEcho() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let repository = try await fixture.open(initial: fixture.snapshot(title: "Before"))
        let binding = try fixture.syncBinding()
        try await repository.bindSync(binding)
        let moveID = try #require(try await repository.snapshot().content.openLoops.items.first?.id)
        let moveOperationID = UUID()
        let validMove = try makeMoveChange(
            cursor: 1,
            operationID: moveOperationID,
            moveID: moveID,
            revision: 1,
            changedFields: ["title"],
            title: "Remote",
            details: "",
            priority: .p1,
            dueOn: nil,
            clock: fixture.date(40)
        )
        let blockedAsset = try makeAssetChange(
            cursor: 2,
            operationID: UUID(),
            workspaceID: binding.workspaceID,
            clock: fixture.date(41)
        )
        let rejectedPage = try makePullResponse(
            workspaceID: binding.workspaceID,
            from: 0,
            changes: [validMove, blockedAsset]
        )
        #expect(await captureSyncError { try await repository.applyRemotePage(rejectedPage) } == .assetsDisabled)
        #expect(try await repository.snapshot().content.openLoops.items[0].title == "Before")
        #expect(try await repository.syncCursor() == SyncCursor(value: 0))
        #expect(try await repository.remoteRevision(entityType: .move, entityID: moveID) == 0)
        #expect(try await repository.pendingOperations().isEmpty)

        let stream = await repository.remoteChanges()
        let event = Task { await firstRemoteChange(from: stream) }
        try await repository.applyRemotePage(
            try makePullResponse(workspaceID: binding.workspaceID, from: 0, changes: [validMove])
        )
        #expect(await event.value?.content.openLoops.items[0].title == "Remote")
        #expect(try await repository.syncCursor() == SyncCursor(value: 1))
        #expect(try await repository.remoteRevision(entityType: .move, entityID: moveID) == 1)
        #expect(try await repository.pendingOperations().isEmpty)

        let replayAtNewCursor = try makeMoveChange(
            cursor: 2,
            operationID: moveOperationID,
            moveID: moveID,
            revision: 2,
            changedFields: ["title"],
            title: "Duplicate must not apply",
            details: "",
            priority: .p1,
            dueOn: nil,
            clock: fixture.date(50)
        )
        let duplicatePage = try makePullResponse(
            workspaceID: binding.workspaceID,
            from: 1,
            changes: [replayAtNewCursor]
        )
        #expect(await captureSyncError { try await repository.applyRemotePage(duplicatePage) } == .invalidCursor)
        #expect(try await repository.snapshot().content.openLoops.items[0].title == "Remote")
        #expect(try await repository.syncCursor() == SyncCursor(value: 1))

        let reopened = try await fixture.open(initial: nil)
        #expect(try await reopened.syncCursor() == SyncCursor(value: 1))
        #expect(try await reopened.snapshot().content.openLoops.items[0].title == "Remote")
        #expect(try await reopened.pendingOperations().isEmpty)
    }

    @Test
    func canonicalBootstrapReceiptRejectsWrongProofReplaysAfterDeletionAndNeverSkipsPullCursor() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let repository = try await fixture.open(initial: fixture.snapshot(title: "Before"))
        let baseline = try await repository.snapshot()
        var replacement = baseline.content
        replacement.openLoops.items[0].title = "Canonical"
        _ = try await repository.transact(
            expectedRevision: baseline.revision,
            mutation: fixture.mutation(replacement: replacement)
        )
        let binding = try fixture.syncBinding()
        try await repository.bindSync(binding)
        let plan = try await repository.canonicalBootstrapPlan()
        let bootstrap = try makeBootstrapResponse(binding: binding, plan: plan, latestCursor: 7)
        let response = try makePushResponse(
            workspaceID: binding.workspaceID,
            operations: plan.operations,
            startingCursor: 8,
            revisionOffset: 0
        )

        let wrongDigestPlan = WorkspaceCanonicalBootstrapPlan(
            localWorkspaceID: plan.localWorkspaceID,
            remoteWorkspaceID: plan.remoteWorkspaceID,
            localRevision: plan.localRevision,
            snapshotDigest: Data(repeating: 0xA5, count: 32),
            workspaceName: plan.workspaceName,
            profileDisplayName: plan.profileDisplayName,
            operations: plan.operations
        )
        #expect(
            await captureSyncError {
                try await repository.acknowledgeCanonicalBootstrap(
                    plan: wrongDigestPlan,
                    bootstrap: bootstrap,
                    responses: [response]
                )
            } == .bootstrapRevisionChanged
        )
        #expect(try await repository.pendingOperations().count == 1)

        let receipt = try await repository.acknowledgeCanonicalBootstrap(
            plan: plan,
            bootstrap: bootstrap,
            responses: [response]
        )
        #expect(receipt.remoteWorkspaceID == binding.workspaceID)
        #expect(try await repository.pendingOperations().isEmpty)
        #expect(!(try await repository.pendingSyncBatch().requiresCanonicalBootstrap))
        #expect(try await repository.syncCursor() == SyncCursor(value: 0))

        let moveOperation = try #require(plan.operations.first { $0.entityType == .move })
        let acceptedRevision = try await repository.remoteRevision(
            entityType: .move,
            entityID: moveOperation.entityID
        )
        let reopened = try await fixture.open(initial: nil)
        let replay = try await reopened.acknowledgeCanonicalBootstrap(
            plan: plan,
            bootstrap: bootstrap,
            responses: [response]
        )
        #expect(replay == receipt)
        #expect(try await reopened.syncCursor() == SyncCursor(value: 0))

        // This valid-looking but different server proof reaches the receipt
        // check only after revision writes. The thrown transaction must roll
        // every provisional write back.
        let interruptedProof = try makePushResponse(
            workspaceID: binding.workspaceID,
            operations: plan.operations,
            startingCursor: 100,
            revisionOffset: 100
        )
        #expect(
            await captureSyncError {
                try await reopened.acknowledgeCanonicalBootstrap(
                    plan: plan,
                    bootstrap: bootstrap,
                    responses: [interruptedProof]
                )
            } == .bootstrapResponseMismatch
        )
        #expect(
            try await reopened.remoteRevision(
                entityType: .move,
                entityID: moveOperation.entityID
            ) == acceptedRevision
        )
        #expect(try await reopened.syncCursor() == SyncCursor(value: 0))
    }

    @Test
    func conflictPersistenceChecksExactOutboxIdentityAndKeepsOtherOperations() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let repository = try await fixture.open(initial: fixture.snapshot(title: "Before"))
        let binding = try fixture.syncBinding()
        try await repository.bindSync(binding)

        // Conflicts are meaningful only after the server has accepted the
        // canonical bootstrap and established positive entity revisions.
        let bootstrapPlan = try await repository.canonicalBootstrapPlan()
        let bootstrap = try makeBootstrapResponse(
            binding: binding,
            plan: bootstrapPlan,
            latestCursor: 0
        )
        let bootstrapResponse = try makePushResponse(
            workspaceID: binding.workspaceID,
            operations: bootstrapPlan.operations,
            startingCursor: 1,
            revisionOffset: 0
        )
        _ = try await repository.acknowledgeCanonicalBootstrap(
            plan: bootstrapPlan,
            bootstrap: bootstrap,
            responses: [bootstrapResponse]
        )

        var firstContent = try await repository.snapshot().content
        firstContent.openLoops.items[0].title = "First local"
        let firstMutation = fixture.mutation(replacement: firstContent)
        let bootstrapRevision = try await repository.snapshot().revision
        _ = try await repository.transact(
            expectedRevision: bootstrapRevision,
            mutation: firstMutation
        )
        let afterFirst = try await repository.snapshot()
        var secondContent = afterFirst.content
        secondContent.openLoops.items[0].details = "Second local"
        secondContent.openLoops.items[0].updatedAt = fixture.date(30)
        secondContent.openLoops.updatedAt = fixture.date(30)
        let secondMutation = WorkspaceMutation(
            entityKind: "move",
            entityID: secondContent.openLoops.items[0].id.uuidString.lowercased(),
            changedFields: ["details", "updatedAt"],
            fieldClocks: ["details": fixture.date(30), "updatedAt": fixture.date(30)],
            replacement: secondContent,
            createdAt: fixture.date(30)
        )
        _ = try await repository.transact(expectedRevision: afterFirst.revision, mutation: secondMutation)
        let pending = try await repository.pendingOperations()
        #expect(pending.count == 2)

        let moveID = secondContent.openLoops.items[0].id
        let serverRecord = moveRecord(
            moveID: moveID,
            revision: 1,
            title: "Server",
            details: "",
            priority: .p1,
            dueOn: nil,
            clockFields: ["title"],
            clock: fixture.date(40)
        )
        let conflict = try SyncConflict(
            operationID: SyncOperationID(rawValue: firstMutation.operationID),
            entityType: .move,
            entityID: moveID,
            baseRevision: 0,
            currentRevision: 1,
            reason: .overlappingChanges,
            conflictingFields: ["title"],
            serverRecord: serverRecord
        )
        let persisted = try WorkspacePersistedSyncConflict(
            workspaceID: binding.workspaceID,
            conflict: conflict,
            recordedAt: fixture.date(40)
        )
        try await repository.acknowledgeRemoteOperations([], conflicts: [persisted])

        let remaining = try await repository.pendingOperations()
        #expect(remaining.map(\.operationID) == [secondMutation.operationID])
        #expect(try await repository.persistedSyncConflicts().map(\.conflict) == [conflict])
        #expect(try await repository.syncStatus().phase == .conflictReviewRequired)

        // Exact replay is idempotent; altered conflict evidence is rejected.
        try await repository.acknowledgeRemoteOperations([], conflicts: [persisted])
        let altered = try WorkspacePersistedSyncConflict(
            workspaceID: binding.workspaceID,
            conflict: try SyncConflict(
                operationID: conflict.operationID,
                entityType: conflict.entityType,
                entityID: conflict.entityID,
                baseRevision: conflict.baseRevision,
                currentRevision: conflict.currentRevision,
                reason: .fieldClockLost,
                conflictingFields: conflict.conflictingFields,
                serverRecord: conflict.serverRecord
            ),
            recordedAt: fixture.date(41)
        )
        #expect(
            await captureSyncError {
                try await repository.acknowledgeRemoteOperations([], conflicts: [altered])
            } == .invalidConflict
        )
        #expect(try await repository.pendingOperations().count == 1)

        let reopened = try await fixture.open(initial: nil)
        #expect(try await reopened.persistedSyncConflicts().count == 1)
        #expect(try await reopened.syncStatus().phase == .conflictReviewRequired)
    }

    @Test
    func workspaceTenancyRejectsOtherLocalAndRemoteWorkspaceIdentifiers() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let repository = try await fixture.open(initial: fixture.snapshot(title: "A"))
        let wrongBinding = try WorkspaceSyncBinding(
            accountID: FounderAccountID(rawValue: UUID()),
            workspaceID: WorkspaceID(rawValue: UUID()),
            deviceID: DeviceID(rawValue: UUID()),
            identityProvider: .google,
            boundAt: fixture.date(20)
        )
        #expect(await captureSyncError { try await repository.bindSync(wrongBinding) } == .bindingMismatch)

        let binding = try fixture.syncBinding()
        try await repository.bindSync(binding)
        let otherWorkspace = WorkspaceID(rawValue: UUID())
        let otherPage = try makePullResponse(workspaceID: otherWorkspace, from: 0, changes: [])
        #expect(await captureSyncError { try await repository.applyRemotePage(otherPage) } == .bindingMismatch)
        #expect(try await repository.syncCursor() == SyncCursor(value: 0))
        #expect(try await repository.snapshot().content.openLoops.items[0].title == "A")
    }
}

struct WorkspaceV2SyncAdapterTests {
    @Test
    func moveAdapterMapsDeadlineStatusPayloadAndClocksExactly() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let repository = try await fixture.open(initial: fixture.snapshot(title: "Move"))
        let baseline = try await repository.snapshot()
        let dueAt = PlanningDate.storedDate(for: PlanningDay(year: 2026, month: 10, day: 30)!)
        var replacement = baseline.content
        replacement.openLoops.items[0].status = .waiting
        replacement.openLoops.items[0].dueAt = dueAt
        replacement.openLoops.items[0].updatedAt = fixture.date(20)
        replacement.openLoops.updatedAt = fixture.date(20)
        let mutation = WorkspaceMutation(
            entityKind: "move",
            entityID: replacement.openLoops.items[0].id.uuidString.lowercased(),
            changedFields: ["dueAt", "status", "updatedAt"],
            fieldClocks: [
                "dueAt": fixture.date(20),
                "status": fixture.date(20),
                "updatedAt": fixture.date(20),
            ],
            replacement: replacement,
            createdAt: fixture.date(20)
        )
        _ = try await repository.transact(expectedRevision: baseline.revision, mutation: mutation)
        let local = try #require(try await repository.pendingOperations().first)
        guard case let .localEntity(envelope) = try local.decodedLocalPayload() else {
            Issue.record("Expected v2 local entity")
            return
        }
        let wire = try WorkspaceV2SyncAdapter.adapt(
            operation: local,
            envelope: envelope,
            remoteBaseRevision: 1,
            workspaceID: WorkspaceID(rawValue: fixture.workspaceID)
        )
        #expect(wire.changedFields == ["dueOn", "status"])
        #expect(Set(wire.fieldClocks.keys) == Set(wire.changedFields))
        #expect(wire.payload?["dueOn"] == .string("2026-10-30"))
        #expect(wire.payload?["status"] == .string("blocked"))
    }

    @Test
    func profileAndAssetAdaptersRemainFailClosed() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let repository = try await fixture.open(initial: fixture.snapshot(title: "Move"))
        let baseline = try await repository.snapshot()
        var profileContent = baseline.content
        profileContent.personalization.preferredName = "Ada"
        profileContent.personalization.updatedAt = fixture.date(20)
        let profileMutation = WorkspaceMutation(
            entityKind: "profile",
            entityID: "profile",
            changedFields: ["preferredName", "updatedAt"],
            fieldClocks: ["preferredName": fixture.date(20), "updatedAt": fixture.date(20)],
            replacement: profileContent,
            createdAt: fixture.date(20)
        )
        _ = try await repository.transact(expectedRevision: baseline.revision, mutation: profileMutation)
        let profileOperation = try #require(try await repository.pendingOperations().first)
        guard case let .localEntity(profileEnvelope) = try profileOperation.decodedLocalPayload() else {
            Issue.record("Expected profile envelope")
            return
        }
        #expect(
            captureAdapterError {
                try WorkspaceV2SyncAdapter.adapt(
                    operation: profileOperation,
                    envelope: profileEnvelope,
                    remoteBaseRevision: 1,
                    workspaceID: WorkspaceID(rawValue: fixture.workspaceID)
                )
            } == .profileRequiresReviewedBootstrap
        )
    }
}

struct WorkspaceSyncCoordinatorTests {
    @Test
    func coordinatorStaysLocalOnlyWithoutBindingAndNeverTouchesTransport() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let repository = try await fixture.open(initial: fixture.snapshot(title: "Move"))
        let transport = RecordingSyncTransport()
        let coordinator = try WorkspaceSyncCoordinator(
            repository: repository,
            auth: FixedAuthSession(session: nil),
            transport: transport,
            jitter: { 1 }
        )
        #expect(await coordinator.synchronizeNow() == .localOnly)
        #expect(await transport.calls().isEmpty)
        #expect(try await repository.syncStatus().phase == .localOnly)
    }

    @Test
    func coordinatorBootstrapsThenPushesBeforePullAndPersistsCompletion() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let repository = try await fixture.open(initial: fixture.snapshot(title: "Move"))
        let binding = try fixture.syncBinding()
        try await repository.bindSync(binding)
        let transport = RecordingSyncTransport()
        let coordinator = try WorkspaceSyncCoordinator(
            repository: repository,
            auth: FixedAuthSession(session: binding.session),
            transport: transport,
            jitter: { 1 }
        )
        #expect(await coordinator.synchronizeNow() == .synchronized)
        #expect(await transport.calls() == ["bootstrap", "push", "pull"])
        #expect(!(try await repository.pendingSyncBatch().requiresCanonicalBootstrap))
        #expect(try await repository.syncCursor() == SyncCursor(value: 0))

        let reopened = try await fixture.open(initial: nil)
        #expect(!(try await reopened.pendingSyncBatch().requiresCanonicalBootstrap))
    }

    @Test
    func revokedOrMismatchedSessionFailsClosedWithoutPulling() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let repository = try await fixture.open(initial: fixture.snapshot(title: "Move"))
        let binding = try fixture.syncBinding()
        try await repository.bindSync(binding)
        let transport = RecordingSyncTransport(failure: .unauthorized)
        let revoked = try WorkspaceSyncCoordinator(
            repository: repository,
            auth: FixedAuthSession(session: binding.session),
            transport: transport
        )
        #expect(await revoked.synchronizeNow() == .authenticationRequired)
        #expect(await transport.calls() == ["bootstrap"])
        #expect(try await repository.syncStatus().failureCode == "session_revoked")

        let otherSession = AuthSession(
            accountID: FounderAccountID(rawValue: UUID()),
            workspaceID: binding.workspaceID,
            deviceID: binding.deviceID,
            identityProvider: .google
        )
        let untouchedTransport = RecordingSyncTransport()
        let mismatched = try WorkspaceSyncCoordinator(
            repository: repository,
            auth: FixedAuthSession(session: otherSession),
            transport: untouchedTransport
        )
        #expect(await mismatched.synchronizeNow() == .authenticationRequired)
        #expect(await untouchedTransport.calls().isEmpty)
    }

    @Test
    func coordinatorConfigurationBoundsAreEnforced() {
        #expect(throws: WorkspaceSyncRepositoryError.requestBoundsExceeded) {
            _ = try WorkspaceSyncCoordinatorConfiguration(maximumPullPagesPerRun: 201)
        }
        #expect(throws: WorkspaceSyncRepositoryError.requestBoundsExceeded) {
            _ = try WorkspaceSyncCoordinatorConfiguration(pushByteLimit: 0)
        }
        #expect(throws: WorkspaceSyncRepositoryError.requestBoundsExceeded) {
            _ = try WorkspaceSyncCoordinatorConfiguration(maximumConsecutiveRunsPerTrigger: 5)
        }
    }

    @Test
    func oneTriggerHasAHardContinuationBudgetAgainstEndlessPages() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let repository = try await fixture.open(initial: fixture.snapshot(title: "Move"))
        let binding = try fixture.syncBinding()
        try await repository.bindSync(binding)
        let plan = try await repository.canonicalBootstrapPlan()
        let bootstrap = try makeBootstrapResponse(binding: binding, plan: plan, latestCursor: 0)
        let push = try makePushResponse(
            workspaceID: binding.workspaceID,
            operations: plan.operations,
            startingCursor: 1,
            revisionOffset: 0
        )
        _ = try await repository.acknowledgeCanonicalBootstrap(
            plan: plan,
            bootstrap: bootstrap,
            responses: [push]
        )

        let transport = EndlessPullTransport(workspaceID: binding.workspaceID)
        let configuration = try WorkspaceSyncCoordinatorConfiguration(
            maximumPushBatchesPerRun: 1,
            maximumPullPagesPerRun: 1,
            maximumConsecutiveRunsPerTrigger: 2
        )
        let coordinator = try WorkspaceSyncCoordinator(
            repository: repository,
            auth: FixedAuthSession(session: binding.session),
            transport: transport,
            configuration: configuration,
            jitter: { 1 }
        )
        await coordinator.start()
        try await Task.sleep(for: .milliseconds(250))
        await coordinator.stop()

        #expect(await transport.pullCount() == 2)
        #expect(try await repository.syncCursor() == SyncCursor(value: 2))
    }

    @Test
    func externalLocalChangeDuringFinalRunIsPreservedAsFreshBoundedDrain() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let repository = try await fixture.open(initial: fixture.snapshot(title: "Move"))
        let binding = try fixture.syncBinding()
        try await repository.bindSync(binding)
        let plan = try await repository.canonicalBootstrapPlan()
        _ = try await repository.acknowledgeCanonicalBootstrap(
            plan: plan,
            bootstrap: makeBootstrapResponse(binding: binding, plan: plan, latestCursor: 0),
            responses: [
                makePushResponse(
                    workspaceID: binding.workspaceID,
                    operations: plan.operations,
                    startingCursor: 1,
                    revisionOffset: 0
                ),
            ]
        )
        let transport = GatedEndlessPullTransport(workspaceID: binding.workspaceID)
        let coordinator = try WorkspaceSyncCoordinator(
            repository: repository,
            auth: FixedAuthSession(session: binding.session),
            transport: transport,
            configuration: WorkspaceSyncCoordinatorConfiguration(
                maximumPushBatchesPerRun: 1,
                maximumPullPagesPerRun: 1,
                maximumConsecutiveRunsPerTrigger: 2
            )
        )
        await coordinator.start()
        try await waitUntil { await transport.isSecondPullWaiting() }

        let current = try await repository.snapshot()
        var replacement = current.content
        replacement.openLoops.items[0].title = "Created during final pull"
        replacement.openLoops.items[0].updatedAt = fixture.date(60)
        replacement.openLoops.updatedAt = fixture.date(60)
        let mutation = WorkspaceMutation(
            entityKind: "move",
            entityID: replacement.openLoops.items[0].id.uuidString.lowercased(),
            changedFields: ["title", "updatedAt"],
            fieldClocks: ["title": fixture.date(60), "updatedAt": fixture.date(60)],
            replacement: replacement,
            createdAt: fixture.date(60)
        )
        _ = try await repository.transact(
            expectedRevision: current.revision,
            mutation: mutation
        )
        await transport.releaseSecondPull()
        try await waitUntil {
            let pushCount = await transport.pushCount()
            let pullCount = await transport.pullCount()
            return pushCount == 1 && pullCount >= 4
        }
        await coordinator.stop()

        #expect(await transport.pushCount() == 1)
        #expect(await transport.pullCount() == 4)
        #expect(try await repository.pendingOperations().isEmpty)
    }

    @Test
    func concurrentManualAndAutomaticRunsCoalesceBootstrapAndPush() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let repository = try await fixture.open(initial: fixture.snapshot(title: "Move"))
        let binding = try fixture.syncBinding()
        try await repository.bindSync(binding)
        let transport = GatedBootstrapTransport(binding: binding)
        let coordinator = try WorkspaceSyncCoordinator(
            repository: repository,
            auth: FixedAuthSession(session: binding.session),
            transport: transport
        )
        await coordinator.start()
        try await waitUntil { await transport.isBootstrapWaiting() }

        let manual = Task { await coordinator.synchronizeNow() }
        await coordinator.trigger(.networkAvailable)
        await transport.releaseBootstrap()
        #expect(await manual.value == .synchronized)
        try await waitUntil { await transport.pullCount() >= 2 }
        await coordinator.stop()

        #expect(await transport.bootstrapCount() == 1)
        #expect(await transport.pushCount() == 1)
        let pushedIDs = await transport.pushedOperationIDs()
        #expect(pushedIDs.count == Set(pushedIDs).count)
        #expect(!(try await repository.pendingSyncBatch().requiresCanonicalBootstrap))
    }
}

private struct FixedAuthSession: AuthSessionProviding {
    let session: AuthSession?
    func currentSession() async throws -> AuthSession? { session }
}

private actor RecordingSyncTransport: WorkspaceSyncTransport {
    private var recorded: [String] = []
    private let failure: WorkspaceSyncTransportFailure?

    init(failure: WorkspaceSyncTransportFailure? = nil) {
        self.failure = failure
    }

    func calls() -> [String] { recorded }

    func bootstrapWorkspace(
        deviceID: DeviceID,
        localWorkspaceID: WorkspaceID?,
        workspaceName: String,
        displayName: String?
    ) async throws -> WorkspaceBootstrap {
        recorded.append("bootstrap")
        if let failure { throw failure }
        let workspaceID = try #require(localWorkspaceID)
        let binding = try WorkspaceSyncBinding(
            accountID: FounderAccountID(
                rawValue: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
            ),
            workspaceID: workspaceID,
            deviceID: deviceID,
            identityProvider: .google,
            boundAt: Date(timeIntervalSince1970: 0)
        )
        // Tests using this mock bind the same fixed account through the
        // fixture below.
        let plan = WorkspaceCanonicalBootstrapPlan(
            localWorkspaceID: workspaceID.rawValue,
            remoteWorkspaceID: workspaceID,
            localRevision: .initial,
            snapshotDigest: Data(),
            workspaceName: workspaceName,
            profileDisplayName: displayName,
            operations: []
        )
        return try makeBootstrapResponse(binding: binding, plan: plan, latestCursor: 0)
    }

    func pushOperations(
        session: AuthSession,
        operations: [SyncOperation]
    ) async throws -> SyncPushResponse {
        recorded.append("push")
        if let failure { throw failure }
        return try makePushResponse(
            workspaceID: session.workspaceID,
            operations: operations,
            startingCursor: 1,
            revisionOffset: 0
        )
    }

    func pullChanges(
        session: AuthSession,
        after cursor: SyncCursor,
        limit: Int
    ) async throws -> SyncPullResponse {
        recorded.append("pull")
        if let failure { throw failure }
        return try makePullResponse(
            workspaceID: session.workspaceID,
            from: cursor.value,
            changes: []
        )
    }

    func exportWorkspace(session: AuthSession) async throws -> WorkspaceExport {
        throw WorkspaceSyncTransportFailure.rejected
    }

    func eraseWorkspace(
        session: AuthSession,
        confirming workspaceID: WorkspaceID
    ) async throws -> WorkspaceEraseReceipt {
        throw WorkspaceSyncTransportFailure.rejected
    }
}

private actor EndlessPullTransport: WorkspaceSyncTransport {
    private let workspaceID: WorkspaceID
    private var pulls = 0

    init(workspaceID: WorkspaceID) {
        self.workspaceID = workspaceID
    }

    func pullCount() -> Int { pulls }

    func bootstrapWorkspace(
        deviceID: DeviceID,
        localWorkspaceID: WorkspaceID?,
        workspaceName: String,
        displayName: String?
    ) async throws -> WorkspaceBootstrap {
        throw WorkspaceSyncTransportFailure.rejected
    }

    func pushOperations(
        session: AuthSession,
        operations: [SyncOperation]
    ) async throws -> SyncPushResponse {
        throw WorkspaceSyncTransportFailure.rejected
    }

    func pullChanges(
        session: AuthSession,
        after cursor: SyncCursor,
        limit: Int
    ) async throws -> SyncPullResponse {
        pulls += 1
        let next = cursor.value + 1
        let clock = Date(timeIntervalSince1970: TimeInterval(100 + next))
        let timestamp = WorkspaceV2SyncAdapter.timestamp(clock)
        let change = try SyncChange(
            cursor: SyncCursor(value: next),
            operationID: SyncOperationID(rawValue: deterministicUUID(next)),
            entityType: .workspace,
            entityID: workspaceID.rawValue,
            action: .upsert,
            revision: next + 10,
            changedFields: ["name"],
            changedAt: clock,
            record: [
                "id": .string(workspaceID.rawValue.uuidString.lowercased()),
                "name": .string("Hostile page \(next)"),
                "revision": .integer(next + 10),
                "fieldClocks": .object(["name": .string(timestamp)]),
                "createdAt": .string(WorkspaceV2SyncAdapter.timestamp(Date(timeIntervalSince1970: 10))),
                "updatedAt": .string(timestamp),
            ]
        )
        return try makePullResponse(
            workspaceID: workspaceID,
            from: cursor.value,
            changes: [change],
            hasMore: true,
            latestCursor: next + 100
        )
    }

    func exportWorkspace(session: AuthSession) async throws -> WorkspaceExport {
        throw WorkspaceSyncTransportFailure.rejected
    }

    func eraseWorkspace(
        session: AuthSession,
        confirming workspaceID: WorkspaceID
    ) async throws -> WorkspaceEraseReceipt {
        throw WorkspaceSyncTransportFailure.rejected
    }
}

private actor GatedEndlessPullTransport: WorkspaceSyncTransport {
    private let workspaceID: WorkspaceID
    private var pulls = 0
    private var pushes = 0
    private var secondPullWaiting = false
    private var secondPullContinuation: CheckedContinuation<Void, Never>?

    init(workspaceID: WorkspaceID) { self.workspaceID = workspaceID }
    func pullCount() -> Int { pulls }
    func pushCount() -> Int { pushes }
    func isSecondPullWaiting() -> Bool { secondPullWaiting }
    func releaseSecondPull() {
        secondPullContinuation?.resume()
        secondPullContinuation = nil
        secondPullWaiting = false
    }

    func bootstrapWorkspace(
        deviceID: DeviceID,
        localWorkspaceID: WorkspaceID?,
        workspaceName: String,
        displayName: String?
    ) async throws -> WorkspaceBootstrap {
        throw WorkspaceSyncTransportFailure.rejected
    }

    func pushOperations(
        session: AuthSession,
        operations: [SyncOperation]
    ) async throws -> SyncPushResponse {
        pushes += 1
        return try makePushResponse(
            workspaceID: session.workspaceID,
            operations: operations,
            startingCursor: 100,
            revisionOffset: 10
        )
    }

    func pullChanges(
        session: AuthSession,
        after cursor: SyncCursor,
        limit: Int
    ) async throws -> SyncPullResponse {
        pulls += 1
        if pulls == 2 {
            secondPullWaiting = true
            await withCheckedContinuation { secondPullContinuation = $0 }
        }
        return try hostileWorkspacePage(
            workspaceID: workspaceID,
            after: cursor,
            sequence: Int64(pulls)
        )
    }

    func exportWorkspace(session: AuthSession) async throws -> WorkspaceExport {
        throw WorkspaceSyncTransportFailure.rejected
    }
    func eraseWorkspace(
        session: AuthSession,
        confirming workspaceID: WorkspaceID
    ) async throws -> WorkspaceEraseReceipt {
        throw WorkspaceSyncTransportFailure.rejected
    }
}

private actor GatedBootstrapTransport: WorkspaceSyncTransport {
    private let binding: WorkspaceSyncBinding
    private var bootstraps = 0
    private var pushes = 0
    private var pulls = 0
    private var operationIDs: [UUID] = []
    private var bootstrapWaiting = false
    private var bootstrapContinuation: CheckedContinuation<Void, Never>?

    init(binding: WorkspaceSyncBinding) { self.binding = binding }
    func bootstrapCount() -> Int { bootstraps }
    func pushCount() -> Int { pushes }
    func pullCount() -> Int { pulls }
    func pushedOperationIDs() -> [UUID] { operationIDs }
    func isBootstrapWaiting() -> Bool { bootstrapWaiting }
    func releaseBootstrap() {
        bootstrapContinuation?.resume()
        bootstrapContinuation = nil
        bootstrapWaiting = false
    }

    func bootstrapWorkspace(
        deviceID: DeviceID,
        localWorkspaceID: WorkspaceID?,
        workspaceName: String,
        displayName: String?
    ) async throws -> WorkspaceBootstrap {
        bootstraps += 1
        bootstrapWaiting = true
        await withCheckedContinuation { bootstrapContinuation = $0 }
        let workspaceID = try #require(localWorkspaceID)
        let plan = WorkspaceCanonicalBootstrapPlan(
            localWorkspaceID: workspaceID.rawValue,
            remoteWorkspaceID: workspaceID,
            localRevision: .initial,
            snapshotDigest: Data(),
            workspaceName: workspaceName,
            profileDisplayName: displayName,
            operations: []
        )
        return try makeBootstrapResponse(binding: binding, plan: plan, latestCursor: 0)
    }

    func pushOperations(
        session: AuthSession,
        operations: [SyncOperation]
    ) async throws -> SyncPushResponse {
        pushes += 1
        operationIDs.append(contentsOf: operations.map { $0.operationID.rawValue })
        return try makePushResponse(
            workspaceID: session.workspaceID,
            operations: operations,
            startingCursor: 1,
            revisionOffset: 0
        )
    }

    func pullChanges(
        session: AuthSession,
        after cursor: SyncCursor,
        limit: Int
    ) async throws -> SyncPullResponse {
        pulls += 1
        return try makePullResponse(
            workspaceID: session.workspaceID,
            from: cursor.value,
            changes: []
        )
    }

    func exportWorkspace(session: AuthSession) async throws -> WorkspaceExport {
        throw WorkspaceSyncTransportFailure.rejected
    }
    func eraseWorkspace(
        session: AuthSession,
        confirming workspaceID: WorkspaceID
    ) async throws -> WorkspaceEraseReceipt {
        throw WorkspaceSyncTransportFailure.rejected
    }
}

private func captureRepositoryError<Result: Sendable>(
    _ body: @Sendable () async throws -> Result
) async -> WorkspaceRepositoryError? {
    do {
        _ = try await body()
        Issue.record("Expected WorkspaceRepositoryError")
        return nil
    } catch let error as WorkspaceRepositoryError {
        return error
    } catch {
        Issue.record("Unexpected error \(error)")
        return nil
    }
}

private func captureSyncError<Result: Sendable>(
    _ body: @Sendable () async throws -> Result
) async -> WorkspaceSyncRepositoryError? {
    do {
        _ = try await body()
        Issue.record("Expected WorkspaceSyncRepositoryError")
        return nil
    } catch let error as WorkspaceSyncRepositoryError {
        return error
    } catch {
        Issue.record("Unexpected error \(error)")
        return nil
    }
}

private func captureAdapterError<Result>(
    _ body: () throws -> Result
) -> WorkspaceV2SyncAdapterError? {
    do {
        _ = try body()
        Issue.record("Expected WorkspaceV2SyncAdapterError")
        return nil
    } catch let error as WorkspaceV2SyncAdapterError {
        return error
    } catch {
        Issue.record("Unexpected error \(error)")
        return nil
    }
}

private func makeMoveChange(
    cursor: Int64,
    operationID: UUID,
    moveID: UUID,
    revision: Int64,
    changedFields: [String],
    title: String,
    details: String,
    priority: LoopPriority,
    dueOn: String?,
    clock: Date
) throws -> SyncChange {
    try SyncChange(
        cursor: SyncCursor(value: cursor),
        operationID: SyncOperationID(rawValue: operationID),
        entityType: .move,
        entityID: moveID,
        action: .upsert,
        revision: revision,
        changedFields: changedFields,
        changedAt: clock,
        record: moveRecord(
            moveID: moveID,
            revision: revision,
            title: title,
            details: details,
            priority: priority,
            dueOn: dueOn,
            clockFields: changedFields,
            clock: clock
        )
    )
}

private func moveRecord(
    moveID: UUID,
    revision: Int64,
    title: String,
    details: String,
    priority: LoopPriority,
    dueOn: String?,
    clockFields: [String],
    clock: Date
) -> [String: SyncJSONValue] {
    let timestamp = WorkspaceV2SyncAdapter.timestamp(clock)
    return [
        "id": .string(moveID.uuidString.lowercased()),
        "title": .string(title),
        "details": .string(details),
        "status": .string("next"),
        "previousStatus": .null,
        "priority": .string(priority.rawValue),
        "dueOn": dueOn.map(SyncJSONValue.string) ?? .null,
        "completedAt": .null,
        "deletedAt": .null,
        "source": .string("test"),
        "revision": .integer(revision),
        "fieldClocks": .object(
            Dictionary(uniqueKeysWithValues: clockFields.map { ($0, .string(timestamp)) })
        ),
        "createdAt": .string(WorkspaceV2SyncAdapter.timestamp(Date(timeIntervalSince1970: 10))),
        "updatedAt": .string(timestamp),
    ]
}

private func makeAssetChange(
    cursor: Int64,
    operationID: UUID,
    workspaceID: WorkspaceID,
    clock: Date
) throws -> SyncChange {
    let assetID = UUID(uuidString: "88888888-8888-4888-8888-888888888888")!
    let fields = ["kind", "storagePath", "contentType", "byteSize", "sha256"]
    let timestamp = WorkspaceV2SyncAdapter.timestamp(clock)
    return try SyncChange(
        cursor: SyncCursor(value: cursor),
        operationID: SyncOperationID(rawValue: operationID),
        entityType: .asset,
        entityID: assetID,
        action: .upsert,
        revision: 1,
        changedFields: fields,
        changedAt: clock,
        record: [
            "id": .string(assetID.uuidString.lowercased()),
            "kind": .string("visionImage"),
            "storagePath": .string(
                "workspaces/\(workspaceID.rawValue.uuidString.lowercased())/vision-images/\(assetID.uuidString.lowercased()).jpg"
            ),
            "contentType": .string("image/jpeg"),
            "byteSize": .integer(1_024),
            "sha256": .string(String(repeating: "0", count: 64)),
            "deletedAt": .null,
            "revision": .integer(1),
            "fieldClocks": .object(
                Dictionary(uniqueKeysWithValues: fields.map { ($0, .string(timestamp)) })
            ),
            "createdAt": .string(timestamp),
            "updatedAt": .string(timestamp),
        ]
    )
}

private func makePullResponse(
    workspaceID: WorkspaceID,
    from: Int64,
    changes: [SyncChange],
    hasMore: Bool = false,
    latestCursor: Int64? = nil
) throws -> SyncPullResponse {
    struct Encoded: Encodable {
        let contractVersion: Int
        let workspaceId: WorkspaceID
        let fromCursor: SyncCursor
        let nextCursor: SyncCursor
        let latestCursor: SyncCursor
        let hasMore: Bool
        let changes: [SyncChange]
    }
    let next = changes.last?.cursor.value ?? from
    let latest = latestCursor ?? next
    let encoded = Encoded(
        contractVersion: SyncOperation.contractVersion,
        workspaceId: workspaceID,
        fromCursor: try SyncCursor(value: from),
        nextCursor: try SyncCursor(value: next),
        latestCursor: try SyncCursor(value: latest),
        hasMore: hasMore,
        changes: changes
    )
    return try syncDecoder.decode(SyncPullResponse.self, from: syncEncoder.encode(encoded))
}

private func deterministicUUID(_ value: Int64) -> UUID {
    precondition((0...999_999_999_999).contains(value))
    return UUID(
        uuidString: String(
            format: "00000000-0000-4000-8000-%012lld",
            value
        )
    )!
}

private func hostileWorkspacePage(
    workspaceID: WorkspaceID,
    after cursor: SyncCursor,
    sequence: Int64
) throws -> SyncPullResponse {
    let next = cursor.value + 1
    let clock = Date(timeIntervalSince1970: TimeInterval(200 + sequence))
    let timestamp = WorkspaceV2SyncAdapter.timestamp(clock)
    let change = try SyncChange(
        cursor: SyncCursor(value: next),
        operationID: SyncOperationID(rawValue: deterministicUUID(next + 100)),
        entityType: .workspace,
        entityID: workspaceID.rawValue,
        action: .upsert,
        revision: next + 100,
        changedFields: ["name"],
        changedAt: clock,
        record: [
            "id": .string(workspaceID.rawValue.uuidString.lowercased()),
            "name": .string("Gated hostile page \(next)"),
            "revision": .integer(next + 100),
            "fieldClocks": .object(["name": .string(timestamp)]),
            "createdAt": .string(WorkspaceV2SyncAdapter.timestamp(Date(timeIntervalSince1970: 10))),
            "updatedAt": .string(timestamp),
        ]
    )
    return try makePullResponse(
        workspaceID: workspaceID,
        from: cursor.value,
        changes: [change],
        hasMore: true,
        latestCursor: next + 100
    )
}

private func waitUntil(
    _ predicate: @escaping @Sendable () async -> Bool
) async throws {
    for _ in 0..<1_000 {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(1))
    }
    Issue.record("Timed out waiting for asynchronous test state")
}

private func makePushResponse(
    workspaceID: WorkspaceID,
    operations: [SyncOperation],
    startingCursor: Int64,
    revisionOffset: Int64
) throws -> SyncPushResponse {
    struct Encoded: Encodable {
        let contractVersion: Int
        let workspaceId: WorkspaceID
        let latestCursor: SyncCursor
        let results: [SyncOperationResult]
    }
    let results = try operations.enumerated().map { index, operation in
        try SyncOperationResult(
            operationID: operation.operationID,
            status: .accepted,
            revision: revisionOffset + Int64(index + 1),
            cursor: SyncCursor(value: startingCursor + Int64(index)),
            conflict: nil
        )
    }
    let latest = startingCursor + Int64(max(0, operations.count - 1))
    return try syncDecoder.decode(
        SyncPushResponse.self,
        from: syncEncoder.encode(
            Encoded(
                contractVersion: SyncOperation.contractVersion,
                workspaceId: workspaceID,
                latestCursor: try SyncCursor(value: latest),
                results: results
            )
        )
    )
}

private func makeBootstrapResponse(
    binding: WorkspaceSyncBinding,
    plan: WorkspaceCanonicalBootstrapPlan,
    latestCursor: Int64
) throws -> WorkspaceBootstrap {
    struct Encoded: Encodable {
        let contractVersion: Int
        let session: AuthSession
        let profile: FounderProfile
        let workspace: [String: SyncJSONValue]
        let startingCursor: SyncCursor
        let latestCursor: SyncCursor
    }
    let clock = Date(timeIntervalSince1970: 10)
    let timestamp = WorkspaceV2SyncAdapter.timestamp(clock)
    let profile = try FounderProfile(
        accountID: binding.accountID,
        identityProvider: binding.identityProvider,
        displayName: plan.profileDisplayName ?? "Founder"
    )
    let workspace: [String: SyncJSONValue] = [
        "id": .string(binding.workspaceID.rawValue.uuidString.lowercased()),
        "name": .string(plan.workspaceName),
        "revision": .integer(1),
        "fieldClocks": .object(["name": .string(timestamp)]),
        "createdAt": .string(timestamp),
        "updatedAt": .string(timestamp),
    ]
    return try syncDecoder.decode(
        WorkspaceBootstrap.self,
        from: syncEncoder.encode(
            Encoded(
                contractVersion: SyncOperation.contractVersion,
                session: binding.session,
                profile: profile,
                workspace: workspace,
                startingCursor: SyncCursor(value: 0),
                latestCursor: SyncCursor(value: latestCursor)
            )
        )
    )
}

private var syncEncoder: JSONEncoder {
    let value = JSONEncoder()
    value.dateEncodingStrategy = .iso8601
    value.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return value
}

private var syncDecoder: JSONDecoder {
    let value = JSONDecoder()
    value.dateDecodingStrategy = .iso8601
    return value
}

private func firstRemoteChange(
    from stream: AsyncStream<WorkspaceRepositorySnapshot>
) async -> WorkspaceRepositorySnapshot? {
    await withTaskGroup(of: WorkspaceRepositorySnapshot?.self) { group in
        group.addTask {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(2))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

private func rewriteClockMaskForMigration(
    databaseURL: URL,
    fieldClocks: [String: Date],
    schemaVersion: Int
) throws {
    let data = try syncEncoder.encode(fieldClocks)
    let hex = data.map { String(format: "%02x", $0) }.joined()
    var connection: OpaquePointer?
    guard sqlite3_open_v2(
        databaseURL.path,
        &connection,
        SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
        nil
    ) == SQLITE_OK,
    let connection else {
        throw WorkspaceRepositoryError.invalidDatabase
    }
    defer { sqlite3_close_v2(connection) }
    guard sqlite3_busy_timeout(connection, 5_000) == SQLITE_OK,
          sqlite3_exec(
            connection,
            "UPDATE operation_outbox SET field_clocks = X'\(hex)'; PRAGMA user_version = \(schemaVersion);",
            nil,
            nil,
            nil
          ) == SQLITE_OK else {
        throw WorkspaceRepositoryError.invalidDatabase
    }
}
