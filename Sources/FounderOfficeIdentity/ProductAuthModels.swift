import Foundation

public enum ProductIdentityProvider: String, Codable, CaseIterable, Sendable {
    case google
    case apple
    case unknown

    public var title: String {
        switch self {
        case .google: return "Google"
        case .apple: return "Apple"
        case .unknown: return "Account"
        }
    }
}

/// A deliberately token-free account summary safe for UI state and support
/// diagnostics. Credentials remain inside the identity client and Keychain.
public struct ProductAccountSession: Equatable, Sendable {
    public let accountID: UUID
    public let provider: ProductIdentityProvider
    public let displayName: String?
    public let expiresAt: Date

    public init(
        accountID: UUID,
        provider: ProductIdentityProvider,
        displayName: String?,
        expiresAt: Date
    ) {
        self.accountID = accountID
        self.provider = provider
        self.displayName = displayName
        self.expiresAt = expiresAt
    }
}

public struct ProductAuthFailure: Equatable, Sendable {
    public enum Code: String, Sendable {
        case cancelled
        case configuration
        case network
        case rejected
        case secureStorage
        case unknown
    }

    public let code: Code
    public let recoveryMessage: String

    public init(code: Code, recoveryMessage: String) {
        self.code = code
        self.recoveryMessage = recoveryMessage
    }
}

public enum ProductAuthState: Equatable, Sendable {
    case localOnly
    case restoring
    case signingIn(ProductIdentityProvider)
    case signedIn(ProductAccountSession)
    case failed(ProductAuthFailure)
}

public enum LocalWorkspaceAccountChoice: String, Codable, CaseIterable, Sendable {
    case keepLocalOnly
    case claimAsNewWorkspace
    case switchWorkspace
    case exportAndReplace
}

public struct WorkspaceClaimContext: Equatable, Sendable {
    public let localWorkspaceHasCustomerData: Bool
    public let locallyBoundAccountID: UUID?
    public let incomingAccountID: UUID

    public init(
        localWorkspaceHasCustomerData: Bool,
        locallyBoundAccountID: UUID?,
        incomingAccountID: UUID
    ) {
        self.localWorkspaceHasCustomerData = localWorkspaceHasCustomerData
        self.locallyBoundAccountID = locallyBoundAccountID
        self.incomingAccountID = incomingAccountID
    }
}

public enum WorkspaceClaimPlan: Equatable, Sendable {
    case continueBoundWorkspace
    case bootstrapRemoteWorkspace
    case requiresCustomerChoice([LocalWorkspaceAccountChoice])
}

public enum WorkspaceClaimPlanner {
    /// Signing in never authorizes an implicit upload. Existing customer data
    /// or a workspace bound to another identity always requires an explicit
    /// disposition before sync can start.
    public static func plan(for context: WorkspaceClaimContext) -> WorkspaceClaimPlan {
        if context.locallyBoundAccountID == context.incomingAccountID {
            return .continueBoundWorkspace
        }

        if !context.localWorkspaceHasCustomerData,
           context.locallyBoundAccountID == nil {
            return .bootstrapRemoteWorkspace
        }

        return .requiresCustomerChoice([
            .keepLocalOnly,
            .claimAsNewWorkspace,
            .switchWorkspace,
            .exportAndReplace
        ])
    }
}

public struct AppleIdentityAuthorization: Equatable, Sendable {
    public let identityToken: String
    public let rawNonce: String
    public let displayName: String?

    public init(identityToken: String, rawNonce: String, displayName: String?) {
        self.identityToken = identityToken
        self.rawNonce = rawNonce
        self.displayName = displayName
    }
}

public protocol ProductAuthServing: Actor {
    func currentState() -> ProductAuthState
    func stateChanges() -> AsyncStream<ProductAuthState>
    func restoreSession() async
    func signInWithGoogle() async
    func signInWithApple(_ authorization: AppleIdentityAuthorization) async
    func updateDisplayName(_ displayName: String) async throws
    func accessToken() async throws -> String
    func signOut() async
}
