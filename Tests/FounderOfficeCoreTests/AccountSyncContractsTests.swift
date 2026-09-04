import Foundation
import Testing
@testable import FounderOfficeCore

struct AccountSyncContractsTests {
    private let accountID = FounderAccountID(
        rawValue: UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
    )
    private let workspaceID = WorkspaceID(
        rawValue: UUID(uuidString: "20000000-0000-4000-8000-000000000002")!
    )
    private let deviceID = DeviceID(
        rawValue: UUID(uuidString: "30000000-0000-4000-8000-000000000003")!
    )
    private let operationID = SyncOperationID(
        rawValue: UUID(uuidString: "40000000-0000-4000-8000-000000000004")!
    )
    private let entityID = UUID(uuidString: "50000000-0000-4000-8000-000000000005")!
    private let timestamp = Date(timeIntervalSince1970: 1_788_134_400)

    private func moveRecord(revision: Int64 = 1) -> [String: SyncJSONValue] {
        [
            "id": .string(entityID.uuidString),
            "title": .string("Review launch checklist"),
            "details": .string(""),
            "status": .string("doing"),
            "previousStatus": .null,
            "priority": .string("P1"),
            "dueOn": .null,
            "completedAt": .null,
            "deletedAt": .null,
            "source": .string("founders-office"),
            "revision": .integer(revision),
            "fieldClocks": .object(["priority": .string("2026-08-31T10:00:00Z")]),
            "createdAt": .string("2026-08-31T10:00:00Z"),
            "updatedAt": .string("2026-08-31T10:00:00Z"),
        ]
    }

    @Test
    func authSessionUsesOpaqueIDsAndKeepsProductProviderSeparate() throws {
        let session = AuthSession(
            accountID: accountID,
            workspaceID: workspaceID,
            deviceID: deviceID,
            identityProvider: .google
        )
        let connectorID = ConnectorAccountID(
            rawValue: UUID(uuidString: "60000000-0000-4000-8000-000000000006")!
        )

        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as? [String: Any]
        )

        #expect(object["accountId"] as? String == accountID.rawValue.uuidString)
        #expect(object["workspaceId"] as? String == workspaceID.rawValue.uuidString)
        #expect(object["deviceId"] as? String == deviceID.rawValue.uuidString)
        #expect(object["identityProvider"] as? String == "google")
        #expect(connectorID.rawValue != accountID.rawValue)
    }

    @Test
    func operationRoundTripsChangedFieldsAndFieldClocks() throws {
        let operation = try SyncOperation(
            operationID: operationID,
            entityType: .move,
            entityID: entityID,
            action: .upsert,
            baseRevision: 7,
            changedFields: ["priority", "dueOn"],
            fieldClocks: ["priority": timestamp, "dueOn": timestamp],
            payload: ["priority": .string("P0"), "dueOn": .string("2026-09-01")],
            occurredAt: timestamp
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(operation)
        let decoded = try decoder.decode(SyncOperation.self, from: data)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(decoded == operation)
        #expect(object["operationId"] as? String == operationID.rawValue.uuidString)
        #expect(Set(object["changedFields"] as? [String] ?? []) == ["priority", "dueOn"])
        #expect((object["fieldClocks"] as? [String: String])?.keys.sorted() == ["dueOn", "priority"])
    }

    @Test
    func operationRejectsClockOrPayloadKeysThatDoNotMatchMask() {
        #expect(throws: SyncContractValidationError.fieldClockMismatch) {
            try SyncOperation(
                operationID: operationID,
                entityType: .move,
                entityID: entityID,
                action: .upsert,
                baseRevision: 1,
                changedFields: ["priority"],
                fieldClocks: ["dueOn": timestamp],
                payload: ["priority": .string("P1")],
                occurredAt: timestamp
            )
        }

        #expect(throws: SyncContractValidationError.payloadMismatch) {
            try SyncOperation(
                operationID: operationID,
                entityType: .move,
                entityID: entityID,
                action: .upsert,
                baseRevision: 1,
                changedFields: ["priority"],
                fieldClocks: ["priority": timestamp],
                payload: ["dueOn": .null],
                occurredAt: timestamp
            )
        }

        #expect(throws: SyncContractValidationError.invalidChangedFields) {
            try SyncOperation(
                operationID: operationID,
                entityType: .move,
                entityID: entityID,
                action: .upsert,
                baseRevision: 1,
                changedFields: ["príority"],
                fieldClocks: ["príority": timestamp],
                payload: ["príority": .string("P1")],
                occurredAt: timestamp
            )
        }
    }

    @Test
    func malformedDecodedOperationCannotBypassValidation() throws {
        let json = """
        {
          "contractVersion": 1,
          "operationId": "40000000-0000-4000-8000-000000000004",
          "entityType": "move",
          "entityId": "50000000-0000-4000-8000-000000000005",
          "action": "upsert",
          "baseRevision": 1,
          "changedFields": ["priority"],
          "fieldClocks": {"dueOn": "2026-08-31T12:00:00Z"},
          "payload": {"priority": "P0"},
          "occurredAt": "2026-08-31T12:00:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        #expect(throws: SyncContractValidationError.fieldClockMismatch) {
            try decoder.decode(SyncOperation.self, from: Data(json.utf8))
        }
    }

    @Test
    func clockSkewValidationUsesFiveMinuteDefaultTolerance() throws {
        let now = Date(timeIntervalSince1970: 1_788_134_400)
        let futureFieldClock = try SyncOperation(
            operationID: operationID,
            entityType: .move,
            entityID: entityID,
            action: .upsert,
            baseRevision: 1,
            changedFields: ["priority"],
            fieldClocks: ["priority": now.addingTimeInterval(301)],
            payload: ["priority": .string("P0")],
            occurredAt: now
        )

        #expect(throws: SyncContractValidationError.futureClockSkew) {
            try futureFieldClock.validateClockSkew(relativeTo: now)
        }

        let futureOccurrence = try SyncOperation(
            operationID: operationID,
            entityType: .move,
            entityID: entityID,
            action: .upsert,
            baseRevision: 1,
            changedFields: ["priority"],
            fieldClocks: ["priority": now],
            payload: ["priority": .string("P0")],
            occurredAt: now.addingTimeInterval(301)
        )
        #expect(throws: SyncContractValidationError.futureClockSkew) {
            try futureOccurrence.validateClockSkew(relativeTo: now)
        }
    }

    @Test
    func jsonValuePreservesIntegersLargerThanDoublePrecision() throws {
        let value = SyncJSONValue.integer(9_007_199_254_740_993)
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(SyncJSONValue.self, from: data)

        #expect(String(decoding: data, as: UTF8.self) == "9007199254740993")
        #expect(decoded == value)
    }

    @Test
    func jsonValuePreservesExactBase10Decimals() throws {
        let decimal = try #require(
            Decimal(
                string: "1234567890123456789012.12345678",
                locale: Locale(identifier: "en_US_POSIX")
            )
        )
        let value = SyncJSONValue.number(decimal)
        let data = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(SyncJSONValue.self, from: data)

        #expect(String(decoding: data, as: UTF8.self) == "1234567890123456789012.12345678")
        #expect(decoded == value)
    }

    @Test
    func displayNamesNormalizeToNFCAndUseAnEightyScalarLimit() throws {
        #expect(try FounderDisplayName.normalize(" e\u{301} ") == "é")
        #expect(try FounderDisplayName.normalize("\u{00A0}Priya\u{3000}") == "Priya")
        #expect(try FounderDisplayName.normalize("²") == "²")
        #expect(
            try FounderDisplayName.normalize(String(repeating: "🙂", count: 80))
                == String(repeating: "🙂", count: 80)
        )
        #expect(throws: SyncContractValidationError.invalidDisplayName) {
            try FounderDisplayName.normalize(String(repeating: "🙂", count: 81))
        }
        for rejected in ["---", "\u{301}", "\u{200B}", "Priya\nShah", "Priya\u{202E}Shah", "\u{FEFF}Priya"] {
            #expect(throws: SyncContractValidationError.invalidDisplayName) {
                try FounderDisplayName.normalize(rejected)
            }
        }

        let decomposedServerProfile = """
        {
          "accountId": "10000000-0000-4000-8000-000000000001",
          "identityProvider": "google",
          "displayName": "e\\u0301"
        }
        """
        #expect(throws: SyncContractValidationError.invalidDisplayName) {
            try JSONDecoder().decode(FounderProfile.self, from: Data(decomposedServerProfile.utf8))
        }
    }

    @Test
    func deleteRequiresOnlyDeletedAtAndNoPayload() throws {
        let valid = try SyncOperation(
            operationID: operationID,
            entityType: .move,
            entityID: entityID,
            action: .delete,
            baseRevision: 2,
            changedFields: ["deletedAt"],
            fieldClocks: ["deletedAt": timestamp],
            payload: nil,
            occurredAt: timestamp
        )

        #expect(valid.action == .delete)
        #expect(throws: SyncContractValidationError.payloadMismatch) {
            try SyncOperation(
                operationID: operationID,
                entityType: .move,
                entityID: entityID,
                action: .delete,
                baseRevision: 2,
                changedFields: ["title"],
                fieldClocks: ["title": timestamp],
                payload: nil,
                occurredAt: timestamp
            )
        }
    }

    @Test
    func cursorRejectsNegativeValuesIncludingDecode() throws {
        #expect(throws: SyncContractValidationError.negativeCursor) {
            try SyncCursor(value: -1)
        }
        #expect(throws: SyncContractValidationError.negativeCursor) {
            try JSONDecoder().decode(SyncCursor.self, from: Data("-1".utf8))
        }
        #expect(try SyncCursor(value: 9).value == 9)
    }

    @Test
    func conflictAndActivityFixturesRoundTripWithoutCredentialFields() throws {
        let conflict = try SyncConflict(
            operationID: operationID,
            entityType: .move,
            entityID: entityID,
            baseRevision: 3,
            currentRevision: 4,
            reason: .fieldClockLost,
            conflictingFields: ["priority"],
            serverRecord: moveRecord(revision: 4)
        )
        let activity = try ActivityEvent(
            id: ActivityEventID(rawValue: UUID(uuidString: "70000000-0000-4000-8000-000000000007")!),
            workspaceID: workspaceID,
            accountID: accountID,
            deviceID: deviceID,
            kind: "move.upserted",
            entityType: .move,
            entityID: entityID,
            occurredAt: timestamp,
            metadata: [:]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        #expect(try decoder.decode(SyncConflict.self, from: encoder.encode(conflict)) == conflict)
        #expect(try decoder.decode(ActivityEvent.self, from: encoder.encode(activity)) == activity)
        let activityObject = try #require(
            JSONSerialization.jsonObject(with: encoder.encode(activity)) as? [String: Any]
        )
        #expect(activityObject["token"] == nil)
        #expect(activityObject["email"] == nil)
    }

    @Test
    func activityEventsRejectAnyContentMetadata() {
        #expect(throws: SyncContractValidationError.invalidActivityEvent) {
            try ActivityEvent(
                id: ActivityEventID(
                    rawValue: UUID(uuidString: "70000000-0000-4000-8000-000000000007")!
                ),
                workspaceID: workspaceID,
                accountID: accountID,
                deviceID: deviceID,
                kind: "move.upserted",
                entityType: .move,
                entityID: entityID,
                occurredAt: timestamp,
                metadata: ["title": .string("must not be logged")]
            )
        }
    }

    @Test
    func operationRejectsFieldsFromAnotherEntityContract() {
        #expect(throws: SyncContractValidationError.invalidChangedFields) {
            try SyncOperation(
                operationID: operationID,
                entityType: .workspace,
                entityID: workspaceID.rawValue,
                action: .upsert,
                baseRevision: 1,
                changedFields: ["priority"],
                fieldClocks: ["priority": timestamp],
                payload: ["priority": .string("P0")],
                occurredAt: timestamp
            )
        }
    }

    @Test
    func operationsValidateEveryChangedFieldAndContextualAssetPath() throws {
        #expect(throws: SyncContractValidationError.invalidPayload) {
            try SyncOperation(
                operationID: operationID,
                entityType: .move,
                entityID: entityID,
                action: .upsert,
                baseRevision: 1,
                changedFields: ["dueOn"],
                fieldClocks: ["dueOn": timestamp],
                payload: ["dueOn": .string("2026-9-1")],
                occurredAt: timestamp
            )
        }

        #expect(throws: SyncContractValidationError.invalidPayload) {
            try SyncOperation(
                operationID: operationID,
                entityType: .primaryGoal,
                entityID: entityID,
                action: .upsert,
                baseRevision: 1,
                changedFields: ["currentValue"],
                fieldClocks: ["currentValue": timestamp],
                payload: ["currentValue": .number(Decimal(string: "0.000000001")!)],
                occurredAt: timestamp
            )
        }

        #expect(throws: SyncContractValidationError.invalidPayload) {
            try SyncOperation(
                operationID: operationID,
                entityType: .milestone,
                entityID: entityID,
                action: .upsert,
                baseRevision: 0,
                changedFields: ["title", "dueAt"],
                fieldClocks: ["title": timestamp, "dueAt": timestamp],
                payload: [
                    "title": .string("Launch"),
                    "dueAt": .string("2026-10-30T10:00:00Z"),
                ],
                occurredAt: timestamp
            )
        }

        let otherWorkspace = UUID(uuidString: "90000000-0000-4000-8000-000000000009")!
        let crossWorkspacePath = "workspaces/\(otherWorkspace.uuidString.lowercased())/vision-images/\(entityID.uuidString.lowercased()).jpg"
        let asset = try SyncOperation(
            operationID: operationID,
            entityType: .asset,
            entityID: entityID,
            action: .upsert,
            baseRevision: 0,
            changedFields: ["kind", "storagePath", "contentType", "byteSize", "sha256"],
            fieldClocks: [
                "kind": timestamp,
                "storagePath": timestamp,
                "contentType": timestamp,
                "byteSize": timestamp,
                "sha256": timestamp,
            ],
            payload: [
                "kind": .string("visionImage"),
                "storagePath": .string(crossWorkspacePath),
                "contentType": .string("image/jpeg"),
                "byteSize": .integer(1_024),
                "sha256": .string(String(repeating: "0", count: 64)),
            ],
            occurredAt: timestamp
        )
        #expect(throws: SyncContractValidationError.invalidPayload) {
            try asset.validate(for: workspaceID)
        }
    }

    @Test
    func syncChangesValidateEntityRecordAndDeleteTombstone() throws {
        let cursor = try SyncCursor(value: 1)
        let valid = try SyncChange(
            cursor: cursor,
            operationID: operationID,
            entityType: .move,
            entityID: entityID,
            action: .upsert,
            revision: 1,
            changedFields: ["priority"],
            changedAt: timestamp,
            record: moveRecord()
        )
        #expect(valid.record["title"] == .string("Review launch checklist"))

        var wrongRecord = moveRecord()
        wrongRecord["id"] = .string(UUID().uuidString)
        #expect(throws: SyncContractValidationError.invalidRecord) {
            try SyncChange(
                cursor: cursor,
                operationID: operationID,
                entityType: .move,
                entityID: entityID,
                action: .upsert,
                revision: 1,
                changedFields: ["priority"],
                changedAt: timestamp,
                record: wrongRecord
            )
        }

        #expect(throws: SyncContractValidationError.invalidResponse) {
            try SyncChange(
                cursor: cursor,
                operationID: operationID,
                entityType: .move,
                entityID: entityID,
                action: .delete,
                revision: 1,
                changedFields: ["deletedAt"],
                changedAt: timestamp,
                record: moveRecord()
            )
        }

        var recordWithoutChangedFieldClock = moveRecord()
        recordWithoutChangedFieldClock["fieldClocks"] = .object([:])
        #expect(throws: SyncContractValidationError.invalidRecord) {
            try SyncChange(
                cursor: cursor,
                operationID: operationID,
                entityType: .move,
                entityID: entityID,
                action: .upsert,
                revision: 1,
                changedFields: ["priority"],
                changedAt: timestamp,
                record: recordWithoutChangedFieldClock
            )
        }

        #expect(throws: SyncContractValidationError.invalidRecord) {
            try SyncConflict(
                operationID: operationID,
                entityType: .move,
                entityID: entityID,
                baseRevision: 0,
                currentRevision: 1,
                reason: .overlappingChanges,
                conflictingFields: ["title"],
                serverRecord: moveRecord()
            )
        }

        var recordWithPostgresTimestampAlias = moveRecord()
        recordWithPostgresTimestampAlias["updatedAt"] = .string("2026-08-31 10:00:00+00")
        #expect(throws: SyncContractValidationError.invalidRecord) {
            try SyncChange(
                cursor: cursor,
                operationID: operationID,
                entityType: .move,
                entityID: entityID,
                action: .upsert,
                revision: 1,
                changedFields: ["priority"],
                changedAt: timestamp,
                record: recordWithPostgresTimestampAlias
            )
        }
    }

    @Test
    func pullPagesCannotStopEarlyOrClaimNonadvancingWork() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let finalBeforeLatest = """
        {
          "contractVersion": 1,
          "workspaceId": "20000000-0000-4000-8000-000000000002",
          "fromCursor": 0,
          "nextCursor": 0,
          "latestCursor": 1,
          "hasMore": false,
          "changes": []
        }
        """
        #expect(throws: SyncContractValidationError.invalidResponse) {
            try decoder.decode(SyncPullResponse.self, from: Data(finalBeforeLatest.utf8))
        }

        let emptyHasMore = finalBeforeLatest.replacingOccurrences(
            of: "\"hasMore\": false",
            with: "\"hasMore\": true"
        )
        #expect(throws: SyncContractValidationError.invalidResponse) {
            try decoder.decode(SyncPullResponse.self, from: Data(emptyHasMore.utf8))
        }
    }

    @Test
    func bootstrapAndExportEnforceWorkspaceAndPrivateAssetCorrespondence() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let fixtureRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("contracts/v1/fixtures")

        let bootstrapData = try Data(contentsOf: fixtureRoot.appendingPathComponent("bootstrap.response.json"))
        let bootstrap = try decoder.decode(WorkspaceBootstrap.self, from: bootstrapData)
        #expect(bootstrap.session.workspaceID.rawValue.uuidString.lowercased() == "11111111-1111-4111-8111-111111111111")

        var mismatchedBootstrap = try #require(
            JSONSerialization.jsonObject(with: bootstrapData) as? [String: Any]
        )
        var session = try #require(mismatchedBootstrap["session"] as? [String: Any])
        session["workspaceId"] = "99999999-9999-4999-8999-999999999999"
        mismatchedBootstrap["session"] = session
        #expect(throws: SyncContractValidationError.invalidResponse) {
            try decoder.decode(
                WorkspaceBootstrap.self,
                from: JSONSerialization.data(withJSONObject: mismatchedBootstrap)
            )
        }

        let exportData = try Data(contentsOf: fixtureRoot.appendingPathComponent("export-with-asset.response.json"))
        let export = try decoder.decode(WorkspaceExport.self, from: exportData)
        #expect(export.milestones.count == 1)
        #expect(export.assets.count == 1)

        var mismatchedExport = try #require(
            JSONSerialization.jsonObject(with: exportData) as? [String: Any]
        )
        var transfer = try #require(mismatchedExport["assetTransfer"] as? [String: Any])
        var manifest = try #require(transfer["manifest"] as? [[String: Any]])
        manifest[0]["sha256"] = String(repeating: "1", count: 64)
        transfer["manifest"] = manifest
        mismatchedExport["assetTransfer"] = transfer
        #expect(throws: SyncContractValidationError.invalidAssetTransfer) {
            try decoder.decode(
                WorkspaceExport.self,
                from: JSONSerialization.data(withJSONObject: mismatchedExport)
            )
        }

        let exportObject = try #require(
            JSONSerialization.jsonObject(with: exportData) as? [String: Any]
        )
        var crossWorkspaceAsset = try #require(
            (exportObject["assets"] as? [[String: Any]])?.first
        )
        crossWorkspaceAsset["storagePath"] = "workspaces/99999999-9999-4999-8999-999999999999/vision-images/88888888-8888-4888-8888-888888888888.jpg"

        let conflictResponse: [String: Any] = [
            "contractVersion": 1,
            "workspaceId": "11111111-1111-4111-8111-111111111111",
            "latestCursor": 1,
            "results": [[
                "operationId": "40000000-0000-4000-8000-000000000004",
                "status": "conflict",
                "conflict": [
                    "operationId": "40000000-0000-4000-8000-000000000004",
                    "entityType": "asset",
                    "entityId": "88888888-8888-4888-8888-888888888888",
                    "baseRevision": 0,
                    "currentRevision": 1,
                    "reason": "overlappingChanges",
                    "conflictingFields": ["storagePath"],
                    "serverRecord": crossWorkspaceAsset,
                ],
            ]],
        ]
        #expect(throws: SyncContractValidationError.invalidResponse) {
            try decoder.decode(
                SyncPushResponse.self,
                from: JSONSerialization.data(withJSONObject: conflictResponse)
            )
        }

        let pullResponse: [String: Any] = [
            "contractVersion": 1,
            "workspaceId": "11111111-1111-4111-8111-111111111111",
            "fromCursor": 0,
            "nextCursor": 1,
            "latestCursor": 1,
            "hasMore": false,
            "changes": [[
                "cursor": 1,
                "operationId": "40000000-0000-4000-8000-000000000004",
                "entityType": "asset",
                "entityId": "88888888-8888-4888-8888-888888888888",
                "action": "upsert",
                "revision": 1,
                "changedFields": ["storagePath"],
                "changedAt": "2026-08-31T10:00:00Z",
                "record": crossWorkspaceAsset,
            ]],
        ]
        #expect(throws: SyncContractValidationError.invalidResponse) {
            try decoder.decode(
                SyncPullResponse.self,
                from: JSONSerialization.data(withJSONObject: pullResponse)
            )
        }
    }

    @Test
    func operationResultsEnforceStatusSpecificShape() throws {
        let decoder = JSONDecoder()
        let acceptedWithoutCursor = """
        {
          "operationId": "40000000-0000-4000-8000-000000000004",
          "status": "accepted",
          "revision": 1
        }
        """
        #expect(throws: SyncContractValidationError.invalidOperationResult) {
            try decoder.decode(SyncOperationResult.self, from: Data(acceptedWithoutCursor.utf8))
        }

        let accepted = """
        {
          "operationId": "40000000-0000-4000-8000-000000000004",
          "status": "accepted",
          "revision": 1,
          "cursor": 4
        }
        """
        #expect(try decoder.decode(SyncOperationResult.self, from: Data(accepted.utf8)).status == .accepted)
    }

    @Test
    func everyCanonicalResponseRejectsUnknownContractVersions() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let responses: [(any Decodable.Type, String)] = [
            (
                WorkspaceBootstrap.self,
                """
                {
                  "contractVersion": 2,
                  "session": {
                    "accountId": "10000000-0000-4000-8000-000000000001",
                    "workspaceId": "20000000-0000-4000-8000-000000000002",
                    "deviceId": "30000000-0000-4000-8000-000000000003",
                    "identityProvider": "google"
                  },
                  "profile": {
                    "accountId": "10000000-0000-4000-8000-000000000001",
                    "identityProvider": "google",
                    "displayName": "Founder"
                  },
                  "workspace": {},
                  "startingCursor": 0,
                  "latestCursor": 0
                }
                """
            ),
            (
                SyncPushResponse.self,
                """
                {
                  "contractVersion": 2,
                  "workspaceId": "20000000-0000-4000-8000-000000000002",
                  "latestCursor": 0,
                  "results": []
                }
                """
            ),
            (
                SyncPullResponse.self,
                """
                {
                  "contractVersion": 2,
                  "workspaceId": "20000000-0000-4000-8000-000000000002",
                  "fromCursor": 0,
                  "nextCursor": 0,
                  "latestCursor": 0,
                  "hasMore": false,
                  "changes": []
                }
                """
            ),
            (
                WorkspaceExport.self,
                """
                {
                  "contractVersion": 2,
                  "exportedAt": "2026-08-31T10:00:00Z",
                  "workspace": {},
                  "moves": [],
                  "appearance": [],
                  "primaryGoals": [],
                  "milestones": [],
                  "assets": [],
                  "assetTransfer": {"state": "notRequired", "manifest": []},
                  "activityEvents": []
                }
                """
            ),
            (
                WorkspaceEraseReceipt.self,
                """
                {
                  "contractVersion": 2,
                  "workspaceId": "20000000-0000-4000-8000-000000000002",
                  "erasedAt": "2026-08-31T10:00:00Z",
                  "assetObjectCount": 0,
                  "assetCleanupState": "notRequired"
                }
                """
            ),
        ]

        for (type, json) in responses {
            #expect(throws: SyncContractValidationError.invalidResponse) {
                try decoder.decode(type, from: Data(json.utf8))
            }
        }
    }
}
