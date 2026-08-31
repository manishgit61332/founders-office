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
        let conflict = SyncConflict(
            operationID: operationID,
            entityType: .move,
            entityID: entityID,
            baseRevision: 3,
            currentRevision: 4,
            reason: .fieldClockLost,
            serverRecord: ["id": .string(entityID.uuidString), "revision": .integer(4)]
        )
        let activity = ActivityEvent(
            id: ActivityEventID(rawValue: UUID(uuidString: "70000000-0000-4000-8000-000000000007")!),
            workspaceID: workspaceID,
            accountID: accountID,
            deviceID: deviceID,
            kind: "move.upserted",
            entityType: .move,
            entityID: entityID,
            occurredAt: timestamp,
            metadata: ["operationId": .string(operationID.rawValue.uuidString), "revision": .integer(4)]
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
}
