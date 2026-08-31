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
