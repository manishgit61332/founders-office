import Foundation
import FounderOfficeCore
@testable import FounderOfficeIdentity
import Testing

@Suite("Supabase workspace sync transport")
struct SupabaseWorkspaceSyncTransportTests {
    @Test
    func bootstrapUsesExactRPCAndCredentialHeaders() async throws {
        let fixture = try SyncTransportFixture()
        let response = try fixture.bootstrapData(deviceID: fixture.deviceID)
        let http = StubWorkspaceHTTPExecutor { request, maximumBytes in
            #expect(maximumBytes == 4 * 1_024 * 1_024)
            return fixture.result(data: response, requestURL: request.url)
        }
        let transport = try fixture.transport(http: http)

        let bootstrap = try await transport.bootstrapWorkspace(
            deviceID: fixture.deviceID,
            localWorkspaceID: fixture.workspaceID,
            workspaceName: "Founder’s Office",
            displayName: "Manish"
        )

        #expect(bootstrap.session == fixture.session)
        let request = try #require(await http.requests().first)
        #expect(
            request.url?.absoluteString
                == "https://project.supabase.co/rest/v1/rpc/bootstrap_workspace"
        )
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-access-token")
        #expect(request.value(forHTTPHeaderField: "apikey") == fixture.publishableKey)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let requestBody = try #require(request.httpBody)
        let body = try #require(
            JSONSerialization.jsonObject(with: requestBody) as? [String: Any]
        )
        #expect(
            Set(body.keys)
                == ["p_device_id", "p_local_workspace_id", "p_workspace_name", "p_display_name"]
        )
        #expect(body["p_workspace_name"] as? String == "Founder’s Office")
    }

    @Test
    func statusContentTypeEndpointAndRedirectFailuresAreFailClosed() async throws {
        let fixture = try SyncTransportFixture()
        for (status, expected) in [
            (401, SupabaseSyncTransportError.unauthorized),
            (403, .forbidden),
            (409, .rejected),
            (429, .unavailable),
            (503, .unavailable),
            (418, .httpStatus(418)),
        ] {
            let http = StubWorkspaceHTTPExecutor { request, _ in
                fixture.result(data: Data(), requestURL: request.url, status: status)
            }
            let transport = try fixture.transport(http: http)
            #expect(await transportError {
                try await transport.bootstrapWorkspace(
                    deviceID: fixture.deviceID,
                    localWorkspaceID: fixture.workspaceID,
                    workspaceName: "Founder’s Office",
                    displayName: nil
                )
            } == expected)
        }

        let valid = try fixture.bootstrapData(deviceID: fixture.deviceID)
        let wrongType = StubWorkspaceHTTPExecutor { request, _ in
            fixture.result(
                data: valid,
                requestURL: request.url,
                contentType: "text/html"
            )
        }
        #expect(await transportError {
            try await fixture.transport(http: wrongType).bootstrapWorkspace(
                deviceID: fixture.deviceID,
                localWorkspaceID: fixture.workspaceID,
                workspaceName: "Founder’s Office",
                displayName: nil
            )
        } == .invalidContentType)

        let wrongEndpoint = StubWorkspaceHTTPExecutor { _, _ in
            fixture.result(
                data: valid,
                requestURL: URL(string: "https://attacker.invalid/response")!
            )
        }
        #expect(await transportError {
            try await fixture.transport(http: wrongEndpoint).bootstrapWorkspace(
                deviceID: fixture.deviceID,
                localWorkspaceID: fixture.workspaceID,
                workspaceName: "Founder’s Office",
                displayName: nil
            )
        } == .unexpectedEndpoint)

        let redirect = StubWorkspaceHTTPExecutor { _, _ in
            throw SupabaseSyncTransportError.redirectRejected
        }
        #expect(await transportError {
            try await fixture.transport(http: redirect).bootstrapWorkspace(
                deviceID: fixture.deviceID,
                localWorkspaceID: fixture.workspaceID,
                workspaceName: "Founder’s Office",
                displayName: nil
            )
        } == .redirectRejected)
    }

    @Test
    func requestAndResponseBoundsStopBeforeDecoding() async throws {
        let fixture = try SyncTransportFixture()
        let requestHTTP = StubWorkspaceHTTPExecutor { _, _ in
            Issue.record("Oversized request reached HTTP")
            throw SupabaseSyncTransportError.network
        }
        let tinyRequest = try SupabaseSyncTransportLimits(
            maximumRequestByteCount: 1,
            maximumResponseByteCount: 4 * 1_024 * 1_024,
            requestTimeout: 2
        )
        let requestTransport = try fixture.transport(http: requestHTTP, limits: tinyRequest)
        #expect(await transportError {
            try await requestTransport.bootstrapWorkspace(
                deviceID: fixture.deviceID,
                localWorkspaceID: fixture.workspaceID,
                workspaceName: "Founder’s Office",
                displayName: nil
            )
        } == .requestTooLarge)
        #expect(await requestHTTP.requests().isEmpty)

        let oversized = Data(repeating: 0x20, count: 65)
        let responseHTTP = StubWorkspaceHTTPExecutor { request, _ in
            fixture.result(data: oversized, requestURL: request.url)
        }
        let tinyResponse = try SupabaseSyncTransportLimits(
            maximumRequestByteCount: 2 * 1_024 * 1_024,
            maximumResponseByteCount: 64,
            requestTimeout: 2
        )
        let responseTransport = try fixture.transport(http: responseHTTP, limits: tinyResponse)
        #expect(await transportError {
            try await responseTransport.bootstrapWorkspace(
                deviceID: fixture.deviceID,
                localWorkspaceID: fixture.workspaceID,
                workspaceName: "Founder’s Office",
                displayName: nil
            )
        } == .responseTooLarge)

        #expect(throws: SupabaseSyncTransportError.invalidConfiguration) {
            _ = try SupabaseSyncTransportLimits(requestTimeout: 61)
        }
    }

    @Test
    func pushRequiresOneExactResultPerOperation() async throws {
        let fixture = try SyncTransportFixture()
        let operation = try fixture.moveOperation()
        for resultObjects in [
            [] as [[String: Any]],
            [fixture.acceptedResult(for: operation), fixture.acceptedResult(for: operation)],
            [fixture.acceptedResult(operationID: UUID())],
        ] {
            let data = try fixture.pushData(results: resultObjects)
            let http = StubWorkspaceHTTPExecutor { request, _ in
                fixture.result(data: data, requestURL: request.url)
            }
            let transport = try fixture.transport(http: http)
            #expect(await transportError {
                try await transport.pushOperations(
                    session: fixture.session,
                    operations: [operation]
                )
            } == .invalidResponse)
        }
    }

    @Test
    func nestedBootstrapSessionAndProfileUnknownKeysAreRejected() async throws {
        let fixture = try SyncTransportFixture()
        for nestedKey in ["session", "profile"] {
            var object = try fixture.bootstrapObject(deviceID: fixture.deviceID)
            var nested = try #require(object[nestedKey] as? [String: Any])
            nested["unexpected"] = "must fail"
            object[nestedKey] = nested
            let data = try JSONSerialization.data(withJSONObject: object)
            let http = StubWorkspaceHTTPExecutor { request, _ in
                fixture.result(data: data, requestURL: request.url)
            }
            let transport = try fixture.transport(http: http)
            #expect(await transportError {
                try await transport.bootstrapWorkspace(
                    deviceID: fixture.deviceID,
                    localWorkspaceID: fixture.workspaceID,
                    workspaceName: "Founder’s Office",
                    displayName: "Manish"
                )
            } == .invalidResponse)
        }

        var object = try fixture.bootstrapObject(deviceID: fixture.deviceID)
        var workspace = try #require(object["workspace"] as? [String: Any])
        workspace["unexpected"] = "must fail"
        object["workspace"] = workspace
        let data = try JSONSerialization.data(withJSONObject: object)
        let http = StubWorkspaceHTTPExecutor { request, _ in
            fixture.result(data: data, requestURL: request.url)
        }
        #expect(await transportError {
            try await fixture.transport(http: http).bootstrapWorkspace(
                deviceID: fixture.deviceID,
                localWorkspaceID: fixture.workspaceID,
                workspaceName: "Founder’s Office",
                displayName: "Manish"
            )
        } == .invalidResponse)
    }

    @Test
    func nestedPushResultAndConflictUnknownKeysAreRejected() async throws {
        let fixture = try SyncTransportFixture()
        let operation = try fixture.moveOperation()
        var accepted = fixture.acceptedResult(for: operation)
        accepted["unexpected"] = true
        var conflict = fixture.conflictResult(for: operation)
        var conflictBody = try #require(conflict["conflict"] as? [String: Any])
        conflictBody["unexpected"] = true
        conflict["conflict"] = conflictBody

        for result in [accepted, conflict] {
            let data = try fixture.pushData(results: [result])
            let http = StubWorkspaceHTTPExecutor { request, _ in
                fixture.result(data: data, requestURL: request.url)
            }
            let transport = try fixture.transport(http: http)
            #expect(await transportError {
                try await transport.pushOperations(
                    session: fixture.session,
                    operations: [operation]
                )
            } == .invalidResponse)
        }
    }

    @Test
    func nestedPullChangeUnknownKeyIsRejected() async throws {
        let fixture = try SyncTransportFixture()
        var change = fixture.workspaceChange(cursor: 1)
        change["unexpected"] = true
        let data = try fixture.pullData(changes: [change])
        let http = StubWorkspaceHTTPExecutor { request, _ in
            fixture.result(data: data, requestURL: request.url)
        }
        let transport = try fixture.transport(http: http)
        #expect(await transportError {
            try await transport.pullChanges(
                session: fixture.session,
                after: SyncCursor(value: 0),
                limit: 100
            )
        } == .invalidResponse)
    }

    @Test
    func exportRejectsUnknownManifestAndActivityEventKeys() async throws {
        let fixture = try SyncTransportFixture()
        var valid = fixture.exportObject(includeAsset: true)
        var transfer = try #require(valid["assetTransfer"] as? [String: Any])
        var manifest = try #require(transfer["manifest"] as? [[String: Any]])
        manifest[0]["unexpected"] = true
        transfer["manifest"] = manifest
        valid["assetTransfer"] = transfer

        var activityUnknown = fixture.exportObject(includeAsset: false)
        var events = try #require(activityUnknown["activityEvents"] as? [[String: Any]])
        events[0]["unexpected"] = true
        activityUnknown["activityEvents"] = events

        for object in [valid, activityUnknown] {
            let data = try JSONSerialization.data(withJSONObject: object)
            let http = StubWorkspaceHTTPExecutor { request, _ in
                fixture.result(data: data, requestURL: request.url)
            }
            #expect(await transportError {
                try await fixture.transport(http: http).exportWorkspace(
                    session: fixture.session
                )
            } == .invalidResponse)
        }
    }

    @Test
    func exactExportNestedShapesDecodeSuccessfully() async throws {
        let fixture = try SyncTransportFixture()
        let data = try JSONSerialization.data(
            withJSONObject: fixture.exportObject(includeAsset: true)
        )
        let http = StubWorkspaceHTTPExecutor { request, _ in
            fixture.result(data: data, requestURL: request.url)
        }
        let export = try await fixture.transport(http: http).exportWorkspace(
            session: fixture.session
        )
        #expect(export.assets.count == 1)
        #expect(export.assetTransfer.manifest.count == 1)
        #expect(export.activityEvents.count == 1)
    }

    @Test
    func bootstrapRejectsWrongDeviceAndProfileIdentity() async throws {
        let fixture = try SyncTransportFixture()
        let wrongDevice = DeviceID(rawValue: UUID())
        let wrongDeviceData = try fixture.bootstrapData(deviceID: wrongDevice)
        let deviceHTTP = StubWorkspaceHTTPExecutor { request, _ in
            fixture.result(data: wrongDeviceData, requestURL: request.url)
        }
        #expect(await transportError {
            try await fixture.transport(http: deviceHTTP).bootstrapWorkspace(
                deviceID: fixture.deviceID,
                localWorkspaceID: fixture.workspaceID,
                workspaceName: "Founder’s Office",
                displayName: "Manish"
            )
        } == .invalidResponse)

        var object = try fixture.bootstrapObject(deviceID: fixture.deviceID)
        var profile = try #require(object["profile"] as? [String: Any])
        profile["accountId"] = UUID().uuidString.lowercased()
        object["profile"] = profile
        let identityData = try JSONSerialization.data(withJSONObject: object)
        let identityHTTP = StubWorkspaceHTTPExecutor { request, _ in
            fixture.result(data: identityData, requestURL: request.url)
        }
        #expect(await transportError {
            try await fixture.transport(http: identityHTTP).bootstrapWorkspace(
                deviceID: fixture.deviceID,
                localWorkspaceID: fixture.workspaceID,
                workspaceName: "Founder’s Office",
                displayName: "Manish"
            )
        } == .invalidResponse)
    }

    @Test
    func cancellationMapsToRedactedTransportFailure() async throws {
        let fixture = try SyncTransportFixture()
        let http = BlockingWorkspaceHTTPExecutor()
        let transport = try fixture.transport(http: http)
        let task = Task {
            await transportError {
                try await transport.bootstrapWorkspace(
                    deviceID: fixture.deviceID,
                    localWorkspaceID: fixture.workspaceID,
                    workspaceName: "Founder’s Office",
                    displayName: nil
                )
            }
        }
        for _ in 0..<1_000 where !(await http.hasStarted()) {
            await Task.yield()
        }
        #expect(await http.hasStarted())
        task.cancel()
        #expect(await task.value == .cancelled)
        #expect(
            SupabaseSyncTransportError.cancelled.localizedDescription
                == "Device sync was cancelled."
        )
    }

    @Test
    func cancellationBeforeBoundedRunnerStartNeverCreatesNetworkTask() async throws {
        let request = URLRequest(url: URL(string: "https://127.0.0.1:9/must-not-connect")!)
        let runner = BoundedURLRequestRunner(
            request: request,
            maximumResponseByteCount: 1_024
        )
        runner.cancel()
        #expect(await transportError { try await runner.start() } == .cancelled)
    }
}

private struct FixedAccessTokenProvider: ProductAccessTokenProviding {
    let token: String
    func accessToken() async throws -> String { token }
}

private actor StubWorkspaceHTTPExecutor: WorkspaceHTTPExecuting {
    typealias Handler = @Sendable (URLRequest, Int) async throws -> WorkspaceHTTPResult
    private let handler: Handler
    private var captured: [URLRequest] = []

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func execute(
        request: URLRequest,
        maximumResponseByteCount: Int
    ) async throws -> WorkspaceHTTPResult {
        captured.append(request)
        return try await handler(request, maximumResponseByteCount)
    }

    func requests() -> [URLRequest] { captured }
}

private actor BlockingWorkspaceHTTPExecutor: WorkspaceHTTPExecuting {
    private var started = false

    func hasStarted() -> Bool { started }

    func execute(
        request: URLRequest,
        maximumResponseByteCount: Int
    ) async throws -> WorkspaceHTTPResult {
        _ = request
        _ = maximumResponseByteCount
        started = true
        try await Task.sleep(for: .seconds(30))
        throw SupabaseSyncTransportError.network
    }
}

private func transportError<Result: Sendable>(
    _ body: @Sendable () async throws -> Result
) async -> SupabaseSyncTransportError? {
    do {
        _ = try await body()
        Issue.record("Expected SupabaseSyncTransportError")
        return nil
    } catch let error as SupabaseSyncTransportError {
        return error
    } catch {
        Issue.record("Unexpected error type: \(type(of: error))")
        return nil
    }
}

private struct SyncTransportFixture: @unchecked Sendable {
    let publishableKey = "sb_publishable_12345678901234567890"
    let accountID = FounderAccountID(
        rawValue: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!
    )
    let workspaceID = WorkspaceID(
        rawValue: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    )
    let deviceID = DeviceID(
        rawValue: UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    )
    let moveID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
    let operationID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
    let configuration: ProductAuthConfiguration

    init() throws {
        configuration = try ProductAuthConfiguration(
            endpoint: URL(string: "https://project.supabase.co")!,
            publishableKey: publishableKey,
            callbackURL: URL(string: "founders-office://auth/callback")!
        )
    }

    var session: AuthSession {
        AuthSession(
            accountID: accountID,
            workspaceID: workspaceID,
            deviceID: deviceID,
            identityProvider: .google
        )
    }

    func transport(
        http: any WorkspaceHTTPExecuting,
        limits: SupabaseSyncTransportLimits? = nil
    ) throws -> SupabaseWorkspaceSyncTransport {
        SupabaseWorkspaceSyncTransport(
            configuration: configuration,
            tokenProvider: FixedAccessTokenProvider(token: "test-access-token"),
            limits: try limits ?? SupabaseSyncTransportLimits(),
            http: http
        )
    }

    func result(
        data: Data,
        requestURL: URL?,
        status: Int = 200,
        contentType: String = "application/json; charset=utf-8"
    ) -> WorkspaceHTTPResult {
        WorkspaceHTTPResult(
            data: data,
            response: HTTPURLResponse(
                url: requestURL ?? URL(string: "https://project.supabase.co")!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": contentType]
            )!
        )
    }

    func bootstrapData(deviceID: DeviceID) throws -> Data {
        try JSONSerialization.data(withJSONObject: bootstrapObject(deviceID: deviceID))
    }

    func bootstrapObject(deviceID: DeviceID) throws -> [String: Any] {
        let timestamp = "2026-08-31T10:00:00Z"
        return [
            "contractVersion": 1,
            "session": [
                "accountId": accountID.rawValue.uuidString.lowercased(),
                "workspaceId": workspaceID.rawValue.uuidString.lowercased(),
                "deviceId": deviceID.rawValue.uuidString.lowercased(),
                "identityProvider": "google",
            ],
            "profile": [
                "accountId": accountID.rawValue.uuidString.lowercased(),
                "identityProvider": "google",
                "displayName": "Manish",
            ],
            "workspace": [
                "id": workspaceID.rawValue.uuidString.lowercased(),
                "name": "Founder’s Office",
                "revision": 1,
                "fieldClocks": ["name": timestamp],
                "createdAt": timestamp,
                "updatedAt": timestamp,
            ],
            "startingCursor": 0,
            "latestCursor": 0,
        ]
    }

    func moveOperation() throws -> SyncOperation {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        return try SyncOperation(
            operationID: SyncOperationID(rawValue: operationID),
            entityType: .move,
            entityID: moveID,
            action: .upsert,
            baseRevision: 1,
            changedFields: ["title"],
            fieldClocks: ["title": date],
            payload: ["title": .string("Reviewed title")],
            occurredAt: date
        )
    }

    func acceptedResult(for operation: SyncOperation) -> [String: Any] {
        acceptedResult(operationID: operation.operationID.rawValue)
    }

    func acceptedResult(operationID: UUID) -> [String: Any] {
        [
            "operationId": operationID.uuidString.lowercased(),
            "status": "accepted",
            "revision": 2,
            "cursor": 1,
        ]
    }

    func conflictResult(for operation: SyncOperation) -> [String: Any] {
        let timestamp = "2026-08-31T10:00:00Z"
        return [
            "operationId": operation.operationID.rawValue.uuidString.lowercased(),
            "status": "conflict",
            "conflict": [
                "operationId": operation.operationID.rawValue.uuidString.lowercased(),
                "entityType": "move",
                "entityId": moveID.uuidString.lowercased(),
                "baseRevision": 1,
                "currentRevision": 2,
                "reason": "overlappingChanges",
                "conflictingFields": ["title"],
                "serverRecord": moveRecord(revision: 2, timestamp: timestamp),
            ],
        ]
    }

    func pushData(results: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "contractVersion": 1,
            "workspaceId": workspaceID.rawValue.uuidString.lowercased(),
            "latestCursor": 1,
            "results": results,
        ])
    }

    func workspaceChange(cursor: Int64) -> [String: Any] {
        let timestamp = "2026-08-31T10:00:00Z"
        return [
            "cursor": cursor,
            "operationId": UUID().uuidString.lowercased(),
            "entityType": "workspace",
            "entityId": workspaceID.rawValue.uuidString.lowercased(),
            "action": "upsert",
            "revision": 2,
            "changedFields": ["name"],
            "changedAt": timestamp,
            "record": [
                "id": workspaceID.rawValue.uuidString.lowercased(),
                "name": "Remote Office",
                "revision": 2,
                "fieldClocks": ["name": timestamp],
                "createdAt": timestamp,
                "updatedAt": timestamp,
            ],
        ]
    }

    func pullData(changes: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "contractVersion": 1,
            "workspaceId": workspaceID.rawValue.uuidString.lowercased(),
            "fromCursor": 0,
            "nextCursor": changes.isEmpty ? 0 : 1,
            "latestCursor": changes.isEmpty ? 0 : 1,
            "hasMore": false,
            "changes": changes,
        ])
    }

    func exportObject(includeAsset: Bool) -> [String: Any] {
        let timestamp = "2026-08-31T10:00:00Z"
        let assetID = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
        let path = "workspaces/\(workspaceID.rawValue.uuidString.lowercased())/vision-images/\(assetID.uuidString.lowercased()).jpg"
        let digest = String(repeating: "0", count: 64)
        let asset: [String: Any] = [
            "id": assetID.uuidString.lowercased(),
            "kind": "visionImage",
            "storagePath": path,
            "contentType": "image/jpeg",
            "byteSize": 1_024,
            "sha256": digest,
            "deletedAt": NSNull(),
            "revision": 1,
            "fieldClocks": ["kind": timestamp],
            "createdAt": timestamp,
            "updatedAt": timestamp,
        ]
        let manifest: [String: Any] = [
            "id": assetID.uuidString.lowercased(),
            "storagePath": path,
            "contentType": "image/jpeg",
            "byteSize": 1_024,
            "sha256": digest,
            "deletedAt": NSNull(),
        ]
        return [
            "contractVersion": 1,
            "exportedAt": timestamp,
            "workspace": [
                "id": workspaceID.rawValue.uuidString.lowercased(),
                "name": "Founder’s Office",
                "revision": 1,
                "fieldClocks": ["name": timestamp],
                "createdAt": timestamp,
                "updatedAt": timestamp,
            ],
            "moves": [],
            "appearance": [],
            "primaryGoals": [],
            "milestones": [],
            "assets": includeAsset ? [asset] : [],
            "assetTransfer": [
                "state": includeAsset ? "requiresPrivateStorageAdapter" : "notRequired",
                "manifest": includeAsset ? [manifest] : [],
            ],
            "activityEvents": [[
                "id": UUID(uuidString: "66666666-6666-4666-8666-666666666666")!.uuidString.lowercased(),
                "workspaceId": workspaceID.rawValue.uuidString.lowercased(),
                "accountId": accountID.rawValue.uuidString.lowercased(),
                "kind": "sync.completed",
                "occurredAt": timestamp,
                "metadata": [:],
            ]],
        ]
    }

    private func moveRecord(revision: Int64, timestamp: String) -> [String: Any] {
        [
            "id": moveID.uuidString.lowercased(),
            "title": "Server title",
            "details": "",
            "status": "next",
            "previousStatus": NSNull(),
            "priority": "P1",
            "dueOn": NSNull(),
            "completedAt": NSNull(),
            "deletedAt": NSNull(),
            "source": "test",
            "revision": revision,
            "fieldClocks": ["title": timestamp],
            "createdAt": timestamp,
            "updatedAt": timestamp,
        ]
    }
}
