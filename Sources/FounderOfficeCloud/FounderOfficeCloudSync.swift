import CloudKit
import Foundation
import FounderOfficeCore
import os
#if os(macOS)
import Security
#endif

public enum FounderOfficeCloudConfigurationError: Error, Equatable, Sendable {
    case cloudDisabled
    case missingContainerIdentifier
    case malformedContainerIdentifier
    case missingContainerEntitlement
    case containerEntitlementMismatch
}

public struct FounderOfficeCloudConfiguration: Sendable {
    public static let infoPlistContainerKey = "FounderOfficeCloudContainerIdentifier"
    public static let cloudEnabledInfoPlistKey = "FounderOfficeCloudEnabled"

    public var containerIdentifier: String
    public var zoneName: String
    public var recordName: String

    public init(
        containerIdentifier: String,
        zoneName: String = "FounderOffice",
        recordName: String = "workspace-default"
    ) {
        self.containerIdentifier = containerIdentifier
        self.zoneName = zoneName
        self.recordName = recordName
    }

    /// Resolves the CloudKit container from product configuration instead of
    /// source defaults. A missing or malformed declaration is a hard failure;
    /// macOS also verifies that it exactly matches the process entitlement.
    /// iOS provisioning and CKContainer enforce that platform's entitlement.
    public static func bundled(in bundle: Bundle = .main) throws -> Self {
        let cloudEnabled = bundle.object(
            forInfoDictionaryKey: cloudEnabledInfoPlistKey
        ) as? Bool == true
        let configuredContainer = bundle.object(
            forInfoDictionaryKey: infoPlistContainerKey
        ) as? String

        let declaredConfiguration = try validatedDeclaredConfiguration(
            cloudEnabled: cloudEnabled,
            configuredContainer: configuredContainer
        )

        #if os(macOS)
        return try validatedBundledConfiguration(
            cloudEnabled: true,
            configuredContainer: declaredConfiguration.containerIdentifier,
            entitledContainers: try signedContainerIdentifiers()
        )
        #else
        // SecTask entitlement inspection is not public on iOS. The signed
        // provisioning profile and CKContainer enforce the entitlement there;
        // runtime configuration still fails closed on a missing or malformed
        // single declared container identifier.
        return declaredConfiguration
        #endif
    }

    static func validatedDeclaredConfiguration(
        cloudEnabled: Bool,
        configuredContainer: String?
    ) throws -> Self {
        guard cloudEnabled else {
            throw FounderOfficeCloudConfigurationError.cloudDisabled
        }
        guard let configuredContainer, !configuredContainer.isEmpty else {
            throw FounderOfficeCloudConfigurationError.missingContainerIdentifier
        }
        guard configuredContainer.hasPrefix("iCloud."),
              configuredContainer.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics
                      .union(CharacterSet(charactersIn: ".-"))
                      .contains($0)
              }) else {
            throw FounderOfficeCloudConfigurationError.malformedContainerIdentifier
        }
        return Self(containerIdentifier: configuredContainer)
    }

    static func validatedBundledConfiguration(
        cloudEnabled: Bool,
        configuredContainer: String?,
        entitledContainers: [String]
    ) throws -> Self {
        let declaredConfiguration = try validatedDeclaredConfiguration(
            cloudEnabled: cloudEnabled,
            configuredContainer: configuredContainer
        )
        guard !entitledContainers.isEmpty else {
            throw FounderOfficeCloudConfigurationError.missingContainerEntitlement
        }
        guard entitledContainers.count == 1,
              entitledContainers[0] == declaredConfiguration.containerIdentifier else {
            throw FounderOfficeCloudConfigurationError.containerEntitlementMismatch
        }
        return declaredConfiguration
    }

    #if os(macOS)
    private static func signedContainerIdentifiers() throws -> [String] {
        guard let task = SecTaskCreateFromSelf(nil) else {
            throw FounderOfficeCloudConfigurationError.missingContainerEntitlement
        }
        var copyError: Unmanaged<CFError>?
        guard let rawValue = SecTaskCopyValueForEntitlement(
            task,
            "com.apple.developer.icloud-container-identifiers" as CFString,
            &copyError
        ) else {
            _ = copyError?.takeRetainedValue()
            throw FounderOfficeCloudConfigurationError.missingContainerEntitlement
        }
        guard let identifiers = rawValue as? [String] else {
            throw FounderOfficeCloudConfigurationError.missingContainerEntitlement
        }
        return identifiers
    }
    #endif
}

public enum FounderOfficeCloudStatus: String, Codable, Sendable {
    case preparing
    case ready
    case syncing
    case offline
    case accountReviewRequired
    case error

    public var title: String {
        switch self {
        case .preparing: return "Preparing iCloud"
        case .ready: return "Saved to iCloud"
        case .syncing: return "Syncing"
        case .offline: return "Saved on this device"
        case .accountReviewRequired: return "Review iCloud account"
        case .error: return "iCloud needs attention"
        }
    }
}

private struct CloudSidecar: Codable {
    var stateSerialization: CKSyncEngine.State.Serialization?
    var lastKnownRecordData: Data?
    var status: FounderOfficeCloudStatus = .preparing
}

/// CKSyncEngine transport for the user's private CloudKit database. The local
/// JSON store is always written first, so edits remain safe offline and sync can
/// resume later without asking the user to reconnect anything.
public final actor FounderOfficeCloudSync: CKSyncEngineDelegate {
    public let configuration: FounderOfficeCloudConfiguration
    public let snapshotStore: JSONSnapshotStore
    public let sidecarURL: URL

    private let automaticallySync: Bool
    private let container: CKContainer
    private var sidecar: CloudSidecar
    private var engine: CKSyncEngine?

    public init(
        snapshotStore: JSONSnapshotStore,
        sidecarURL: URL,
        configuration: FounderOfficeCloudConfiguration,
        automaticallySync: Bool = true
    ) {
        self.snapshotStore = snapshotStore
        self.sidecarURL = sidecarURL
        self.configuration = configuration
        self.automaticallySync = automaticallySync
        container = CKContainer(identifier: configuration.containerIdentifier)

        if let data = try? Data(contentsOf: sidecarURL),
           let decoded = try? JSONDecoder().decode(CloudSidecar.self, from: data) {
            sidecar = decoded
        } else {
            sidecar = CloudSidecar()
        }
    }

    public var status: FounderOfficeCloudStatus { sidecar.status }

    public func start() {
        initializeEngine()
        queueCurrentSnapshot()
    }

    /// Call after every successful local mutation. CKSyncEngine persists the
    /// pending change in its serialized state and retries transient failures.
    public func noteLocalChange() {
        queueCurrentSnapshot()
    }

    public func syncNow() async throws {
        let engine = syncEngine
        sidecar.status = .syncing
        try persistSidecar()
        do {
            try await engine.fetchChanges()
            queueCurrentSnapshot()
            try await engine.sendChanges()
            sidecar.status = .ready
            try persistSidecar()
        } catch {
            if let cloudError = error as? CKError,
               [.notAuthenticated, .accountTemporarilyUnavailable, .networkFailure,
                .networkUnavailable, .serviceUnavailable, .requestRateLimited]
                .contains(cloudError.code) {
                sidecar.status = .offline
            } else {
                sidecar.status = .error
            }
            try? persistSidecar()
            throw error
        }
    }

    /// An iCloud account switch never silently uploads one account's local data
    /// into another. The Settings screen must explicitly choose whether to keep
    /// and upload the local workspace or first replace it from the new account.
    public func resumeAfterAccountReview(uploadLocalWorkspace: Bool) async throws {
        sidecar.stateSerialization = nil
        sidecar.lastKnownRecordData = nil
        sidecar.status = .preparing
        try persistSidecar()
        initializeEngine()

        if uploadLocalWorkspace {
            queueCurrentSnapshot()
            try await syncEngine.sendChanges()
        } else {
            try await syncEngine.fetchChanges()
        }
    }

    private var syncEngine: CKSyncEngine {
        if engine == nil { initializeEngine() }
        return engine!
    }

    private var zoneID: CKRecordZone.ID {
        CKRecordZone.ID(zoneName: configuration.zoneName)
    }

    private var recordID: CKRecord.ID {
        CKRecord.ID(recordName: configuration.recordName, zoneID: zoneID)
    }

    private func initializeEngine() {
        var engineConfiguration = CKSyncEngine.Configuration(
            database: container.privateCloudDatabase,
            stateSerialization: sidecar.stateSerialization,
            delegate: self
        )
        engineConfiguration.automaticallySync = automaticallySync && sidecar.status != .accountReviewRequired
        engine = CKSyncEngine(engineConfiguration)
        try? persistSidecar()
    }

    private func queueCurrentSnapshot() {
        guard sidecar.status != .accountReviewRequired else { return }
        sidecar.status = .syncing
        try? persistSidecar()
        syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
        syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])
    }

    public func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case let .stateUpdate(update):
            sidecar.stateSerialization = update.stateSerialization
            try? persistSidecar()

        case let .fetchedRecordZoneChanges(changes):
            await handleFetchedRecordZoneChanges(changes)

        case let .fetchedDatabaseChanges(changes):
            for deletion in changes.deletions where deletion.zoneID == zoneID {
                queueCurrentSnapshot()
            }

        case let .sentRecordZoneChanges(changes):
            await handleSentRecordZoneChanges(changes)

        case let .accountChange(change):
            handleAccountChange(change)

        case .willFetchChanges, .willFetchRecordZoneChanges, .didFetchRecordZoneChanges,
             .didFetchChanges, .willSendChanges, .didSendChanges, .sentDatabaseChanges:
            break

        @unknown default:
            break
        }
    }

    public func nextRecordZoneChangeBatch(
        _ context: CKSyncEngine.SendChangesContext,
        syncEngine: CKSyncEngine
    ) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let changes = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        guard !changes.isEmpty else { return nil }

        guard let snapshot = try? await snapshotStore.readSnapshot(),
              let payload = try? Self.encode(snapshot) else {
            return nil
        }

        let targetRecordID = recordID
        let record = decodeLastKnownRecord() ?? CKRecord(recordType: "WorkspaceSnapshot", recordID: targetRecordID)
        record.encryptedValues["payload"] = payload as CKRecordValue
        record.encryptedValues["updatedAt"] = Date() as CKRecordValue
        if let photoURL = await snapshotStore.photoURL(named: snapshot.personalization.photoFileName) {
            record.encryptedValues["visionImage"] = CKAsset(fileURL: photoURL)
        } else {
            record.encryptedValues["visionImage"] = nil
        }

        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: changes) { requestedRecordID in
            requestedRecordID == targetRecordID ? record : nil
        }
    }

    private func handleFetchedRecordZoneChanges(
        _ event: CKSyncEngine.Event.FetchedRecordZoneChanges
    ) async {
        guard sidecar.status != .accountReviewRequired else { return }
        for modification in event.modifications where modification.record.recordID == recordID {
            let record = modification.record
            guard let payload = record.encryptedValues["payload"] as? Data,
                  let remote = try? Self.decode(payload) else { continue }

            do {
                if let asset = record.encryptedValues["visionImage"] as? CKAsset,
                   let fileURL = asset.fileURL,
                   let fileName = remote.personalization.photoFileName {
                    try await snapshotStore.importPhoto(from: fileURL, named: fileName)
                }
                let merged = try await snapshotStore.mergeAndPersist(remote)
                setLastKnownRecord(record)
                if try Self.encode(merged) != payload {
                    queueCurrentSnapshot()
                }
            } catch {
                sidecar.status = .error
            }
        }

        if event.deletions.contains(where: { $0.recordID == recordID }) {
            sidecar.lastKnownRecordData = nil
            queueCurrentSnapshot()
        }
        try? persistSidecar()
    }

    private func handleSentRecordZoneChanges(
        _ event: CKSyncEngine.Event.SentRecordZoneChanges
    ) async {
        for savedRecord in event.savedRecords where savedRecord.recordID == recordID {
            setLastKnownRecord(savedRecord)
            sidecar.status = .ready
        }

        for failure in event.failedRecordSaves where failure.record.recordID == recordID {
            switch failure.error.code {
            case .serverRecordChanged:
                guard let serverRecord = failure.error.serverRecord,
                      let payload = serverRecord.encryptedValues["payload"] as? Data,
                      let remote = try? Self.decode(payload) else { continue }
                _ = try? await snapshotStore.mergeAndPersist(remote)
                setLastKnownRecord(serverRecord)
                queueCurrentSnapshot()

            case .zoneNotFound:
                sidecar.lastKnownRecordData = nil
                syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
                syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])

            case .unknownItem:
                sidecar.lastKnownRecordData = nil
                syncEngine.state.add(pendingRecordZoneChanges: [.saveRecord(recordID)])

            case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable,
                 .notAuthenticated, .accountTemporarilyUnavailable, .operationCancelled:
                sidecar.status = .offline

            default:
                sidecar.status = .error
            }
        }
        try? persistSidecar()
    }

    private func handleAccountChange(_ event: CKSyncEngine.Event.AccountChange) {
        switch event.changeType {
        case .signIn:
            sidecar.status = .ready
            queueCurrentSnapshot()
        case .switchAccounts:
            sidecar.status = .accountReviewRequired
            sidecar.stateSerialization = nil
            sidecar.lastKnownRecordData = nil
            initializeEngine()
        case .signOut:
            sidecar.status = .offline
            sidecar.stateSerialization = nil
            sidecar.lastKnownRecordData = nil
        @unknown default:
            sidecar.status = .error
        }
        try? persistSidecar()
    }

    private func decodeLastKnownRecord() -> CKRecord? {
        guard let data = sidecar.lastKnownRecordData else { return nil }
        do {
            let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
            unarchiver.requiresSecureCoding = true
            return CKRecord(coder: unarchiver)
        } catch {
            return nil
        }
    }

    private func setLastKnownRecord(_ record: CKRecord) {
        if let localDate = decodeLastKnownRecord()?.modificationDate,
           let remoteDate = record.modificationDate,
           localDate >= remoteDate {
            return
        }
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        sidecar.lastKnownRecordData = archiver.encodedData
    }

    private func persistSidecar() throws {
        try FileManager.default.createDirectory(
            at: sidecarURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(sidecar).write(to: sidecarURL, options: .atomic)
    }

    private static func encode(_ snapshot: FounderOfficeSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(snapshot)
    }

    private static func decode(_ data: Data) throws -> FounderOfficeSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(FounderOfficeSnapshot.self, from: data)
    }
}
