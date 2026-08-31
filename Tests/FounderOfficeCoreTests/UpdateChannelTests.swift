import CryptoKit
import Foundation
import FounderOfficeCore
import Testing

@Suite("Signed update channel")
struct UpdateChannelTests {
    private let origin = URL(string: "https://updates.founders-office.example")!

    @Test("Configuration accepts only an HTTPS feed and Ed25519 public key")
    func configurationIsFailClosed() throws {
        let key = Curve25519.Signing.PrivateKey()
        let publicKey = key.publicKey.rawRepresentation.base64EncodedString()

        _ = try UpdateChannelConfiguration(
            feedURL: #require(URL(string: "https://updates.founders-office.example/channel/beta.json")),
            publicKeyBase64: publicKey
        )

        #expect(throws: UpdateChannelError.invalidConfiguration) {
            try UpdateChannelConfiguration(
                feedURL: #require(URL(string: "http://updates.founders-office.example/channel/beta.json")),
                publicKeyBase64: publicKey
            )
        }
        #expect(throws: UpdateChannelError.invalidConfiguration) {
            try UpdateChannelConfiguration(
                feedURL: #require(URL(string: "https://updates.founders-office.example/channel/beta.json?mutable=1")),
                publicKeyBase64: publicKey
            )
        }
        #expect(throws: UpdateChannelError.invalidConfiguration) {
            try UpdateChannelConfiguration(
                feedURL: #require(URL(string: "https://updates.founders-office.example/channel/beta.json")),
                publicKeyBase64: Data(repeating: 0, count: 31).base64EncodedString()
            )
        }
        #expect(throws: UpdateChannelError.invalidConfiguration) {
            try UpdateChannelConfiguration(
                feedURL: #require(URL(string: "https://updates.founders-office.example/channel/beta.json")),
                publicKeyBase64: " \(publicKey)"
            )
        }
        #expect(throws: UpdateChannelError.invalidConfiguration) {
            try UpdateChannelConfiguration(
                feedURL: #require(URL(string: "https://updates.founders-office.example/")),
                publicKeyBase64: publicKey
            )
        }
        #expect(throws: UpdateChannelError.invalidConfiguration) {
            try UpdateChannelConfiguration(
                feedURL: #require(URL(string: "https://updates.founders-office.example/channel/%2E%2E/beta.json")),
                publicKeyBase64: publicKey
            )
        }
        #expect(throws: UpdateChannelError.invalidConfiguration) {
            try UpdateChannelConfiguration(
                feedURL: #require(URL(string: "https://updates.founders-office.example:0/channel/beta.json")),
                publicKeyBase64: publicKey
            )
        }
        #expect(UpdateChannelConfiguration.load(infoDictionary: [
            UpdateChannelConfiguration.feedURLInfoKey:
                "https://updates.founders-office.example/channel/beta.json",
            UpdateChannelConfiguration.publicKeyInfoKey: publicKey
        ]) == .failure(.missingConfiguration))
    }

    @Test("Replay state is isolated by feed, channel, and signing key")
    func replayStateUsesImmutableConfigurationNamespace() throws {
        let firstKey = Curve25519.Signing.PrivateKey().publicKey
        let secondKey = Curve25519.Signing.PrivateKey().publicKey
        let beta = try UpdateChannelConfiguration(
            feedURL: origin.appending(path: "channel/beta.json"),
            publicKeyBase64: firstKey.rawRepresentation.base64EncodedString(),
            expectedChannel: .beta
        )
        let identical = try UpdateChannelConfiguration(
            feedURL: origin.appending(path: "channel/beta.json"),
            publicKeyBase64: firstKey.rawRepresentation.base64EncodedString(),
            expectedChannel: .beta
        )
        let stable = try UpdateChannelConfiguration(
            feedURL: origin.appending(path: "channel/beta.json"),
            publicKeyBase64: firstKey.rawRepresentation.base64EncodedString(),
            expectedChannel: .stable
        )
        let rotatedKey = try UpdateChannelConfiguration(
            feedURL: origin.appending(path: "channel/beta.json"),
            publicKeyBase64: secondKey.rawRepresentation.base64EncodedString(),
            expectedChannel: .beta
        )
        let movedFeed = try UpdateChannelConfiguration(
            feedURL: origin.appending(path: "channel/beta-v2.json"),
            publicKeyBase64: firstKey.rawRepresentation.base64EncodedString(),
            expectedChannel: .beta
        )

        #expect(beta.persistenceNamespace == identical.persistenceNamespace)
        #expect(beta.persistenceNamespace != stable.persistenceNamespace)
        #expect(beta.persistenceNamespace != rotatedKey.persistenceNamespace)
        #expect(beta.persistenceNamespace != movedFeed.persistenceNamespace)
        #expect(beta.persistenceNamespace.range(
            of: "^[0-9a-f]{64}$",
            options: .regularExpression
        ) != nil)
        #expect(!beta.persistenceNamespace.contains(origin.host ?? ""))
        #expect(!beta.persistenceNamespace.contains(
            firstKey.rawRepresentation.base64EncodedString()
        ))
    }

    @Test("A client rejects a valid signature for the other release channel")
    func configuredChannelCannotBeCrossed() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let configuration = try UpdateChannelConfiguration(
            feedURL: origin.appending(path: "channel/stable.json"),
            publicKeyBase64: privateKey.publicKey.rawRepresentation.base64EncodedString(),
            expectedChannel: .stable
        )
        let payload = try encode(makeManifest())
        let envelope = SignedUpdateEnvelope(
            payload: payload.base64EncodedString(),
            signature: try privateKey.signature(for: payload).base64EncodedString()
        )
        #expect(throws: UpdateChannelError.invalidManifest) {
            try envelope.verifiedManifest(configuration: configuration)
        }
    }

    @Test("Signed strings and URLs remain bounded before reaching UI")
    func signedDisplayValuesAreBounded() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let configuration = try makeConfiguration(publicKey: privateKey.publicKey)
        let oversizedRelease = UpdateRelease(
            version: String(repeating: "1", count: 33) + ".2.3",
            build: 123,
            minimumSystemVersion: "14.0",
            commit: String(repeating: "a", count: 40),
            artifactURL: origin.appending(path: "releases/123/FounderOffice.zip"),
            artifactSHA256: String(repeating: "b", count: 64),
            artifactSizeBytes: 10_000,
            evidenceURL: origin.appending(path: "releases/123/release.json")
        )
        #expect(throws: UpdateChannelError.invalidManifest) {
            try makeManifest(release: oversizedRelease).validate(configuration: configuration)
        }

        let longPath = String(repeating: "a", count: 2_100)
        let longURLRelease = UpdateRelease(
            version: "1.2.3",
            build: 123,
            minimumSystemVersion: "14.0",
            commit: String(repeating: "a", count: 40),
            artifactURL: try #require(URL(string: "https://updates.founders-office.example/\(longPath)")),
            artifactSHA256: String(repeating: "b", count: 64),
            artifactSizeBytes: 10_000,
            evidenceURL: origin.appending(path: "releases/123/release.json")
        )
        #expect(throws: UpdateChannelError.invalidManifest) {
            try makeManifest(release: longURLRelease).validate(configuration: configuration)
        }
    }

    @Test("A signed payload verifies and a one-byte change fails")
    func signatureCoversExactPayloadBytes() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let configuration = try makeConfiguration(publicKey: privateKey.publicKey)
        let manifest = makeManifest()
        let payload = try encode(manifest)
        let signature = try privateKey.signature(for: payload)
        let envelope = SignedUpdateEnvelope(
            payload: payload.base64EncodedString(),
            signature: signature.base64EncodedString()
        )

        #expect(try envelope.verifiedManifest(configuration: configuration) == manifest)

        var changedPayload = payload
        changedPayload[changedPayload.startIndex] ^= 1
        let tampered = SignedUpdateEnvelope(
            payload: changedPayload.base64EncodedString(),
            signature: signature.base64EncodedString()
        )
        #expect(throws: UpdateChannelError.invalidSignature) {
            try tampered.verifiedManifest(configuration: configuration)
        }
    }

    @Test("A valid signature cannot redirect a release outside the approved origin")
    func releaseURLsStayOnApprovedOrigin() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let configuration = try makeConfiguration(publicKey: privateKey.publicKey)
        let badRelease = UpdateRelease(
            version: "1.2.3",
            build: 123,
            minimumSystemVersion: "14.0",
            commit: String(repeating: "a", count: 40),
            artifactURL: try #require(URL(string: "https://attacker.example/FoundersOffice-1.2.3-build-123-macOS.zip")),
            artifactSHA256: String(repeating: "b", count: 64),
            artifactSizeBytes: 10_000,
            evidenceURL: origin.appending(path: "releases/123/release.json")
        )
        let manifest = makeManifest(release: badRelease)
        let payload = try encode(manifest)
        let envelope = SignedUpdateEnvelope(
            payload: payload.base64EncodedString(),
            signature: try privateKey.signature(for: payload).base64EncodedString()
        )

        #expect(throws: UpdateChannelError.invalidManifest) {
            try envelope.verifiedManifest(configuration: configuration)
        }
    }

    @Test("A signed release cannot use a mutable same-origin download path")
    func releaseURLsUseExactImmutablePaths() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let configuration = try makeConfiguration(publicKey: privateKey.publicKey)
        let badRelease = UpdateRelease(
            version: "1.2.3",
            build: 123,
            minimumSystemVersion: "14.0",
            commit: String(repeating: "a", count: 40),
            artifactURL: origin.appending(path: "latest/FoundersOffice-1.2.3-build-123-macOS.zip"),
            artifactSHA256: String(repeating: "b", count: 64),
            artifactSizeBytes: 10_000,
            evidenceURL: origin.appending(path: "latest/release.json")
        )

        #expect(throws: UpdateChannelError.invalidManifest) {
            try makeManifest(release: badRelease).validate(configuration: configuration)
        }
    }

    @Test("Automatic rollout is deterministic while manual checks may opt in early")
    func stagedRolloutIsDeterministic() {
        let installationID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let rolloutID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let group = UpdateChannelEvaluator.rolloutGroup(
            installationID: installationID,
            rolloutID: rolloutID,
            phaseCount: 7
        )
        #expect(group == UpdateChannelEvaluator.rolloutGroup(
            installationID: installationID,
            rolloutID: rolloutID,
            phaseCount: 7
        ))
        #expect((0..<7).contains(group))

        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let rollout = UpdateRollout(
            id: rolloutID,
            startsAt: now,
            phaseCount: 7,
            phaseIntervalSeconds: 86_400,
            isPaused: false,
            isCritical: false
        )
        let manifest = makeManifest(publishedAt: now, rollout: rollout)
        let automatic = UpdateChannelEvaluator.evaluate(
            manifest: manifest,
            currentBuild: 122,
            currentSystemVersion: OperatingSystemVersion(
                majorVersion: 14,
                minorVersion: 0,
                patchVersion: 0
            ),
            installationID: installationID,
            mode: .automatic,
            now: now
        )
        if group == 0 {
            #expect(automatic == .available(manifest.release))
        } else {
            #expect(automatic == .notYetEligible(now.addingTimeInterval(TimeInterval(group * 86_400))))
        }

        #expect(UpdateChannelEvaluator.evaluate(
            manifest: manifest,
            currentBuild: 122,
            currentSystemVersion: OperatingSystemVersion(
                majorVersion: 14,
                minorVersion: 0,
                patchVersion: 0
            ),
            installationID: installationID,
            mode: .manual,
            now: now
        ) == .available(manifest.release))
    }

    @Test("A paused release and an already installed build never open a download")
    func pauseAndCurrentBuildWin() {
        let rollout = UpdateRollout(
            id: UUID(),
            startsAt: .distantPast,
            phaseCount: 1,
            phaseIntervalSeconds: 60,
            isPaused: true,
            isCritical: true
        )
        let manifest = makeManifest(rollout: rollout)
        let environment = OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)

        #expect(UpdateChannelEvaluator.evaluate(
            manifest: manifest,
            currentBuild: 122,
            currentSystemVersion: environment,
            installationID: UUID(),
            mode: .manual
        ) == .paused)
        #expect(UpdateChannelEvaluator.evaluate(
            manifest: manifest,
            currentBuild: 123,
            currentSystemVersion: environment,
            installationID: UUID(),
            mode: .manual
        ) == .current)
    }

    @Test("Rollback evidence names only an older build")
    func rollbackEvidenceCannotPointForward() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let configuration = try makeConfiguration(publicKey: privateKey.publicKey)
        let invalidRollback = UpdateRollbackEvidence(
            revertsBuild: 123,
            reason: .stability,
            incidentID: UUID()
        )
        let release = UpdateRelease(
            version: "1.2.3",
            build: 123,
            minimumSystemVersion: "14.0",
            commit: String(repeating: "a", count: 40),
            artifactURL: origin.appending(
                path: "releases/macos/v1.2.3/build-123/\(String(repeating: "a", count: 40))/FoundersOffice-1.2.3-build-123-macOS.zip"
            ),
            artifactSHA256: String(repeating: "b", count: 64),
            artifactSizeBytes: 10_000,
            evidenceURL: origin.appending(
                path: "releases/macos/v1.2.3/build-123/\(String(repeating: "a", count: 40))/release.json"
            ),
            rollback: invalidRollback
        )
        #expect(throws: UpdateChannelError.invalidManifest) {
            try makeManifest(release: release).validate(configuration: configuration)
        }
    }

    @Test("The HTTP boundary accepts only the exact small JSON response")
    func httpResponseBoundaryIsBounded() throws {
        let feedURL = origin.appending(path: "channel/beta.json")
        let valid = try #require(HTTPURLResponse(
            url: feedURL,
            statusCode: 200,
            httpVersion: "HTTP/2",
            headerFields: [
                "Content-Type": "application/json",
                "Content-Length": "4096"
            ]
        ))
        try UpdateChannelHTTPClient.validateResponse(valid, expectedURL: feedURL)

        let redirected = try #require(HTTPURLResponse(
            url: origin.appending(path: "channel/latest.json"),
            statusCode: 200,
            httpVersion: "HTTP/2",
            headerFields: ["Content-Type": "application/json"]
        ))
        #expect(throws: UpdateChannelError.invalidHTTPResponse) {
            try UpdateChannelHTTPClient.validateResponse(redirected, expectedURL: feedURL)
        }

        let oversized = try #require(HTTPURLResponse(
            url: feedURL,
            statusCode: 200,
            httpVersion: "HTTP/2",
            headerFields: [
                "Content-Type": "application/json",
                "Content-Length": String(513 * 1_024)
            ]
        ))
        #expect(throws: UpdateChannelError.responseTooLarge) {
            try UpdateChannelHTTPClient.validateResponse(oversized, expectedURL: feedURL)
        }

        let wrongType = try #require(HTTPURLResponse(
            url: feedURL,
            statusCode: 200,
            httpVersion: "HTTP/2",
            headerFields: ["Content-Type": "text/html"]
        ))
        #expect(throws: UpdateChannelError.invalidHTTPResponse) {
            try UpdateChannelHTTPClient.validateResponse(wrongType, expectedURL: feedURL)
        }
    }

    @Test("Automatic checks are bounded without becoming stuck after clock skew")
    func automaticCheckScheduleIsBounded() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let interval: TimeInterval = 86_400
        #expect(UpdateCheckSchedule.shouldAttempt(
            lastAttempt: nil,
            now: now,
            minimumInterval: interval
        ))
        #expect(!UpdateCheckSchedule.shouldAttempt(
            lastAttempt: now.addingTimeInterval(-60),
            now: now,
            minimumInterval: interval
        ))
        #expect(UpdateCheckSchedule.shouldAttempt(
            lastAttempt: now.addingTimeInterval(-interval),
            now: now,
            minimumInterval: interval
        ))
        #expect(UpdateCheckSchedule.shouldAttempt(
            lastAttempt: now.addingTimeInterval(60),
            now: now,
            minimumInterval: interval
        ))
    }

    @Test("Accepted feed sequence rejects rollback and sequence reuse")
    func feedReplayGuardIsMonotonic() {
        let firstDigest = String(repeating: "a", count: 64)
        let secondDigest = String(repeating: "b", count: 64)
        #expect(UpdateFeedReplayGuard.evaluate(
            candidateSequence: 10,
            candidatePayloadSHA256: firstDigest,
            acceptedSequence: nil,
            acceptedPayloadSHA256: nil
        ) == .acceptNew)
        #expect(UpdateFeedReplayGuard.evaluate(
            candidateSequence: 10,
            candidatePayloadSHA256: firstDigest,
            acceptedSequence: 10,
            acceptedPayloadSHA256: firstDigest
        ) == .acceptSame)
        #expect(UpdateFeedReplayGuard.evaluate(
            candidateSequence: 10,
            candidatePayloadSHA256: secondDigest,
            acceptedSequence: 10,
            acceptedPayloadSHA256: firstDigest
        ) == .reject)
        #expect(UpdateFeedReplayGuard.evaluate(
            candidateSequence: 9,
            candidatePayloadSHA256: firstDigest,
            acceptedSequence: 10,
            acceptedPayloadSHA256: firstDigest
        ) == .reject)
        #expect(UpdateFeedReplayGuard.evaluate(
            candidateSequence: 11,
            candidatePayloadSHA256: secondDigest,
            acceptedSequence: 10,
            acceptedPayloadSHA256: firstDigest
        ) == .acceptNew)
    }

    @Test("Cancelling a check cancels the underlying bounded request")
    func cancelledCheckReturnsCancellation() async throws {
        let key = Curve25519.Signing.PrivateKey()
        let configuration = try UpdateChannelConfiguration(
            feedURL: #require(URL(string: "https://192.0.2.1/channel/beta.json")),
            publicKeyBase64: key.publicKey.rawRepresentation.base64EncodedString()
        )
        let task = Task {
            try await UpdateChannelHTTPClient().fetchEnvelope(configuration: configuration)
        }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("cancelled update check unexpectedly completed")
        } catch is CancellationError {
            // Expected: cancellation reaches the URLSession request holder.
        } catch {
            Issue.record("cancelled update check returned a non-cancellation error")
        }
    }

    private func makeConfiguration(
        publicKey: Curve25519.Signing.PublicKey
    ) throws -> UpdateChannelConfiguration {
        try UpdateChannelConfiguration(
            feedURL: origin.appending(path: "channel/beta.json"),
            publicKeyBase64: publicKey.rawRepresentation.base64EncodedString()
        )
    }

    private func makeManifest(
        publishedAt: Date = Date(
            timeIntervalSince1970: floor(Date().timeIntervalSince1970)
        ),
        rollout: UpdateRollout? = nil,
        release: UpdateRelease? = nil
    ) -> UpdateChannelManifest {
        let commit = String(repeating: "a", count: 40)
        let immutableBase = "releases/macos/v1.2.3/build-123/\(commit)"
        let resolvedRelease = release ?? UpdateRelease(
            version: "1.2.3",
            build: 123,
            minimumSystemVersion: "14.0",
            commit: commit,
            artifactURL: origin.appending(
                path: "\(immutableBase)/FoundersOffice-1.2.3-build-123-macOS.zip"
            ),
            artifactSHA256: String(repeating: "b", count: 64),
            artifactSizeBytes: 10_000,
            evidenceURL: origin.appending(path: "\(immutableBase)/release.json")
        )
        return UpdateChannelManifest(
            channel: .beta,
            publishedAt: publishedAt,
            rollout: rollout ?? UpdateRollout(
                id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                startsAt: publishedAt,
                phaseCount: 7,
                phaseIntervalSeconds: 86_400,
                isPaused: false,
                isCritical: false
            ),
            release: resolvedRelease
        )
    }

    private func encode(_ manifest: UpdateChannelManifest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(manifest)
    }
}
