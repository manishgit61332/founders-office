import Foundation
import SQLite3
import Testing
@testable import FounderOfficeCore
@testable import OpenLoops

@MainActor
struct WorkspaceSessionIntegrationTests {
    @Test
    func legacyBytesStayUntouchedWhileMacMutationRelaunchAndProjectionUseSQLite() async throws {
        let fixture = try MacStorageFixture()
        defer { fixture.remove() }
        let workspaceID = UUID()
        let legacy = fixture.snapshot(moveCount: 1)
        let movesBytes = try fixture.encoder.encode(legacy.openLoops)
        let personalizationBytes = try fixture.encoder.encode(legacy.personalization)
        let recoveryBytes = Data("recovery remains byte exact".utf8)
        try movesBytes.write(to: fixture.root.appendingPathComponent("openloops.json"))
        try personalizationBytes.write(to: fixture.root.appendingPathComponent("personalization.json"))
        let recoveryURL = fixture.root
            .appendingPathComponent("Recovery", isDirectory: true)
            .appendingPathComponent("preserved.json")
        try FileManager.default.createDirectory(
            at: recoveryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try recoveryBytes.write(to: recoveryURL)

        let session = try await WorkspaceSession.open(
            rootURL: fixture.root,
            workspaceID: workspaceID,
            initialSnapshot: WorkspaceSession.freshSnapshot
        )
        let store = OpenLoopStore(session: session)
        let id = try #require(store.items.first?.id)
        let result = await store.updatePlanning(
            id: id,
            priorityChange: .set(.p0),
            deadlineChange: .clear
        )
        guard case .saved = result else {
            Issue.record("Expected the Mac store mutation to commit")
            return
        }
        #expect(await session.refreshProjectionNow())

        #expect(try Data(contentsOf: fixture.root.appendingPathComponent("openloops.json")) == movesBytes)
        #expect(try Data(contentsOf: fixture.root.appendingPathComponent("personalization.json")) == personalizationBytes)
        #expect(try Data(contentsOf: recoveryURL) == recoveryBytes)
        let projectionURL = try #require(session.projectionURL)
        let projectedMovesData = try Data(
            contentsOf: projectionURL.appendingPathComponent("openloops.json")
        )
        let projectedMoves = try fixture.decoder.decode(OpenLoopsDocument.self, from: projectedMovesData)
        #expect(projectedMoves.items.first?.priority == .p0)
        let projectedContext = try String(
            contentsOf: projectionURL.appendingPathComponent("OPEN_LOOPS_CONTEXT.md"),
            encoding: .utf8
        )
        #expect(projectedContext.contains("Fixture 0"))
        let manifestData = try Data(
            contentsOf: projectionURL.appendingPathComponent("workspace-export-manifest.json")
        )
        let manifest = try fixture.decoder.decode(WorkspaceExportManifest.self, from: manifestData)
        #expect(manifest.revision == WorkspaceRevision(rawValue: 1))
        let writerID = session.snapshot.writerID

        try WorkspaceBootstrapCoordinator.commitIdentity(
            workspaceID: workspaceID,
            to: fixture.root.appendingPathComponent(WorkspaceBootstrapCoordinator.identityFileName)
        )
        let relaunchDecision = WorkspaceBootstrapCoordinator.inspect(
            rootURL: fixture.root,
            expectedWorkspaceID: workspaceID
        ).decision
        #expect(relaunchDecision == .useExisting(workspaceID: workspaceID, needsIdentityCommit: false))

        store.stop()
        session.stop()
        let reopened = try await WorkspaceSession.open(
            rootURL: fixture.root,
            workspaceID: workspaceID,
            initialSnapshot: WorkspaceSession.freshSnapshot
        )
        #expect(reopened.snapshot.revision == WorkspaceRevision(rawValue: 1))
        #expect(reopened.snapshot.writerID == writerID)
        #expect(reopened.snapshot.content.openLoops.items.first?.priority == .p0)
        #expect(try await reopened.repository.pendingOperations().count == 1)
        reopened.stop()
    }

    @Test
    func rapidMacMutationsSerializeWithoutDroppingMoves() async throws {
        let fixture = try MacStorageFixture()
        defer { fixture.remove() }
        let session = try await WorkspaceSession.open(
            rootURL: fixture.root,
            workspaceID: UUID(),
            initialSnapshot: fixture.snapshot(moveCount: 1)
        )
        let store = OpenLoopStore(session: session)

        for index in 0..<75 {
            store.add(
                title: "Queued \(index)",
                status: .next,
                priority: .p2,
                dueAt: nil
            )
        }
        let barrierID = try #require(store.items.first?.id)
        let barrier = await store.updatePlanning(
            id: barrierID,
            priorityChange: .set(.p1),
            deadlineChange: .unchanged
        )
        guard case .saved = barrier else {
            Issue.record("Expected the queue barrier to commit")
            return
        }
        #expect(await session.refreshProjectionNow())

        let durable = try await session.repository.snapshot()
        #expect(durable.content.openLoops.items.count == 76)
        #expect(durable.content.openLoops.items.first?.priority == .p1)
        #expect(durable.revision == WorkspaceRevision(rawValue: 76))
        #expect(try await session.repository.pendingOperations().count == 76)
        let generatedRevisions = try FileManager.default.contentsOfDirectory(
            at: session.projectionsRootURL,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix("revision-") }
        #expect(generatedRevisions.count <= 2)
        store.stop()
        session.stop()
    }

    @Test
    func appearanceDraftCommitsOnceAndDetectsSameFieldConflict() async throws {
        let fixture = try MacStorageFixture()
        defer { fixture.remove() }
        let session = try await WorkspaceSession.open(
            rootURL: fixture.root,
            workspaceID: UUID(),
            initialSnapshot: fixture.snapshot(moveCount: 1)
        )
        let store = PersonalizationStore(session: session)
        store.beginAppearanceEditing()
        store.updateAccentColor(RGB24Color(red: 20, green: 140, blue: 220), stopIndex: 0)
        let save = await store.saveAppearanceChanges()
        #expect(save == .saved)
        #expect(session.snapshot.revision == WorkspaceRevision(rawValue: 1))

        store.beginAppearanceEditing()
        store.updateAccentColor(RGB24Color(red: 110, green: 70, blue: 210), stopIndex: 0)
        var unrelatedMoves = session.snapshot.content.openLoops
        unrelatedMoves.items[0].details = "An unrelated Move edit"
        unrelatedMoves.items[0].updatedAt = Date().addingTimeInterval(1)
        unrelatedMoves.updatedAt = unrelatedMoves.items[0].updatedAt
        _ = try await session.commit(
            WorkspacePatchMutation(
                entityKind: "move",
                entityID: unrelatedMoves.items[0].id.uuidString.lowercased(),
                changedFields: ["details", "updatedAt"],
                fieldClocks: ["details": unrelatedMoves.updatedAt],
                patch: .openLoops(unrelatedMoves),
                createdAt: unrelatedMoves.updatedAt
            )
        )
        let saveAfterUnrelatedMove = await store.saveAppearanceChanges()
        #expect(saveAfterUnrelatedMove == .saved)
        #expect(session.snapshot.revision == WorkspaceRevision(rawValue: 3))

        store.beginAppearanceEditing()
        store.updateAccentColor(RGB24Color(red: 220, green: 80, blue: 40), stopIndex: 0)
        var remote = session.snapshot.content.personalization
        var remoteAppearance = remote.resolvedAppearance
        remoteAppearance.accent = AccentStyle(
            mode: .solid,
            stops: [AccentStop(color: RGB24Color(red: 80, green: 220, blue: 90), location: 0)],
            angleDegrees: 0
        )
        remoteAppearance.updatedAt = Date().addingTimeInterval(10)
        remote.appearance = remoteAppearance
        remote.updatedAt = remoteAppearance.updatedAt
        _ = try await session.commit(
            WorkspacePatchMutation(
                entityKind: "appearance",
                entityID: "appearance",
                changedFields: ["appearance", "updatedAt"],
                fieldClocks: ["appearance": remoteAppearance.updatedAt ?? Date()],
                patch: .personalization(remote),
                createdAt: remoteAppearance.updatedAt ?? Date()
            )
        )
        let conflict = await store.saveAppearanceChanges()
        #expect(conflict == .conflict)
        #expect(store.hasUnsavedAppearanceChanges)
        #expect(session.snapshot.content.personalization.resolvedAppearance.accent.primaryColor
            == RGB24Color(red: 80, green: 220, blue: 90))
        store.stop()
        session.stop()
    }

    @Test
    func sqliteWriteFailureKeepsCommittedAppearanceAndRetryableDraftSeparate() async throws {
        let fixture = try MacStorageFixture()
        defer { fixture.remove() }
        let session = try await WorkspaceSession.open(
            rootURL: fixture.root,
            workspaceID: UUID(),
            initialSnapshot: fixture.snapshot(moveCount: 1)
        )
        let store = PersonalizationStore(session: session)
        let committed = store.document.resolvedAppearance
        store.beginAppearanceEditing()
        store.updateAccentColor(RGB24Color(red: 240, green: 40, blue: 90), stopIndex: 0)

        try fixture.installFailingWorkspaceUpdateTrigger(at: session.databaseURL)
        let result = await store.saveAppearanceChanges()

        guard case .failed = result else {
            Issue.record("Expected the injected SQLite failure to reach the Appearance UI")
            return
        }
        #expect(store.hasUnsavedAppearanceChanges)
        #expect(store.appearanceSaveError != nil)
        #expect(session.snapshot.content.personalization.resolvedAppearance == committed)
        #expect(try await session.repository.pendingOperations().isEmpty)
        store.stop()
        session.stop()
    }
}

private struct MacStorageFixture {
    let root: URL
    let encoder: JSONEncoder
    let decoder: JSONDecoder

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("founder-office-mac-storage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func installFailingWorkspaceUpdateTrigger(at databaseURL: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
              let database else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close_v2(database) }
        let sql = """
        CREATE TRIGGER fail_workspace_update
        BEFORE UPDATE ON workspace_state
        BEGIN
            SELECT RAISE(FAIL, 'injected write failure');
        END;
        """
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    @MainActor
    func snapshot(moveCount: Int) -> FounderOfficeSnapshot {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let items = (0..<moveCount).map { index in
            OpenLoop(
                id: UUID(),
                title: "Fixture \(index)",
                details: "",
                status: .next,
                previousStatus: nil,
                priority: .p2,
                dueAt: nil,
                createdAt: now,
                updatedAt: now,
                completedAt: nil,
                deletedAt: nil,
                source: "integration-test",
                priorityUpdatedAt: now,
                dueAtUpdatedAt: now
            )
        }
        var snapshot = WorkspaceSession.freshSnapshot
        snapshot.openLoops = OpenLoopsDocument(schemaVersion: 3, updatedAt: now, items: items)
        snapshot.personalization.updatedAt = now
        var appearance = snapshot.personalization.resolvedAppearance
        appearance.updatedAt = now
        snapshot.personalization.appearance = appearance
        return snapshot
    }
}
