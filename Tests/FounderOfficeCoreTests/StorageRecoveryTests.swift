import Foundation
import Testing
@testable import FounderOfficeCore

struct StorageRecoveryTests {
    @Test
    func testRecoveryStateMergesAffectedStoresAndBackupNamesDeterministically() {
        let tasks = WorkspaceRecoveryState(
            affectedComponents: [.openLoops],
            preservedCopyNames: ["tasks-backup.json"]
        )
        let personalization = WorkspaceRecoveryState(
            affectedComponents: [.personalization, .openLoops],
            preservedCopyNames: ["profile-backup.json", "tasks-backup.json"]
        )

        let merged = tasks.merging(personalization)

        #expect(merged.requiresRecovery)
        #expect(merged.affectedComponents == [.openLoops, .personalization])
        #expect(merged.preservedCopyNames == ["profile-backup.json", "tasks-backup.json"])
        #expect(merged.message.contains("recovery copy was preserved"))
    }

    @Test
    func testQuarantineCopiesExactBytesAndLeavesCanonicalFailSafeInPlace() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("founder-office-recovery-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let canonicalURL = root.appendingPathComponent("openloops.json")
        let damagedData = Data("{not-json".utf8)
        try damagedData.write(to: canonicalURL)

        let firstBackupURL = try CorruptFileQuarantine.preserve(canonicalURL)
        let secondBackupURL = try CorruptFileQuarantine.preserve(canonicalURL)

        #expect(try Data(contentsOf: canonicalURL) == damagedData)
        #expect(try Data(contentsOf: firstBackupURL) == damagedData)
        #expect(try Data(contentsOf: secondBackupURL) == damagedData)
        #expect(firstBackupURL != secondBackupURL)
        #expect(firstBackupURL.deletingLastPathComponent().lastPathComponent == "Recovery")
    }

    @Test
    func testFreshWorkspaceMayInitializeOnlyWithoutRememberedIdentity() {
        let generated = UUID()
        let fresh = WorkspaceBootstrapPolicy.decide(
            openLoopsExists: false,
            personalizationExists: false,
            identityFileExists: false,
            identityFileIsReadable: true,
            onDiskWorkspaceID: nil,
            expectedWorkspaceID: nil,
            generatedWorkspaceID: generated
        )
        let remembered = WorkspaceBootstrapPolicy.decide(
            openLoopsExists: false,
            personalizationExists: false,
            identityFileExists: false,
            identityFileIsReadable: true,
            onDiskWorkspaceID: nil,
            expectedWorkspaceID: UUID(),
            generatedWorkspaceID: generated
        )

        #expect(fresh == .initializeNew(workspaceID: generated))
        #expect(remembered == .requireRecovery(affectedComponents: [.openLoops, .personalization]))
    }

    @Test(arguments: [
        (true, false, WorkspaceStorageComponent.personalization),
        (false, true, WorkspaceStorageComponent.openLoops)
    ])
    func testPartialCanonicalWorkspaceAlwaysRequiresRecovery(
        openLoopsExists: Bool,
        personalizationExists: Bool,
        missingComponent: WorkspaceStorageComponent
    ) {
        let decision = WorkspaceBootstrapPolicy.decide(
            openLoopsExists: openLoopsExists,
            personalizationExists: personalizationExists,
            identityFileExists: false,
            identityFileIsReadable: true,
            onDiskWorkspaceID: nil,
            expectedWorkspaceID: nil
        )

        #expect(decision == .requireRecovery(affectedComponents: [missingComponent]))
    }

    @Test
    func testWorkspaceIdentityMustMatchRememberedConsent() {
        let onDisk = UUID()
        let matching = WorkspaceBootstrapPolicy.decide(
            openLoopsExists: true,
            personalizationExists: true,
            identityFileExists: true,
            identityFileIsReadable: true,
            onDiskWorkspaceID: onDisk,
            expectedWorkspaceID: onDisk
        )
        let mismatched = WorkspaceBootstrapPolicy.decide(
            openLoopsExists: true,
            personalizationExists: true,
            identityFileExists: true,
            identityFileIsReadable: true,
            onDiskWorkspaceID: onDisk,
            expectedWorkspaceID: UUID()
        )

        #expect(matching == .useExisting(workspaceID: onDisk, needsIdentityCommit: false))
        #expect(mismatched == .requireRecovery(affectedComponents: [.openLoops, .personalization]))
    }

    @Test
    func testLegacyCompleteWorkspaceGetsIdentityOnlyWhenNoConsentIsRemembered() {
        let generated = UUID()
        let decision = WorkspaceBootstrapPolicy.decide(
            openLoopsExists: true,
            personalizationExists: true,
            identityFileExists: false,
            identityFileIsReadable: true,
            onDiskWorkspaceID: nil,
            expectedWorkspaceID: nil,
            generatedWorkspaceID: generated
        )

        #expect(decision == .useExisting(workspaceID: generated, needsIdentityCommit: true))
    }

    @Test
    func testUnreadableIdentityFailsClosed() {
        let decision = WorkspaceBootstrapPolicy.decide(
            openLoopsExists: true,
            personalizationExists: true,
            identityFileExists: true,
            identityFileIsReadable: false,
            onDiskWorkspaceID: nil,
            expectedWorkspaceID: nil
        )

        #expect(decision == .requireRecovery(affectedComponents: [.openLoops, .personalization]))
    }
}
