import CryptoKit
import Foundation
import SQLite3
import Testing
@testable import FounderOfficeCore

struct WorkspaceRepositoryTests {
    @Test
    func exactPrimaryGoalEditSurvivesOutboxAndRepositoryRelaunch() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let goalID = UUID()
        var initial = fixture.snapshot(title: "Before")
        initial.personalization.primaryGoal = PrimaryGoal(
            id: goalID,
            title: "Reach the finish line",
            metric: "MRR",
            currentValue: try GoalDecimal(userInput: "3000.1234567"),
            targetValue: 10_000,
            unit: .usd,
            dueAt: fixture.date(9_000),
            createdAt: fixture.date(10),
            updatedAt: fixture.date(10)
        )

        let repository = try await fixture.open(initial: initial)
        let baseline = try await repository.snapshot()
        var replacement = baseline.content
        replacement.personalization.primaryGoal?.currentValue = try GoalDecimal(
            userInput: "3000.12345678"
        )
        replacement.personalization.primaryGoal?.updatedAt = fixture.date(20)
        replacement.personalization.updatedAt = fixture.date(20)
        let mutation = WorkspaceMutation(
            entityKind: "primary_goal",
            entityID: goalID.uuidString.lowercased(),
            changedFields: ["currentValue", "updatedAt"],
            fieldClocks: [
                "currentValue": fixture.date(20),
                "updatedAt": fixture.date(20)
            ],
            replacement: replacement,
            createdAt: fixture.date(20)
        )

        _ = try await repository.transact(
            expectedRevision: baseline.revision,
            mutation: mutation
        )

        let pending = try #require(try await repository.pendingOperations().first)
        #expect(String(decoding: pending.payload, as: UTF8.self).contains(
            #""currentValue":3000.12345678"#
        ))
        guard case let .localEntity(envelope) = try pending.decodedLocalPayload(),
              case let .primaryGoal(outboxGoal) = envelope.record else {
            Issue.record("Expected an exact primary-goal operation")
            return
        }
        #expect(outboxGoal.currentValue?.canonicalString == "3000.12345678")

        let reopened = try await fixture.open(initial: nil)
        let durable = try await reopened.snapshot()
        #expect(
            durable.content.personalization.primaryGoal?.currentValue?.canonicalString
                == "3000.12345678"
        )
    }

    @Test
    func commitAdvancesRevisionAndPersistsWriterReceiptAndOutbox() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let workspaceID = UUID()
        let writerID = WorkspaceWriterID()
        let initial = fixture.snapshot(title: "Before")
        let repository = try await fixture.open(
            workspaceID: workspaceID,
            writerID: writerID,
            initial: initial
        )

        let baseline = try await repository.snapshot()
        var replacement = baseline.content
        replacement.openLoops.items[0].title = "After"
        replacement.openLoops.items[0].updatedAt = fixture.date(20)
        replacement.openLoops.updatedAt = fixture.date(20)
        let mutation = fixture.mutation(
            replacement: replacement,
            changedFields: ["title", "updatedAt", "title"]
        )

        let result = try await repository.transact(
            expectedRevision: baseline.revision,
            mutation: mutation
        )

        guard case let .committed(change) = result else {
            Issue.record("Expected a committed transaction")
            return
        }
        #expect(change.snapshot.revision == WorkspaceRevision(rawValue: 1))
        #expect(change.snapshot.writerID == writerID)
        #expect(change.snapshot.content.openLoops.items.first?.title == "After")
        #expect(change.operation.baseRevision == .initial)
        #expect(change.operation.committedRevision == WorkspaceRevision(rawValue: 1))
        #expect(change.operation.changedFields == ["title", "updatedAt"])

        let pending = try await repository.pendingOperations()
        #expect(pending.count == 1)
        #expect(pending.first?.operationID == mutation.operationID)
        let operation = try #require(pending.first)
        #expect(operation.payloadFormatVersion == WorkspaceLocalOperationEnvelopeV2.formatVersion)
        guard case let .localEntity(envelope) = try operation.decodedLocalPayload(),
              case let .move(move) = envelope.record else {
            Issue.record("Expected one bounded Move operation")
            return
        }
        #expect(move.title == "After")

        let reopened = try await fixture.open(
            workspaceID: workspaceID,
            writerID: writerID,
            initial: nil
        )
        let durable = try await reopened.snapshot()
        #expect(durable.revision == WorkspaceRevision(rawValue: 1))
        #expect(durable.writerID == writerID)
        #expect(durable.content.openLoops.items.first?.title == "After")
        #expect(try await reopened.pendingOperations().count == 1)
    }

    @Test
    func staleRevisionFailsWithoutChangingSnapshotOrOutbox() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let repository = try await fixture.open(initial: fixture.snapshot(title: "Before"))
        let baseline = try await repository.snapshot()
        var replacement = baseline.content
        replacement.openLoops.items[0].title = "Rejected"
        let rejectedReplacement = replacement

        let error = await capturedRepositoryError {
            try await repository.transact(
                expectedRevision: WorkspaceRevision(rawValue: 9),
                mutation: fixture.mutation(replacement: rejectedReplacement)
            )
        }
        #expect(
            error == .revisionConflict(
                expected: WorkspaceRevision(rawValue: 9),
                actual: .initial
            )
        )
        let unchanged = try await repository.snapshot()
        #expect(unchanged.revision == .initial)
        #expect(unchanged.content.openLoops.items.first?.title == "Before")
        #expect(try await repository.pendingOperations().isEmpty)
    }

    @Test
    func identicalRetryIsIdempotentAndKeyReuseWithDifferentInputFails() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let repository = try await fixture.open(initial: fixture.snapshot(title: "Before"))
        let baseline = try await repository.snapshot()
        var replacement = baseline.content
        replacement.openLoops.items[0].title = "After"
        let mutation = fixture.mutation(replacement: replacement)

        _ = try await repository.transact(
            expectedRevision: baseline.revision,
            mutation: mutation
        )
        let retry = try await repository.transact(
            expectedRevision: baseline.revision,
            mutation: mutation
        )

        guard case let .replayed(snapshot, committedRevision) = retry else {
            Issue.record("Expected an idempotent replay")
            return
        }
        #expect(snapshot.revision == WorkspaceRevision(rawValue: 1))
        #expect(committedRevision == WorkspaceRevision(rawValue: 1))
        #expect(try await repository.pendingOperations().count == 1)

        var conflictingMutation = mutation
        conflictingMutation.operationID = UUID()
        conflictingMutation.entityID = UUID().uuidString.lowercased()
        let reusedMutation = conflictingMutation
        let error = await capturedRepositoryError {
            try await repository.transact(
                expectedRevision: baseline.revision,
                mutation: reusedMutation
            )
        }
        #expect(error == .idempotencyKeyReused)
        #expect(try await repository.snapshot().revision == WorkspaceRevision(rawValue: 1))
        #expect(try await repository.pendingOperations().count == 1)
    }

    @Test
    func unchangedMutationGetsDurableReceiptWithoutOutboxEntry() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let repository = try await fixture.open(initial: fixture.snapshot(title: "Same"))
        let baseline = try await repository.snapshot()
        let mutation = fixture.mutation(replacement: baseline.content)

        let first = try await repository.transact(
            expectedRevision: baseline.revision,
            mutation: mutation
        )
        guard case let .unchanged(snapshot) = first else {
            Issue.record("Expected an unchanged result")
            return
        }
        #expect(snapshot.revision == .initial)
        #expect(try await repository.pendingOperations().isEmpty)

        let retry = try await repository.transact(
            expectedRevision: baseline.revision,
            mutation: mutation
        )
        guard case let .replayed(_, committedRevision) = retry else {
            Issue.record("Expected the no-op receipt to replay")
            return
        }
        #expect(committedRevision == .initial)
    }

    @Test
    func changesStreamPublishesOnlyAfterSuccessfulCommit() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let repository = try await fixture.open(initial: fixture.snapshot(title: "Before"))
        let baseline = try await repository.snapshot()
        let stream = await repository.changes()
        let nextChange = Task {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }

        var replacement = baseline.content
        replacement.openLoops.items[0].title = "Streamed"
        let mutation = fixture.mutation(replacement: replacement)
        _ = try await repository.transact(
            expectedRevision: baseline.revision,
            mutation: mutation
        )

        let change = try #require(await nextChange.value)
        #expect(change.snapshot.revision == WorkspaceRevision(rawValue: 1))
        #expect(change.operation.operationID == mutation.operationID)
        #expect(change.snapshot.content.openLoops.items.first?.title == "Streamed")
    }

    @Test
    func simultaneousTransactionsSerializeAtOneExpectedRevision() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let repository = try await fixture.open(initial: fixture.snapshot(title: "Before"))
        let baseline = try await repository.snapshot()
        var firstReplacement = baseline.content
        firstReplacement.openLoops.items[0].title = "First"
        var secondReplacement = baseline.content
        secondReplacement.openLoops.items[0].title = "Second"
        let firstMutation = fixture.mutation(replacement: firstReplacement)
        let secondMutation = fixture.mutation(replacement: secondReplacement)

        async let first = repositoryAttempt(
            repository,
            revision: baseline.revision,
            mutation: firstMutation
        )
        async let second = repositoryAttempt(
            repository,
            revision: baseline.revision,
            mutation: secondMutation
        )
        let outcomes = await [first, second]

        var commitCount = 0
        var conflictCount = 0
        for outcome in outcomes {
            switch outcome {
            case .success(.committed):
                commitCount += 1
            case let .failure(.revisionConflict(expected, actual)):
                #expect(expected == .initial)
                #expect(actual == WorkspaceRevision(rawValue: 1))
                conflictCount += 1
            default:
                Issue.record("Unexpected simultaneous transaction outcome")
            }
        }

        #expect(commitCount == 1)
        #expect(conflictCount == 1)
        let durable = try await repository.snapshot()
        #expect(durable.revision == WorkspaceRevision(rawValue: 1))
        #expect(["First", "Second"].contains(durable.content.openLoops.items[0].title))
        #expect(try await repository.pendingOperations().count == 1)
    }

    @Test
    func legacyImportPreservesSourceAndRecoveryBytesThenExportsImmutableProjection() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let legacyURL = fixture.rootURL.appendingPathComponent("legacy", isDirectory: true)
        let recoveryURL = legacyURL.appendingPathComponent("Recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: recoveryURL, withIntermediateDirectories: true)

        let legacySnapshot = fixture.snapshot(title: "Imported", openLoopsSchemaVersion: 2)
        let encoder = fixture.prettyEncoder
        let openLoopsData = try encoder.encode(legacySnapshot.openLoops)
        let personalizationData = try encoder.encode(legacySnapshot.personalization)
        let recoveryData = Data("preserved recovery bytes".utf8)
        let openLoopsURL = legacyURL.appendingPathComponent("openloops.json")
        let personalizationURL = legacyURL.appendingPathComponent("personalization.json")
        let recoveryFileURL = recoveryURL.appendingPathComponent("prior-copy.json")
        try openLoopsData.write(to: openLoopsURL)
        try personalizationData.write(to: personalizationURL)
        try recoveryData.write(to: recoveryFileURL)

        let repository = try await fixture.open(
            legacyDirectoryURL: legacyURL,
            initial: nil
        )
        let imported = try await repository.snapshot()

        #expect(imported.revision == .initial)
        #expect(imported.content.openLoops.schemaVersion == 3)
        #expect(imported.content.openLoops.items.first?.title == "Imported")
        #expect(try Data(contentsOf: openLoopsURL) == openLoopsData)
        #expect(try Data(contentsOf: personalizationURL) == personalizationData)
        #expect(try Data(contentsOf: recoveryFileURL) == recoveryData)

        let exportURL = fixture.rootURL.appendingPathComponent("export", isDirectory: true)
        let generatedAt = fixture.date(50)
        let manifest = try await repository.export(
            to: exportURL,
            generatedAt: generatedAt,
            calendar: fixture.calendar
        )
        #expect(manifest.revision == .initial)
        #expect(manifest.generatedAt == generatedAt)
        #expect(manifest.files.map(\.name) == [
            "openloops.json",
            "personalization.json",
            "OPEN_LOOPS_CONTEXT.md"
        ])

        for record in manifest.files {
            let data = try Data(contentsOf: exportURL.appendingPathComponent(record.name))
            #expect(data.count == record.byteCount)
            #expect(fixture.digest(data) == record.sha256)
        }
        let context = try String(
            contentsOf: exportURL.appendingPathComponent("OPEN_LOOPS_CONTEXT.md"),
            encoding: .utf8
        )
        #expect(context.contains("Generated from the transactional workspace"))
        #expect(context.contains("Imported"))

        let markerURL = exportURL.appendingPathComponent("marker.txt")
        let marker = Data("do not replace".utf8)
        try marker.write(to: markerURL)
        let error = await capturedRepositoryError {
            try await repository.export(to: exportURL)
        }
        #expect(error == .exportDestinationExists)
        #expect(try Data(contentsOf: markerURL) == marker)
    }

    @Test
    func boundedProjectionRepairReplacesOnlyDerivedBytesAndPreservesCanonicalRevision() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let repository = try await fixture.open(initial: fixture.snapshot(title: "Canonical"))
        let before = try await repository.snapshot()
        let outboxBefore = try await repository.pendingOperations()
        let projectionsURL = fixture.rootURL.appendingPathComponent("Generated", isDirectory: true)
        let projectionURL = try await repository.ensureProjection(
            in: projectionsURL,
            generatedAt: fixture.date(60),
            calendar: fixture.calendar
        )
        try Data("damaged derived bytes".utf8).write(
            to: projectionURL.appendingPathComponent("openloops.json"),
            options: [.atomic]
        )

        #expect(await repository.currentProjectionURLIfHealthy(in: projectionsURL) == nil)
        let validationError = await capturedRepositoryError {
            try await repository.ensureProjection(in: projectionsURL)
        }
        #expect(validationError == .exportFailed(operation: "validate_generated_projection"))

        let repairedURL = try await repository.repairCurrentProjection(
            in: projectionsURL,
            generatedAt: fixture.date(61),
            calendar: fixture.calendar
        )

        #expect(repairedURL == projectionURL)
        #expect(await repository.currentProjectionURLIfHealthy(in: projectionsURL) == projectionURL)
        let projectedData = try Data(
            contentsOf: projectionURL.appendingPathComponent("openloops.json")
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let projected = try decoder.decode(OpenLoopsDocument.self, from: projectedData)
        #expect(projected.items.first?.title == "Canonical")
        let after = try await repository.snapshot()
        #expect(after.revision == before.revision)
        #expect(
            try fixture.prettyEncoder.encode(after.content)
                == fixture.prettyEncoder.encode(before.content)
        )
        #expect(outboxBefore.isEmpty)
        #expect(try await repository.pendingOperations().isEmpty)
    }

    @Test
    func boundedProjectionRepairRefusesSymlinkAndLeavesItsTargetUntouched() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let repository = try await fixture.open(initial: fixture.snapshot(title: "Canonical"))
        let projectionsURL = fixture.rootURL.appendingPathComponent("Generated", isDirectory: true)
        try FileManager.default.createDirectory(at: projectionsURL, withIntermediateDirectories: true)
        let projectionURL = projectionsURL.appendingPathComponent(
            "revision-000000000000",
            isDirectory: true
        )
        let targetURL = fixture.rootURL.appendingPathComponent("unrelated", isDirectory: true)
        let markerURL = targetURL.appendingPathComponent("marker.txt")
        try FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: true)
        let marker = Data("must remain".utf8)
        try marker.write(to: markerURL)
        try FileManager.default.createSymbolicLink(
            at: projectionURL,
            withDestinationURL: targetURL
        )

        let error = await capturedRepositoryError {
            try await repository.repairCurrentProjection(in: projectionsURL)
        }

        #expect(error == .exportFailed(operation: "refuse_linked_projection"))
        #expect(try Data(contentsOf: markerURL) == marker)
        let values = try projectionURL.resourceValues(forKeys: [.isSymbolicLinkKey])
        #expect(values.isSymbolicLink == true)
        #expect((try await repository.snapshot()).revision == .initial)
    }

    @Test
    func incompleteLegacyImportFailsClosedWithoutChangingSource() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let legacyURL = fixture.rootURL.appendingPathComponent("legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyURL, withIntermediateDirectories: true)
        let data = try fixture.prettyEncoder.encode(fixture.snapshot(title: "Only Moves").openLoops)
        let sourceURL = legacyURL.appendingPathComponent("openloops.json")
        try data.write(to: sourceURL)

        let error = await capturedRepositoryError {
            try await fixture.open(legacyDirectoryURL: legacyURL, initial: nil)
        }
        #expect(error == .incompleteLegacyWorkspace)
        #expect(try Data(contentsOf: sourceURL) == data)
    }

    @Test
    func newerDatabaseSchemaRefusesDowngrade() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        try fixture.createDatabaseWithSchemaVersion(5)
        let before = try Data(contentsOf: fixture.databaseURL)

        let error = await capturedRepositoryError {
            try await fixture.open(initial: fixture.snapshot(title: "Unused"))
        }
        #expect(error == .schemaTooNew(found: 5, supported: 4))
        #expect(try Data(contentsOf: fixture.databaseURL) == before)
    }

    @Test
    func acknowledgedOutboxEntryStaysIdempotent() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let repository = try await fixture.open(initial: fixture.snapshot(title: "Before"))
        let baseline = try await repository.snapshot()
        var replacement = baseline.content
        replacement.openLoops.items[0].title = "After"
        let mutation = fixture.mutation(replacement: replacement)
        _ = try await repository.transact(
            expectedRevision: baseline.revision,
            mutation: mutation
        )

        try await repository.recordDeliveryAttempt(operationIDs: [mutation.operationID])
        #expect(try await repository.pendingOperations().first?.deliveryAttempts == 1)
        try await repository.acknowledgeOperations(operationIDs: [mutation.operationID])
        #expect(try await repository.pendingOperations().isEmpty)

        let retry = try await repository.transact(
            expectedRevision: baseline.revision,
            mutation: mutation
        )
        guard case let .replayed(snapshot, committedRevision) = retry else {
            Issue.record("Expected acknowledged mutation to remain idempotent")
            return
        }
        #expect(snapshot.revision == WorkspaceRevision(rawValue: 1))
        #expect(committedRevision == WorkspaceRevision(rawValue: 1))
        #expect(try await repository.pendingOperations().isEmpty)
    }

    @Test
    func tenThousandMoveImportMutationOutboxAndReopenRemainFunctional() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let legacyURL = fixture.rootURL.appendingPathComponent("large-legacy", isDirectory: true)
        let recoveryURL = legacyURL.appendingPathComponent("Recovery", isDirectory: true)
        try FileManager.default.createDirectory(at: recoveryURL, withIntermediateDirectories: true)

        let items = (0..<10_000).map { index in
            OpenLoop(
                id: UUID(),
                title: "Move \(index)",
                details: "",
                status: index.isMultiple(of: 5) ? .done : .next,
                previousStatus: index.isMultiple(of: 5) ? .next : nil,
                priority: LoopPriority.allCases[index % LoopPriority.allCases.count],
                dueAt: nil,
                createdAt: fixture.date(10),
                updatedAt: fixture.date(10),
                completedAt: index.isMultiple(of: 5) ? fixture.date(10) : nil,
                deletedAt: nil,
                source: "stress-test"
            )
        }
        let legacySnapshot = FounderOfficeSnapshot(
            openLoops: OpenLoopsDocument(
                schemaVersion: 3,
                updatedAt: fixture.date(10),
                items: items
            ),
            personalization: TestFixtures.personalization(updatedAt: fixture.date(10))
        )
        let sourceMoves = try fixture.prettyEncoder.encode(legacySnapshot.openLoops)
        let sourcePersonalization = try fixture.prettyEncoder.encode(legacySnapshot.personalization)
        let recoveryData = Data("large import recovery marker".utf8)
        let movesURL = legacyURL.appendingPathComponent("openloops.json")
        let personalizationURL = legacyURL.appendingPathComponent("personalization.json")
        let recoveryFileURL = recoveryURL.appendingPathComponent("before-import.json")
        try sourceMoves.write(to: movesURL)
        try sourcePersonalization.write(to: personalizationURL)
        try recoveryData.write(to: recoveryFileURL)

        let startedAt = Date()
        let repository = try await fixture.open(
            legacyDirectoryURL: legacyURL,
            initial: nil
        )
        let imported = try await repository.snapshot()
        #expect(imported.content.openLoops.items.count == 10_000)

        var replacement = imported.content
        replacement.openLoops.items[9_999].title = "Mutated final Move"
        replacement.openLoops.items[9_999].updatedAt = fixture.date(20)
        replacement.openLoops.updatedAt = fixture.date(20)
        let mutation = WorkspaceMutation(
            operationID: UUID(),
            idempotencyKey: WorkspaceIdempotencyKey(),
            entityKind: "move",
            entityID: replacement.openLoops.items[9_999].id.uuidString.lowercased(),
            changedFields: ["title", "updatedAt"],
            fieldClocks: ["title": fixture.date(20), "updatedAt": fixture.date(20)],
            replacement: replacement,
            createdAt: fixture.date(20)
        )
        _ = try await repository.transact(
            expectedRevision: imported.revision,
            mutation: mutation
        )
        let pending = try await repository.pendingOperations()
        #expect(pending.count == 1)
        #expect(pending.first?.operationID == mutation.operationID)
        #expect(pending.first?.committedRevision == WorkspaceRevision(rawValue: 1))

        let operation = try #require(pending.first)
        #expect(operation.payloadFormatVersion == WorkspaceLocalOperationEnvelopeV2.formatVersion)
        guard case let .localEntity(envelope) = try operation.decodedLocalPayload(),
              case let .move(move) = envelope.record else {
            Issue.record("Expected one bounded Move operation")
            return
        }
        #expect(move.title == "Mutated final Move")
        #expect(operation.payload.count < 4 * 1_024)
        #expect(operation.payload.count < sourceMoves.count / 100)

        let reopened = try await fixture.open(initial: nil)
        let durable = try await reopened.snapshot()
        #expect(durable.revision == WorkspaceRevision(rawValue: 1))
        #expect(durable.content.openLoops.items.count == 10_000)
        #expect(durable.content.openLoops.items[9_999].title == "Mutated final Move")
        #expect(try await reopened.pendingOperations().count == 1)

        #expect(try Data(contentsOf: movesURL) == sourceMoves)
        #expect(try Data(contentsOf: personalizationURL) == sourcePersonalization)
        #expect(try Data(contentsOf: recoveryFileURL) == recoveryData)
        #expect(Date().timeIntervalSince(startedAt) < 30)
    }

    @Test
    func versionOneMovePayloadMigratesInPlaceWithoutChangingOperationIdentityOrRetryReceipt() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let repository = try await fixture.open(initial: fixture.snapshot(title: "Before"))
        let baseline = try await repository.snapshot()
        var replacement = baseline.content
        replacement.openLoops.items[0].title = "After 👨🏽‍💻"
        replacement.openLoops.items[0].details = "First line\n\tIndented second line\r\nThird line"
        replacement.openLoops.items[0].updatedAt = fixture.date(20)
        replacement.openLoops.updatedAt = fixture.date(20)
        let mutation = WorkspaceMutation(
            entityKind: "move",
            entityID: replacement.openLoops.items[0].id.uuidString.lowercased(),
            changedFields: ["title", "details", "updatedAt"],
            fieldClocks: [
                "title": fixture.date(20),
                "details": fixture.date(20),
                "updatedAt": fixture.date(20)
            ],
            replacement: replacement,
            createdAt: fixture.date(20)
        )
        _ = try await repository.transact(expectedRevision: baseline.revision, mutation: mutation)
        let committed = try await repository.snapshot()
        let before = try #require(try await repository.pendingOperations().first)

        try fixture.rewritePendingOperationAsVersionOne(
            operationID: mutation.operationID,
            snapshot: committed.content,
            entityKind: "move",
            entityID: mutation.entityID,
            changedFields: before.changedFields,
            fieldClocks: before.fieldClocks,
            expectedRevision: baseline.revision,
            mutation: mutation
        )

        let reopened = try await fixture.open(initial: nil)
        let migrated = try #require(try await reopened.pendingOperations().first)
        #expect(migrated.operationID == before.operationID)
        #expect(migrated.idempotencyKey == before.idempotencyKey)
        #expect(migrated.baseRevision == before.baseRevision)
        #expect(migrated.committedRevision == before.committedRevision)
        #expect(migrated.payloadFormatVersion == WorkspaceLocalOperationEnvelopeV2.formatVersion)
        guard case let .localEntity(envelope) = try migrated.decodedLocalPayload(),
              case let .move(move) = envelope.record else {
            Issue.record("Expected the legacy Move to migrate to one entity operation")
            return
        }
        #expect(move.title == "After 👨🏽‍💻")
        #expect(move.details.contains("\n\t"))

        let retry = try await reopened.transact(
            expectedRevision: baseline.revision,
            mutation: mutation
        )
        guard case let .replayed(_, committedRevision) = retry else {
            Issue.record("Expected the pre-upgrade idempotency receipt to remain valid")
            return
        }
        #expect(committedRevision == WorkspaceRevision(rawValue: 1))
    }

    @Test
    func broadLegacyPersonalizationStaysPendingUntilEveryProfileFieldHasReviewedWireSemantics() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let repository = try await fixture.open(initial: fixture.snapshot(title: "Before"))
        let baseline = try await repository.snapshot()
        var replacement = baseline.content
        replacement.openLoops.items[0].title = "After"
        replacement.openLoops.items[0].updatedAt = fixture.date(20)
        replacement.openLoops.updatedAt = fixture.date(20)
        let mutation = fixture.mutation(replacement: replacement)
        _ = try await repository.transact(expectedRevision: baseline.revision, mutation: mutation)
        let committed = try await repository.snapshot()
        let exactLegacyPayload = try fixture.compactEncoder.encode(committed.content)

        try fixture.rewritePendingOperationAsVersionOne(
            operationID: mutation.operationID,
            snapshot: committed.content,
            entityKind: "personalization",
            entityID: "personalization",
            changedFields: ["personalization", "updatedAt"],
            fieldClocks: [
                "personalization": fixture.date(20),
                "updatedAt": fixture.date(20)
            ],
            expectedRevision: baseline.revision,
            mutation: mutation
        )

        let reopened = try await fixture.open(initial: nil)
        let legacy = try #require(try await reopened.pendingOperations().first)
        #expect(legacy.payloadFormatVersion == WorkspaceOutboxOperation.legacySnapshotPayloadFormatVersion)
        #expect(legacy.payload == exactLegacyPayload)
        guard case .requiresBootstrap = try legacy.decodedLocalPayload() else {
            Issue.record("Expected an explicit bootstrap requirement")
            return
        }

        try await reopened.recordDeliveryAttempt(operationIDs: [legacy.operationID])
        try await reopened.acknowledgeOperations(operationIDs: [legacy.operationID])
        let stillPending = try #require(try await reopened.pendingOperations().first)
        #expect(stillPending.deliveryAttempts == 0)
        #expect(stillPending.payload == exactLegacyPayload)

        let current = try await reopened.snapshot()
        var nextReplacement = current.content
        nextReplacement.openLoops.items[0].details = "A new entity operation"
        nextReplacement.openLoops.items[0].updatedAt = fixture.date(30)
        nextReplacement.openLoops.updatedAt = fixture.date(30)
        let nextMutation = WorkspaceMutation(
            entityKind: "move",
            entityID: nextReplacement.openLoops.items[0].id.uuidString.lowercased(),
            changedFields: ["details", "updatedAt"],
            fieldClocks: ["details": fixture.date(30), "updatedAt": fixture.date(30)],
            replacement: nextReplacement,
            createdAt: fixture.date(30)
        )
        _ = try await reopened.transact(
            expectedRevision: current.revision,
            mutation: nextMutation
        )
        let mixedPending = try await reopened.pendingOperations()
        #expect(mixedPending.count == 2)
        #expect(mixedPending.map(\.payloadFormatVersion) == [
            WorkspaceOutboxOperation.legacySnapshotPayloadFormatVersion,
            WorkspaceLocalOperationEnvelopeV2.formatVersion
        ])

        let binding = try fixture.syncBinding()
        try await reopened.bindSync(binding)
        let pendingBatch = try await reopened.pendingSyncBatch()
        #expect(pendingBatch.requiresCanonicalBootstrap)
        let adapterError = await capturedAdapterError {
            try await reopened.canonicalBootstrapPlan()
        }
        #expect(adapterError == .profileRequiresReviewedBootstrap)
        #expect(try await reopened.pendingOperations().count == 2)
    }

    @Test
    func newAssetOperationContainsOnlySyncSafeMetadataAndNeverOriginalDetails() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let repository = try await fixture.open(initial: fixture.snapshot(title: "Before"))
        let baseline = try await repository.snapshot()
        let asset = try PersonalizationImageAsset(
            id: UUID(),
            originalFileExtension: "png",
            originalByteCount: 87_654_321,
            pixelWidth: 4_000,
            pixelHeight: 3_000,
            importedAt: fixture.date(20)
        )
        var replacement = baseline.content
        replacement.personalization.visionImageAsset = asset
        replacement.personalization.photoFileName = asset.displayFileName
        replacement.personalization.updatedAt = fixture.date(20)
        let mutation = WorkspaceMutation(
            entityKind: "asset",
            entityID: asset.id.uuidString.lowercased(),
            changedFields: ["photoFileName", "updatedAt", "visionImageAsset"],
            fieldClocks: [
                "photoFileName": fixture.date(20),
                "updatedAt": fixture.date(20),
                "visionImageAsset": fixture.date(20)
            ],
            replacement: replacement,
            createdAt: fixture.date(20)
        )

        _ = try await repository.transact(expectedRevision: baseline.revision, mutation: mutation)
        let operation = try #require(try await repository.pendingOperations().first)
        #expect(operation.payloadFormatVersion == WorkspaceLocalOperationEnvelopeV2.formatVersion)
        guard case let .localEntity(envelope) = try operation.decodedLocalPayload(),
              case let .asset(record) = envelope.record else {
            Issue.record("Expected one sync-safe asset metadata operation")
            return
        }
        #expect(record.id == asset.id)
        #expect(record.syncFileName == asset.syncFileName)
        #expect(record.importedAt == asset.importedAt)
        #expect(record.removedAt == nil)

        let encoded = try #require(String(data: operation.payload, encoding: .utf8))
        #expect(!encoded.contains("originalFileExtension"))
        #expect(!encoded.contains("originalByteCount"))
        #expect(!encoded.contains(asset.originalFileName))
        #expect(!encoded.contains(asset.displayFileName))
        #expect(!encoded.contains("87654321"))
    }

    @Test
    func profileOperationExcludesAppearanceGoalsAndMilestonesAndUsesChangedFieldsAsAuthority() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        var initial = fixture.snapshot(title: "Before")
        let goalSentinel = "GOAL-MUST-NOT-ENTER-PROFILE-OUTBOX"
        let milestoneSentinel = "MILESTONE-MUST-NOT-ENTER-PROFILE-OUTBOX"
        initial.personalization.primaryGoal = PrimaryGoal(
            id: UUID(),
            title: goalSentinel,
            metric: "MRR",
            currentValue: 3_000,
            targetValue: 10_000,
            unit: .usd,
            dueAt: fixture.date(9_000),
            createdAt: fixture.date(10)
        )
        initial.personalization.milestones = (0..<500).map { index in
            Milestone(
                id: UUID(),
                title: "\(milestoneSentinel)-\(index)",
                dueAt: fixture.date(TimeInterval(10_000 + index)),
                createdAt: fixture.date(10)
            )
        }
        initial.personalization.appearance = .preset(.pixel)

        let repository = try await fixture.open(initial: initial)
        let baseline = try await repository.snapshot()
        var replacement = baseline.content
        replacement.personalization.preferredName = "Ada"
        replacement.personalization.updatedAt = fixture.date(20)
        let mutation = WorkspaceMutation(
            entityKind: "profile",
            entityID: "profile",
            changedFields: ["preferredName", "updatedAt"],
            fieldClocks: [
                "preferredName": fixture.date(20),
                "updatedAt": fixture.date(20)
            ],
            replacement: replacement,
            createdAt: fixture.date(20)
        )

        _ = try await repository.transact(expectedRevision: baseline.revision, mutation: mutation)
        let operation = try #require(try await repository.pendingOperations().first)
        guard case let .localEntity(envelope) = try operation.decodedLocalPayload(),
              case let .profile(profile) = envelope.record else {
            Issue.record("Expected one bounded profile operation")
            return
        }
        #expect(envelope.changedFields == ["preferredName", "updatedAt"])
        #expect(profile.preferredName == "Ada")
        #expect(operation.payload.count < 2 * 1_024)

        let encoded = try #require(String(data: operation.payload, encoding: .utf8))
        #expect(!encoded.contains(goalSentinel))
        #expect(!encoded.contains(milestoneSentinel))
        #expect(!encoded.contains("primaryGoal"))
        #expect(!encoded.contains("milestones"))
        #expect(!encoded.contains("appearance"))
        #expect(!encoded.contains("accent"))
    }

    @Test
    func unsupportedNewBroadPersonalizationWriteFailsAtomicallyInsteadOfReintroducingVersionOne() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let repository = try await fixture.open(initial: fixture.snapshot(title: "Before"))
        let baseline = try await repository.snapshot()
        var replacement = baseline.content
        replacement.personalization.preferredName = "Synthetic"
        replacement.personalization.updatedAt = fixture.date(20)
        let mutation = WorkspaceMutation(
            entityKind: "personalization",
            entityID: "personalization",
            changedFields: ["personalization", "updatedAt"],
            fieldClocks: [
                "personalization": fixture.date(20),
                "updatedAt": fixture.date(20),
            ],
            replacement: replacement,
            createdAt: fixture.date(20)
        )

        let error = await capturedRepositoryError {
            try await repository.transact(expectedRevision: baseline.revision, mutation: mutation)
        }
        #expect(error == .invalidMutation(reason: "entity kind is unsupported"))
        #expect(try await repository.snapshot().revision == .initial)
        #expect(try await repository.pendingOperations().isEmpty)
    }

    @Test
    func oversizedMoveDetailsFailAtomicallyInsteadOfEscapingTheV2Bound() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let repository = try await fixture.open(initial: fixture.snapshot(title: "Before"))
        let baseline = try await repository.snapshot()
        var replacement = baseline.content
        replacement.openLoops.items[0].details = String(
            repeating: "x",
            count: (128 * 1_024) + 1
        )
        replacement.openLoops.items[0].updatedAt = fixture.date(20)
        replacement.openLoops.updatedAt = fixture.date(20)
        let mutation = WorkspaceMutation(
            entityKind: "move",
            entityID: replacement.openLoops.items[0].id.uuidString.lowercased(),
            changedFields: ["details", "updatedAt"],
            fieldClocks: ["details": fixture.date(20), "updatedAt": fixture.date(20)],
            replacement: replacement,
            createdAt: fixture.date(20)
        )

        let error = await capturedRepositoryError {
            try await repository.transact(expectedRevision: baseline.revision, mutation: mutation)
        }
        #expect(error == .invalidMutation(reason: "entity operation metadata is invalid"))
        #expect(try await repository.snapshot().revision == .initial)
        #expect(try await repository.pendingOperations().isEmpty)
    }
}

struct WorkspaceRepositoryPerformanceTests {
    @Test
    func tenThousandMovesAndManyMutationsKeepOutboxAndDatabaseGrowthBounded() async throws {
        let fixture = try RepositoryFixture()
        defer { fixture.remove() }
        let initial = fixture.largeSnapshot(moveCount: 10_000)
        let repository = try await fixture.open(initial: initial)
        let fullSnapshotBytes = try fixture.compactEncoder.encode(initial).count
        let initialDatabaseBytes = fixture.databaseArtifactByteCount()
        let warmupCount = 12
        let measuredCount = 96
        var timings: [Double] = []

        for index in 0..<(warmupCount + measuredCount) {
            let baseline = try await repository.snapshot()
            var replacement = baseline.content
            let moveIndex = index % replacement.openLoops.items.count
            let changedAt = fixture.date(TimeInterval(1_000 + index))
            replacement.openLoops.items[moveIndex].title = "Updated \(index)"
            replacement.openLoops.items[moveIndex].updatedAt = changedAt
            replacement.openLoops.updatedAt = changedAt
            let moveID = replacement.openLoops.items[moveIndex].id.uuidString.lowercased()
            let mutation = WorkspaceMutation(
                entityKind: "move",
                entityID: moveID,
                changedFields: ["title", "updatedAt"],
                fieldClocks: ["title": changedAt, "updatedAt": changedAt],
                replacement: replacement,
                createdAt: changedAt
            )

            let startedAt = Date()
            _ = try await repository.transact(
                expectedRevision: baseline.revision,
                mutation: mutation
            )
            let elapsedMilliseconds = Date().timeIntervalSince(startedAt) * 1_000
            if index >= warmupCount {
                timings.append(elapsedMilliseconds)
            }
        }

        let pending = try await repository.pendingOperations(limit: 1_000)
        let payloadBytes = pending.reduce(0) { $0 + $1.payload.count }
        let largestPayload = pending.map(\.payload.count).max() ?? 0
        let sortedTimings = timings.sorted()
        let p95Index = max(0, Int(ceil(Double(sortedTimings.count) * 0.95)) - 1)
        let p95Milliseconds = sortedTimings[p95Index]
        let finalDatabaseBytes = fixture.databaseArtifactByteCount()
        let databaseGrowthBytes = max(0, finalDatabaseBytes - initialDatabaseBytes)

        print(
            String(
                format: "OUTBOX_PERF moves=10000 mutations=%d p95_ms=%.2f payload_bytes=%d largest_payload_bytes=%d db_initial_bytes=%lld db_final_bytes=%lld db_growth_bytes=%lld",
                warmupCount + measuredCount,
                p95Milliseconds,
                payloadBytes,
                largestPayload,
                initialDatabaseBytes,
                finalDatabaseBytes,
                databaseGrowthBytes
            )
        )

        #expect(pending.count == warmupCount + measuredCount)
        #expect(pending.allSatisfy {
            $0.payloadFormatVersion == WorkspaceLocalOperationEnvelopeV2.formatVersion
        })
        #expect(largestPayload < 4 * 1_024)
        #expect(payloadBytes < (warmupCount + measuredCount) * 4 * 1_024)
        #expect(payloadBytes < fullSnapshotBytes)
        #expect(p95Milliseconds < 250)
        #expect(finalDatabaseBytes < Int64(max(64 * 1_024 * 1_024, fullSnapshotBytes * 12)))
        #expect(databaseGrowthBytes < Int64(max(16 * 1_024 * 1_024, fullSnapshotBytes * 3)))

        let reopened = try await fixture.open(initial: nil)
        let durable = try await reopened.snapshot()
        #expect(durable.content.openLoops.items.count == 10_000)
        #expect(durable.revision == WorkspaceRevision(rawValue: Int64(warmupCount + measuredCount)))
        #expect(try await reopened.pendingOperations(limit: 1_000).count == warmupCount + measuredCount)
    }
}

private func capturedRepositoryError<Result: Sendable>(
    _ operation: @Sendable () async throws -> Result
) async -> WorkspaceRepositoryError? {
    do {
        _ = try await operation()
        Issue.record("Expected a WorkspaceRepositoryError")
        return nil
    } catch let error as WorkspaceRepositoryError {
        return error
    } catch {
        Issue.record("Expected WorkspaceRepositoryError, received \(type(of: error))")
        return nil
    }
}

private func capturedSyncRepositoryError<Result: Sendable>(
    _ operation: @Sendable () async throws -> Result
) async -> WorkspaceSyncRepositoryError? {
    do {
        _ = try await operation()
        Issue.record("Expected a WorkspaceSyncRepositoryError")
        return nil
    } catch let error as WorkspaceSyncRepositoryError {
        return error
    } catch {
        Issue.record("Expected WorkspaceSyncRepositoryError, received \(type(of: error))")
        return nil
    }
}

private func capturedAdapterError<Result: Sendable>(
    _ operation: @Sendable () async throws -> Result
) async -> WorkspaceV2SyncAdapterError? {
    do {
        _ = try await operation()
        Issue.record("Expected a WorkspaceV2SyncAdapterError")
        return nil
    } catch let error as WorkspaceV2SyncAdapterError {
        return error
    } catch {
        Issue.record("Expected WorkspaceV2SyncAdapterError, received \(type(of: error))")
        return nil
    }
}

private func acceptedPushResponse(
    workspaceID: WorkspaceID,
    operations: [SyncOperation],
    startingCursor: Int64 = 1
) throws -> SyncPushResponse {
    let results = try operations.enumerated().map { index, operation in
        try SyncOperationResult(
            operationID: operation.operationID,
            status: .accepted,
            revision: Int64(index + 1),
            cursor: SyncCursor(value: startingCursor + Int64(index)),
            conflict: nil
        )
    }
    struct EncodedResponse: Encodable {
        let contractVersion: Int
        let workspaceId: WorkspaceID
        let latestCursor: SyncCursor
        let results: [SyncOperationResult]
    }
    let response = EncodedResponse(
        contractVersion: SyncOperation.contractVersion,
        workspaceId: workspaceID,
        latestCursor: try SyncCursor(
            value: startingCursor + Int64(max(0, operations.count - 1))
        ),
        results: results
    )
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(SyncPushResponse.self, from: encoder.encode(response))
}

private func repositoryAttempt(
    _ repository: SQLiteWorkspaceRepository,
    revision: WorkspaceRevision,
    mutation: WorkspaceMutation
) async -> Result<WorkspaceTransactionResult, WorkspaceRepositoryError> {
    do {
        return .success(
            try await repository.transact(
                expectedRevision: revision,
                mutation: mutation
            )
        )
    } catch let error as WorkspaceRepositoryError {
        return .failure(error)
    } catch {
        Issue.record("Expected WorkspaceRepositoryError, received \(type(of: error))")
        return .failure(.invalidDatabase)
    }
}

struct RepositoryFixture: Sendable {
    let rootURL: URL
    let databaseURL: URL
    let workspaceID = UUID()
    let writerID = WorkspaceWriterID()

    init() throws {
        rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "founder-office-repository-tests-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        databaseURL = rootURL.appendingPathComponent("workspace.sqlite3")
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    var prettyEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    var compactEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    func snapshot(
        title: String,
        openLoopsSchemaVersion: Int = 3
    ) -> FounderOfficeSnapshot {
        let move = OpenLoop(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            title: title,
            details: "",
            status: .next,
            previousStatus: nil,
            priority: .p1,
            dueAt: nil,
            createdAt: date(10),
            updatedAt: date(10),
            completedAt: nil,
            deletedAt: nil,
            source: "test"
        )
        return FounderOfficeSnapshot(
            openLoops: OpenLoopsDocument(
                schemaVersion: openLoopsSchemaVersion,
                updatedAt: date(10),
                items: [move]
            ),
            personalization: TestFixtures.personalization(updatedAt: date(10))
        )
    }

    func largeSnapshot(moveCount: Int) -> FounderOfficeSnapshot {
        let items = (0..<moveCount).map { index in
            OpenLoop(
                id: UUID(),
                title: "Move \(index)",
                details: "",
                status: index.isMultiple(of: 5) ? .done : .next,
                previousStatus: index.isMultiple(of: 5) ? .next : nil,
                priority: LoopPriority.allCases[index % LoopPriority.allCases.count],
                dueAt: nil,
                createdAt: date(10),
                updatedAt: date(10),
                completedAt: index.isMultiple(of: 5) ? date(10) : nil,
                deletedAt: nil,
                source: "stress-test",
                priorityUpdatedAt: date(10),
                dueAtUpdatedAt: date(10)
            )
        }
        return FounderOfficeSnapshot(
            openLoops: OpenLoopsDocument(schemaVersion: 3, updatedAt: date(10), items: items),
            personalization: TestFixtures.personalization(updatedAt: date(10))
        )
    }

    func mutation(
        replacement: FounderOfficeSnapshot,
        changedFields: [String] = ["title"]
    ) -> WorkspaceMutation {
        let normalizedFields = Array(Set(changedFields)).sorted()
        return WorkspaceMutation(
            operationID: UUID(),
            idempotencyKey: WorkspaceIdempotencyKey(),
            entityKind: "move",
            entityID: "00000000-0000-0000-0000-000000000001",
            changedFields: normalizedFields,
            fieldClocks: Dictionary(
                uniqueKeysWithValues: normalizedFields.map { ($0, date(20)) }
            ),
            replacement: replacement,
            createdAt: date(20)
        )
    }

    func syncBinding() throws -> WorkspaceSyncBinding {
        try WorkspaceSyncBinding(
            accountID: FounderAccountID(
                rawValue: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
            ),
            workspaceID: WorkspaceID(rawValue: workspaceID),
            deviceID: DeviceID(
                rawValue: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
            ),
            identityProvider: .google,
            boundAt: date(20)
        )
    }

    func open(
        workspaceID: UUID? = nil,
        writerID: WorkspaceWriterID? = nil,
        legacyDirectoryURL: URL? = nil,
        initial: FounderOfficeSnapshot?
    ) async throws -> SQLiteWorkspaceRepository {
        try await SQLiteWorkspaceRepository.open(
            configuration: WorkspaceRepositoryConfiguration(
                databaseURL: databaseURL,
                workspaceID: workspaceID ?? self.workspaceID,
                requestedWriterID: writerID ?? self.writerID,
                legacyDirectoryURL: legacyDirectoryURL,
                initialSnapshot: initial
            )
        )
    }

    func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func createDatabaseWithSchemaVersion(_ version: Int) throws {
        var connection: OpaquePointer?
        let result = sqlite3_open_v2(
            databaseURL.path,
            &connection,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE,
            nil
        )
        guard result == SQLITE_OK, let connection else {
            throw WorkspaceRepositoryError.databaseUnavailable(
                operation: "test_database_open",
                code: result
            )
        }
        defer { sqlite3_close_v2(connection) }
        guard sqlite3_exec(connection, "PRAGMA user_version = \(version)", nil, nil, nil) == SQLITE_OK else {
            throw WorkspaceRepositoryError.databaseUnavailable(
                operation: "test_database_schema",
                code: sqlite3_errcode(connection)
            )
        }
    }

    func rewritePendingOperationAsVersionOne(
        operationID: UUID,
        snapshot: FounderOfficeSnapshot,
        entityKind: String,
        entityID: String,
        changedFields: [String],
        fieldClocks: [String: Date],
        expectedRevision: WorkspaceRevision,
        mutation: WorkspaceMutation
    ) throws {
        var connection: OpaquePointer?
        let result = sqlite3_open_v2(
            databaseURL.path,
            &connection,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let connection else {
            throw WorkspaceRepositoryError.databaseUnavailable(
                operation: "test_database_open",
                code: result
            )
        }
        defer { sqlite3_close_v2(connection) }
        guard sqlite3_busy_timeout(connection, 5_000) == SQLITE_OK,
              sqlite3_exec(connection, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            throw WorkspaceRepositoryError.databaseUnavailable(
                operation: "test_legacy_outbox_begin",
                code: sqlite3_errcode(connection)
            )
        }
        do {
            let sql = """
            UPDATE operation_outbox
            SET entity_kind = ?, entity_id = ?, changed_fields = ?, field_clocks = ?,
                payload_format_version = 1, payload = ?
            WHERE operation_id = ?
            """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else {
                throw WorkspaceRepositoryError.databaseUnavailable(
                    operation: "test_legacy_outbox_prepare",
                    code: sqlite3_errcode(connection)
                )
            }
            defer { sqlite3_finalize(statement) }
            let fieldsData = try compactEncoder.encode(Array(Set(changedFields)).sorted())
            let clocksData = try compactEncoder.encode(fieldClocks)
            let snapshotData = try compactEncoder.encode(snapshot)
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            guard entityKind.withCString({
                sqlite3_bind_text(statement, 1, $0, -1, transient)
            }) == SQLITE_OK,
            entityID.withCString({
                sqlite3_bind_text(statement, 2, $0, -1, transient)
            }) == SQLITE_OK,
            fieldsData.withUnsafeBytes({
                sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32($0.count), transient)
            }) == SQLITE_OK,
            clocksData.withUnsafeBytes({
                sqlite3_bind_blob(statement, 4, $0.baseAddress, Int32($0.count), transient)
            }) == SQLITE_OK,
            snapshotData.withUnsafeBytes({
                sqlite3_bind_blob(statement, 5, $0.baseAddress, Int32($0.count), transient)
            }) == SQLITE_OK,
            operationID.uuidString.lowercased().withCString({
                sqlite3_bind_text(statement, 6, $0, -1, transient)
            }) == SQLITE_OK,
            sqlite3_step(statement) == SQLITE_DONE,
            sqlite3_changes(connection) == 1 else {
                throw WorkspaceRepositoryError.databaseUnavailable(
                    operation: "test_legacy_outbox_write",
                    code: sqlite3_errcode(connection)
                )
            }

            struct LegacyFingerprintEnvelope: Codable {
                var expectedRevision: WorkspaceRevision
                var mutation: WorkspaceMutation
            }
            var normalizedMutation = mutation
            normalizedMutation.entityKind = mutation.entityKind.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            normalizedMutation.entityID = mutation.entityID.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            normalizedMutation.changedFields = Array(Set(mutation.changedFields)).sorted()
            normalizedMutation.replacement = snapshot
            let fingerprintInput = try compactEncoder.encode(
                LegacyFingerprintEnvelope(
                    expectedRevision: expectedRevision,
                    mutation: normalizedMutation
                )
            )
            let fingerprint = Data(SHA256.hash(data: fingerprintInput))
            var receiptStatement: OpaquePointer?
            let receiptSQL = """
            UPDATE operation_receipts
            SET request_fingerprint = ?, fingerprint_version = 1
            WHERE operation_id = ?
            """
            guard sqlite3_prepare_v2(
                connection,
                receiptSQL,
                -1,
                &receiptStatement,
                nil
            ) == SQLITE_OK,
            let receiptStatement else {
                throw WorkspaceRepositoryError.databaseUnavailable(
                    operation: "test_legacy_receipt_prepare",
                    code: sqlite3_errcode(connection)
                )
            }
            do {
                defer { sqlite3_finalize(receiptStatement) }
                guard fingerprint.withUnsafeBytes({
                    sqlite3_bind_blob(
                        receiptStatement,
                        1,
                        $0.baseAddress,
                        Int32($0.count),
                        transient
                    )
                }) == SQLITE_OK,
                operationID.uuidString.lowercased().withCString({
                    sqlite3_bind_text(receiptStatement, 2, $0, -1, transient)
                }) == SQLITE_OK,
                sqlite3_step(receiptStatement) == SQLITE_DONE,
                sqlite3_changes(connection) == 1 else {
                    throw WorkspaceRepositoryError.databaseUnavailable(
                        operation: "test_legacy_receipt_write",
                        code: sqlite3_errcode(connection)
                    )
                }
            }
            // Recreate the exact schema-1 receipt shape. Opening the database
            // must add this column and preserve the pre-v2 fingerprint bytes.
            guard sqlite3_exec(
                connection,
                "ALTER TABLE operation_receipts DROP COLUMN fingerprint_version",
                nil,
                nil,
                nil
            ) == SQLITE_OK,
            sqlite3_exec(connection, "PRAGMA user_version = 1", nil, nil, nil) == SQLITE_OK,
            sqlite3_exec(connection, "COMMIT", nil, nil, nil) == SQLITE_OK else {
                throw WorkspaceRepositoryError.databaseUnavailable(
                    operation: "test_legacy_receipt_write",
                    code: sqlite3_errcode(connection)
                )
            }
        } catch {
            sqlite3_exec(connection, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    func databaseArtifactByteCount() -> Int64 {
        [databaseURL, URL(fileURLWithPath: databaseURL.path + "-wal")]
            .reduce(Int64(0)) { total, url in
                let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
                let bytes = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
                return total + bytes
            }
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}
