import CryptoKit
import Foundation

public struct UpdateChannelConfiguration: Equatable, Sendable {
    public static let feedURLInfoKey = "FounderOfficeUpdateFeedURL"
    public static let publicKeyInfoKey = "FounderOfficeUpdatePublicKey"
    public static let channelInfoKey = "FounderOfficeUpdateChannel"

    public let feedURL: URL
    public let approvedOrigin: URL
    public let publicKey: Data
    public let expectedChannel: UpdateChannelName
    /// A content-free, immutable namespace for state that must not cross feed,
    /// channel, or signing-key boundaries. The source URL and key never appear
    /// in preferences or diagnostics.
    public let persistenceNamespace: String

    public init(
        feedURL: URL,
        publicKeyBase64: String,
        expectedChannel: UpdateChannelName = .beta
    ) throws {
        let absoluteFeedURL = feedURL.absoluteString
        let encodedFeedPath = URLComponents(
            url: feedURL,
            resolvingAgainstBaseURL: false
        )?.percentEncodedPath
        let pathComponents = feedURL.path.split(separator: "/", omittingEmptySubsequences: false)
        guard feedURL.scheme == "https",
              let host = feedURL.host,
              !host.isEmpty,
              absoluteFeedURL.utf8.count <= 2_048,
              !absoluteFeedURL.contains(where: { $0.isWhitespace }),
              feedURL.port.map({ (1...65_535).contains($0) }) ?? true,
              feedURL.user == nil,
              feedURL.password == nil,
              feedURL.query == nil,
              feedURL.fragment == nil,
              feedURL.path.count <= 1_024,
              feedURL.path != "/",
              feedURL.pathExtension == "json",
              encodedFeedPath?.contains("%") == false,
              !feedURL.path.contains("//"),
              !pathComponents.contains("."),
              !pathComponents.contains("..") else {
            throw UpdateChannelError.invalidConfiguration
        }

        let keyText = publicKeyBase64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard keyText == publicKeyBase64,
              let key = Data(base64Encoded: keyText),
              key.count == 32,
              key.base64EncodedString() == keyText,
              (try? Curve25519.Signing.PublicKey(rawRepresentation: key)) != nil else {
            throw UpdateChannelError.invalidConfiguration
        }

        var origin = URLComponents()
        origin.scheme = "https"
        origin.host = host
        origin.port = feedURL.port
        guard let approvedOrigin = origin.url else {
            throw UpdateChannelError.invalidConfiguration
        }

        self.feedURL = feedURL
        self.approvedOrigin = approvedOrigin
        publicKey = key
        self.expectedChannel = expectedChannel
        persistenceNamespace = Self.makePersistenceNamespace(
            feedURL: feedURL,
            publicKey: key,
            channel: expectedChannel
        )
    }

    public static func load(
        infoDictionary: [String: Any]
    ) -> Result<UpdateChannelConfiguration, UpdateChannelError> {
        guard let feedText = infoDictionary[feedURLInfoKey] as? String,
              let keyText = infoDictionary[publicKeyInfoKey] as? String,
              let channelText = infoDictionary[channelInfoKey] as? String,
              let expectedChannel = UpdateChannelName(rawValue: channelText),
              !feedText.isEmpty,
              !keyText.isEmpty,
              !feedText.contains("$("),
              !keyText.contains("$("),
              let feedURL = URL(string: feedText) else {
            return .failure(.missingConfiguration)
        }

        do {
            return .success(try UpdateChannelConfiguration(
                feedURL: feedURL,
                publicKeyBase64: keyText,
                expectedChannel: expectedChannel
            ))
        } catch {
            return .failure(.invalidConfiguration)
        }
    }

    public func accepts(_ url: URL) -> Bool {
        let encodedPath = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        )?.percentEncodedPath
        guard url.scheme == approvedOrigin.scheme,
              url.host?.lowercased() == approvedOrigin.host?.lowercased(),
              url.port == approvedOrigin.port,
              url.user == nil,
              url.password == nil,
              url.query == nil,
              url.fragment == nil,
              url.absoluteString.utf8.count <= 2_048,
              url.path.count <= 1_024,
              encodedPath?.contains("%") == false,
              !url.path.contains("//"),
              !url.path.split(separator: "/", omittingEmptySubsequences: false).contains("."),
              !url.path.split(separator: "/", omittingEmptySubsequences: false).contains("..") else {
            return false
        }
        return true
    }

    private static func makePersistenceNamespace(
        feedURL: URL,
        publicKey: Data,
        channel: UpdateChannelName
    ) -> String {
        var material = Data("founder-office-update-state-v1".utf8)
        for field in [Data(channel.rawValue.utf8), Data(feedURL.absoluteString.utf8), publicKey] {
            var length = UInt64(field.count).bigEndian
            withUnsafeBytes(of: &length) { bytes in
                material.append(contentsOf: bytes)
            }
            material.append(field)
        }
        return SHA256.hash(data: material).map {
            String(format: "%02x", $0)
        }.joined()
    }
}

public struct SignedUpdateEnvelope: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public static let maximumEncodedBytes = 256 * 1_024

    public let schemaVersion: Int
    public let payload: String
    public let signature: String

    public init(
        schemaVersion: Int = SignedUpdateEnvelope.schemaVersion,
        payload: String,
        signature: String
    ) {
        self.schemaVersion = schemaVersion
        self.payload = payload
        self.signature = signature
    }

    public func verifiedManifest(
        configuration: UpdateChannelConfiguration
    ) throws -> UpdateChannelManifest {
        try verifiedUpdate(configuration: configuration).manifest
    }

    public func verifiedUpdate(
        configuration: UpdateChannelConfiguration
    ) throws -> VerifiedUpdateManifest {
        guard schemaVersion == Self.schemaVersion,
              let payloadData = Data(base64Encoded: payload),
              payloadData.count <= Self.maximumEncodedBytes,
              let signatureData = Data(base64Encoded: signature),
              signatureData.count == 64 else {
            throw UpdateChannelError.invalidEnvelope
        }

        let publicKey: Curve25519.Signing.PublicKey
        do {
            publicKey = try Curve25519.Signing.PublicKey(
                rawRepresentation: configuration.publicKey
            )
        } catch {
            throw UpdateChannelError.invalidConfiguration
        }
        guard publicKey.isValidSignature(signatureData, for: payloadData) else {
            throw UpdateChannelError.invalidSignature
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest: UpdateChannelManifest
        do {
            manifest = try decoder.decode(UpdateChannelManifest.self, from: payloadData)
        } catch {
            throw UpdateChannelError.invalidManifest
        }
        try manifest.validate(configuration: configuration)
        let digest = SHA256.hash(data: payloadData).map {
            String(format: "%02x", $0)
        }.joined()
        return VerifiedUpdateManifest(manifest: manifest, payloadSHA256: digest)
    }
}

public struct VerifiedUpdateManifest: Equatable, Sendable {
    public let manifest: UpdateChannelManifest
    public let payloadSHA256: String

    public init(manifest: UpdateChannelManifest, payloadSHA256: String) {
        self.manifest = manifest
        self.payloadSHA256 = payloadSHA256
    }
}

public enum UpdateChannelName: String, Codable, CaseIterable, Sendable {
    case beta
    case stable
}

public enum UpdateRollbackReason: String, Codable, CaseIterable, Sendable {
    case dataIntegrity = "data_integrity"
    case privacy
    case security
    case stability
}

public struct UpdateRollout: Codable, Equatable, Sendable {
    public let id: UUID
    public let startsAt: Date
    public let phaseCount: Int
    public let phaseIntervalSeconds: Int
    public let isPaused: Bool
    public let isCritical: Bool

    public init(
        id: UUID,
        startsAt: Date,
        phaseCount: Int,
        phaseIntervalSeconds: Int,
        isPaused: Bool,
        isCritical: Bool
    ) {
        self.id = id
        self.startsAt = startsAt
        self.phaseCount = phaseCount
        self.phaseIntervalSeconds = phaseIntervalSeconds
        self.isPaused = isPaused
        self.isCritical = isCritical
    }
}

public struct UpdateRollbackEvidence: Codable, Equatable, Sendable {
    public let revertsBuild: Int
    public let reason: UpdateRollbackReason
    public let incidentID: UUID

    public init(revertsBuild: Int, reason: UpdateRollbackReason, incidentID: UUID) {
        self.revertsBuild = revertsBuild
        self.reason = reason
        self.incidentID = incidentID
    }
}

public struct UpdateRelease: Codable, Equatable, Sendable {
    public let version: String
    public let build: Int
    public let minimumSystemVersion: String
    public let commit: String
    public let artifactURL: URL
    public let artifactSHA256: String
    public let artifactSizeBytes: Int64
    public let evidenceURL: URL
    public let rollback: UpdateRollbackEvidence?

    public init(
        version: String,
        build: Int,
        minimumSystemVersion: String,
        commit: String,
        artifactURL: URL,
        artifactSHA256: String,
        artifactSizeBytes: Int64,
        evidenceURL: URL,
        rollback: UpdateRollbackEvidence? = nil
    ) {
        self.version = version
        self.build = build
        self.minimumSystemVersion = minimumSystemVersion
        self.commit = commit
        self.artifactURL = artifactURL
        self.artifactSHA256 = artifactSHA256
        self.artifactSizeBytes = artifactSizeBytes
        self.evidenceURL = evidenceURL
        self.rollback = rollback
    }
}

public struct UpdateChannelManifest: Codable, Equatable, Sendable {
    public static let contractVersion = 1

    public let contractVersion: Int
    public let sequence: Int64
    public let channel: UpdateChannelName
    public let publishedAt: Date
    public let rollout: UpdateRollout
    public let release: UpdateRelease

    public init(
        contractVersion: Int = UpdateChannelManifest.contractVersion,
        sequence: Int64 = 1,
        channel: UpdateChannelName,
        publishedAt: Date,
        rollout: UpdateRollout,
        release: UpdateRelease
    ) {
        self.contractVersion = contractVersion
        self.sequence = sequence
        self.channel = channel
        self.publishedAt = publishedAt
        self.rollout = rollout
        self.release = release
    }

    public func validate(configuration: UpdateChannelConfiguration) throws {
        let immutableBasePath = "/releases/macos/v\(release.version)/build-\(release.build)/\(release.commit)"
        let expectedArtifactPath = "\(immutableBasePath)/FoundersOffice-\(release.version)-build-\(release.build)-macOS.zip"
        let expectedEvidencePath = "\(immutableBasePath)/release.json"
        guard contractVersion == Self.contractVersion,
              sequence > 0,
              channel == configuration.expectedChannel,
              release.version.utf8.count <= 32,
              Self.isVersion(release.version),
              release.build > 0,
              release.minimumSystemVersion.utf8.count <= 16,
              Self.isSystemVersion(release.minimumSystemVersion),
              release.commit.range(
                of: "^[0-9a-f]{40}$",
                options: .regularExpression
              ) != nil,
              release.artifactSHA256.range(
                of: "^[0-9a-f]{64}$",
                options: .regularExpression
              ) != nil,
              release.artifactSizeBytes > 0,
              release.artifactSizeBytes <= 4 * 1_024 * 1_024 * 1_024,
              rollout.phaseCount >= 1,
              rollout.phaseCount <= 100,
              rollout.phaseIntervalSeconds >= 60,
              rollout.phaseIntervalSeconds <= 7 * 24 * 60 * 60,
              publishedAt <= Date().addingTimeInterval(5 * 60),
              rollout.startsAt <= publishedAt.addingTimeInterval(30 * 24 * 60 * 60),
              configuration.accepts(release.artifactURL),
              configuration.accepts(release.evidenceURL),
              release.artifactURL.path == expectedArtifactPath,
              release.evidenceURL.path == expectedEvidencePath else {
            throw UpdateChannelError.invalidManifest
        }

        if let rollback = release.rollback {
            guard rollback.revertsBuild > 0,
                  rollback.revertsBuild < release.build else {
                throw UpdateChannelError.invalidManifest
            }
        }
    }

    private static func isVersion(_ value: String) -> Bool {
        value.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) != nil
    }

    private static func isSystemVersion(_ value: String) -> Bool {
        value.range(of: "^[0-9]+\\.[0-9]+(?:\\.[0-9]+)?$", options: .regularExpression) != nil
    }
}

public enum UpdateFeedReplayDecision: Equatable, Sendable {
    case acceptNew
    case acceptSame
    case reject
}

public enum UpdateFeedReplayGuard {
    public static func evaluate(
        candidateSequence: Int64,
        candidatePayloadSHA256: String,
        acceptedSequence: Int64?,
        acceptedPayloadSHA256: String?
    ) -> UpdateFeedReplayDecision {
        guard candidateSequence > 0,
              candidatePayloadSHA256.range(
                of: "^[0-9a-f]{64}$",
                options: .regularExpression
              ) != nil else { return .reject }
        guard let acceptedSequence else { return .acceptNew }
        if candidateSequence > acceptedSequence { return .acceptNew }
        if candidateSequence == acceptedSequence,
           candidatePayloadSHA256 == acceptedPayloadSHA256 {
            return .acceptSame
        }
        return .reject
    }
}

public enum UpdateCheckMode: Equatable, Sendable {
    case automatic
    case manual
}

public enum UpdateAvailability: Equatable, Sendable {
    case current
    case paused
    case notYetEligible(Date)
    case requiresNewerSystem(String)
    case available(UpdateRelease)
}

public enum UpdateChannelEvaluator {
    public static func evaluate(
        manifest: UpdateChannelManifest,
        currentBuild: Int,
        currentSystemVersion: OperatingSystemVersion,
        installationID: UUID,
        mode: UpdateCheckMode,
        now: Date = Date()
    ) -> UpdateAvailability {
        guard manifest.release.build > currentBuild else { return .current }
        guard systemVersion(currentSystemVersion, satisfies: manifest.release.minimumSystemVersion) else {
            return .requiresNewerSystem(manifest.release.minimumSystemVersion)
        }
        guard !manifest.rollout.isPaused else { return .paused }
        if mode == .manual || manifest.rollout.isCritical {
            return .available(manifest.release)
        }

        let group = rolloutGroup(
            installationID: installationID,
            rolloutID: manifest.rollout.id,
            phaseCount: manifest.rollout.phaseCount
        )
        let eligibleAt = manifest.rollout.startsAt.addingTimeInterval(
            TimeInterval(group * manifest.rollout.phaseIntervalSeconds)
        )
        return now >= eligibleAt ? .available(manifest.release) : .notYetEligible(eligibleAt)
    }

    public static func rolloutGroup(
        installationID: UUID,
        rolloutID: UUID,
        phaseCount: Int
    ) -> Int {
        precondition(phaseCount > 0)
        var data = Data(installationID.uuidString.lowercased().utf8)
        data.append(contentsOf: rolloutID.uuidString.lowercased().utf8)
        let digest = SHA256.hash(data: data)
        let prefix = digest.prefix(8).reduce(UInt64.zero) { ($0 << 8) | UInt64($1) }
        return Int(prefix % UInt64(phaseCount))
    }

    private static func systemVersion(
        _ current: OperatingSystemVersion,
        satisfies requiredText: String
    ) -> Bool {
        let values = requiredText.split(separator: ".").compactMap { Int($0) }
        guard values.count == 2 || values.count == 3 else { return false }
        let required = OperatingSystemVersion(
            majorVersion: values[0],
            minorVersion: values[1],
            patchVersion: values.count == 3 ? values[2] : 0
        )
        if current.majorVersion != required.majorVersion {
            return current.majorVersion > required.majorVersion
        }
        if current.minorVersion != required.minorVersion {
            return current.minorVersion > required.minorVersion
        }
        return current.patchVersion >= required.patchVersion
    }
}

public enum UpdateCheckSchedule {
    public static func shouldAttempt(
        lastAttempt: Date?,
        now: Date,
        minimumInterval: TimeInterval
    ) -> Bool {
        guard minimumInterval > 0, minimumInterval <= 7 * 24 * 60 * 60 else {
            return false
        }
        guard let lastAttempt else { return true }
        let elapsed = now.timeIntervalSince(lastAttempt)
        // A future timestamp means the wall clock moved backwards. Retrying is
        // safer than suppressing checks indefinitely; rollout eligibility still
        // remains signed and deterministic.
        return elapsed < 0 || elapsed >= minimumInterval
    }
}

public enum UpdateChannelError: Error, Equatable, Sendable {
    case missingConfiguration
    case invalidConfiguration
    case responseTooLarge
    case invalidHTTPResponse
    case invalidEnvelope
    case invalidSignature
    case invalidManifest
}

public struct UpdateChannelHTTPClient: Sendable {
    public struct Limits: Equatable, Sendable {
        public static let production = Limits(
            maximumResponseBytes: 512 * 1_024,
            maximumHeaderBytes: 32 * 1_024,
            maximumHeaderCount: 64,
            requestTimeout: 8,
            resourceTimeout: 12
        )

        public let maximumResponseBytes: Int
        public let maximumHeaderBytes: Int
        public let maximumHeaderCount: Int
        public let requestTimeout: TimeInterval
        public let resourceTimeout: TimeInterval

        public init(
            maximumResponseBytes: Int,
            maximumHeaderBytes: Int,
            maximumHeaderCount: Int,
            requestTimeout: TimeInterval,
            resourceTimeout: TimeInterval
        ) {
            self.maximumResponseBytes = maximumResponseBytes
            self.maximumHeaderBytes = maximumHeaderBytes
            self.maximumHeaderCount = maximumHeaderCount
            self.requestTimeout = requestTimeout
            self.resourceTimeout = resourceTimeout
        }
    }

    public let limits: Limits

    public init(limits: Limits = .production) {
        self.limits = limits
    }

    public func fetchEnvelope(
        configuration: UpdateChannelConfiguration
    ) async throws -> SignedUpdateEnvelope {
        guard Self.areSafe(limits) else {
            throw UpdateChannelError.invalidConfiguration
        }

        let cancellation = UpdateRequestCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let request = BoundedUpdateRequest(
                    channelConfiguration: configuration,
                    limits: limits,
                    continuation: continuation
                )
                cancellation.install(request)
                request.start()
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    public static func validateResponse(
        _ response: HTTPURLResponse,
        expectedURL: URL,
        limits: Limits = .production
    ) throws {
        guard areSafe(limits),
              response.statusCode == 200,
              response.url == expectedURL,
              response.mimeType?.lowercased() == "application/json" else {
            throw UpdateChannelError.invalidHTTPResponse
        }

        let headers = response.allHeaderFields
        guard headers.count <= limits.maximumHeaderCount else {
            throw UpdateChannelError.invalidHTTPResponse
        }
        var headerBytes = 0
        for (rawName, rawValue) in headers {
            let name = String(describing: rawName)
            let value = String(describing: rawValue)
            guard name.utf8.count <= 128, value.utf8.count <= 4_096 else {
                throw UpdateChannelError.invalidHTTPResponse
            }
            headerBytes += name.utf8.count + value.utf8.count + 4
            guard headerBytes <= limits.maximumHeaderBytes else {
                throw UpdateChannelError.invalidHTTPResponse
            }
        }

        if response.expectedContentLength != NSURLSessionTransferSizeUnknown {
            guard response.expectedContentLength >= 0,
                  response.expectedContentLength <= Int64(limits.maximumResponseBytes) else {
                throw UpdateChannelError.responseTooLarge
            }
        }
    }

    private static func areSafe(_ limits: Limits) -> Bool {
        limits.maximumResponseBytes >= 1_024
            && limits.maximumResponseBytes <= 1_024 * 1_024
            && limits.maximumHeaderBytes >= 1_024
            && limits.maximumHeaderBytes <= 64 * 1_024
            && limits.maximumHeaderCount >= 1
            && limits.maximumHeaderCount <= 128
            && limits.requestTimeout >= 1
            && limits.requestTimeout <= 30
            && limits.resourceTimeout >= limits.requestTimeout
            && limits.resourceTimeout <= 60
    }
}

private final class UpdateRequestCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var request: BoundedUpdateRequest?
    private var isCancelled = false

    func install(_ request: BoundedUpdateRequest) {
        lock.lock()
        self.request = request
        let shouldCancel = isCancelled
        lock.unlock()
        if shouldCancel { request.cancel() }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let request = request
        lock.unlock()
        request?.cancel()
    }
}

private final class BoundedUpdateRequest: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate,
    @unchecked Sendable {
    private let channelConfiguration: UpdateChannelConfiguration
    private let limits: UpdateChannelHTTPClient.Limits
    private let lock = NSLock()
    private var continuation: CheckedContinuation<SignedUpdateEnvelope, Error>?
    private var session: URLSession?
    private var receivedData = Data()

    init(
        channelConfiguration: UpdateChannelConfiguration,
        limits: UpdateChannelHTTPClient.Limits,
        continuation: CheckedContinuation<SignedUpdateEnvelope, Error>
    ) {
        self.channelConfiguration = channelConfiguration
        self.limits = limits
        self.continuation = continuation
    }

    func start() {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.urlCache = nil
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        sessionConfiguration.httpCookieStorage = nil
        sessionConfiguration.urlCredentialStorage = nil
        sessionConfiguration.httpShouldSetCookies = false
        sessionConfiguration.httpMaximumConnectionsPerHost = 1
        sessionConfiguration.timeoutIntervalForRequest = limits.requestTimeout
        sessionConfiguration.timeoutIntervalForResource = limits.resourceTimeout

        let session = URLSession(
            configuration: sessionConfiguration,
            delegate: self,
            delegateQueue: nil
        )
        lock.lock()
        guard continuation != nil else {
            lock.unlock()
            session.invalidateAndCancel()
            return
        }
        self.session = session
        lock.unlock()

        var request = URLRequest(
            url: channelConfiguration.feedURL,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: limits.requestTimeout
        )
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        session.dataTask(with: request).resume()
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // The feed URL is immutable product configuration. Even a same-origin
        // redirect would weaken that exact-URL contract.
        completionHandler(nil)
        finish(.failure(UpdateChannelError.invalidHTTPResponse))
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(UpdateChannelError.invalidHTTPResponse))
            return
        }
        do {
            try UpdateChannelHTTPClient.validateResponse(
                response,
                expectedURL: channelConfiguration.feedURL,
                limits: limits
            )
            completionHandler(.allow)
        } catch {
            completionHandler(.cancel)
            finish(.failure(error))
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        lock.lock()
        guard continuation != nil else {
            lock.unlock()
            return
        }
        let remaining = limits.maximumResponseBytes - receivedData.count
        guard data.count <= remaining else {
            lock.unlock()
            dataTask.cancel()
            finish(.failure(UpdateChannelError.responseTooLarge))
            return
        }
        receivedData.append(data)
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error {
            finish(.failure(error))
            return
        }

        lock.lock()
        let payload = receivedData
        lock.unlock()
        guard !payload.isEmpty else {
            finish(.failure(UpdateChannelError.invalidEnvelope))
            return
        }

        do {
            let envelope = try JSONDecoder().decode(SignedUpdateEnvelope.self, from: payload)
            finish(.success(envelope))
        } catch {
            finish(.failure(UpdateChannelError.invalidEnvelope))
        }
    }

    private func finish(_ result: Result<SignedUpdateEnvelope, Error>) {
        lock.lock()
        guard let continuation else {
            lock.unlock()
            return
        }
        self.continuation = nil
        let session = self.session
        self.session = nil
        receivedData.removeAll(keepingCapacity: false)
        lock.unlock()

        session?.invalidateAndCancel()
        continuation.resume(with: result)
    }
}

extension UpdateChannelError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "Updates are not configured in this development build."
        case .invalidConfiguration:
            return "The update channel is not configured safely."
        case .responseTooLarge, .invalidHTTPResponse, .invalidEnvelope,
             .invalidSignature, .invalidManifest:
            return "The update channel could not be verified. No download was opened."
        }
    }
}
