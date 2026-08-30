import Foundation

public enum WorkspaceBootstrapDecision: Equatable, Sendable {
    case initializeNew(workspaceID: UUID)
    case useExisting(workspaceID: UUID, needsIdentityCommit: Bool)
    case requireRecovery(affectedComponents: [WorkspaceStorageComponent])
}

/// Decides whether startup may create files before any mutable store or cloud
/// engine is initialized. A remembered workspace must never be reconstructed
/// from missing defaults because those defaults could later win a sync merge.
public enum WorkspaceBootstrapPolicy {
    public static func decide(
        openLoopsExists: Bool,
        personalizationExists: Bool,
        identityFileExists: Bool,
        identityFileIsReadable: Bool,
        onDiskWorkspaceID: UUID?,
        expectedWorkspaceID: UUID?,
        generatedWorkspaceID: UUID = UUID()
    ) -> WorkspaceBootstrapDecision {
        if openLoopsExists != personalizationExists {
            let missing: WorkspaceStorageComponent = openLoopsExists ? .personalization : .openLoops
            return .requireRecovery(affectedComponents: [missing])
        }

        if !openLoopsExists && !personalizationExists {
            guard expectedWorkspaceID == nil, !identityFileExists else {
                return .requireRecovery(affectedComponents: WorkspaceStorageComponent.allCases)
            }
            return .initializeNew(workspaceID: generatedWorkspaceID)
        }

        if identityFileExists {
            guard identityFileIsReadable, let onDiskWorkspaceID else {
                return .requireRecovery(affectedComponents: WorkspaceStorageComponent.allCases)
            }
            if let expectedWorkspaceID, expectedWorkspaceID != onDiskWorkspaceID {
                return .requireRecovery(affectedComponents: WorkspaceStorageComponent.allCases)
            }
            return .useExisting(workspaceID: onDiskWorkspaceID, needsIdentityCommit: false)
        }

        guard expectedWorkspaceID == nil else {
            return .requireRecovery(affectedComponents: WorkspaceStorageComponent.allCases)
        }
        return .useExisting(workspaceID: generatedWorkspaceID, needsIdentityCommit: true)
    }
}
