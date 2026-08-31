import Foundation
import FounderOfficeIdentity
import Testing

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

    @Test("Callbacks use an explicit custom-scheme or universal-link allowlist")
    func validatesCallbackAllowlist() throws {
        let endpoint = try #require(URL(string: "https://project.supabase.co"))
        for callback in [
            "founders-office://auth/callback",
            "founders-office-dev://auth/callback",
            "https://accounts.example.test/auth/callback"
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
}
