import CryptoKit
import Foundation
import SQLite3
import Testing
@testable import FounderOfficeCore

struct WorkspaceRepositoryTests {
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
        let payload = try fixture.decoder.decode(
            FounderOfficeSnapshot.self,
            from: try #require(pending.first?.payload)
        )
        #expect(payload.openLoops.items.first?.title == "After")

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
        try fixture.createDatabaseWithSchemaVersion(2)
        let before = try Data(contentsOf: fixture.databaseURL)

        let error = await capturedRepositoryError {
            try await fixture.open(initial: fixture.snapshot(title: "Unused"))
        }
        #expect(error == .schemaTooNew(found: 2, supported: 1))
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

        let payload = try fixture.decoder.decode(
            FounderOfficeSnapshot.self,
            from: try #require(pending.first?.payload)
        )
        #expect(payload.openLoops.items.count == 10_000)
        #expect(payload.openLoops.items[9_999].title == "Mutated final Move")

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

private struct RepositoryFixture: Sendable {
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

    func mutation(
        replacement: FounderOfficeSnapshot,
        changedFields: [String] = ["title"]
    ) -> WorkspaceMutation {
        WorkspaceMutation(
            operationID: UUID(),
            idempotencyKey: WorkspaceIdempotencyKey(),
            entityKind: "move",
            entityID: "00000000-0000-0000-0000-000000000001",
            changedFields: changedFields,
            fieldClocks: ["title": date(20)],
            replacement: replacement,
            createdAt: date(20)
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

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}
