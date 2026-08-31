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
        let retention = try await migrated.enforceSyncRetention(
            try WorkspaceSyncRetentionPolicy(
                acknowledgementLimit: 1,
                bootstrapReceiptLimit: 1,
                appliedOperationLimit: 1
            )
        )
        #expect(retention.quarantinedOperationCount == 1)

        let relaunched = try await fixture.open(initial: nil)
        #expect(try await relaunched.pendingOperations().isEmpty)
        #expect(try await relaunched.syncStatus().failureCode == "legacy_clock_mask_mismatch")
        #expect(try await relaunched.enforceSyncRetention(
            try WorkspaceSyncRetentionPolicy(
                acknowledgementLimit: 1,
                bootstrapReceiptLimit: 1,
                appliedOperationLimit: 1
            )
        ).quarantinedOperationCount == 1)
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

        let unifiedStream = await repository.events()
        var unifiedIterator = unifiedStream.makeAsyncIterator()
        let initialEvent = await unifiedIterator.next()
        #expect(initialEvent?.origin == .initial)
        #expect(initialEvent?.snapshot.content.openLoops.items[0].title == "Before")
        let stream = await repository.remoteChanges()
        let event = Task { await firstRemoteChange(from: stream) }
        try await repository.applyRemotePage(
            try makePullResponse(workspaceID: binding.workspaceID, from: 0, changes: [validMove])
        )
        let unifiedRemote = await unifiedIterator.next()
        #expect(unifiedRemote?.origin == .remote)
        #expect(unifiedRemote?.snapshot.content.openLoops.items[0].title == "Remote")
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
    func repositoryEventSubscriptionReplaysLatestSnapshotAfterACommitInTheConstructionGap() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let repository = try await fixture.open(initial: fixture.snapshot(title: "Before"))
        let binding = try fixture.syncBinding()
        try await repository.bindSync(binding)
        let beforeSubscription = try await repository.snapshot()
        let moveID = try #require(beforeSubscription.content.openLoops.items.first?.id)
        let remote = try makeMoveChange(
            cursor: 1,
            operationID: UUID(),
            moveID: moveID,
            revision: 1,
            changedFields: ["title"],
            title: "Committed inside gap",
            details: "",
            priority: .p1,
            dueOn: nil,
            clock: fixture.date(40)
        )

        // Model the exact session-construction gap: a caller has read the old
        // snapshot, the remote transaction commits, and only then it obtains
        // the event stream. The first replay must already be the new revision.
        try await repository.applyRemotePage(
            try makePullResponse(workspaceID: binding.workspaceID, from: 0, changes: [remote])
        )
        let events = await repository.events()
        var iterator = events.makeAsyncIterator()
        let replay = try #require(await iterator.next())
        #expect(replay.origin == .initial)
        #expect(replay.snapshot.revision > beforeSubscription.revision)
        #expect(replay.snapshot.content.openLoops.items[0].title == "Committed inside gap")
        #expect(try await repository.pendingOperations().isEmpty)
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
        let baseRemoteRevision = try await repository.remoteRevision(
            entityType: .move,
            entityID: moveID
        )
        let remoteClocksBeforeConflict = try readRemoteFieldClocks(
            databaseURL: fixture.databaseURL,
            entityType: .move,
            entityID: moveID
        )
        let serverRecord = moveRecord(
            moveID: moveID,
            revision: baseRemoteRevision + 1,
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
            baseRevision: baseRemoteRevision,
            currentRevision: baseRemoteRevision + 1,
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
        #expect(remaining.map(\.operationID) == [firstMutation.operationID, secondMutation.operationID])
        #expect(
            try await repository.pendingSyncBatch().operations.map(\.operationID)
                == [secondMutation.operationID]
        )
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
        #expect(try await repository.pendingOperations().count == 2)

        let reopened = try await fixture.open(initial: nil)
        #expect(try await reopened.persistedSyncConflicts().count == 1)
        #expect(try await reopened.syncStatus().phase == .conflictReviewRequired)

        // A later pull may replace the visible field, but it must not erase
        // the exact quarantined local payload required by Keep Mine.
        let laterServerChange = try makeMoveChange(
            cursor: 1,
            operationID: UUID(),
            moveID: moveID,
            revision: baseRemoteRevision + 2,
            changedFields: ["title"],
            title: "Later server value",
            details: "",
            priority: .p1,
            dueOn: nil,
            clock: fixture.date(50)
        )
        try await reopened.applyRemotePage(
            try makePullResponse(
                workspaceID: binding.workspaceID,
                from: 0,
                changes: [laterServerChange]
            )
        )
        let afterPull = try await fixture.open(initial: nil)
        let retainedEvidence = try await afterPull.enforceSyncRetention(
            try WorkspaceSyncRetentionPolicy(
                acknowledgementLimit: 1,
                bootstrapReceiptLimit: 1,
                appliedOperationLimit: 1
            )
        )
        #expect(retainedEvidence.appliedOperationCount == 1)
        #expect(retainedEvidence.appliedOperationLimitReached)
        #expect(retainedEvidence.unresolvedConflictCount == 1)
        #expect(try await afterPull.pendingOperations().count == 2)
        let exactConflict = try #require(
            try await afterPull.persistedSyncConflicts().first
        )
        let resolved = try await afterPull.resolveSyncConflict(
            id: exactConflict.id,
            resolution: .keepMine,
            resolvedAt: fixture.date(60)
        )
        #expect(resolved.origin == .local)
        let reviewedOperationID = try #require(resolved.reviewedOperationID)
        #expect(reviewedOperationID != firstMutation.operationID)
        #expect(resolved.snapshot.content.openLoops.items[0].title == "First local")
        #expect(try await afterPull.persistedSyncConflicts().isEmpty)
        let redeliverable = try await afterPull.pendingSyncBatch().operations
        let retained = try #require(
            redeliverable.first(where: { $0.operationID == reviewedOperationID })
        )
        #expect(!redeliverable.contains(where: { $0.operationID == firstMutation.operationID }))
        #expect(retained.fieldClocks == ["title": fixture.date(60)])
        let remoteClocksAfterPartialConflict = try readRemoteFieldClocks(
            databaseURL: fixture.databaseURL,
            entityType: .move,
            entityID: moveID
        )
        #expect(remoteClocksAfterPartialConflict["title"] == fixture.date(50))
        for (field, clock) in remoteClocksBeforeConflict where field != "title" {
            #expect(remoteClocksAfterPartialConflict[field] == clock)
        }
        guard case let .localEntity(envelope) = try retained.decodedLocalPayload(),
              case let .move(retainedMove) = envelope.record else {
            Issue.record("Expected exact retained Move evidence")
            return
        }
        #expect(retainedMove.title == "First local")
        let reviewedWire = try WorkspaceV2SyncAdapter.adapt(
            operation: retained,
            envelope: envelope,
            remoteBaseRevision: try await afterPull.remoteRevision(
                entityType: .move,
                entityID: moveID
            ),
            workspaceID: binding.workspaceID
        )
        #expect(reviewedWire.baseRevision == baseRemoteRevision + 2)
        #expect(reviewedWire.fieldClocks == ["title": fixture.date(60)])
        #expect(try await afterPull.syncStatus().phase == .idle)

        // The reviewed operation has a new identity, newer clocks, and the
        // latest remote base. It can be accepted instead of deterministically
        // reproducing the original conflict.
        let acceptingTransport = RecordingSyncTransport(revisionOffset: 100)
        let coordinator = try WorkspaceSyncCoordinator(
            repository: afterPull,
            auth: FixedAuthSession(session: binding.session),
            transport: acceptingTransport,
            jitter: { 1 }
        )
        #expect(await coordinator.synchronizeNow() == .synchronized)
        #expect(try await afterPull.pendingOperations().isEmpty)
        #expect(try await afterPull.persistedSyncConflicts().isEmpty)
    }

    @Test
    func cleanRunsAndRelaunchKeepConflictReviewUntilAtomicUseLatestResolution() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let repository = try await fixture.open(initial: fixture.snapshot(title: "Before"))
        let binding = try fixture.syncBinding()
        try await repository.bindSync(binding)
        try await completeCanonicalBootstrap(
            repository: repository,
            binding: binding
        )

        let baseline = try await repository.snapshot()
        var local = baseline.content
        local.openLoops.items[0].title = "Attempted local"
        let mutation = fixture.mutation(replacement: local)
        _ = try await repository.transact(
            expectedRevision: baseline.revision,
            mutation: mutation
        )
        let moveID = local.openLoops.items[0].id
        let baseRevision = try await repository.remoteRevision(
            entityType: .move,
            entityID: moveID
        )
        let remoteClocksBeforeConflict = try readRemoteFieldClocks(
            databaseURL: fixture.databaseURL,
            entityType: .move,
            entityID: moveID
        )
        let conflict = try SyncConflict(
            operationID: SyncOperationID(rawValue: mutation.operationID),
            entityType: .move,
            entityID: moveID,
            baseRevision: baseRevision,
            currentRevision: baseRevision + 1,
            reason: .overlappingChanges,
            conflictingFields: ["title"],
            serverRecord: moveRecord(
                moveID: moveID,
                revision: baseRevision + 1,
                title: "Reviewed server value",
                details: "",
                priority: .p1,
                dueOn: nil,
                clockFields: ["title"],
                clock: fixture.date(30)
            )
        )
        let persisted = try WorkspacePersistedSyncConflict(
            workspaceID: binding.workspaceID,
            conflict: conflict,
            recordedAt: fixture.date(31)
        )
        try await repository.acknowledgeRemoteOperations([], conflicts: [persisted])

        let coordinator = try WorkspaceSyncCoordinator(
            repository: repository,
            auth: FixedAuthSession(session: binding.session),
            transport: RecordingSyncTransport(),
            now: { Date(timeIntervalSince1970: 40) },
            jitter: { 1 }
        )
        #expect(await coordinator.synchronizeNow() == .conflicts(1))
        #expect(try await repository.syncStatus().phase == .conflictReviewRequired)
        #expect(try await repository.pendingSyncBatch().operations.isEmpty)

        let reopened = try await fixture.open(initial: nil)
        #expect(try await reopened.syncStatus().phase == .conflictReviewRequired)
        #expect(try await reopened.unresolvedSyncConflictCount() == 1)
        let events = await reopened.events()
        var iterator = events.makeAsyncIterator()
        #expect((await iterator.next())?.origin == .initial)
        let exactConflict = try #require(
            try await reopened.persistedSyncConflicts().first
        )
        let result = try await reopened.resolveSyncConflict(
            id: exactConflict.id,
            resolution: .useLatest,
            resolvedAt: fixture.date(50)
        )
        let resolutionEvent = try #require(await iterator.next())
        #expect(result.origin == .remote)
        #expect(result.reviewedOperationID == nil)
        #expect(resolutionEvent.origin == .remote)
        #expect(result.snapshot.content.openLoops.items[0].title == "Reviewed server value")
        let remoteClocksAfterPartialConflict = try readRemoteFieldClocks(
            databaseURL: fixture.databaseURL,
            entityType: .move,
            entityID: moveID
        )
        #expect(remoteClocksAfterPartialConflict["title"] == fixture.date(30))
        for (field, clock) in remoteClocksBeforeConflict where field != "title" {
            #expect(remoteClocksAfterPartialConflict[field] == clock)
        }
        #expect(try await reopened.pendingOperations().isEmpty)
        #expect(try await reopened.unresolvedSyncConflictCount() == 0)
        #expect(try await reopened.syncStatus().phase == .idle)

        let afterResolutionRelaunch = try await fixture.open(initial: nil)
        #expect(try await afterResolutionRelaunch.snapshot().content.openLoops.items[0].title
            == "Reviewed server value")
        #expect(try await afterResolutionRelaunch.pendingOperations().isEmpty)
        #expect(try await afterResolutionRelaunch.persistedSyncConflicts().isEmpty)
    }

    @Test
    func partialConflictCannotRegressAnAuthenticatedRemoteFieldClock() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let repository = try await fixture.open(initial: fixture.snapshot(title: "Before"))
        let binding = try fixture.syncBinding()
        try await repository.bindSync(binding)
        try await completeCanonicalBootstrap(repository: repository, binding: binding)

        let baseline = try await repository.snapshot()
        let moveID = baseline.content.openLoops.items[0].id
        let newerRemote = try makeMoveChange(
            cursor: 1,
            operationID: UUID(),
            moveID: moveID,
            revision: try await repository.remoteRevision(
                entityType: .move,
                entityID: moveID
            ) + 1,
            changedFields: ["title"],
            title: "Authenticated newer server value",
            details: "",
            priority: .p1,
            dueOn: nil,
            clock: fixture.date(40)
        )
        try await repository.applyRemotePage(
            try makePullResponse(
                workspaceID: binding.workspaceID,
                from: 0,
                changes: [newerRemote]
            )
        )

        let current = try await repository.snapshot()
        var local = current.content
        local.openLoops.items[0].title = "Local review candidate"
        let mutation = WorkspaceMutation(
            entityKind: "move",
            entityID: moveID.uuidString.lowercased(),
            changedFields: ["title"],
            fieldClocks: ["title": fixture.date(50)],
            replacement: local,
            createdAt: fixture.date(50)
        )
        _ = try await repository.transact(
            expectedRevision: current.revision,
            mutation: mutation
        )
        let knownRevision = try await repository.remoteRevision(
            entityType: .move,
            entityID: moveID
        )
        let regressingConflict = try SyncConflict(
            operationID: SyncOperationID(rawValue: mutation.operationID),
            entityType: .move,
            entityID: moveID,
            baseRevision: knownRevision,
            currentRevision: knownRevision + 1,
            reason: .fieldClockLost,
            conflictingFields: ["title"],
            serverRecord: moveRecord(
                moveID: moveID,
                revision: knownRevision + 1,
                title: "Regressing server evidence",
                details: "",
                priority: .p1,
                dueOn: nil,
                clockFields: ["title"],
                clock: fixture.date(30)
            )
        )
        try await repository.acknowledgeRemoteOperations(
            [],
            conflicts: [
                try WorkspacePersistedSyncConflict(
                    workspaceID: binding.workspaceID,
                    conflict: regressingConflict,
                    recordedAt: fixture.date(60)
                ),
            ]
        )
        let unresolved = try #require(
            try await repository.persistedSyncConflicts().first
        )
        #expect(
            await captureSyncError {
                try await repository.resolveSyncConflict(
                    id: unresolved.id,
                    resolution: .useLatest,
                    resolvedAt: fixture.date(70)
                )
            } == .invalidRemoteRevision
        )
        #expect(try await repository.unresolvedSyncConflictCount() == 1)
        #expect(try await repository.pendingOperations().map(\.operationID)
            == [mutation.operationID])
        #expect(try await repository.snapshot().content.openLoops.items[0].title
            == "Local review candidate")
        let retainedClocks = try readRemoteFieldClocks(
            databaseURL: fixture.databaseURL,
            entityType: .move,
            entityID: moveID
        )
        #expect(retainedClocks["title"] == fixture.date(40))
    }

    @Test
    func staleConflictReviewCannotOverwriteOrDiscardANewerSameFieldLocalEdit() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let repository = try await fixture.open(initial: fixture.snapshot(title: "Before"))
        let binding = try fixture.syncBinding()
        try await repository.bindSync(binding)
        try await completeCanonicalBootstrap(repository: repository, binding: binding)

        let baseline = try await repository.snapshot()
        var first = baseline.content
        first.openLoops.items[0].title = "Old attempted value"
        let oldMutation = fixture.mutation(replacement: first)
        _ = try await repository.transact(
            expectedRevision: baseline.revision,
            mutation: oldMutation
        )
        let moveID = first.openLoops.items[0].id
        let baseRevision = try await repository.remoteRevision(
            entityType: .move,
            entityID: moveID
        )
        let oldConflict = try SyncConflict(
            operationID: SyncOperationID(rawValue: oldMutation.operationID),
            entityType: .move,
            entityID: moveID,
            baseRevision: baseRevision,
            currentRevision: baseRevision + 1,
            reason: .overlappingChanges,
            conflictingFields: ["title"],
            serverRecord: moveRecord(
                moveID: moveID,
                revision: baseRevision + 1,
                title: "Server at old review",
                details: "",
                priority: .p1,
                dueOn: nil,
                clockFields: ["title"],
                clock: fixture.date(30)
            )
        )
        try await repository.acknowledgeRemoteOperations(
            [],
            conflicts: [
                try WorkspacePersistedSyncConflict(
                    workspaceID: binding.workspaceID,
                    conflict: oldConflict,
                    recordedAt: fixture.date(31)
                ),
            ]
        )

        let afterConflict = try await repository.snapshot()
        var latest = afterConflict.content
        latest.openLoops.items[0].title = "Newer local intent"
        latest.openLoops.items[0].updatedAt = fixture.date(40)
        latest.openLoops.updatedAt = fixture.date(40)
        let newerMutation = WorkspaceMutation(
            entityKind: "move",
            entityID: moveID.uuidString.lowercased(),
            changedFields: ["title", "updatedAt"],
            fieldClocks: ["title": fixture.date(40), "updatedAt": fixture.date(40)],
            replacement: latest,
            createdAt: fixture.date(40)
        )
        _ = try await repository.transact(
            expectedRevision: afterConflict.revision,
            mutation: newerMutation
        )
        let unresolved = try #require(
            try await repository.persistedSyncConflicts().first
        )
        #expect(
            await captureSyncError {
                try await repository.resolveSyncConflict(
                    id: unresolved.id,
                    resolution: .keepMine,
                    resolvedAt: fixture.date(50)
                )
            } == .conflictResolutionUnavailable
        )
        #expect(
            await captureSyncError {
                try await repository.resolveSyncConflict(
                    id: unresolved.id,
                    resolution: .useLatest,
                    resolvedAt: fixture.date(50)
                )
            } == .conflictResolutionUnavailable
        )
        #expect(try await repository.snapshot().content.openLoops.items[0].title
            == "Newer local intent")
        #expect(try await repository.pendingOperations().count == 2)
        #expect(try await repository.pendingSyncBatch().operations.map(\.operationID)
            == [newerMutation.operationID])
        #expect(try await repository.unresolvedSyncConflictCount() == 1)

        let retention = try await repository.enforceSyncRetention(
            try WorkspaceSyncRetentionPolicy(
                acknowledgementLimit: 1,
                bootstrapReceiptLimit: 1,
                appliedOperationLimit: 1
            )
        )
        #expect(retention.unresolvedConflictCount == 1)
        #expect(try await repository.pendingOperations().count == 2)
        let relaunched = try await fixture.open(initial: nil)
        #expect(try await relaunched.unresolvedSyncConflictCount() == 1)
        #expect(try await relaunched.pendingOperations().count == 2)
        #expect(try await relaunched.snapshot().content.openLoops.items[0].title
            == "Newer local intent")
    }

    @Test
    func unresolvedConflictProtectsLaterAcknowledgementsAndReportsOnlyUnprunableOverflow() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let repository = try await fixture.open(initial: fixture.snapshot(title: "Before"))
        let binding = try fixture.syncBinding()
        try await repository.bindSync(binding)
        try await completeCanonicalBootstrap(repository: repository, binding: binding)

        let baseline = try await repository.snapshot()
        let moveID = baseline.content.openLoops.items[0].id
        var attempted = baseline.content
        attempted.openLoops.items[0].title = "Conflicted title"
        let conflictedMutation = fixture.mutation(replacement: attempted)
        _ = try await repository.transact(
            expectedRevision: baseline.revision,
            mutation: conflictedMutation
        )
        let baseRemoteRevision = try await repository.remoteRevision(
            entityType: .move,
            entityID: moveID
        )
        let conflict = try SyncConflict(
            operationID: SyncOperationID(rawValue: conflictedMutation.operationID),
            entityType: .move,
            entityID: moveID,
            baseRevision: baseRemoteRevision,
            currentRevision: baseRemoteRevision + 1,
            reason: .overlappingChanges,
            conflictingFields: ["title"],
            serverRecord: moveRecord(
                moveID: moveID,
                revision: baseRemoteRevision + 1,
                title: "Server title",
                details: "",
                priority: .p1,
                dueOn: nil,
                clockFields: ["title"],
                clock: fixture.date(30)
            )
        )
        try await repository.acknowledgeRemoteOperations(
            [],
            conflicts: [
                try WorkspacePersistedSyncConflict(
                    workspaceID: binding.workspaceID,
                    conflict: conflict,
                    recordedAt: fixture.date(31)
                ),
            ]
        )

        for (index, field) in ["details", "priority"].enumerated() {
            let current = try await repository.snapshot()
            let clock = fixture.date(TimeInterval(40 + index))
            var replacement = current.content
            if field == "details" {
                replacement.openLoops.items[0].details = "Accepted disjoint details"
            } else {
                replacement.openLoops.items[0].priority = .p2
            }
            replacement.openLoops.items[0].updatedAt = clock
            replacement.openLoops.updatedAt = clock
            let mutation = WorkspaceMutation(
                entityKind: "move",
                entityID: moveID.uuidString.lowercased(),
                changedFields: [field, "updatedAt"],
                fieldClocks: [field: clock, "updatedAt": clock],
                replacement: replacement,
                createdAt: clock
            )
            _ = try await repository.transact(
                expectedRevision: current.revision,
                mutation: mutation
            )
            let operation = try #require(
                try await repository.pendingOperations().first {
                    $0.operationID == mutation.operationID
                }
            )
            guard case let .localEntity(envelope) = try operation.decodedLocalPayload() else {
                Issue.record("Expected a v2 Move operation")
                return
            }
            let remoteBase = try await repository.remoteRevision(
                entityType: .move,
                entityID: moveID
            )
            let wire = try WorkspaceV2SyncAdapter.adapt(
                operation: operation,
                envelope: envelope,
                remoteBaseRevision: remoteBase,
                workspaceID: binding.workspaceID
            )
            try await repository.acknowledgeRemoteOperations(
                [
                    try WorkspaceRemoteOperationAcknowledgement(
                        localOperationID: operation.operationID,
                        entityType: wire.entityType,
                        entityID: wire.entityID,
                        remoteRevision: remoteBase + 1,
                        fieldClocks: wire.fieldClocks
                    ),
                ],
                conflicts: []
            )
        }

        let report = try await repository.enforceSyncRetention(
            try WorkspaceSyncRetentionPolicy(
                acknowledgementLimit: 1,
                bootstrapReceiptLimit: 1,
                appliedOperationLimit: 10
            )
        )
        #expect(report.acknowledgementsPruned == 0)
        #expect(report.acknowledgementLimitReached)
        #expect(report.unresolvedConflictCount == 1)

        let reopened = try await fixture.open(initial: nil)
        let relaunchedReport = try await reopened.enforceSyncRetention(
            try WorkspaceSyncRetentionPolicy(
                acknowledgementLimit: 1,
                bootstrapReceiptLimit: 1,
                appliedOperationLimit: 10
            )
        )
        #expect(relaunchedReport.acknowledgementLimitReached)
        #expect(try await reopened.unresolvedSyncConflictCount() == 1)
    }

    @Test
    func acknowledgementRetentionIsBoundedAndPrunedReplayFailsClosedAfterRelaunch() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let repository = try await fixture.open(initial: fixture.snapshot(title: "Before"))
        let binding = try fixture.syncBinding()
        try await repository.bindSync(binding)
        try await completeCanonicalBootstrap(repository: repository, binding: binding)
        let moveID = try #require(
            try await repository.snapshot().content.openLoops.items.first?.id
        )
        var acknowledgements: [WorkspaceRemoteOperationAcknowledgement] = []

        for index in 0..<3 {
            let current = try await repository.snapshot()
            let clock = fixture.date(TimeInterval(40 + index))
            var replacement = current.content
            replacement.openLoops.items[0].title = "Accepted local \(index)"
            replacement.openLoops.items[0].updatedAt = clock
            replacement.openLoops.updatedAt = clock
            let mutation = WorkspaceMutation(
                entityKind: "move",
                entityID: moveID.uuidString.lowercased(),
                changedFields: ["title", "updatedAt"],
                fieldClocks: ["title": clock, "updatedAt": clock],
                replacement: replacement,
                createdAt: clock
            )
            _ = try await repository.transact(
                expectedRevision: current.revision,
                mutation: mutation
            )
            let operation = try #require(
                try await repository.pendingOperations().first {
                    $0.operationID == mutation.operationID
                }
            )
            guard case let .localEntity(envelope) = try operation.decodedLocalPayload() else {
                Issue.record("Expected a v2 Move operation")
                return
            }
            let remoteBase = try await repository.remoteRevision(
                entityType: .move,
                entityID: moveID
            )
            let wire = try WorkspaceV2SyncAdapter.adapt(
                operation: operation,
                envelope: envelope,
                remoteBaseRevision: remoteBase,
                workspaceID: binding.workspaceID
            )
            let acknowledgement = try WorkspaceRemoteOperationAcknowledgement(
                localOperationID: operation.operationID,
                entityType: wire.entityType,
                entityID: wire.entityID,
                remoteRevision: remoteBase + 1,
                fieldClocks: wire.fieldClocks
            )
            try await repository.acknowledgeRemoteOperations(
                [acknowledgement],
                conflicts: []
            )
            acknowledgements.append(acknowledgement)
        }
        #expect(try await repository.pendingOperations().isEmpty)

        let report = try await repository.enforceSyncRetention(
            try WorkspaceSyncRetentionPolicy(
                acknowledgementLimit: 1,
                bootstrapReceiptLimit: 1,
                appliedOperationLimit: 10
            )
        )
        #expect(report.acknowledgementsPruned == 2)
        #expect(!report.acknowledgementLimitReached)
        let reopened = try await fixture.open(initial: nil)
        let newestAcknowledgement = try #require(acknowledgements.last)
        let oldestAcknowledgement = acknowledgements[0]
        try await reopened.acknowledgeRemoteOperations(
            [newestAcknowledgement],
            conflicts: []
        )
        #expect(
            await captureSyncError {
                try await reopened.acknowledgeRemoteOperations(
                    [oldestAcknowledgement],
                    conflicts: []
                )
            } == .acknowledgementMismatch
        )
        #expect(try await reopened.pendingOperations().isEmpty)
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

    @Test
    func bootstrapAttemptSurvivesPartialAcceptanceLocalRenameAndRelaunch() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        var initial = fixture.snapshot(title: "Before")
        initial.personalization.workspaceName = "Studio"
        let repository = try await fixture.open(initial: initial)
        let binding = try fixture.syncBinding()
        try await repository.bindSync(binding)

        let pinned = try await repository.canonicalBootstrapPlan()
        #expect(pinned.workspaceName == "Studio")
        #expect(!pinned.operations.contains { $0.entityType == .workspace })
        let acceptedBootstrap = try makeBootstrapResponse(
            binding: binding,
            plan: pinned,
            latestCursor: 0
        )
        let firstAcceptedChunk = try makePushResponse(
            workspaceID: binding.workspaceID,
            operations: Array(pinned.operations.prefix(1)),
            startingCursor: 1,
            revisionOffset: 10
        )
        #expect(
            await captureSyncError {
                try await repository.acknowledgeCanonicalBootstrap(
                    plan: pinned,
                    bootstrap: acceptedBootstrap,
                    responses: [firstAcceptedChunk]
                )
            } == .bootstrapResponseMismatch
        )
        #expect(try await repository.canonicalBootstrapPlan() == pinned)
        #expect(try await repository.pendingSyncBatch().requiresCanonicalBootstrap)

        let acceptedOperations = try makePushResponse(
            workspaceID: binding.workspaceID,
            operations: pinned.operations,
            startingCursor: 1,
            revisionOffset: 10,
            statuses: [.duplicate] + Array(
                repeating: .accepted,
                count: max(0, pinned.operations.count - 1)
            )
        )

        let baseline = try await repository.snapshot()
        var renamed = baseline.content
        renamed.personalization.workspaceName = "Renamed after send"
        renamed.personalization.updatedAt = fixture.date(30)
        _ = try await repository.transact(
            expectedRevision: baseline.revision,
            mutation: WorkspaceMutation(
                entityKind: "workspace",
                entityID: "workspace",
                changedFields: ["updatedAt", "workspaceName"],
                fieldClocks: [
                    "updatedAt": fixture.date(30),
                    "workspaceName": fixture.date(30),
                ],
                replacement: renamed,
                createdAt: fixture.date(30)
            )
        )

        let reopened = try await fixture.open(initial: nil)
        #expect(try await reopened.canonicalBootstrapPlan() == pinned)
        _ = try await reopened.acknowledgeCanonicalBootstrap(
            plan: pinned,
            bootstrap: acceptedBootstrap,
            responses: [acceptedOperations]
        )

        #expect(
            try await reopened.remoteRevision(
                entityType: .workspace,
                entityID: binding.workspaceID.rawValue
            ) == 1
        )
        let pending = try #require(try await reopened.pendingSyncBatch().operations.first)
        guard case let .localEntity(envelope) = try pending.decodedLocalPayload() else {
            Issue.record("Expected retained workspace rename")
            return
        }
        let rename = try WorkspaceV2SyncAdapter.adapt(
            operation: pending,
            envelope: envelope,
            remoteBaseRevision: try await reopened.remoteRevision(
                entityType: .workspace,
                entityID: binding.workspaceID.rawValue
            ),
            workspaceID: binding.workspaceID
        )
        #expect(rename.baseRevision == 1)
        #expect(rename.payload?["name"] == .string("Renamed after send"))
    }

    @Test
    func acceptedOlderLocalValueCannotOverwriteNewerPendingSameField() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let repository = try await fixture.open(initial: fixture.snapshot(title: "Before"))
        let binding = try fixture.syncBinding()
        try await repository.bindSync(binding)
        try await completeBootstrap(repository: repository, binding: binding)

        let initial = try await repository.snapshot()
        var sentA = initial.content
        sentA.openLoops.items[0].title = "Sent A"
        sentA.openLoops.items[0].updatedAt = fixture.date(20)
        sentA.openLoops.updatedAt = fixture.date(20)
        _ = try await repository.transact(
            expectedRevision: initial.revision,
            mutation: WorkspaceMutation(
                entityKind: "move",
                entityID: sentA.openLoops.items[0].id.uuidString.lowercased(),
                changedFields: ["title", "updatedAt"],
                fieldClocks: ["title": fixture.date(20), "updatedAt": fixture.date(20)],
                replacement: sentA,
                createdAt: fixture.date(20)
            )
        )
        let operationA = try #require(try await repository.pendingOperations().first)
        guard case let .localEntity(envelopeA) = try operationA.decodedLocalPayload() else {
            Issue.record("Expected operation A")
            return
        }
        let baseA = try await repository.remoteRevision(
            entityType: .move,
            entityID: sentA.openLoops.items[0].id
        )
        let wireA = try WorkspaceV2SyncAdapter.adapt(
            operation: operationA,
            envelope: envelopeA,
            remoteBaseRevision: baseA,
            workspaceID: binding.workspaceID
        )

        let afterA = try await repository.snapshot()
        var pendingB = afterA.content
        pendingB.openLoops.items[0].title = "Pending B"
        pendingB.openLoops.items[0].updatedAt = fixture.date(30)
        pendingB.openLoops.updatedAt = fixture.date(30)
        _ = try await repository.transact(
            expectedRevision: afterA.revision,
            mutation: WorkspaceMutation(
                entityKind: "move",
                entityID: pendingB.openLoops.items[0].id.uuidString.lowercased(),
                changedFields: ["title", "updatedAt"],
                fieldClocks: ["title": fixture.date(30), "updatedAt": fixture.date(30)],
                replacement: pendingB,
                createdAt: fixture.date(30)
            )
        )

        try await repository.acknowledgeRemoteOperations(
            [
                try WorkspaceRemoteOperationAcknowledgement(
                    localOperationID: operationA.operationID,
                    entityType: .move,
                    entityID: wireA.entityID,
                    remoteRevision: baseA + 1,
                    fieldClocks: wireA.fieldClocks
                )
            ],
            conflicts: []
        )
        let acceptedA = try makeMoveChange(
            cursor: 1,
            operationID: operationA.operationID,
            moveID: wireA.entityID,
            revision: baseA + 1,
            changedFields: ["title"],
            title: "Sent A",
            details: "",
            priority: .p1,
            dueOn: nil,
            clock: fixture.date(20)
        )
        try await repository.applyRemotePage(
            try makePullResponse(
                workspaceID: binding.workspaceID,
                from: 0,
                changes: [acceptedA]
            )
        )

        #expect(try await repository.snapshot().content.openLoops.items[0].title == "Pending B")
        #expect(try await repository.pendingOperations().count == 1)
        let reopened = try await fixture.open(initial: nil)
        #expect(try await reopened.snapshot().content.openLoops.items[0].title == "Pending B")
        let operationB = try #require(try await reopened.pendingOperations().first)
        guard case let .localEntity(envelopeB) = try operationB.decodedLocalPayload() else {
            Issue.record("Expected operation B")
            return
        }
        let wireB = try WorkspaceV2SyncAdapter.adapt(
            operation: operationB,
            envelope: envelopeB,
            remoteBaseRevision: try await reopened.remoteRevision(
                entityType: .move,
                entityID: wireA.entityID
            ),
            workspaceID: binding.workspaceID
        )
        try await reopened.acknowledgeRemoteOperations(
            [
                try WorkspaceRemoteOperationAcknowledgement(
                    localOperationID: operationB.operationID,
                    entityType: .move,
                    entityID: wireB.entityID,
                    remoteRevision: baseA + 2,
                    fieldClocks: wireB.fieldClocks
                )
            ],
            conflicts: []
        )
        #expect(try await reopened.pendingOperations().isEmpty)
        #expect(try await reopened.snapshot().content.openLoops.items[0].title == "Pending B")
    }

    @Test
    func exactInboundPrimaryGoalAndTombstonePersistWithoutOutboxEcho() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let goalID = UUID()
        var initial = fixture.snapshot(title: "Move")
        initial.personalization.primaryGoal = PrimaryGoal(
            id: goalID,
            title: "Goal",
            metric: "MRR",
            currentValue: 1,
            targetValue: 2,
            unit: .usd,
            dueAt: PlanningDate.storedDate(for: PlanningDay(year: 2026, month: 9, day: 10)!),
            createdAt: fixture.date(10),
            updatedAt: fixture.date(10)
        )
        let repository = try await fixture.open(initial: initial)
        let binding = try fixture.syncBinding()
        try await repository.bindSync(binding)

        let exact = try makeGoalChange(
            cursor: 1,
            operationID: UUID(),
            goalID: goalID,
            revision: 1,
            action: .upsert,
            changedFields: ["currentValue", "targetValue", "dueOn"],
            currentValue: try GoalDecimal(userInput: "123.12345678"),
            targetValue: .maximum,
            dueOn: "2026-12-31",
            deletedAt: nil,
            clock: fixture.date(40)
        )
        try await repository.applyRemotePage(
            try makePullResponse(workspaceID: binding.workspaceID, from: 0, changes: [exact])
        )
        let reopened = try await fixture.open(initial: nil)
        let durableGoal = try #require(try await reopened.snapshot().content.personalization.primaryGoal)
        #expect(durableGoal.currentValue?.canonicalString == "123.12345678")
        #expect(durableGoal.targetValue == .maximum)
        #expect(WorkspaceV2SyncAdapter.dateOnly(durableGoal.dueAt) == "2026-12-31")
        #expect(try await reopened.pendingOperations().isEmpty)

        let tombstone = try makeGoalChange(
            cursor: 2,
            operationID: UUID(),
            goalID: goalID,
            revision: 2,
            action: .delete,
            changedFields: ["deletedAt"],
            currentValue: try GoalDecimal(userInput: "123.12345678"),
            targetValue: .maximum,
            dueOn: "2026-12-31",
            deletedAt: fixture.date(50),
            clock: fixture.date(50)
        )
        try await reopened.applyRemotePage(
            try makePullResponse(workspaceID: binding.workspaceID, from: 1, changes: [tombstone])
        )
        let afterDelete = try await fixture.open(initial: nil)
        #expect(try await afterDelete.snapshot().content.personalization.primaryGoal?.deletedAt == fixture.date(50))
        #expect(try await afterDelete.pendingOperations().isEmpty)
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

    @Test
    func primaryGoalAdapterPreservesExactDecimalsNilsDatesAndTombstones() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let goalID = UUID()
        var initial = fixture.snapshot(title: "Move")
        initial.personalization.primaryGoal = PrimaryGoal(
            id: goalID,
            title: "Reach the finish line",
            metric: "MRR",
            currentValue: try GoalDecimal(userInput: "3000.12345678"),
            targetValue: .maximum,
            unit: .usd,
            dueAt: PlanningDate.storedDate(for: PlanningDay(year: 2026, month: 10, day: 30)!),
            createdAt: fixture.date(10),
            updatedAt: fixture.date(10)
        )
        let repository = try await fixture.open(initial: initial)
        let snapshot = try await repository.snapshot()
        let bootstrap = try WorkspaceV2SyncAdapter.canonicalBootstrapPlan(
            snapshot: snapshot,
            remoteWorkspaceID: WorkspaceID(rawValue: fixture.workspaceID)
        )
        let bootstrapGoal = try #require(bootstrap.operations.first { $0.entityType == .primaryGoal })
        let exactCurrent = try GoalDecimal(userInput: "3000.12345678")
        #expect(bootstrapGoal.payload?["currentValue"] == .number(exactCurrent.decimalValue))
        #expect(bootstrapGoal.payload?["targetValue"] == .number(GoalDecimal.maximum.decimalValue))
        #expect(bootstrapGoal.payload?["dueOn"] == .string("2026-10-30"))

        var nilBootstrapSnapshot = snapshot
        nilBootstrapSnapshot.content.personalization.primaryGoal?.currentValue = nil
        nilBootstrapSnapshot.content.personalization.primaryGoal?.targetValue = nil
        let nilBootstrap = try WorkspaceV2SyncAdapter.canonicalBootstrapPlan(
            snapshot: nilBootstrapSnapshot,
            remoteWorkspaceID: WorkspaceID(rawValue: fixture.workspaceID)
        )
        let nilBootstrapGoal = try #require(
            nilBootstrap.operations.first { $0.entityType == .primaryGoal }
        )
        #expect(nilBootstrapGoal.payload?["currentValue"] == .null)
        #expect(nilBootstrapGoal.payload?["targetValue"] == .null)

        var nilUpdate = snapshot.content
        nilUpdate.personalization.primaryGoal?.currentValue = nil
        nilUpdate.personalization.primaryGoal?.targetValue = nil
        nilUpdate.personalization.primaryGoal?.updatedAt = fixture.date(20)
        nilUpdate.personalization.updatedAt = fixture.date(20)
        _ = try await repository.transact(
            expectedRevision: snapshot.revision,
            mutation: WorkspaceMutation(
                entityKind: "primary_goal",
                entityID: goalID.uuidString.lowercased(),
                changedFields: ["currentValue", "targetValue", "updatedAt"],
                fieldClocks: [
                    "currentValue": fixture.date(20),
                    "targetValue": fixture.date(20),
                    "updatedAt": fixture.date(20),
                ],
                replacement: nilUpdate,
                createdAt: fixture.date(20)
            )
        )
        let nilOperation = try #require(try await repository.pendingOperations().first)
        guard case let .localEntity(nilEnvelope) = try nilOperation.decodedLocalPayload() else {
            Issue.record("Expected goal update")
            return
        }
        let nilWire = try WorkspaceV2SyncAdapter.adapt(
            operation: nilOperation,
            envelope: nilEnvelope,
            remoteBaseRevision: 4,
            workspaceID: WorkspaceID(rawValue: fixture.workspaceID)
        )
        #expect(nilWire.payload?["currentValue"] == .null)
        #expect(nilWire.payload?["targetValue"] == .null)

        let afterNil = try await repository.snapshot()
        var deleted = afterNil.content
        deleted.personalization.primaryGoal?.deletedAt = fixture.date(30)
        deleted.personalization.primaryGoal?.updatedAt = fixture.date(30)
        deleted.personalization.updatedAt = fixture.date(30)
        _ = try await repository.transact(
            expectedRevision: afterNil.revision,
            mutation: WorkspaceMutation(
                entityKind: "primary_goal",
                entityID: goalID.uuidString.lowercased(),
                changedFields: ["deletedAt", "updatedAt"],
                fieldClocks: ["deletedAt": fixture.date(30), "updatedAt": fixture.date(30)],
                replacement: deleted,
                createdAt: fixture.date(30)
            )
        )
        let tombstoneOperation = try #require(try await repository.pendingOperations().last)
        guard case let .localEntity(tombstoneEnvelope) = try tombstoneOperation.decodedLocalPayload() else {
            Issue.record("Expected goal tombstone")
            return
        }
        let tombstone = try WorkspaceV2SyncAdapter.adapt(
            operation: tombstoneOperation,
            envelope: tombstoneEnvelope,
            remoteBaseRevision: 5,
            workspaceID: WorkspaceID(rawValue: fixture.workspaceID)
        )
        #expect(tombstone.action == .delete)
        #expect(tombstone.changedFields == ["deletedAt"])
        #expect(tombstone.payload == nil)
    }

    @Test
    func legacyResolvedPhotoBlocksBootstrapWithoutAssetMetadata() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        var initial = fixture.snapshot(title: "Move")
        initial.personalization.photoFileName = "legacy-photo.jpg"
        let repository = try await fixture.open(initial: initial)
        let binding = try fixture.syncBinding()
        try await repository.bindSync(binding)
        do {
            _ = try await repository.canonicalBootstrapPlan()
            Issue.record("Expected legacy photo bootstrap to remain disabled")
        } catch let error as WorkspaceV2SyncAdapterError {
            #expect(error == .assetTransferDisabled)
        }
    }

    @Test
    func responseSingletonEntityIDsMustMatchOuterWorkspace() throws {
        let workspaceID = WorkspaceID(rawValue: UUID())
        let wrongID = UUID()
        let clock = Date(timeIntervalSince1970: 40)
        let timestamp = WorkspaceV2SyncAdapter.timestamp(clock)
        let workspace = try SyncChange(
            cursor: SyncCursor(value: 1),
            operationID: SyncOperationID(rawValue: UUID()),
            entityType: .workspace,
            entityID: wrongID,
            action: .upsert,
            revision: 1,
            changedFields: ["name"],
            changedAt: clock,
            record: [
                "id": .string(wrongID.uuidString.lowercased()),
                "name": .string("Wrong singleton"),
                "revision": .integer(1),
                "fieldClocks": .object(["name": .string(timestamp)]),
                "createdAt": .string(timestamp),
                "updatedAt": .string(timestamp),
            ]
        )
        #expect(throws: SyncContractValidationError.invalidResponse) {
            try workspace.validate(for: workspaceID)
        }

        let appearance = try SyncChange(
            cursor: SyncCursor(value: 1),
            operationID: SyncOperationID(rawValue: UUID()),
            entityType: .appearance,
            entityID: wrongID,
            action: .upsert,
            revision: 1,
            changedFields: ["preferences", "schemaVersion"],
            changedAt: clock,
            record: [
                "id": .string(wrongID.uuidString.lowercased()),
                "schemaVersion": .integer(6),
                "preferences": .object([:]),
                "revision": .integer(1),
                "fieldClocks": .object([
                    "preferences": .string(timestamp),
                    "schemaVersion": .string(timestamp),
                ]),
                "createdAt": .string(timestamp),
                "updatedAt": .string(timestamp),
            ]
        )
        #expect(throws: SyncContractValidationError.invalidResponse) {
            try appearance.validate(for: workspaceID)
        }
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

    @Test
    func retryStreakAndExponentialBackoffSurviveManualFailureSyncingAndRelaunch() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let repository = try await fixture.open(initial: fixture.snapshot(title: "Move"))
        let binding = try fixture.syncBinding()
        try await repository.bindSync(binding)
        let lastSuccess = fixture.date(90)
        try await repository.setSyncStatus(
            try WorkspaceSyncStatus(phase: .idle, lastSuccessAt: lastSuccess)
        )
        let configuration = try WorkspaceSyncCoordinatorConfiguration(
            initialRetryDelay: 1,
            maximumRetryDelay: 16
        )

        // A standalone manual pass owns no timer, so it reports a truthful
        // blocked result while retaining attempt one for the next lifecycle.
        let manual = try WorkspaceSyncCoordinator(
            repository: repository,
            auth: FixedAuthSession(session: binding.session),
            transport: RecordingSyncTransport(failure: .network),
            configuration: configuration,
            now: { Date(timeIntervalSince1970: 100) },
            jitter: { 1 }
        )
        #expect(await manual.synchronizeNow() == .blocked("transport_unavailable"))
        let first = try await repository.syncStatus()
        #expect(first.phase == .idle)
        #expect(first.retryAttempt == 1)
        #expect(first.nextRetryAt == nil)
        #expect(first.lastSuccessAt == lastSuccess)

        // Relaunch starts a real coordinator, installs a timer, and doubles
        // the delay from one to two seconds without losing last success.
        let reopened = try await fixture.open(initial: nil)
        let secondTransport = RecordingSyncTransport(failure: .network)
        let second = try WorkspaceSyncCoordinator(
            repository: reopened,
            auth: FixedAuthSession(session: binding.session),
            transport: secondTransport,
            configuration: configuration,
            now: { Date(timeIntervalSince1970: 200) },
            jitter: { 1 }
        )
        await second.start()
        try await waitUntil {
            guard let status = try? await reopened.syncStatus() else { return false }
            return status.phase == .retryScheduled && status.retryAttempt == 2
        }
        let secondStatus = try await reopened.syncStatus()
        #expect(secondStatus.nextRetryAt == Date(timeIntervalSince1970: 202))
        #expect(secondStatus.lastSuccessAt == lastSuccess)
        await second.stop()

        // Simulate process death after persisting `.syncing`. The next launch
        // normalizes through a new run and grows 1, 2, 4 rather than resetting.
        try await reopened.setSyncStatus(
            try WorkspaceSyncStatus(
                phase: .syncing,
                retryAttempt: 2,
                lastSuccessAt: lastSuccess,
                failureCode: "transport_unavailable"
            )
        )
        let relaunchedAgain = try await fixture.open(initial: nil)
        let third = try WorkspaceSyncCoordinator(
            repository: relaunchedAgain,
            auth: FixedAuthSession(session: binding.session),
            transport: RecordingSyncTransport(failure: .network),
            configuration: configuration,
            now: { Date(timeIntervalSince1970: 300) },
            jitter: { 1 }
        )
        await third.start()
        try await waitUntil {
            guard let status = try? await relaunchedAgain.syncStatus() else { return false }
            return status.phase == .retryScheduled && status.retryAttempt == 3
        }
        let thirdStatus = try await relaunchedAgain.syncStatus()
        #expect(thirdStatus.nextRetryAt == Date(timeIntervalSince1970: 304))
        #expect(thirdStatus.lastSuccessAt == lastSuccess)
        await third.stop()
    }

    @Test
    func durableRetryScheduledStatusHasALiveTimerTrigger() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let repository = try await fixture.open(initial: fixture.snapshot(title: "Move"))
        let binding = try fixture.syncBinding()
        try await repository.bindSync(binding)
        let transport = RecordingSyncTransport(failure: .network)
        let coordinator = try WorkspaceSyncCoordinator(
            repository: repository,
            auth: FixedAuthSession(session: binding.session),
            transport: transport,
            configuration: WorkspaceSyncCoordinatorConfiguration(
                initialRetryDelay: 0.1,
                maximumRetryDelay: 1
            ),
            now: { Date(timeIntervalSince1970: 100) },
            jitter: { 1 }
        )
        await coordinator.start()
        try await waitUntil {
            let calls = await transport.calls()
            guard calls.count >= 2,
                  let status = try? await repository.syncStatus() else { return false }
            return status.phase == .retryScheduled && status.retryAttempt >= 2
        }
        await coordinator.stop()
        #expect(await transport.calls().count >= 2)
        #expect(try await repository.syncStatus().phase != .syncing)
    }

    @Test
    func cancellationNeverLeavesDurableSyncingAndPreservesLastSuccess() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let repository = try await fixture.open(initial: fixture.snapshot(title: "Move"))
        let binding = try fixture.syncBinding()
        try await repository.bindSync(binding)
        let lastSuccess = fixture.date(90)
        try await repository.setSyncStatus(
            try WorkspaceSyncStatus(phase: .idle, lastSuccessAt: lastSuccess)
        )
        let transport = CancellableBootstrapTransport()
        let coordinator = try WorkspaceSyncCoordinator(
            repository: repository,
            auth: FixedAuthSession(session: binding.session),
            transport: transport
        )
        let run = Task { await coordinator.synchronizeNow() }
        try await waitUntil { await transport.isWaiting() }
        #expect(try await repository.syncStatus().phase == .syncing)
        await coordinator.stop()
        #expect(await run.value == .cancelled)
        let status = try await repository.syncStatus()
        #expect(status.phase == .idle)
        #expect(status.lastSuccessAt == lastSuccess)
    }

    @Test
    func mutationDuringAwaitedBootstrapResumesWithoutASecondExternalTrigger() async throws {
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

        let current = try await repository.snapshot()
        var replacement = current.content
        replacement.openLoops.items[0].title = "Changed during bootstrap"
        let mutation = fixture.mutation(replacement: replacement)
        _ = try await repository.transact(
            expectedRevision: current.revision,
            mutation: mutation
        )
        await transport.releaseBootstrap()
        try await waitUntil {
            let bootstraps = await transport.bootstrapCount()
            let pulls = await transport.pullCount()
            let empty = (try? await repository.pendingOperations().isEmpty) ?? false
            let idle = (try? await repository.syncStatus().phase == .idle) ?? false
            // The schema-4 attempt pins the accepted bootstrap plan. The
            // newer local operation remains outside its acknowledgement
            // boundary and is delivered in the same bounded drain, without
            // issuing a second create/bootstrap request.
            return bootstraps == 1 && pulls >= 1 && empty && idle
        }
        await coordinator.stop()
        try await waitUntil {
            (try? await repository.syncStatus().phase == .idle) ?? false
        }

        #expect(await transport.bootstrapCount() == 1)
        #expect(await transport.pushedOperationIDs().contains(mutation.operationID))
        #expect(try await repository.snapshot().content.openLoops.items[0].title
            == "Changed during bootstrap")
        #expect(try await repository.syncStatus().phase == .idle)
    }

    @Test
    func cursorChangeDuringAwaitedPullGetsOneBoundedFreshRunWithoutRemoteEcho() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let repository = try await fixture.open(initial: fixture.snapshot(title: "Move"))
        let binding = try fixture.syncBinding()
        try await repository.bindSync(binding)
        try await completeCanonicalBootstrap(repository: repository, binding: binding)
        let transport = GatedFirstPullTransport()
        let coordinator = try WorkspaceSyncCoordinator(
            repository: repository,
            auth: FixedAuthSession(session: binding.session),
            transport: transport
        )
        await coordinator.start()
        try await waitUntil { await transport.isWaiting() }

        try await repository.applyRemotePage(
            try hostileWorkspacePage(
                workspaceID: binding.workspaceID,
                after: SyncCursor(value: 0),
                sequence: 1
            )
        )
        await transport.release()
        try await waitUntil {
            let pulls = await transport.pullCount()
            guard pulls == 2,
                  let status = try? await repository.syncStatus() else { return false }
            return status.phase == .idle
        }
        await coordinator.stop()

        #expect(await transport.pullCount() == 2)
        #expect(try await repository.syncCursor() == SyncCursor(value: 1))
        #expect(try await repository.pendingOperations().isEmpty)
        #expect(try await repository.snapshot().content.personalization.workspaceName
            == "Gated hostile page 1")
    }
}

private struct FixedAuthSession: AuthSessionProviding {
    let session: AuthSession?
    func currentSession() async throws -> AuthSession? { session }
}

private actor RecordingSyncTransport: WorkspaceSyncTransport {
    private var recorded: [String] = []
    private let failure: WorkspaceSyncTransportFailure?
    private let revisionOffset: Int64

    init(
        failure: WorkspaceSyncTransportFailure? = nil,
        revisionOffset: Int64 = 0
    ) {
        self.failure = failure
        self.revisionOffset = revisionOffset
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
            revisionOffset: revisionOffset
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

private actor CancellableBootstrapTransport: WorkspaceSyncTransport {
    private var waiting = false

    func isWaiting() -> Bool { waiting }

    func bootstrapWorkspace(
        deviceID: DeviceID,
        localWorkspaceID: WorkspaceID?,
        workspaceName: String,
        displayName: String?
    ) async throws -> WorkspaceBootstrap {
        waiting = true
        defer { waiting = false }
        try await Task.sleep(for: .seconds(60))
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
        throw WorkspaceSyncTransportFailure.rejected
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

private actor GatedFirstPullTransport: WorkspaceSyncTransport {
    private var pulls = 0
    private var waiting = false
    private var continuation: CheckedContinuation<Void, Never>?

    func pullCount() -> Int { pulls }
    func isWaiting() -> Bool { waiting }
    func release() {
        continuation?.resume()
        continuation = nil
        waiting = false
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
        throw WorkspaceSyncTransportFailure.rejected
    }

    func pullChanges(
        session: AuthSession,
        after cursor: SyncCursor,
        limit: Int
    ) async throws -> SyncPullResponse {
        pulls += 1
        if pulls == 1 {
            waiting = true
            await withCheckedContinuation { continuation = $0 }
        }
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
        if bootstraps == 1 {
            bootstrapWaiting = true
            await withCheckedContinuation { bootstrapContinuation = $0 }
        }
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

private func completeCanonicalBootstrap(
    repository: SQLiteWorkspaceRepository,
    binding: WorkspaceSyncBinding
) async throws {
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

private func completeBootstrap(
    repository: SQLiteWorkspaceRepository,
    binding: WorkspaceSyncBinding
) async throws {
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
            )
        ]
    )
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

private func makeGoalChange(
    cursor: Int64,
    operationID: UUID,
    goalID: UUID,
    revision: Int64,
    action: SyncMutationAction,
    changedFields: [String],
    currentValue: GoalDecimal?,
    targetValue: GoalDecimal?,
    dueOn: String,
    deletedAt: Date?,
    clock: Date
) throws -> SyncChange {
    let timestamp = WorkspaceV2SyncAdapter.timestamp(clock)
    return try SyncChange(
        cursor: SyncCursor(value: cursor),
        operationID: SyncOperationID(rawValue: operationID),
        entityType: .primaryGoal,
        entityID: goalID,
        action: action,
        revision: revision,
        changedFields: changedFields,
        changedAt: clock,
        record: [
            "id": .string(goalID.uuidString.lowercased()),
            "title": .string("Exact goal"),
            "metric": .string("MRR"),
            "currentValue": currentValue.map { .number($0.decimalValue) } ?? .null,
            "targetValue": targetValue.map { .number($0.decimalValue) } ?? .null,
            "unit": .string("usd"),
            "dueOn": .string(dueOn),
            "deletedAt": deletedAt.map { .string(WorkspaceV2SyncAdapter.timestamp($0)) } ?? .null,
            "revision": .integer(revision),
            "fieldClocks": .object(
                Dictionary(uniqueKeysWithValues: changedFields.map { ($0, .string(timestamp)) })
            ),
            "createdAt": .string(WorkspaceV2SyncAdapter.timestamp(Date(timeIntervalSince1970: 10))),
            "updatedAt": .string(timestamp),
        ]
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
    revisionOffset: Int64,
    statuses: [SyncOperationStatus]? = nil
) throws -> SyncPushResponse {
    struct Encoded: Encodable {
        let contractVersion: Int
        let workspaceId: WorkspaceID
        let latestCursor: SyncCursor
        let results: [SyncOperationResult]
    }
    guard statuses == nil || statuses?.count == operations.count else {
        throw WorkspaceSyncRepositoryError.bootstrapResponseMismatch
    }
    let results = try operations.enumerated().map { index, operation in
        try SyncOperationResult(
            operationID: operation.operationID,
            status: statuses?[index] ?? .accepted,
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

private func readRemoteFieldClocks(
    databaseURL: URL,
    entityType: SyncEntityType,
    entityID: UUID
) throws -> [String: Date] {
    var connection: OpaquePointer?
    guard sqlite3_open_v2(
        databaseURL.path,
        &connection,
        SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
        nil
    ) == SQLITE_OK,
    let connection else {
        throw WorkspaceRepositoryError.invalidDatabase
    }
    defer { sqlite3_close_v2(connection) }

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(
        connection,
        """
        SELECT field_clocks FROM sync_entity_revisions
        WHERE entity_type = ? AND entity_id = ?
        """,
        -1,
        &statement,
        nil
    ) == SQLITE_OK,
    let statement else {
        throw WorkspaceRepositoryError.invalidDatabase
    }
    defer { sqlite3_finalize(statement) }
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    guard entityType.rawValue.withCString({
        sqlite3_bind_text(statement, 1, $0, -1, transient)
    }) == SQLITE_OK,
    entityID.uuidString.lowercased().withCString({
        sqlite3_bind_text(statement, 2, $0, -1, transient)
    }) == SQLITE_OK,
    sqlite3_step(statement) == SQLITE_ROW,
    let bytes = sqlite3_column_blob(statement, 0) else {
        throw WorkspaceRepositoryError.invalidDatabase
    }
    let count = Int(sqlite3_column_bytes(statement, 0))
    return try syncDecoder.decode(
        [String: Date].self,
        from: Data(bytes: bytes, count: count)
    )
}
