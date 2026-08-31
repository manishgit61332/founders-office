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

/// Versioned display-name rules shared with the backend profile contract.
/// Counts are measured after NFC normalization, never as grapheme clusters.
public enum ProductDisplayNameContractV1 {
    public static let version = 1
    public static let maximumUnicodeScalarCount = 80
    public static let maximumUTF8ByteCount = 320

    fileprivate static func normalized(_ input: String) throws -> String {
        let nfcInput = input.precomposedStringWithCanonicalMapping
        guard !nfcInput.unicodeScalars.contains(where: isForbiddenScalar) else {
            throw ProductDisplayNameValidationError.containsControlCharacter
        }

        let normalized = nfcInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              normalized.unicodeScalars.contains(where: isVisibleScalar) else {
            throw ProductDisplayNameValidationError.empty
        }
        guard normalized.unicodeScalars.count <= maximumUnicodeScalarCount else {
            throw ProductDisplayNameValidationError.tooManyUnicodeScalars
        }
        guard normalized.utf8.count <= maximumUTF8ByteCount else {
            throw ProductDisplayNameValidationError.tooManyUTF8Bytes
        }
        return normalized
    }

    private static func isForbiddenScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .lineSeparator, .paragraphSeparator:
            return true
        default:
            break
        }

        // Reject bidi overrides/isolates and BOM while retaining ZWJ/ZWNJ for
        // names whose normal spelling uses them.
        return scalar.value == 0x061C
            || scalar.value == 0x200E
            || scalar.value == 0x200F
            || (0x202A...0x202E).contains(scalar.value)
            || (0x2066...0x2069).contains(scalar.value)
            || scalar.value == 0xFEFF
    }

    private static func isVisibleScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter,
             .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber,
             .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
            return true
        default:
            return false
        }
    }
}

public enum ProductDisplayNameValidationError: Error, Equatable, Sendable {
    case empty
    case containsControlCharacter
    case tooManyUnicodeScalars
    case tooManyUTF8Bytes
}

extension ProductDisplayNameValidationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .empty:
            return "Enter a name."
        case .containsControlCharacter:
            return "The name cannot contain control characters or line breaks."
        case .tooManyUnicodeScalars, .tooManyUTF8Bytes:
            return "Enter a name of at most 80 Unicode characters."
        }
    }
}

/// A provider-supplied value that may prefill onboarding. It has not been
/// reviewed by the customer and must never be used as a durable profile value.
public struct OnboardingDisplayNameSuggestion: Equatable, Sendable {
    public let suggestedValue: String

    public init?(providerValue: String?) {
        guard let providerValue,
              let normalized = try? ProductDisplayNameContractV1.normalized(providerValue) else {
            return nil
        }
        suggestedValue = normalized
    }
}

/// A display name explicitly accepted or entered by the customer. Durable
/// profile update APIs require this type so provider suggestions cannot flow
/// into bootstrap or persistence without an explicit review boundary.
public struct ReviewedDisplayName: Equatable, Sendable {
    public let value: String

    public init(reviewedInput: String) throws {
        value = try ProductDisplayNameContractV1.normalized(reviewedInput)
    }
}

/// A deliberately token-free in-memory account summary. It may contain a
/// provider name suggestion for onboarding, so it must not be logged or placed
/// in support diagnostics. Credentials remain inside the client and Keychain.
public struct ProductAccountSession: Equatable, Sendable {
    public let accountID: UUID
    public let provider: ProductIdentityProvider
    /// A profile value previously accepted through the reviewed-name API.
    /// This is distinct from provider metadata and may be trusted as reviewed,
    /// but applying it to a local workspace still requires the workspace
    /// disposition gate.
    public let reviewedDisplayName: ReviewedDisplayName?
    public let onboardingDisplayNameSuggestion: OnboardingDisplayNameSuggestion?
    public let expiresAt: Date

    public init(
        accountID: UUID,
        provider: ProductIdentityProvider,
        reviewedDisplayName: ReviewedDisplayName? = nil,
        onboardingDisplayNameSuggestion: OnboardingDisplayNameSuggestion?,
        expiresAt: Date
    ) {
        self.accountID = accountID
        self.provider = provider
        self.reviewedDisplayName = reviewedDisplayName
        self.onboardingDisplayNameSuggestion = onboardingDisplayNameSuggestion
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
    public let onboardingDisplayNameSuggestion: OnboardingDisplayNameSuggestion?

    public init(
        identityToken: String,
        rawNonce: String,
        onboardingDisplayNameSuggestion: OnboardingDisplayNameSuggestion?
    ) {
        self.identityToken = identityToken
        self.rawNonce = rawNonce
        self.onboardingDisplayNameSuggestion = onboardingDisplayNameSuggestion
    }
}

public protocol ProductAuthServing: Actor {
    func currentState() -> ProductAuthState
    func stateChanges() -> AsyncStream<ProductAuthState>
    func restoreSession() async
    func signInWithGoogle() async
    func signInWithApple(_ authorization: AppleIdentityAuthorization) async
    func updateReviewedDisplayName(_ displayName: ReviewedDisplayName) async throws
    func accessToken() async throws -> String
    func signOut() async
}
