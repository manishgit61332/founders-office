import CryptoKit
import Foundation
import FounderOfficeCore
import Security

private enum SignerFailure: Error {
    case refused(String)
}

private struct Arguments {
    var values: [String: String] = [:]
    var flags: Set<String> = []

    init(_ raw: ArraySlice<String>) throws {
        var index = raw.startIndex
        let booleanFlags: Set<String> = [
            "--critical", "--export-public-key", "--generate-key", "--paused", "--stdin-key"
        ]
        let valueOptions: Set<String> = [
            "--artifact-url", "--channel", "--evidence-url", "--feed-url",
            "--expected-public-key",
            "--incident-id", "--keychain-account", "--keychain-service",
            "--metadata", "--output", "--phase-count",
            "--phase-interval-seconds", "--public-key-output",
            "--rollback-build", "--rollback-reason", "--rollout-id",
            "--sequence", "--starts-at", "--verified-artifact"
        ]
        while index < raw.endIndex {
            let name = raw[index]
            guard name.hasPrefix("--") else {
                throw SignerFailure.refused("unexpected positional argument")
            }
            guard values[name] == nil, !flags.contains(name) else {
                throw SignerFailure.refused("duplicate option: \(name)")
            }
            if booleanFlags.contains(name) {
                flags.insert(name)
                index = raw.index(after: index)
                continue
            }
            guard valueOptions.contains(name) else {
                throw SignerFailure.refused("unknown option: \(name)")
            }
            let valueIndex = raw.index(after: index)
            guard valueIndex < raw.endIndex else {
                throw SignerFailure.refused("missing value for \(name)")
            }
            values[name] = raw[valueIndex]
            index = raw.index(after: valueIndex)
        }
    }

    func required(_ name: String) throws -> String {
        guard let value = values[name], !value.isEmpty else {
            throw SignerFailure.refused("missing required option: \(name)")
        }
        return value
    }

    func optionalInt(_ name: String, default defaultValue: Int) throws -> Int {
        guard let text = values[name] else { return defaultValue }
        guard let value = Int(text) else {
            throw SignerFailure.refused("\(name) must be an integer")
        }
        return value
    }
}

private struct SealedReleaseMetadata: Decodable {
    struct Product: Decodable {
        let name: String
        let minimumSystemVersion: String
        let cloudEnabled: Bool
        let syncAuthority: String
    }

    struct Release: Decodable {
        let version: String
        let build: String
        let commit: String
    }

    struct Artifact: Decodable {
        let fileName: String
        let sha256: String
        let sizeBytes: Int64
        let format: String
    }

    struct Signing: Decodable {
        let hardenedRuntime: Bool
        let timestamped: Bool
    }

    struct Notarization: Decodable {
        let status: String
        let ticketStapled: Bool
        let gatekeeperAssessment: String
    }

    let schemaVersion: Int
    let writeOnce: Bool
    let product: Product
    let release: Release
    let artifact: Artifact
    let signing: Signing
    let notarization: Notarization

    func validate(artifactURL: URL, evidenceURL: URL) throws -> Int {
        guard schemaVersion == 2,
              writeOnce,
              product.name == "Founder's Office",
              product.cloudEnabled,
              product.syncAuthority == "supabase",
              release.version.range(
                of: "^[0-9]+\\.[0-9]+\\.[0-9]+$",
                options: .regularExpression
              ) != nil,
              let build = Int(release.build),
              build > 0,
              release.commit.range(
                of: "^[0-9a-f]{40}$",
                options: .regularExpression
              ) != nil,
              artifact.format == "zip",
              artifact.fileName == "FoundersOffice-\(release.version)-build-\(release.build)-macOS.zip",
              artifact.sha256.range(
                of: "^[0-9a-f]{64}$",
                options: .regularExpression
              ) != nil,
              artifact.sizeBytes > 0,
              signing.hardenedRuntime,
              signing.timestamped,
              notarization.status == "Accepted",
              notarization.ticketStapled,
              notarization.gatekeeperAssessment == "accepted" else {
            throw SignerFailure.refused("release metadata has not passed the sealed Mac release contract")
        }

        let expectedBasePath = "/releases/macos/v\(release.version)/build-\(release.build)/\(release.commit)"
        guard artifactURL.path == "\(expectedBasePath)/\(artifact.fileName)",
              evidenceURL.path == "\(expectedBasePath)/release.json" else {
            throw SignerFailure.refused("artifact and evidence URLs must use the exact immutable release paths")
        }
        return build
    }
}

private struct KeychainStore {
    let service: String
    let account: String

    func read() throws -> Data {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else {
            throw SignerFailure.refused("the update signing key is unavailable in Keychain")
        }
        return data
    }

    func create() throws -> Curve25519.Signing.PrivateKey {
        let existingQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        guard SecItemCopyMatching(existingQuery as CFDictionary, nil) == errSecItemNotFound else {
            throw SignerFailure.refused("a Keychain item already exists; key replacement is refused")
        }

        let key = Curve25519.Signing.PrivateKey()
        let insert: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData: key.rawRepresentation
        ]
        guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else {
            throw SignerFailure.refused("the update signing key could not be stored in Keychain")
        }
        return key
    }
}

private func regularFileData(at path: String, maximumBytes: Int) throws -> Data {
    let url = URL(fileURLWithPath: path)
    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    guard values.isRegularFile == true,
          values.isSymbolicLink != true,
          let size = values.fileSize,
          size > 0,
          size <= maximumBytes else {
        throw SignerFailure.refused("an input file is missing, linked, empty, or oversized")
    }
    return try Data(contentsOf: url, options: [.mappedIfSafe])
}

private func parseHTTPSURL(_ text: String) throws -> URL {
    guard let url = URL(string: text),
          url.scheme == "https",
          url.host?.isEmpty == false,
          url.user == nil,
          url.password == nil,
          url.query == nil,
          url.fragment == nil else {
        throw SignerFailure.refused("release URLs must be credential-free HTTPS URLs without query strings or fragments")
    }
    return url
}

private func decodePrivateKey(_ data: Data) throws -> Curve25519.Signing.PrivateKey {
    let raw: Data
    if data.count == 32 {
        raw = data
    } else {
        guard data.count <= 4_096,
              let text = String(data: data, encoding: .utf8),
              let decoded = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              decoded.count == 32 else {
            throw SignerFailure.refused("the private signing key has an invalid format")
        }
        raw = decoded
    }
    do {
        return try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    } catch {
        throw SignerFailure.refused("the private signing key has an invalid format")
    }
}

private func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var digest = SHA256()
    while true {
        let data = try handle.read(upToCount: 1_024 * 1_024) ?? Data()
        if data.isEmpty { break }
        digest.update(data: data)
    }
    return digest.finalize().map { String(format: "%02x", $0) }.joined()
}

private func writeOnce(_ data: Data, to path: String) throws {
    let url = URL(fileURLWithPath: path)
    guard !FileManager.default.fileExists(atPath: url.path) else {
        throw SignerFailure.refused("output replacement is refused")
    }
    let parent = url.deletingLastPathComponent()
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory),
          isDirectory.boolValue else {
        throw SignerFailure.refused("the output directory does not exist")
    }
    let temporary = parent.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
    do {
        try data.write(to: temporary, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: temporary.path
        )
        // A hard-link creation fails atomically if the destination appeared
        // after the check above; existing feed or key records are never replaced.
        try FileManager.default.linkItem(at: temporary, to: url)
        try FileManager.default.removeItem(at: temporary)
    } catch {
        try? FileManager.default.removeItem(at: temporary)
        throw error
    }
}

private func loadPrivateKey(_ arguments: Arguments) throws -> Curve25519.Signing.PrivateKey {
    let usesStdin = arguments.flags.contains("--stdin-key")
    let hasKeychain = arguments.values["--keychain-service"] != nil
        || arguments.values["--keychain-account"] != nil
    guard usesStdin != hasKeychain else {
        throw SignerFailure.refused("choose exactly one private-key source: stdin or Keychain")
    }
    if usesStdin {
        let handle = FileHandle.standardInput
        let data = try handle.read(upToCount: 4_097) ?? Data()
        guard data.count <= 4_096 else {
            throw SignerFailure.refused("the private signing key has an invalid format")
        }
        return try decodePrivateKey(data)
    }
    let store = KeychainStore(
        service: try arguments.required("--keychain-service"),
        account: try arguments.required("--keychain-account")
    )
    return try decodePrivateKey(store.read())
}

private func generateKey(_ arguments: Arguments) throws {
    guard !arguments.flags.contains("--stdin-key") else {
        throw SignerFailure.refused("key generation never accepts private key input")
    }
    let store = KeychainStore(
        service: try arguments.required("--keychain-service"),
        account: try arguments.required("--keychain-account")
    )
    let output = try arguments.required("--public-key-output")
    let key = try store.create()
    let publicKey = key.publicKey.rawRepresentation.base64EncodedString()
    try writeOnce(Data((publicKey + "\n").utf8), to: output)
}

private func exportPublicKey(_ arguments: Arguments) throws {
    let privateKey = try loadPrivateKey(arguments)
    let output = try arguments.required("--public-key-output")
    let publicKey = privateKey.publicKey.rawRepresentation.base64EncodedString()
    try writeOnce(Data((publicKey + "\n").utf8), to: output)
}

private func signFeed(_ arguments: Arguments) throws {
    let metadataPath = try arguments.required("--metadata")
    let artifactPath = try arguments.required("--verified-artifact")
    let artifactURL = try parseHTTPSURL(try arguments.required("--artifact-url"))
    let evidenceURL = try parseHTTPSURL(try arguments.required("--evidence-url"))
    let feedURL = try parseHTTPSURL(try arguments.required("--feed-url"))
    let output = try arguments.required("--output")
    let channelText = try arguments.required("--channel")
    guard let channel = UpdateChannelName(rawValue: channelText) else {
        throw SignerFailure.refused("channel must be beta or stable")
    }
    guard let rolloutID = UUID(uuidString: try arguments.required("--rollout-id")) else {
        throw SignerFailure.refused("rollout ID must be a UUID")
    }
    guard let sequence = Int64(try arguments.required("--sequence")), sequence > 0 else {
        throw SignerFailure.refused("sequence must be a positive integer")
    }
    let formatter = ISO8601DateFormatter()
    guard let startsAt = formatter.date(from: try arguments.required("--starts-at")) else {
        throw SignerFailure.refused("rollout start must be an ISO-8601 timestamp")
    }

    let metadataData = try regularFileData(at: metadataPath, maximumBytes: 1_048_576)
    let metadata = try JSONDecoder().decode(SealedReleaseMetadata.self, from: metadataData)
    let build = try metadata.validate(artifactURL: artifactURL, evidenceURL: evidenceURL)

    let artifactFileURL = URL(fileURLWithPath: artifactPath)
    let artifactValues = try artifactFileURL.resourceValues(
        forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
    )
    guard artifactValues.isRegularFile == true,
          artifactValues.isSymbolicLink != true,
          artifactFileURL.lastPathComponent == metadata.artifact.fileName,
          Int64(artifactValues.fileSize ?? -1) == metadata.artifact.sizeBytes,
          try sha256(of: artifactFileURL) == metadata.artifact.sha256 else {
        throw SignerFailure.refused("verified artifact bytes do not match the sealed release metadata")
    }

    let privateKey = try loadPrivateKey(arguments)
    let publicKey = privateKey.publicKey.rawRepresentation.base64EncodedString()
    let expectedPublicKey = try arguments.required("--expected-public-key")
    guard publicKey == expectedPublicKey else {
        throw SignerFailure.refused("the private key does not match the reviewed public key")
    }
    let configuration = try UpdateChannelConfiguration(
        feedURL: feedURL,
        publicKeyBase64: publicKey,
        expectedChannel: channel
    )

    let rollback: UpdateRollbackEvidence?
    let rollbackFields = [
        arguments.values["--rollback-build"],
        arguments.values["--rollback-reason"],
        arguments.values["--incident-id"]
    ]
    if rollbackFields.allSatisfy({ $0 == nil }) {
        rollback = nil
    } else {
        guard rollbackFields.allSatisfy({ $0 != nil }),
              let revertsBuild = Int(rollbackFields[0]!),
              let reason = UpdateRollbackReason(rawValue: rollbackFields[1]!),
              let incidentID = UUID(uuidString: rollbackFields[2]!) else {
            throw SignerFailure.refused("rollback build, reason, and incident ID must be supplied together")
        }
        rollback = UpdateRollbackEvidence(
            revertsBuild: revertsBuild,
            reason: reason,
            incidentID: incidentID
        )
    }

    let publishedAt = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
    let manifest = UpdateChannelManifest(
        sequence: sequence,
        channel: channel,
        publishedAt: publishedAt,
        rollout: UpdateRollout(
            id: rolloutID,
            startsAt: startsAt,
            phaseCount: try arguments.optionalInt("--phase-count", default: 10),
            phaseIntervalSeconds: try arguments.optionalInt(
                "--phase-interval-seconds",
                default: 86_400
            ),
            isPaused: arguments.flags.contains("--paused"),
            isCritical: arguments.flags.contains("--critical")
        ),
        release: UpdateRelease(
            version: metadata.release.version,
            build: build,
            minimumSystemVersion: metadata.product.minimumSystemVersion,
            commit: metadata.release.commit,
            artifactURL: artifactURL,
            artifactSHA256: metadata.artifact.sha256,
            artifactSizeBytes: metadata.artifact.sizeBytes,
            evidenceURL: evidenceURL,
            rollback: rollback
        )
    )
    try manifest.validate(configuration: configuration)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let payload = try encoder.encode(manifest)
    let signature = try privateKey.signature(for: payload)
    let envelope = SignedUpdateEnvelope(
        payload: payload.base64EncodedString(),
        signature: signature.base64EncodedString()
    )
    var envelopeData = try encoder.encode(envelope)
    envelopeData.append(0x0A)
    try writeOnce(envelopeData, to: output)
}

do {
    let arguments = try Arguments(CommandLine.arguments.dropFirst())
    if arguments.flags.contains("--generate-key") {
        try generateKey(arguments)
    } else if arguments.flags.contains("--export-public-key") {
        try exportPublicKey(arguments)
    } else {
        try signFeed(arguments)
    }
} catch let SignerFailure.refused(message) {
    FileHandle.standardError.write(Data("Update feed signing refused: \(message)\n".utf8))
    exit(1)
} catch {
    // Do not interpolate arbitrary errors: Security and decoding errors can
    // contain input details. The operator gets a finite, content-free failure.
    FileHandle.standardError.write(Data("Update feed signing refused: input validation failed\n".utf8))
    exit(1)
}
