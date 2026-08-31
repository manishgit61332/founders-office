import Foundation
import Supabase
import Testing
@testable import FounderOfficeIdentity

@Suite("Product identity")
struct ProductAuthTests {
    private let publishableKey = "sb_publishable_12345678901234567890"

    @Test("Production configuration requires HTTPS and rejects service-role material")
    func validatesProductionConfiguration() throws {
        #expect(throws: ProductAuthConfigurationError.productionRequiresHTTPS) {
            try ProductAuthConfiguration(
                endpoint: #require(URL(string: "http://project.supabase.co")),
                publishableKey: publishableKey,
                callbackURL: #require(URL(string: "founders-office://auth/callback"))
            )
        }

        #expect(throws: ProductAuthConfigurationError.invalidPublishableKey) {
            try ProductAuthConfiguration(
                endpoint: #require(URL(string: "https://project.supabase.co")),
                publishableKey: "service_role_12345678901234567890",
                callbackURL: #require(URL(string: "founders-office://auth/callback"))
            )
        }

        #expect(throws: ProductAuthConfigurationError.invalidPublishableKey) {
            try ProductAuthConfiguration(
                endpoint: #require(URL(string: "https://project.supabase.co")),
                publishableKey: "an-arbitrary-string-that-is-not-a-client-key",
                callbackURL: #require(URL(string: "founders-office://auth/callback"))
            )
        }
    }

    @Test("Local development is explicitly limited to loopback")
    func limitsDevelopmentEndpoint() throws {
        _ = try ProductAuthConfiguration(
            endpoint: #require(URL(string: "http://127.0.0.1:54321")),
            publishableKey: publishableKey,
            callbackURL: #require(URL(string: "founders-office-dev://auth/callback")),
            environment: .localDevelopment
        )

        #expect(throws: ProductAuthConfigurationError.developmentRequiresLoopback) {
            try ProductAuthConfiguration(
                endpoint: #require(URL(string: "http://example.test")),
                publishableKey: publishableKey,
                callbackURL: #require(URL(string: "founders-office-dev://auth/callback")),
                environment: .localDevelopment
            )
        }
    }

    @Test("Callbacks use only the reviewed custom-scheme allowlist")
    func validatesCallbackAllowlist() throws {
        let endpoint = try #require(URL(string: "https://project.supabase.co"))
        for callback in [
            "founders-office://auth/callback",
            "founders-office-dev://auth/callback"
        ] {
            _ = try ProductAuthConfiguration(
                endpoint: endpoint,
                publishableKey: publishableKey,
                callbackURL: #require(URL(string: callback))
            )
        }

        for callback in [
            "javascript://auth/callback",
            "file://auth/callback",
            "data://auth/callback",
            "http://accounts.example.test/auth/callback",
            "https://accounts.example.test/auth/callback",
            "founders-office://attacker/callback",
            "founders-office://auth/other",
            "founders-office://auth/callback?code=unexpected",
            "https://accounts.example.test/other",
            "https://user:password@accounts.example.test/auth/callback",
            "https://accounts.example.test:8443/auth/callback",
            "https://accounts.example.test/auth/callback#fragment"
        ] {
            #expect(throws: ProductAuthConfigurationError.invalidCallbackURL) {
                try ProductAuthConfiguration(
                    endpoint: endpoint,
                    publishableKey: publishableKey,
                    callbackURL: #require(URL(string: callback))
                )
            }
        }
    }

    @Test("A signed-in state requires a durable Keychain-equivalent read-back")
    func requiresDurableSessionReadBack() throws {
        let session = makeSession()
        let storage = TestAuthStorage()
        let verified = VerifiedProductAuthStorage(
            storage: storage,
            sessionKey: "session"
        )

        try verified.store(key: "session", value: JSONEncoder().encode(session))
        try verified.verifyDurableSession(session)

        storage.failWrites = true
        #expect(throws: TestStorageError.write) {
            try verified.store(key: "session", value: Data("replacement".utf8))
        }
        #expect(throws: ProductAuthSecureStorageError.writeFailed) {
            try verified.verifyDurableSession(session)
        }
    }

    @Test("A missing, mismatched, or undeletable persisted session fails closed")
    func rejectsUnsafePersistenceOutcomes() throws {
        let session = makeSession()
        let storage = TestAuthStorage()
        let verified = VerifiedProductAuthStorage(
            storage: storage,
            sessionKey: "session"
        )

        #expect(throws: ProductAuthSecureStorageError.missingReadBack) {
            try verified.verifyDurableSession(session)
        }

        let other = makeSession(accountID: UUID())
        try verified.store(key: "session", value: JSONEncoder().encode(other))
        #expect(throws: ProductAuthSecureStorageError.mismatchedReadBack) {
            try verified.verifyDurableSession(session)
        }

        try verified.store(key: "session", value: JSONEncoder().encode(session))
        storage.failDeletes = true
        #expect(throws: TestStorageError.delete) {
            try verified.remove(key: "session")
        }
        #expect(throws: ProductAuthSecureStorageError.deleteFailed) {
            try verified.verifySessionRemoved()
        }
    }

    @Test("Display-name contract normalizes NFC and counts Unicode scalars")
    func normalizesReviewedDisplayNames() throws {
        let reviewed = try ReviewedDisplayName(reviewedInput: "  Jose\u{301}  ")
        let maximumFourByteName = String(repeating: "🧠", count: 80)
        let maximum = try ReviewedDisplayName(reviewedInput: maximumFourByteName)

        #expect(ProductDisplayNameContractV1.version == 1)
        #expect(reviewed.value == "José")
        #expect(reviewed.value == reviewed.value.precomposedStringWithCanonicalMapping)
        #expect(maximum.value.unicodeScalars.count == 80)
        #expect(maximum.value.utf8.count == ProductDisplayNameContractV1.maximumUTF8ByteCount)
        #expect(throws: ProductDisplayNameValidationError.tooManyUnicodeScalars) {
            try ReviewedDisplayName(reviewedInput: String(repeating: "a", count: 81))
        }
    }

    @Test("Provider names remain non-authoritative onboarding suggestions")
    func separatesSuggestionsFromReviewedNames() throws {
        let suggestion = try #require(
            OnboardingDisplayNameSuggestion(providerValue: "  Priya  ")
        )
        let session = ProductAccountSession(
            accountID: UUID(),
            provider: .google,
            onboardingDisplayNameSuggestion: suggestion,
            expiresAt: .distantFuture
        )

        #expect(suggestion.suggestedValue == "Priya")
        #expect(session.onboardingDisplayNameSuggestion == suggestion)
        #expect(OnboardingDisplayNameSuggestion(providerValue: "\u{200B}") == nil)
        #expect(OnboardingDisplayNameSuggestion(providerValue: "\u{301}") == nil)
        #expect(OnboardingDisplayNameSuggestion(providerValue: "---") == nil)
        #expect(OnboardingDisplayNameSuggestion(providerValue: "Priya\nShah") == nil)
        #expect(OnboardingDisplayNameSuggestion(providerValue: "Priya\u{202E}Shah") == nil)
        #expect(OnboardingDisplayNameSuggestion(providerValue: "\u{FEFF}Priya") == nil)
        #expect(throws: ProductDisplayNameValidationError.containsControlCharacter) {
            try ReviewedDisplayName(reviewedInput: "Priya\tShah")
        }
        #expect(throws: ProductDisplayNameValidationError.empty) {
            try ReviewedDisplayName(reviewedInput: "   ")
        }
    }

    @Test("Missing product configuration fails closed to local-only")
    func missingConfigurationFailsClosed() {
        let result = ProductAuthConfiguration.load(infoDictionary: [:])
        #expect(result == .failure(.missingConfiguration))
    }

    @Test("A different identity never claims local customer data implicitly")
    func identityChangeRequiresChoice() {
        let existingAccount = UUID()
        let incomingAccount = UUID()
        let plan = WorkspaceClaimPlanner.plan(
            for: WorkspaceClaimContext(
                localWorkspaceHasCustomerData: true,
                locallyBoundAccountID: existingAccount,
                incomingAccountID: incomingAccount
            )
        )

        #expect(
            plan == .requiresCustomerChoice([
                .keepLocalOnly,
                .claimAsNewWorkspace,
                .switchWorkspace,
                .exportAndReplace
            ])
        )
    }

    @Test("The same identity may reopen its bound workspace")
    func sameIdentityContinues() {
        let accountID = UUID()
        #expect(
            WorkspaceClaimPlanner.plan(
                for: WorkspaceClaimContext(
                    localWorkspaceHasCustomerData: true,
                    locallyBoundAccountID: accountID,
                    incomingAccountID: accountID
                )
            ) == .continueBoundWorkspace
        )
    }

    @Test("An empty unbound install may bootstrap without uploading local data")
    func emptyInstallMayBootstrap() {
        #expect(
            WorkspaceClaimPlanner.plan(
                for: WorkspaceClaimContext(
                    localWorkspaceHasCustomerData: false,
                    locallyBoundAccountID: nil,
                    incomingAccountID: UUID()
                )
            ) == .bootstrapRemoteWorkspace
        )
    }

    private func makeSession(accountID: UUID = UUID()) -> Session {
        let now = Date()
        return Session(
            accessToken: "access-token",
            tokenType: "bearer",
            expiresIn: 3_600,
            expiresAt: now.addingTimeInterval(3_600).timeIntervalSince1970,
            refreshToken: "refresh-token",
            user: User(
                id: accountID,
                appMetadata: [:],
                userMetadata: [:],
                aud: "authenticated",
                createdAt: now,
                updatedAt: now
            )
        )
    }
}

private enum TestStorageError: Error {
    case write
    case read
    case delete
}

private final class TestAuthStorage: AuthLocalStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    var failWrites = false
    var failReads = false
    var failDeletes = false

    func store(key: String, value: Data) throws {
        try lock.withLock {
            guard !failWrites else { throw TestStorageError.write }
            values[key] = value
        }
    }

    func retrieve(key: String) throws -> Data? {
        try lock.withLock {
            guard !failReads else { throw TestStorageError.read }
            return values[key]
        }
    }

    func remove(key: String) throws {
        try lock.withLock {
            guard !failDeletes else { throw TestStorageError.delete }
            values.removeValue(forKey: key)
        }
    }
}
