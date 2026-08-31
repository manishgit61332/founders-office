import Foundation
import FounderOfficeCore

public protocol ProductAccessTokenProviding: Sendable {
    func accessToken() async throws -> String
}

extension SupabaseProductAuthClient: ProductAccessTokenProviding {}

public struct SupabaseSyncTransportLimits: Equatable, Sendable {
    public let maximumRequestByteCount: Int
    public let maximumResponseByteCount: Int
    public let requestTimeout: TimeInterval

    public init(
        maximumRequestByteCount: Int = 2 * 1_024 * 1_024,
        maximumResponseByteCount: Int = 4 * 1_024 * 1_024,
        requestTimeout: TimeInterval = 20
    ) throws {
        guard (1...2 * 1_024 * 1_024).contains(maximumRequestByteCount),
              (1...8 * 1_024 * 1_024).contains(maximumResponseByteCount),
              requestTimeout.isFinite,
              (1...60).contains(requestTimeout) else {
            throw SupabaseSyncTransportError.invalidConfiguration
        }
        self.maximumRequestByteCount = maximumRequestByteCount
        self.maximumResponseByteCount = maximumResponseByteCount
        self.requestTimeout = requestTimeout
    }
}

public typealias SupabaseSyncTransportError = WorkspaceSyncTransportFailure

struct WorkspaceHTTPResult: @unchecked Sendable {
    let data: Data
    let response: HTTPURLResponse
}

protocol WorkspaceHTTPExecuting: Sendable {
    func execute(
        request: URLRequest,
        maximumResponseByteCount: Int
    ) async throws -> WorkspaceHTTPResult
}

/// URLSession adapter that cancels while bytes are arriving instead of first
/// allocating an unbounded response and checking its size afterwards.
actor BoundedURLSessionHTTPExecutor: WorkspaceHTTPExecuting {
    func execute(
        request: URLRequest,
        maximumResponseByteCount: Int
    ) async throws -> WorkspaceHTTPResult {
        let runner = BoundedURLRequestRunner(
            request: request,
            maximumResponseByteCount: maximumResponseByteCount
        )
        return try await withTaskCancellationHandler {
            try await runner.start()
        } onCancel: {
            runner.cancel()
        }
    }
}

final class BoundedURLRequestRunner: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let request: URLRequest
    private let maximumResponseByteCount: Int
    private var data = Data()
    private var response: HTTPURLResponse?
    private var continuation: CheckedContinuation<WorkspaceHTTPResult, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var terminalError: Error?
    private var finished = false

    init(request: URLRequest, maximumResponseByteCount: Int) {
        self.request = request
        self.maximumResponseByteCount = maximumResponseByteCount
    }

    func start() async throws -> WorkspaceHTTPResult {
        try await withCheckedThrowingContinuation { continuation in
            let taskToStart: URLSessionDataTask? = lock.withLock {
                guard terminalError == nil, !finished else { return nil }
                self.continuation = continuation
                let configuration = URLSessionConfiguration.ephemeral
                configuration.urlCache = nil
                configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                configuration.timeoutIntervalForRequest = request.timeoutInterval
                configuration.timeoutIntervalForResource = request.timeoutInterval
                configuration.httpCookieStorage = nil
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.dataTask(with: request)
                self.task = task
                return task
            }
            if let taskToStart {
                taskToStart.resume()
            } else {
                lock.withLock {
                    if !finished {
                        finished = true
                        self.continuation = nil
                    }
                }
                continuation.resume(throwing: SupabaseSyncTransportError.cancelled)
            }
        }
    }

    func cancel() {
        lock.withLock {
            guard !finished else { return }
            terminalError = SupabaseSyncTransportError.cancelled
            task?.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        _ = response
        _ = request
        lock.withLock { terminalError = SupabaseSyncTransportError.redirectRejected }
        completionHandler(nil)
        task.cancel()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            lock.withLock { terminalError = SupabaseSyncTransportError.invalidResponse }
            completionHandler(.cancel)
            return
        }
        let expectedLength = http.expectedContentLength
        guard expectedLength < 0 || expectedLength <= maximumResponseByteCount else {
            lock.withLock { terminalError = SupabaseSyncTransportError.responseTooLarge }
            completionHandler(.cancel)
            return
        }
        lock.withLock { self.response = http }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        let shouldCancel = lock.withLock { () -> Bool in
            guard data.count <= maximumResponseByteCount - chunk.count else {
                terminalError = SupabaseSyncTransportError.responseTooLarge
                return true
            }
            data.append(chunk)
            return false
        }
        if shouldCancel { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let completion: (CheckedContinuation<WorkspaceHTTPResult, Error>, Result<WorkspaceHTTPResult, Error>)? = lock.withLock {
            guard !finished, let continuation else { return nil }
            finished = true
            self.continuation = nil
            let result: Result<WorkspaceHTTPResult, Error>
            if let terminalError {
                result = .failure(terminalError)
            } else if let error {
                if (error as? URLError)?.code == .cancelled {
                    result = .failure(SupabaseSyncTransportError.cancelled)
                } else {
                    result = .failure(SupabaseSyncTransportError.network)
                }
            } else if let response {
                result = .success(WorkspaceHTTPResult(data: data, response: response))
            } else {
                result = .failure(SupabaseSyncTransportError.invalidResponse)
            }
            return (continuation, result)
        }
        session.finishTasksAndInvalidate()
        guard let completion else { return }
        completion.0.resume(with: completion.1)
    }
}

public actor SupabaseWorkspaceSyncTransport: WorkspaceSyncTransport {
    private let endpoint: URL
    private let publishableKey: String
    private let tokenProvider: any ProductAccessTokenProviding
    private let limits: SupabaseSyncTransportLimits
    private let http: any WorkspaceHTTPExecuting
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        configuration: ProductAuthConfiguration,
        tokenProvider: any ProductAccessTokenProviding,
        limits: SupabaseSyncTransportLimits? = nil
    ) throws {
        self.endpoint = configuration.endpoint
        self.publishableKey = configuration.publishableKey
        self.tokenProvider = tokenProvider
        self.limits = try limits ?? SupabaseSyncTransportLimits()
        self.http = BoundedURLSessionHTTPExecutor()
        self.encoder = Self.makeEncoder()
        self.decoder = Self.makeDecoder()
    }

    init(
        configuration: ProductAuthConfiguration,
        tokenProvider: any ProductAccessTokenProviding,
        limits: SupabaseSyncTransportLimits,
        http: any WorkspaceHTTPExecuting
    ) {
        self.endpoint = configuration.endpoint
        self.publishableKey = configuration.publishableKey
        self.tokenProvider = tokenProvider
        self.limits = limits
        self.http = http
        self.encoder = Self.makeEncoder()
        self.decoder = Self.makeDecoder()
    }

    public func bootstrapWorkspace(
        deviceID: DeviceID,
        localWorkspaceID: WorkspaceID?,
        workspaceName: String,
        displayName: String?
    ) async throws -> WorkspaceBootstrap {
        let cleanWorkspaceName = workspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanWorkspaceName.isEmpty,
              cleanWorkspaceName.unicodeScalars.count <= 120 else {
            throw SupabaseSyncTransportError.invalidResponse
        }
        let cleanDisplayName: String?
        do {
            cleanDisplayName = try FounderDisplayName.normalize(displayName)
        } catch {
            throw SupabaseSyncTransportError.invalidResponse
        }
        let request = BootstrapRequest(
            deviceID: deviceID,
            localWorkspaceID: localWorkspaceID,
            workspaceName: cleanWorkspaceName,
            displayName: cleanDisplayName
        )
        let response: WorkspaceBootstrap = try await call(
            rpc: "bootstrap_workspace",
            body: request,
            response: WorkspaceBootstrap.self,
            exactTopLevelKeys: [
                "contractVersion", "session", "profile", "workspace",
                "startingCursor", "latestCursor",
            ],
            shape: .bootstrap
        )
        guard response.session.deviceID == deviceID,
              localWorkspaceID.map({ $0 == response.session.workspaceID }) ?? true,
              cleanDisplayName.map({ $0 == response.profile.displayName }) ?? true else {
            throw SupabaseSyncTransportError.invalidResponse
        }
        return response
    }

    public func pushOperations(
        session: AuthSession,
        operations: [SyncOperation]
    ) async throws -> SyncPushResponse {
        guard (1...100).contains(operations.count),
              Set(operations.map(\.operationID)).count == operations.count else {
            throw SupabaseSyncTransportError.invalidResponse
        }
        try operations.forEach {
            try $0.validate(for: session.workspaceID)
            try $0.validateClockSkew(relativeTo: Date())
        }
        let response: SyncPushResponse = try await call(
            rpc: "push_operations",
            body: PushRequest(session: session, operations: operations),
            response: SyncPushResponse.self,
            exactTopLevelKeys: ["contractVersion", "workspaceId", "latestCursor", "results"],
            shape: .push
        )
        guard response.workspaceID == session.workspaceID,
              Set(response.results.map(\.operationID)) == Set(operations.map(\.operationID)),
              response.results.count == operations.count else {
            throw SupabaseSyncTransportError.invalidResponse
        }
        return response
    }

    public func pullChanges(
        session: AuthSession,
        after cursor: SyncCursor,
        limit: Int
    ) async throws -> SyncPullResponse {
        guard (1...500).contains(limit) else {
            throw SupabaseSyncTransportError.invalidResponse
        }
        let response: SyncPullResponse = try await call(
            rpc: "pull_changes",
            body: PullRequest(session: session, cursor: cursor, limit: limit),
            response: SyncPullResponse.self,
            exactTopLevelKeys: [
                "contractVersion", "workspaceId", "fromCursor", "nextCursor",
                "latestCursor", "hasMore", "changes",
            ],
            shape: .pull
        )
        guard response.workspaceID == session.workspaceID,
              response.fromCursor == cursor,
              response.changes.count <= limit else {
            throw SupabaseSyncTransportError.invalidResponse
        }
        return response
    }

    public func exportWorkspace(session: AuthSession) async throws -> WorkspaceExport {
        try await call(
            rpc: "export_workspace",
            body: WorkspaceRequest(session: session),
            response: WorkspaceExport.self,
            exactTopLevelKeys: [
                "contractVersion", "exportedAt", "workspace", "moves", "appearance",
                "primaryGoals", "milestones", "assets", "assetTransfer", "activityEvents",
            ],
            shape: .export
        )
    }

    public func eraseWorkspace(
        session: AuthSession,
        confirming workspaceID: WorkspaceID
    ) async throws -> WorkspaceEraseReceipt {
        guard session.workspaceID == workspaceID else {
            throw SupabaseSyncTransportError.forbidden
        }
        return try await call(
            rpc: "erase_workspace",
            body: EraseRequest(session: session, confirming: workspaceID),
            response: WorkspaceEraseReceipt.self,
            exactTopLevelKeys: [
                "contractVersion", "workspaceId", "erasedAt",
                "assetObjectCount", "assetCleanupState",
            ],
            shape: .erase
        )
    }

    private func call<Request: Encodable, Response: Decodable>(
        rpc: String,
        body: Request,
        response: Response.Type,
        exactTopLevelKeys: Set<String>,
        shape: ResponseShape
    ) async throws -> Response {
        guard !Task.isCancelled else {
            throw SupabaseSyncTransportError.cancelled
        }
        let token: String
        do {
            token = try await tokenProvider.accessToken()
        } catch is CancellationError {
            throw SupabaseSyncTransportError.cancelled
        } catch {
            throw SupabaseSyncTransportError.unauthorized
        }
        guard !Task.isCancelled else {
            throw SupabaseSyncTransportError.cancelled
        }
        guard !token.isEmpty,
              token.utf8.count <= 16 * 1_024,
              !token.unicodeScalars.contains(where: CharacterSet.whitespacesAndNewlines.contains) else {
            throw SupabaseSyncTransportError.invalidAccessToken
        }
        let data = try encoder.encode(body)
        guard data.count <= limits.maximumRequestByteCount else {
            throw SupabaseSyncTransportError.requestTooLarge
        }
        let url = try rpcURL(named: rpc)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = limits.requestTimeout
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(publishableKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let result: WorkspaceHTTPResult
        do {
            result = try await http.execute(
                request: request,
                maximumResponseByteCount: limits.maximumResponseByteCount
            )
        } catch is CancellationError {
            throw SupabaseSyncTransportError.cancelled
        } catch let error as SupabaseSyncTransportError {
            throw error
        } catch {
            throw SupabaseSyncTransportError.network
        }
        guard result.response.url == url else {
            throw SupabaseSyncTransportError.unexpectedEndpoint
        }
        switch result.response.statusCode {
        case 200: break
        case 401: throw SupabaseSyncTransportError.unauthorized
        case 403: throw SupabaseSyncTransportError.forbidden
        case 400, 409, 422: throw SupabaseSyncTransportError.rejected
        case 429, 500...599: throw SupabaseSyncTransportError.unavailable
        default: throw SupabaseSyncTransportError.httpStatus(result.response.statusCode)
        }
        guard let contentType = result.response.value(forHTTPHeaderField: "Content-Type")?.lowercased(),
              contentType.hasPrefix("application/json") else {
            throw SupabaseSyncTransportError.invalidContentType
        }
        guard result.data.count <= limits.maximumResponseByteCount else {
            throw SupabaseSyncTransportError.responseTooLarge
        }
        try validateResponseObject(
            result.data,
            exactKeys: exactTopLevelKeys,
            shape: shape
        )
        do {
            return try decoder.decode(Response.self, from: result.data)
        } catch is CancellationError {
            throw SupabaseSyncTransportError.cancelled
        } catch {
            throw SupabaseSyncTransportError.invalidResponse
        }
    }

    private func rpcURL(named name: String) throws -> URL {
        guard [
            "bootstrap_workspace", "push_operations", "pull_changes",
            "export_workspace", "erase_workspace",
        ].contains(name) else {
            throw SupabaseSyncTransportError.invalidConfiguration
        }
        let url = endpoint
            .appendingPathComponent("rest", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent("rpc", isDirectory: true)
            .appendingPathComponent(name, isDirectory: false)
        guard url.scheme == endpoint.scheme,
              url.host == endpoint.host,
              url.port == endpoint.port,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil else {
            throw SupabaseSyncTransportError.unexpectedEndpoint
        }
        return url
    }

    private func validateResponseObject(
        _ data: Data,
        exactKeys: Set<String>,
        shape: ResponseShape
    ) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == exactKeys else {
            throw SupabaseSyncTransportError.invalidResponse
        }
        switch shape {
        case .bootstrap:
            try requireExactObject(
                object["session"],
                keys: ["accountId", "workspaceId", "deviceId", "identityProvider"]
            )
            try requireExactObject(
                object["profile"],
                keys: ["accountId", "identityProvider", "displayName"]
            )
        case .push:
            guard let results = object["results"] as? [Any] else {
                throw SupabaseSyncTransportError.invalidResponse
            }
            for raw in results {
                guard let result = raw as? [String: Any],
                      let status = result["status"] as? String else {
                    throw SupabaseSyncTransportError.invalidResponse
                }
                switch status {
                case "accepted", "duplicate":
                    guard Set(result.keys) == ["operationId", "status", "revision", "cursor"] else {
                        throw SupabaseSyncTransportError.invalidResponse
                    }
                case "conflict":
                    guard Set(result.keys) == ["operationId", "status", "conflict"] else {
                        throw SupabaseSyncTransportError.invalidResponse
                    }
                    try requireExactObject(
                        result["conflict"],
                        keys: [
                            "operationId", "entityType", "entityId", "baseRevision",
                            "currentRevision", "reason", "conflictingFields", "serverRecord",
                        ]
                    )
                default:
                    throw SupabaseSyncTransportError.invalidResponse
                }
            }
        case .pull:
            guard let changes = object["changes"] as? [Any] else {
                throw SupabaseSyncTransportError.invalidResponse
            }
            for change in changes {
                try requireExactObject(
                    change,
                    keys: [
                        "cursor", "operationId", "entityType", "entityId", "action",
                        "revision", "changedFields", "changedAt", "record",
                    ]
                )
            }
        case .export:
            try requireExactObject(object["assetTransfer"], keys: ["state", "manifest"])
            guard let transfer = object["assetTransfer"] as? [String: Any],
                  let manifest = transfer["manifest"] as? [Any],
                  let activityEvents = object["activityEvents"] as? [Any] else {
                throw SupabaseSyncTransportError.invalidResponse
            }
            for item in manifest {
                try requireObjectKeys(
                    item,
                    required: ["id", "storagePath", "contentType", "byteSize", "sha256"],
                    optional: ["deletedAt"]
                )
            }
            for event in activityEvents {
                try requireObjectKeys(
                    event,
                    required: ["id", "workspaceId", "accountId", "kind", "occurredAt", "metadata"],
                    optional: ["deviceId", "entityType", "entityId"]
                )
            }
        case .erase:
            break
        }
    }

    private func requireExactObject(_ value: Any?, keys: Set<String>) throws {
        guard let value = value as? [String: Any], Set(value.keys) == keys else {
            throw SupabaseSyncTransportError.invalidResponse
        }
    }

    private func requireObjectKeys(
        _ value: Any?,
        required: Set<String>,
        optional: Set<String>
    ) throws {
        guard let value = value as? [String: Any] else {
            throw SupabaseSyncTransportError.invalidResponse
        }
        let keys = Set(value.keys)
        guard required.isSubset(of: keys), keys.isSubset(of: required.union(optional)) else {
            throw SupabaseSyncTransportError.invalidResponse
        }
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private enum ResponseShape {
    case bootstrap
    case push
    case pull
    case export
    case erase
}

private struct BootstrapRequest: Encodable {
    let deviceID: DeviceID
    let localWorkspaceID: WorkspaceID?
    let workspaceName: String
    let displayName: String?

    enum CodingKeys: String, CodingKey {
        case deviceID = "p_device_id"
        case localWorkspaceID = "p_local_workspace_id"
        case workspaceName = "p_workspace_name"
        case displayName = "p_display_name"
    }
}

private struct PushRequest: Encodable {
    let workspaceID: WorkspaceID
    let deviceID: DeviceID
    let operations: [SyncOperation]

    init(session: AuthSession, operations: [SyncOperation]) {
        workspaceID = session.workspaceID
        deviceID = session.deviceID
        self.operations = operations
    }

    enum CodingKeys: String, CodingKey {
        case workspaceID = "p_workspace_id"
        case deviceID = "p_device_id"
        case operations = "p_operations"
    }
}

private struct PullRequest: Encodable {
    let workspaceID: WorkspaceID
    let deviceID: DeviceID
    let cursor: SyncCursor
    let limit: Int

    init(session: AuthSession, cursor: SyncCursor, limit: Int) {
        workspaceID = session.workspaceID
        deviceID = session.deviceID
        self.cursor = cursor
        self.limit = limit
    }

    enum CodingKeys: String, CodingKey {
        case workspaceID = "p_workspace_id"
        case deviceID = "p_device_id"
        case cursor = "p_cursor"
        case limit = "p_limit"
    }
}

private struct WorkspaceRequest: Encodable {
    let workspaceID: WorkspaceID
    init(session: AuthSession) { workspaceID = session.workspaceID }
    enum CodingKeys: String, CodingKey { case workspaceID = "p_workspace_id" }
}

private struct EraseRequest: Encodable {
    let workspaceID: WorkspaceID
    let confirmation: WorkspaceID
    init(session: AuthSession, confirming: WorkspaceID) {
        workspaceID = session.workspaceID
        confirmation = confirming
    }
    enum CodingKeys: String, CodingKey {
        case workspaceID = "p_workspace_id"
        case confirmation = "p_confirm_workspace_id"
    }
}
