import CryptoKit
import Foundation
import SQLite3

public actor SQLiteWorkspaceRepository: WorkspaceRepository {
    private let database: SQLiteWorkspaceDatabase
    private var latestSnapshot: WorkspaceRepositorySnapshot
    private var changeContinuations: [UUID: AsyncStream<WorkspaceChange>.Continuation] = [:]

    private init(
        database: SQLiteWorkspaceDatabase,
        snapshot: WorkspaceRepositorySnapshot
    ) {
        self.database = database
        latestSnapshot = snapshot
    }

    /// Opens and migrates the database on a generic executor so callers on
    /// `MainActor` never perform SQLite or legacy JSON I/O themselves.
    public static func open(
        configuration: WorkspaceRepositoryConfiguration
    ) async throws -> SQLiteWorkspaceRepository {
        let opened = try await Task.detached(priority: .userInitiated) {
            try SQLiteWorkspaceDatabase.open(configuration: configuration)
        }.value
        return SQLiteWorkspaceRepository(database: opened.database, snapshot: opened.snapshot)
    }

    public func snapshot() throws -> WorkspaceRepositorySnapshot {
        let snapshot = try database.loadSnapshot()
        latestSnapshot = snapshot
        return snapshot
    }

    public func transact(
        expectedRevision: WorkspaceRevision,
        mutation: WorkspaceMutation
    ) throws -> WorkspaceTransactionResult {
        let result = try database.transact(
            expectedRevision: expectedRevision,
            mutation: mutation
        )

        switch result {
        case let .committed(change):
            latestSnapshot = change.snapshot
            for continuation in changeContinuations.values {
                continuation.yield(change)
            }
            return .committed(change)
        case let .unchanged(snapshot):
            latestSnapshot = snapshot
            return .unchanged(snapshot)
        case let .replayed(snapshot, committedRevision):
            latestSnapshot = snapshot
            return .replayed(snapshot: snapshot, committedRevision: committedRevision)
        }
    }

    /// Applies a local component patch to the latest durable snapshot. Because
    /// this method performs no suspension before SQLite commits, concurrent UI
    /// requests are serialized by the repository actor in arrival order.
    public func transact(patch request: WorkspacePatchMutation) throws -> WorkspaceTransactionResult {
        let current = try database.loadSnapshot()
        switch request.precondition {
        case .none:
            break
        case let .appearanceRevision(expected):
            guard current.content.personalization.resolvedAppearance.updatedAt == expected else {
                throw WorkspaceRepositoryError.componentConflict(component: "Appearance")
            }
        }

        var replacement = current.content
        switch request.patch {
        case let .openLoops(document):
            replacement.openLoops = document
        case let .personalization(document):
            replacement.personalization = document
        }

        return try transact(
            expectedRevision: current.revision,
            mutation: WorkspaceMutation(
                operationID: request.operationID,
                idempotencyKey: request.idempotencyKey,
                entityKind: request.entityKind,
                entityID: request.entityID,
                changedFields: request.changedFields,
                fieldClocks: request.fieldClocks,
                replacement: replacement,
                createdAt: request.createdAt
            )
        )
    }

    public func changes() -> AsyncStream<WorkspaceChange> {
        let identifier = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(32)) { continuation in
            changeContinuations[identifier] = continuation
            continuation.onTermination = { [weak self] _ in
                Task {
                    await self?.removeChangeContinuation(identifier)
                }
            }
        }
    }

    public func pendingOperations(limit: Int = 100) throws -> [WorkspaceOutboxOperation] {
        try database.pendingOperations(limit: limit)
    }

    public func recordDeliveryAttempt(operationIDs: [UUID]) throws {
        try database.recordDeliveryAttempt(operationIDs: operationIDs)
    }

    /// Removes only operations positively acknowledged by the remote sync
    /// endpoint. Idempotency receipts remain durable after acknowledgement.
    public func acknowledgeOperations(operationIDs: [UUID]) throws {
        try database.acknowledgeOperations(operationIDs: operationIDs)
    }

    /// Removes legacy whole-snapshot rows only after a sync coordinator has
    /// durably bootstrapped the exact current canonical revision. Ordinary
    /// entity acknowledgements can never delete these compatibility rows.
    public func acknowledgeLegacyOperationsAfterBootstrap(
        revision: WorkspaceRevision
    ) throws {
        try database.acknowledgeLegacyOperationsAfterBootstrap(revision: revision)
    }

    /// Writes a revision-consistent, immutable projection. The destination
    /// must not exist; exports never replace canonical or previously exported
    /// customer data.
    @discardableResult
    public func export(
        to destinationURL: URL,
        generatedAt: Date = Date(),
        calendar: Calendar = .current
    ) throws -> WorkspaceExportManifest {
        let snapshot = try database.loadSnapshot()
        latestSnapshot = snapshot
        return try Self.writeExport(
            snapshot: snapshot,
            to: destinationURL,
            generatedAt: generatedAt,
            calendar: calendar
        )
    }

    /// Ensures one immutable generated projection exists for the current
    /// revision. Existing revision directories are never replaced.
    @discardableResult
    public func ensureProjection(
        in projectionsRootURL: URL,
        generatedAt: Date = Date(),
        calendar: Calendar = .current
    ) throws -> URL {
        let snapshot = try database.loadSnapshot()
        latestSnapshot = snapshot
        let revisionName = String(format: "revision-%012lld", snapshot.revision.rawValue)
        let destinationURL = projectionsRootURL.appendingPathComponent(revisionName, isDirectory: true)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try Self.pruneGeneratedProjections(in: projectionsRootURL, keeping: 2)
            return destinationURL
        }
        _ = try Self.writeExport(
            snapshot: snapshot,
            to: destinationURL,
            generatedAt: generatedAt,
            calendar: calendar
        )
        try Self.pruneGeneratedProjections(in: projectionsRootURL, keeping: 2)
        return destinationURL
    }

    private static func pruneGeneratedProjections(
        in rootURL: URL,
        keeping retentionCount: Int
    ) throws {
        let fileManager = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        let candidates: [URL]
        do {
            candidates = try fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )
            .filter { url in
                guard url.lastPathComponent.range(
                    of: #"^revision-[0-9]{12}$"#,
                    options: .regularExpression
                ) != nil,
                let values = try? url.resourceValues(forKeys: keys) else { return false }
                return values.isDirectory == true && values.isSymbolicLink != true
            }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        } catch {
            throw WorkspaceRepositoryError.exportFailed(operation: "inspect_generated_projections")
        }

        for staleURL in candidates.dropFirst(max(1, retentionCount)) {
            do {
                try fileManager.removeItem(at: staleURL)
            } catch {
                throw WorkspaceRepositoryError.exportFailed(operation: "prune_generated_projection")
            }
        }
    }

    private func removeChangeContinuation(_ identifier: UUID) {
        changeContinuations.removeValue(forKey: identifier)
    }

    private static func writeExport(
        snapshot: WorkspaceRepositorySnapshot,
        to destinationURL: URL,
        generatedAt: Date,
        calendar: Calendar
    ) throws -> WorkspaceExportManifest {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw WorkspaceRepositoryError.exportDestinationExists
        }

        let parentURL = destinationURL.deletingLastPathComponent()
        let stagingURL = parentURL.appendingPathComponent(
            ".founder-office-export-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )

        do {
            try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: false)
        } catch {
            throw WorkspaceRepositoryError.exportFailed(operation: "create_staging_directory")
        }

        var shouldRemoveStaging = true
        defer {
            if shouldRemoveStaging {
                try? fileManager.removeItem(at: stagingURL)
            }
        }

        let encoder = WorkspaceJSONCodec.makeEncoder(prettyPrinted: true)
        let openLoopsData: Data
        let personalizationData: Data
        do {
            openLoopsData = try encoder.encode(snapshot.content.openLoops)
            personalizationData = try encoder.encode(snapshot.content.personalization)
        } catch {
            throw WorkspaceRepositoryError.exportFailed(operation: "encode_projection")
        }
        let contextData = Data(
            WorkspaceProjection.contextMarkdown(
                for: snapshot.content.openLoops,
                generatedAt: generatedAt,
                calendar: calendar
            ).utf8
        )

        let projectedFiles = [
            (WorkspaceProjection.openLoopsFileName, openLoopsData),
            (WorkspaceProjection.personalizationFileName, personalizationData),
            (WorkspaceProjection.contextFileName, contextData)
        ]
        let records = projectedFiles.map { name, data in
            WorkspaceExportManifest.FileRecord(
                name: name,
                byteCount: data.count,
                sha256: WorkspaceProjection.digest(data)
            )
        }
        let manifest = WorkspaceExportManifest(
            workspaceID: snapshot.workspaceID,
            revision: snapshot.revision,
            generatedAt: generatedAt,
            files: records
        )

        do {
            for (name, data) in projectedFiles {
                try data.write(
                    to: stagingURL.appendingPathComponent(name),
                    options: [.atomic]
                )
            }
            let manifestData = try encoder.encode(manifest)
            try manifestData.write(
                to: stagingURL.appendingPathComponent(WorkspaceProjection.manifestFileName),
                options: [.atomic]
            )
            try fileManager.moveItem(at: stagingURL, to: destinationURL)
            shouldRemoveStaging = false
            return manifest
        } catch {
            if fileManager.fileExists(atPath: destinationURL.path) {
                throw WorkspaceRepositoryError.exportDestinationExists
            }
            throw WorkspaceRepositoryError.exportFailed(operation: "commit_projection")
        }
    }
}

private enum SQLiteWorkspaceTransactionResult {
    case committed(WorkspaceChange)
    case unchanged(WorkspaceRepositorySnapshot)
    case replayed(WorkspaceRepositorySnapshot, WorkspaceRevision)
}

private struct OpenedSQLiteWorkspace: @unchecked Sendable {
    var database: SQLiteWorkspaceDatabase
    var snapshot: WorkspaceRepositorySnapshot
}

private struct LegacyWorkspaceImport {
    var snapshot: FounderOfficeSnapshot
    var openLoopsDigest: String
    var personalizationDigest: String
}

private struct WorkspaceOperationReceipt {
    var fingerprint: Data
    var fingerprintVersion: Int
    var resultRevision: WorkspaceRevision
}

private struct StoredWorkspaceState {
    var workspaceID: UUID
    var writerID: WorkspaceWriterID
    var revision: WorkspaceRevision
    var snapshotData: Data
}

private struct LegacyOutboxUpgrade {
    var operationID: String
    var entityKind: String
    var entityID: String
    var payload: Data
}

private struct ValidatedWorkspaceMutation {
    var mutation: WorkspaceMutation
    var snapshotData: Data
    var fingerprint: Data
}

private enum SQLiteWorkspaceValue {
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
    case null
}

private final class SQLiteWorkspaceDatabase: @unchecked Sendable {
    static let currentSchemaVersion = 2
    static let applicationID: Int64 = 1_179_600_454 // ASCII "FOFF"
    static let supportedOpenLoopsSchemaVersion = 3
    static let supportedPersonalizationSchemaVersion = 6

    private let connection: OpaquePointer
    private let codec = WorkspaceJSONCodec()

    private init(connection: OpaquePointer) {
        self.connection = connection
    }

    deinit {
        sqlite3_close_v2(connection)
    }

    static func open(
        configuration: WorkspaceRepositoryConfiguration
    ) throws -> OpenedSQLiteWorkspace {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: configuration.databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            throw WorkspaceRepositoryError.databaseUnavailable(
                operation: "create_database_directory",
                code: Int32(SQLITE_CANTOPEN)
            )
        }

        var pointer: OpaquePointer?
        let openResult = sqlite3_open_v2(
            configuration.databaseURL.path,
            &pointer,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let pointer else {
            if let pointer {
                sqlite3_close_v2(pointer)
            }
            throw WorkspaceRepositoryError.databaseUnavailable(
                operation: "open_database",
                code: openResult
            )
        }

        let database = SQLiteWorkspaceDatabase(connection: pointer)
        try database.configureConnection()
        try database.migrateIfNeeded()
        try database.configureDurability()

        if let existing = try database.readState() {
            guard existing.workspaceID == configuration.workspaceID else {
                throw WorkspaceRepositoryError.workspaceMismatch
            }
            if let requestedWriterID = configuration.requestedWriterID,
               requestedWriterID != existing.writerID {
                throw WorkspaceRepositoryError.writerMismatch
            }
            return OpenedSQLiteWorkspace(database: database, snapshot: existing)
        }

        let legacyImport: LegacyWorkspaceImport?
        if let legacyDirectoryURL = configuration.legacyDirectoryURL {
            legacyImport = try loadLegacyWorkspace(from: legacyDirectoryURL)
        } else {
            legacyImport = nil
        }
        let seedSnapshot: FounderOfficeSnapshot
        if let legacyImport {
            seedSnapshot = legacyImport.snapshot
        } else if let initialSnapshot = configuration.initialSnapshot {
            seedSnapshot = initialSnapshot
        } else {
            throw WorkspaceRepositoryError.missingBootstrapSnapshot
        }

        let normalized = try database.codec.canonicalized(seedSnapshot)
        let writerID = configuration.requestedWriterID ?? WorkspaceWriterID()
        let snapshot = WorkspaceRepositorySnapshot(
            workspaceID: configuration.workspaceID,
            writerID: writerID,
            revision: .initial,
            content: normalized
        )
        try database.insertInitialState(snapshot, legacyImport: legacyImport)
        return OpenedSQLiteWorkspace(database: database, snapshot: snapshot)
    }

    func loadSnapshot() throws -> WorkspaceRepositorySnapshot {
        guard let snapshot = try readState() else {
            throw WorkspaceRepositoryError.invalidDatabase
        }
        return snapshot
    }

    func transact(
        expectedRevision: WorkspaceRevision,
        mutation: WorkspaceMutation
    ) throws -> SQLiteWorkspaceTransactionResult {
        let validated = try validate(mutation, expectedRevision: expectedRevision)
        let result: SQLiteWorkspaceTransactionResult = try transaction {
            guard let current = try readStoredState() else {
                throw WorkspaceRepositoryError.invalidDatabase
            }

            if let receipt = try receipt(for: mutation.idempotencyKey) {
                let expectedFingerprint: Data
                switch receipt.fingerprintVersion {
                case 1:
                    expectedFingerprint = try legacyFingerprint(
                        mutation: validated.mutation,
                        expectedRevision: expectedRevision
                    )
                case 2:
                    expectedFingerprint = validated.fingerprint
                default:
                    throw WorkspaceRepositoryError.invalidDatabase
                }
                guard receipt.fingerprint == expectedFingerprint else {
                    throw WorkspaceRepositoryError.idempotencyKeyReused
                }
                return .replayed(try decodeState(current), receipt.resultRevision)
            }

            if try receiptExists(operationID: mutation.operationID) {
                throw WorkspaceRepositoryError.operationIDReused
            }

            guard current.revision == expectedRevision else {
                throw WorkspaceRepositoryError.revisionConflict(
                    expected: expectedRevision,
                    actual: current.revision
                )
            }

            if current.snapshotData == validated.snapshotData {
                try insertReceipt(
                    mutation: mutation,
                    fingerprint: validated.fingerprint,
                    resultRevision: current.revision,
                    producedChange: false
                )
                return .unchanged(
                    WorkspaceRepositorySnapshot(
                        workspaceID: current.workspaceID,
                        writerID: current.writerID,
                        revision: current.revision,
                        content: validated.mutation.replacement
                    )
                )
            }

            let committedRevision = WorkspaceRevision(rawValue: current.revision.rawValue + 1)
            let nextSnapshot = WorkspaceRepositorySnapshot(
                workspaceID: current.workspaceID,
                writerID: current.writerID,
                revision: committedRevision,
                content: validated.mutation.replacement
            )
            let localEnvelope: WorkspaceLocalOperationEnvelopeV2
            let outboxPayload: Data
            do {
                localEnvelope = try WorkspaceLocalOperationBuilder.makeEnvelope(
                    entityKind: validated.mutation.entityKind,
                    entityID: validated.mutation.entityID,
                    changedFields: validated.mutation.changedFields,
                    snapshot: validated.mutation.replacement,
                    createdAt: validated.mutation.createdAt
                )
                outboxPayload = try WorkspaceLocalOperationBuilder.encode(localEnvelope)
            } catch let error as WorkspaceLocalOperationError {
                let reason: String
                switch error {
                case .unsupportedEntityKind:
                    reason = "entity kind is unsupported"
                case .missingEntity:
                    reason = "entity metadata does not identify one record"
                case .payloadTooLarge:
                    reason = "entity operation exceeds the local safety limit"
                case .unsupportedFormat, .invalidMetadata, .invalidRecord:
                    reason = "entity operation metadata is invalid"
                }
                throw WorkspaceRepositoryError.invalidMutation(reason: reason)
            }
            let operation = WorkspaceOutboxOperation(
                operationID: mutation.operationID,
                idempotencyKey: mutation.idempotencyKey,
                workspaceID: current.workspaceID,
                writerID: current.writerID,
                baseRevision: current.revision,
                committedRevision: committedRevision,
                entityKind: localEnvelope.entityKind.rawValue,
                entityID: localEnvelope.entityID,
                changedFields: validated.mutation.changedFields,
                fieldClocks: validated.mutation.fieldClocks,
                payload: outboxPayload,
                createdAt: validated.mutation.createdAt
            )

            try insertReceipt(
                mutation: mutation,
                fingerprint: validated.fingerprint,
                resultRevision: committedRevision,
                producedChange: true
            )
            try insertOutbox(operation)
            try updateState(
                nextSnapshot,
                snapshotData: validated.snapshotData,
                expectedRevision: current.revision
            )
            let change = WorkspaceChange(snapshot: nextSnapshot, operation: operation)
            return .committed(change)
        }
        return result
    }

    func pendingOperations(limit: Int) throws -> [WorkspaceOutboxOperation] {
        guard limit > 0, limit <= 1_000 else {
            throw WorkspaceRepositoryError.invalidMutation(
                reason: "outbox limit must be between 1 and 1000"
            )
        }
        let statement = try prepare(
            """
            SELECT operation_id, idempotency_key, workspace_id, writer_id,
                   base_revision, committed_revision, entity_kind, entity_id,
                   changed_fields, field_clocks, payload_format_version,
                   payload, created_at, delivery_attempts
            FROM operation_outbox
            ORDER BY committed_revision ASC, operation_id ASC
            LIMIT ?
            """,
            operation: "read_outbox"
        )
        try statement.bind([.integer(Int64(limit))], operation: "read_outbox")

        var operations: [WorkspaceOutboxOperation] = []
        while try statement.step(operation: "read_outbox") {
            let changedFieldsData = try statement.requiredBlob(at: 8, operation: "read_outbox")
            let fieldClocksData = try statement.requiredBlob(at: 9, operation: "read_outbox")
            let changedFields: [String]
            let fieldClocks: [String: Date]
            do {
                changedFields = try codec.decoder.decode([String].self, from: changedFieldsData)
                fieldClocks = try codec.decoder.decode([String: Date].self, from: fieldClocksData)
            } catch {
                throw WorkspaceRepositoryError.invalidDatabase
            }

            guard
                let operationID = UUID(uuidString: try statement.requiredText(at: 0, operation: "read_outbox")),
                let idempotencyUUID = UUID(uuidString: try statement.requiredText(at: 1, operation: "read_outbox")),
                let workspaceID = UUID(uuidString: try statement.requiredText(at: 2, operation: "read_outbox")),
                let writerUUID = UUID(uuidString: try statement.requiredText(at: 3, operation: "read_outbox"))
            else {
                throw WorkspaceRepositoryError.invalidDatabase
            }

            let operation = WorkspaceOutboxOperation(
                operationID: operationID,
                idempotencyKey: WorkspaceIdempotencyKey(rawValue: idempotencyUUID),
                workspaceID: workspaceID,
                writerID: WorkspaceWriterID(rawValue: writerUUID),
                baseRevision: WorkspaceRevision(rawValue: statement.integer(at: 4)),
                committedRevision: WorkspaceRevision(rawValue: statement.integer(at: 5)),
                entityKind: try statement.requiredText(at: 6, operation: "read_outbox"),
                entityID: try statement.requiredText(at: 7, operation: "read_outbox"),
                changedFields: changedFields,
                fieldClocks: fieldClocks,
                payloadFormatVersion: Int(statement.integer(at: 10)),
                payload: try statement.requiredBlob(at: 11, operation: "read_outbox"),
                createdAt: Date(timeIntervalSince1970: statement.double(at: 12)),
                deliveryAttempts: Int(statement.integer(at: 13))
            )
            guard operation.baseRevision.rawValue >= 0,
                  operation.committedRevision.rawValue > operation.baseRevision.rawValue,
                  operation.createdAt.timeIntervalSinceReferenceDate.isFinite,
                  operation.deliveryAttempts >= 0,
                  operation.changedFields == Array(Set(operation.changedFields)).sorted(),
                  Set(operation.fieldClocks.keys).isSubset(of: Set(operation.changedFields)),
                  operation.fieldClocks.values.allSatisfy({
                      $0.timeIntervalSinceReferenceDate.isFinite
                  }) else {
                throw WorkspaceRepositoryError.invalidDatabase
            }
            do {
                _ = try operation.decodedLocalPayload()
            } catch {
                throw WorkspaceRepositoryError.invalidDatabase
            }
            operations.append(operation)
        }
        return operations
    }

    func recordDeliveryAttempt(operationIDs: [UUID]) throws {
        guard !operationIDs.isEmpty else { return }
        try transaction {
            for operationID in Set(operationIDs) {
                try execute(
                    """
                    UPDATE operation_outbox
                    SET delivery_attempts = delivery_attempts + 1
                    WHERE operation_id = ? AND payload_format_version = ?
                    """,
                    bindings: [
                        .text(operationID.uuidString.lowercased()),
                        .integer(Int64(WorkspaceLocalOperationEnvelopeV2.formatVersion))
                    ],
                    operation: "record_delivery_attempt"
                )
            }
        }
    }

    func acknowledgeOperations(operationIDs: [UUID]) throws {
        guard !operationIDs.isEmpty else { return }
        try transaction {
            for operationID in Set(operationIDs) {
                try execute(
                    """
                    DELETE FROM operation_outbox
                    WHERE operation_id = ? AND payload_format_version = ?
                    """,
                    bindings: [
                        .text(operationID.uuidString.lowercased()),
                        .integer(Int64(WorkspaceLocalOperationEnvelopeV2.formatVersion))
                    ],
                    operation: "acknowledge_outbox"
                )
            }
        }
    }

    func acknowledgeLegacyOperationsAfterBootstrap(
        revision: WorkspaceRevision
    ) throws {
        guard revision.rawValue >= 0 else {
            throw WorkspaceRepositoryError.invalidMutation(
                reason: "bootstrap revision cannot be negative"
            )
        }
        try transaction {
            let current = try loadSnapshot()
            guard revision == current.revision else {
                throw WorkspaceRepositoryError.revisionConflict(
                    expected: revision,
                    actual: current.revision
                )
            }
            try execute(
                """
                DELETE FROM operation_outbox
                WHERE payload_format_version = ? AND committed_revision <= ?
                """,
                bindings: [
                    .integer(Int64(WorkspaceOutboxOperation.legacySnapshotPayloadFormatVersion)),
                    .integer(revision.rawValue)
                ],
                operation: "acknowledge_legacy_outbox_bootstrap"
            )
        }
    }

    private func configureConnection() throws {
        _ = sqlite3_limit(connection, SQLITE_LIMIT_LENGTH, 72 * 1_024 * 1_024)
        try execute("PRAGMA foreign_keys = ON", operation: "configure_database")
        try execute("PRAGMA busy_timeout = 5000", operation: "configure_database")
    }

    /// Persistent pragmas are applied only after the application ID and schema
    /// version pass validation. Opening an unrelated or newer SQLite file must
    /// not change that file before failing closed.
    private func configureDurability() throws {
        try execute("PRAGMA journal_mode = WAL", operation: "configure_database")
        try execute("PRAGMA synchronous = FULL", operation: "configure_database")
    }

    private func migrateIfNeeded() throws {
        let applicationID = try pragmaInteger("application_id")
        let schemaVersion = Int(try pragmaInteger("user_version"))

        if applicationID != 0, applicationID != Self.applicationID {
            throw WorkspaceRepositoryError.invalidDatabase
        }
        guard schemaVersion <= Self.currentSchemaVersion else {
            throw WorkspaceRepositoryError.schemaTooNew(
                found: schemaVersion,
                supported: Self.currentSchemaVersion
            )
        }

        if schemaVersion == 0 {
            if applicationID == 0, try hasUserTables() {
                throw WorkspaceRepositoryError.invalidDatabase
            }
            try transaction {
                try execute(
                    """
                    CREATE TABLE workspace_state (
                        singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                        workspace_id TEXT NOT NULL,
                        writer_id TEXT NOT NULL,
                        revision INTEGER NOT NULL CHECK (revision >= 0),
                        snapshot BLOB NOT NULL,
                        updated_at REAL NOT NULL
                    )
                    """,
                    operation: "migrate_database"
                )
                try execute(
                    """
                    CREATE TABLE operation_receipts (
                        idempotency_key TEXT PRIMARY KEY NOT NULL,
                        operation_id TEXT NOT NULL UNIQUE,
                        request_fingerprint BLOB NOT NULL,
                        fingerprint_version INTEGER NOT NULL CHECK (fingerprint_version IN (1, 2)),
                        result_revision INTEGER NOT NULL CHECK (result_revision >= 0),
                        produced_change INTEGER NOT NULL CHECK (produced_change IN (0, 1)),
                        created_at REAL NOT NULL
                    )
                    """,
                    operation: "migrate_database"
                )
                try execute(
                    """
                    CREATE TABLE operation_outbox (
                        operation_id TEXT PRIMARY KEY NOT NULL,
                        idempotency_key TEXT NOT NULL UNIQUE
                            REFERENCES operation_receipts(idempotency_key),
                        workspace_id TEXT NOT NULL,
                        writer_id TEXT NOT NULL,
                        base_revision INTEGER NOT NULL CHECK (base_revision >= 0),
                        committed_revision INTEGER NOT NULL UNIQUE CHECK (committed_revision > 0),
                        entity_kind TEXT NOT NULL,
                        entity_id TEXT NOT NULL,
                        changed_fields BLOB NOT NULL,
                        field_clocks BLOB NOT NULL,
                        payload_format_version INTEGER NOT NULL,
                        payload BLOB NOT NULL,
                        created_at REAL NOT NULL,
                        delivery_attempts INTEGER NOT NULL DEFAULT 0 CHECK (delivery_attempts >= 0)
                    )
                    """,
                    operation: "migrate_database"
                )
                try execute(
                    """
                    CREATE TABLE legacy_imports (
                        singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                        openloops_sha256 TEXT NOT NULL,
                        personalization_sha256 TEXT NOT NULL,
                        imported_at REAL NOT NULL
                    )
                    """,
                    operation: "migrate_database"
                )
                try execute(
                    "PRAGMA application_id = \(Self.applicationID)",
                    operation: "migrate_database"
                )
                try execute(
                    "PRAGMA user_version = \(Self.currentSchemaVersion)",
                    operation: "migrate_database"
                )
            }
        } else if applicationID != Self.applicationID {
            throw WorkspaceRepositoryError.invalidDatabase
        } else if schemaVersion == 1 {
            try migrateVersionOneOutbox()
        }
    }

    /// Converts only legacy rows whose snapshot and metadata identify one
    /// bounded entity without ambiguity. Broad historical personalization rows
    /// stay at format 1 and require an explicit full bootstrap acknowledgement;
    /// they are never disguised as normal entity operations.
    private func migrateVersionOneOutbox() throws {
        try transaction {
            if try !table("operation_receipts", hasColumn: "fingerprint_version") {
                try execute(
                    """
                    ALTER TABLE operation_receipts
                    ADD COLUMN fingerprint_version INTEGER NOT NULL DEFAULT 1
                        CHECK (fingerprint_version IN (1, 2))
                    """,
                    operation: "migrate_outbox_v2"
                )
            }
            let statement = try prepare(
                """
                SELECT operation_id, entity_kind, entity_id, changed_fields,
                       payload_format_version, payload, created_at
                FROM operation_outbox
                ORDER BY committed_revision ASC, operation_id ASC
                """,
                operation: "migrate_outbox_v2"
            )
            var upgrades: [LegacyOutboxUpgrade] = []
            while try statement.step(operation: "migrate_outbox_v2") {
                let payloadFormatVersion = Int(statement.integer(at: 4))
                guard payloadFormatVersion == WorkspaceOutboxOperation.legacySnapshotPayloadFormatVersion
                        || payloadFormatVersion == WorkspaceLocalOperationEnvelopeV2.formatVersion else {
                    throw WorkspaceRepositoryError.invalidDatabase
                }
                guard payloadFormatVersion == WorkspaceOutboxOperation.legacySnapshotPayloadFormatVersion else {
                    continue
                }

                let payload = try statement.requiredBlob(at: 5, operation: "migrate_outbox_v2")
                guard !payload.isEmpty,
                      payload.count <= WorkspaceOutboxOperation.maximumLegacySnapshotPayloadByteCount else {
                    throw WorkspaceRepositoryError.invalidDatabase
                }
                let snapshot: FounderOfficeSnapshot
                let changedFields: [String]
                do {
                    snapshot = try codec.normalized(
                        codec.decoder.decode(FounderOfficeSnapshot.self, from: payload)
                    )
                    changedFields = try codec.decoder.decode(
                        [String].self,
                        from: try statement.requiredBlob(at: 3, operation: "migrate_outbox_v2")
                    )
                } catch let error as WorkspaceRepositoryError {
                    throw error
                } catch {
                    throw WorkspaceRepositoryError.invalidDatabase
                }

                do {
                    let envelope = try WorkspaceLocalOperationBuilder.makeEnvelope(
                        entityKind: try statement.requiredText(at: 1, operation: "migrate_outbox_v2"),
                        entityID: try statement.requiredText(at: 2, operation: "migrate_outbox_v2"),
                        changedFields: Array(Set(changedFields)).sorted(),
                        snapshot: snapshot,
                        createdAt: Date(timeIntervalSince1970: statement.double(at: 6))
                    )
                    upgrades.append(
                        LegacyOutboxUpgrade(
                            operationID: try statement.requiredText(at: 0, operation: "migrate_outbox_v2"),
                            entityKind: envelope.entityKind.rawValue,
                            entityID: envelope.entityID,
                            payload: try WorkspaceLocalOperationBuilder.encode(envelope)
                        )
                    )
                } catch is WorkspaceLocalOperationError {
                    // A decoded schema-1 row that cannot be represented by the
                    // stricter bounded shape stays byte-for-byte intact for a
                    // future canonical bootstrap. Never approximate it or turn
                    // a compatibility limitation into a launch failure.
                    continue
                }
            }

            for upgrade in upgrades {
                try execute(
                    """
                    UPDATE operation_outbox
                    SET entity_kind = ?, entity_id = ?, payload_format_version = ?, payload = ?
                    WHERE operation_id = ? AND payload_format_version = ?
                    """,
                    bindings: [
                        .text(upgrade.entityKind),
                        .text(upgrade.entityID),
                        .integer(Int64(WorkspaceLocalOperationEnvelopeV2.formatVersion)),
                        .blob(upgrade.payload),
                        .text(upgrade.operationID),
                        .integer(Int64(WorkspaceOutboxOperation.legacySnapshotPayloadFormatVersion))
                    ],
                    operation: "migrate_outbox_v2"
                )
                guard sqlite3_changes(connection) == 1 else {
                    throw WorkspaceRepositoryError.invalidDatabase
                }
            }
            try execute(
                "PRAGMA user_version = \(Self.currentSchemaVersion)",
                operation: "migrate_outbox_v2"
            )
        }
    }

    private func insertInitialState(
        _ snapshot: WorkspaceRepositorySnapshot,
        legacyImport: LegacyWorkspaceImport?
    ) throws {
        let snapshotData = try codec.encode(snapshot.content)
        try transaction {
            guard try readState() == nil else {
                throw WorkspaceRepositoryError.invalidDatabase
            }
            try execute(
                """
                INSERT INTO workspace_state (
                    singleton, workspace_id, writer_id, revision, snapshot, updated_at
                ) VALUES (1, ?, ?, ?, ?, ?)
                """,
                bindings: [
                    .text(snapshot.workspaceID.uuidString.lowercased()),
                    .text(snapshot.writerID.description),
                    .integer(snapshot.revision.rawValue),
                    .blob(snapshotData),
                    .real(Date().timeIntervalSince1970)
                ],
                operation: "bootstrap_workspace"
            )
            if let legacyImport {
                try execute(
                    """
                    INSERT INTO legacy_imports (
                        singleton, openloops_sha256, personalization_sha256, imported_at
                    ) VALUES (1, ?, ?, ?)
                    """,
                    bindings: [
                        .text(legacyImport.openLoopsDigest),
                        .text(legacyImport.personalizationDigest),
                        .real(Date().timeIntervalSince1970)
                    ],
                    operation: "record_legacy_import"
                )
            }
        }
    }

    private func readState() throws -> WorkspaceRepositorySnapshot? {
        guard let stored = try readStoredState() else { return nil }
        return try decodeState(stored)
    }

    /// Reads the exact canonical bytes without decoding the full workspace.
    /// A changed transaction already carries a canonical replacement, so this
    /// avoids another 10,000-Move decode and encode cycle on its hot path.
    private func readStoredState() throws -> StoredWorkspaceState? {
        let statement = try prepare(
            """
            SELECT workspace_id, writer_id, revision, snapshot
            FROM workspace_state
            WHERE singleton = 1
            """,
            operation: "read_snapshot"
        )
        guard try statement.step(operation: "read_snapshot") else { return nil }

        guard
            let workspaceID = UUID(uuidString: try statement.requiredText(at: 0, operation: "read_snapshot")),
            let writerUUID = UUID(uuidString: try statement.requiredText(at: 1, operation: "read_snapshot"))
        else {
            throw WorkspaceRepositoryError.invalidDatabase
        }
        let revisionValue = statement.integer(at: 2)
        guard revisionValue >= 0 else {
            throw WorkspaceRepositoryError.invalidDatabase
        }

        let data = try statement.requiredBlob(at: 3, operation: "read_snapshot")
        guard !data.isEmpty, data.count <= 64 * 1_024 * 1_024 else {
            throw WorkspaceRepositoryError.invalidDatabase
        }
        return StoredWorkspaceState(
            workspaceID: workspaceID,
            writerID: WorkspaceWriterID(rawValue: writerUUID),
            revision: WorkspaceRevision(rawValue: revisionValue),
            snapshotData: data
        )
    }

    private func decodeState(
        _ stored: StoredWorkspaceState
    ) throws -> WorkspaceRepositorySnapshot {
        let content: FounderOfficeSnapshot
        do {
            content = try codec.normalized(
                codec.decoder.decode(FounderOfficeSnapshot.self, from: stored.snapshotData)
            )
        } catch let error as WorkspaceRepositoryError {
            throw error
        } catch {
            throw WorkspaceRepositoryError.invalidDatabase
        }
        return WorkspaceRepositorySnapshot(
            workspaceID: stored.workspaceID,
            writerID: stored.writerID,
            revision: stored.revision,
            content: content
        )
    }

    private func validate(
        _ mutation: WorkspaceMutation,
        expectedRevision: WorkspaceRevision
    ) throws -> ValidatedWorkspaceMutation {
        guard expectedRevision.rawValue >= 0 else {
            throw WorkspaceRepositoryError.invalidMutation(reason: "revision cannot be negative")
        }

        let entityKind = mutation.entityKind.trimmingCharacters(in: .whitespacesAndNewlines)
        let entityID = mutation.entityID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entityKind.isEmpty, entityKind.utf8.count <= 128 else {
            throw WorkspaceRepositoryError.invalidMutation(reason: "entity kind is missing or too long")
        }
        guard !entityID.isEmpty, entityID.utf8.count <= 512 else {
            throw WorkspaceRepositoryError.invalidMutation(reason: "entity identifier is missing or too long")
        }
        guard mutation.createdAt.timeIntervalSinceReferenceDate.isFinite else {
            throw WorkspaceRepositoryError.invalidMutation(reason: "creation time is invalid")
        }

        let changedFields = Array(Set(mutation.changedFields)).sorted()
        guard !changedFields.isEmpty, changedFields.count <= 256 else {
            throw WorkspaceRepositoryError.invalidMutation(reason: "changed fields are missing or too numerous")
        }
        guard changedFields.allSatisfy({ field in
            !field.isEmpty
                && field == field.trimmingCharacters(in: .whitespacesAndNewlines)
                && field.utf8.count <= 128
        }) else {
            throw WorkspaceRepositoryError.invalidMutation(reason: "a changed field is invalid")
        }
        guard Set(mutation.fieldClocks.keys).isSubset(of: Set(changedFields)) else {
            throw WorkspaceRepositoryError.invalidMutation(
                reason: "field clocks must refer to changed fields"
            )
        }
        guard mutation.fieldClocks.values.allSatisfy({ $0.timeIntervalSinceReferenceDate.isFinite }) else {
            throw WorkspaceRepositoryError.invalidMutation(reason: "a field clock is invalid")
        }

        let canonical = try codec.canonicalizedWithData(mutation.replacement)
        let normalizedSnapshot = canonical.snapshot
        let normalizedMutation = WorkspaceMutation(
            operationID: mutation.operationID,
            idempotencyKey: mutation.idempotencyKey,
            entityKind: entityKind,
            entityID: entityID,
            changedFields: changedFields,
            fieldClocks: mutation.fieldClocks,
            replacement: normalizedSnapshot,
            createdAt: mutation.createdAt
        )
        let snapshotData = canonical.data
        guard snapshotData.count <= 64 * 1_024 * 1_024 else {
            throw WorkspaceRepositoryError.invalidMutation(reason: "snapshot exceeds the local safety limit")
        }

        struct FingerprintEnvelope: Codable {
            var expectedRevision: WorkspaceRevision
            var operationID: UUID
            var idempotencyKey: WorkspaceIdempotencyKey
            var entityKind: String
            var entityID: String
            var changedFields: [String]
            var fieldClocks: [String: Date]
            var snapshotDigest: Data
            var createdAt: Date
        }
        let fingerprintInput = try codec.encode(
            FingerprintEnvelope(
                expectedRevision: expectedRevision,
                operationID: normalizedMutation.operationID,
                idempotencyKey: normalizedMutation.idempotencyKey,
                entityKind: normalizedMutation.entityKind,
                entityID: normalizedMutation.entityID,
                changedFields: normalizedMutation.changedFields,
                fieldClocks: normalizedMutation.fieldClocks,
                snapshotDigest: Data(SHA256.hash(data: snapshotData)),
                createdAt: normalizedMutation.createdAt
            )
        )
        let fingerprint = Data(SHA256.hash(data: fingerprintInput))
        return ValidatedWorkspaceMutation(
            mutation: normalizedMutation,
            snapshotData: snapshotData,
            fingerprint: fingerprint
        )
    }

    private func updateState(
        _ snapshot: WorkspaceRepositorySnapshot,
        snapshotData: Data,
        expectedRevision: WorkspaceRevision
    ) throws {
        try execute(
            """
            UPDATE workspace_state
            SET revision = ?, snapshot = ?, updated_at = ?
            WHERE singleton = 1 AND revision = ?
            """,
            bindings: [
                .integer(snapshot.revision.rawValue),
                .blob(snapshotData),
                .real(Date().timeIntervalSince1970),
                .integer(expectedRevision.rawValue)
            ],
            operation: "commit_snapshot"
        )
        guard sqlite3_changes(connection) == 1 else {
            let actual = try readState()?.revision ?? expectedRevision
            throw WorkspaceRepositoryError.revisionConflict(
                expected: expectedRevision,
                actual: actual
            )
        }
    }

    private func receipt(for key: WorkspaceIdempotencyKey) throws -> WorkspaceOperationReceipt? {
        let statement = try prepare(
            """
            SELECT request_fingerprint, fingerprint_version, result_revision
            FROM operation_receipts
            WHERE idempotency_key = ?
            """,
            operation: "read_idempotency_receipt"
        )
        try statement.bind([.text(key.description)], operation: "read_idempotency_receipt")
        guard try statement.step(operation: "read_idempotency_receipt") else { return nil }
        return WorkspaceOperationReceipt(
            fingerprint: try statement.requiredBlob(at: 0, operation: "read_idempotency_receipt"),
            fingerprintVersion: Int(statement.integer(at: 1)),
            resultRevision: WorkspaceRevision(rawValue: statement.integer(at: 2))
        )
    }

    /// Reproduces the schema-1 fingerprint exactly so retries written by a
    /// previous app build remain idempotent after the outbox migration.
    private func legacyFingerprint(
        mutation: WorkspaceMutation,
        expectedRevision: WorkspaceRevision
    ) throws -> Data {
        struct FingerprintEnvelope: Codable {
            var expectedRevision: WorkspaceRevision
            var mutation: WorkspaceMutation
        }
        let input = try codec.encode(
            FingerprintEnvelope(expectedRevision: expectedRevision, mutation: mutation)
        )
        return Data(SHA256.hash(data: input))
    }

    private func receiptExists(operationID: UUID) throws -> Bool {
        let statement = try prepare(
            "SELECT 1 FROM operation_receipts WHERE operation_id = ? LIMIT 1",
            operation: "read_operation_receipt"
        )
        try statement.bind(
            [.text(operationID.uuidString.lowercased())],
            operation: "read_operation_receipt"
        )
        return try statement.step(operation: "read_operation_receipt")
    }

    private func insertReceipt(
        mutation: WorkspaceMutation,
        fingerprint: Data,
        resultRevision: WorkspaceRevision,
        producedChange: Bool
    ) throws {
        try execute(
            """
            INSERT INTO operation_receipts (
                idempotency_key, operation_id, request_fingerprint,
                fingerprint_version, result_revision, produced_change, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .text(mutation.idempotencyKey.description),
                .text(mutation.operationID.uuidString.lowercased()),
                .blob(fingerprint),
                .integer(2),
                .integer(resultRevision.rawValue),
                .integer(producedChange ? 1 : 0),
                .real(mutation.createdAt.timeIntervalSince1970)
            ],
            operation: "insert_idempotency_receipt"
        )
    }

    private func insertOutbox(_ operation: WorkspaceOutboxOperation) throws {
        let changedFields = try codec.encode(operation.changedFields)
        let fieldClocks = try codec.encode(operation.fieldClocks)
        try execute(
            """
            INSERT INTO operation_outbox (
                operation_id, idempotency_key, workspace_id, writer_id,
                base_revision, committed_revision, entity_kind, entity_id,
                changed_fields, field_clocks, payload_format_version, payload,
                created_at, delivery_attempts
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .text(operation.operationID.uuidString.lowercased()),
                .text(operation.idempotencyKey.description),
                .text(operation.workspaceID.uuidString.lowercased()),
                .text(operation.writerID.description),
                .integer(operation.baseRevision.rawValue),
                .integer(operation.committedRevision.rawValue),
                .text(operation.entityKind),
                .text(operation.entityID),
                .blob(changedFields),
                .blob(fieldClocks),
                .integer(Int64(operation.payloadFormatVersion)),
                .blob(operation.payload),
                .real(operation.createdAt.timeIntervalSince1970),
                .integer(Int64(operation.deliveryAttempts))
            ],
            operation: "insert_outbox"
        )
    }

    private static func loadLegacyWorkspace(
        from directoryURL: URL
    ) throws -> LegacyWorkspaceImport? {
        let fileManager = FileManager.default
        let openLoopsURL = directoryURL.appendingPathComponent(WorkspaceProjection.openLoopsFileName)
        let personalizationURL = directoryURL.appendingPathComponent(
            WorkspaceProjection.personalizationFileName
        )
        let openLoopsExists = fileManager.fileExists(atPath: openLoopsURL.path)
        let personalizationExists = fileManager.fileExists(atPath: personalizationURL.path)

        guard openLoopsExists || personalizationExists else { return nil }
        guard openLoopsExists && personalizationExists else {
            throw WorkspaceRepositoryError.incompleteLegacyWorkspace
        }

        let openLoopsData: Data
        let personalizationData: Data
        do {
            openLoopsData = try Data(contentsOf: openLoopsURL, options: [.mappedIfSafe])
        } catch {
            throw WorkspaceRepositoryError.unreadableLegacyWorkspace(component: "Moves")
        }
        do {
            personalizationData = try Data(contentsOf: personalizationURL, options: [.mappedIfSafe])
        } catch {
            throw WorkspaceRepositoryError.unreadableLegacyWorkspace(component: "personalization")
        }

        let codec = WorkspaceJSONCodec()
        let openLoops: OpenLoopsDocument
        let personalization: PersonalizationDocument
        do {
            openLoops = try codec.decoder.decode(OpenLoopsDocument.self, from: openLoopsData)
        } catch {
            throw WorkspaceRepositoryError.unreadableLegacyWorkspace(component: "Moves")
        }
        do {
            personalization = try codec.decoder.decode(
                PersonalizationDocument.self,
                from: personalizationData
            )
        } catch {
            throw WorkspaceRepositoryError.unreadableLegacyWorkspace(component: "personalization")
        }

        let snapshot = try codec.normalized(
            FounderOfficeSnapshot(openLoops: openLoops, personalization: personalization)
        )
        return LegacyWorkspaceImport(
            snapshot: snapshot,
            openLoopsDigest: WorkspaceProjection.digest(openLoopsData),
            personalizationDigest: WorkspaceProjection.digest(personalizationData)
        )
    }

    private func hasUserTables() throws -> Bool {
        let statement = try prepare(
            """
            SELECT 1
            FROM sqlite_master
            WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
            LIMIT 1
            """,
            operation: "inspect_database"
        )
        return try statement.step(operation: "inspect_database")
    }

    private func table(_ tableName: String, hasColumn columnName: String) throws -> Bool {
        guard tableName == "operation_receipts", columnName == "fingerprint_version" else {
            throw WorkspaceRepositoryError.invalidDatabase
        }
        let statement = try prepare(
            "PRAGMA table_info(operation_receipts)",
            operation: "inspect_database"
        )
        while try statement.step(operation: "inspect_database") {
            if try statement.requiredText(at: 1, operation: "inspect_database") == columnName {
                return true
            }
        }
        return false
    }

    private func pragmaInteger(_ name: String) throws -> Int64 {
        let statement = try prepare("PRAGMA \(name)", operation: "inspect_database")
        guard try statement.step(operation: "inspect_database") else {
            throw WorkspaceRepositoryError.invalidDatabase
        }
        return statement.integer(at: 0)
    }

    private func transaction<Result>(_ body: () throws -> Result) throws -> Result {
        try execute("BEGIN IMMEDIATE", operation: "begin_transaction")
        do {
            let result = try body()
            try execute("COMMIT", operation: "commit_transaction")
            return result
        } catch {
            try? execute("ROLLBACK", operation: "rollback_transaction")
            throw error
        }
    }

    private func execute(
        _ sql: String,
        bindings: [SQLiteWorkspaceValue] = [],
        operation: String
    ) throws {
        let statement = try prepare(sql, operation: operation)
        try statement.bind(bindings, operation: operation)
        while true {
            switch sqlite3_step(statement.pointer) {
            case SQLITE_ROW:
                continue
            case SQLITE_DONE:
                return
            default:
                throw databaseError(operation: operation)
            }
        }
    }

    private func prepare(_ sql: String, operation: String) throws -> SQLiteWorkspaceStatement {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw databaseError(operation: operation)
        }
        return SQLiteWorkspaceStatement(database: connection, pointer: statement)
    }

    private func databaseError(operation: String) -> WorkspaceRepositoryError {
        WorkspaceRepositoryError.databaseUnavailable(
            operation: operation,
            code: sqlite3_errcode(connection)
        )
    }
}

private final class SQLiteWorkspaceStatement {
    let database: OpaquePointer
    let pointer: OpaquePointer

    init(database: OpaquePointer, pointer: OpaquePointer) {
        self.database = database
        self.pointer = pointer
    }

    deinit {
        sqlite3_finalize(pointer)
    }

    func bind(_ values: [SQLiteWorkspaceValue], operation: String) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case let .integer(value):
                result = sqlite3_bind_int64(pointer, index, value)
            case let .real(value):
                result = sqlite3_bind_double(pointer, index, value)
            case let .text(value):
                result = value.withCString { cString in
                    sqlite3_bind_text(pointer, index, cString, -1, sqliteTransientDestructor)
                }
            case let .blob(data):
                result = data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(
                        pointer,
                        index,
                        bytes.baseAddress,
                        Int32(bytes.count),
                        sqliteTransientDestructor
                    )
                }
            case .null:
                result = sqlite3_bind_null(pointer, index)
            }
            guard result == SQLITE_OK else {
                throw WorkspaceRepositoryError.databaseUnavailable(
                    operation: operation,
                    code: sqlite3_errcode(database)
                )
            }
        }
    }

    func step(operation: String) throws -> Bool {
        let result = sqlite3_step(pointer)
        switch result {
        case SQLITE_ROW:
            return true
        case SQLITE_DONE:
            return false
        default:
            throw WorkspaceRepositoryError.databaseUnavailable(
                operation: operation,
                code: sqlite3_errcode(database)
            )
        }
    }

    func integer(at index: Int32) -> Int64 {
        sqlite3_column_int64(pointer, index)
    }

    func double(at index: Int32) -> Double {
        sqlite3_column_double(pointer, index)
    }

    func requiredText(at index: Int32, operation: String) throws -> String {
        guard sqlite3_column_type(pointer, index) == SQLITE_TEXT,
              let text = sqlite3_column_text(pointer, index) else {
            throw WorkspaceRepositoryError.databaseUnavailable(
                operation: operation,
                code: Int32(SQLITE_CORRUPT)
            )
        }
        return String(cString: text)
    }

    func requiredBlob(at index: Int32, operation: String) throws -> Data {
        guard sqlite3_column_type(pointer, index) == SQLITE_BLOB else {
            throw WorkspaceRepositoryError.databaseUnavailable(
                operation: operation,
                code: Int32(SQLITE_CORRUPT)
            )
        }
        let byteCount = Int(sqlite3_column_bytes(pointer, index))
        guard byteCount > 0 else { return Data() }
        guard let bytes = sqlite3_column_blob(pointer, index) else {
            throw WorkspaceRepositoryError.databaseUnavailable(
                operation: operation,
                code: Int32(SQLITE_CORRUPT)
            )
        }
        return Data(bytes: bytes, count: byteCount)
    }
}

private final class WorkspaceJSONCodec {
    let encoder: JSONEncoder
    let decoder: JSONDecoder

    init() {
        encoder = Self.makeEncoder(prettyPrinted: false)
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    static func makeEncoder(prettyPrinted: Bool) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    func encode<Value: Encodable>(_ value: Value) throws -> Data {
        do {
            return try encoder.encode(value)
        } catch {
            throw WorkspaceRepositoryError.invalidMutation(reason: "data could not be encoded")
        }
    }

    func normalized(_ snapshot: FounderOfficeSnapshot) throws -> FounderOfficeSnapshot {
        guard snapshot.openLoops.schemaVersion <= SQLiteWorkspaceDatabase.supportedOpenLoopsSchemaVersion else {
            throw WorkspaceRepositoryError.snapshotSchemaTooNew(
                component: "Moves",
                found: snapshot.openLoops.schemaVersion,
                supported: SQLiteWorkspaceDatabase.supportedOpenLoopsSchemaVersion
            )
        }
        guard snapshot.personalization.schemaVersion <= SQLiteWorkspaceDatabase.supportedPersonalizationSchemaVersion else {
            throw WorkspaceRepositoryError.snapshotSchemaTooNew(
                component: "personalization",
                found: snapshot.personalization.schemaVersion,
                supported: SQLiteWorkspaceDatabase.supportedPersonalizationSchemaVersion
            )
        }
        return FounderOfficeSnapshot(
            openLoops: OpenLoopsMigration.upgradingPlanningSchema(snapshot.openLoops),
            personalization: snapshot.personalization
        )
    }

    /// Returns the exact representation that a subsequent database read will
    /// produce. This avoids exposing sub-second Date values that the existing
    /// ISO-8601 documents intentionally normalize during durable encoding.
    func canonicalized(_ snapshot: FounderOfficeSnapshot) throws -> FounderOfficeSnapshot {
        try canonicalizedWithData(snapshot).snapshot
    }

    /// Canonical content and the exact bytes persisted for it. Keeping these
    /// together avoids re-encoding a 10,000-Move workspace when one entity is
    /// committed to the bounded operation outbox.
    func canonicalizedWithData(
        _ snapshot: FounderOfficeSnapshot
    ) throws -> (snapshot: FounderOfficeSnapshot, data: Data) {
        let normalizedSnapshot = try normalized(snapshot)
        do {
            let data = try encoder.encode(normalizedSnapshot)
            return (
                try decoder.decode(FounderOfficeSnapshot.self, from: data),
                data
            )
        } catch let error as WorkspaceRepositoryError {
            throw error
        } catch {
            throw WorkspaceRepositoryError.invalidMutation(reason: "data could not be encoded")
        }
    }
}

private let sqliteTransientDestructor = unsafeBitCast(
    -1,
    to: sqlite3_destructor_type.self
)
