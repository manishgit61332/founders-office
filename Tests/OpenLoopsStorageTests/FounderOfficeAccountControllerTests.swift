import Foundation
import FounderOfficeCore
import FounderOfficeIdentity
import Testing
@testable import OpenLoops

@MainActor
struct FounderOfficeAccountControllerTests {
    @Test
    func missingConfigurationRemainsLocalOnlyWithoutTouchingAuth() {
        let controller = FounderOfficeAccountController(
            availability: .localOnly("Sign-in is not configured in this build."),
            service: nil,
            appleAuthorizer: nil,
            localContext: { FounderOfficeLocalAccountContext(hasCustomerData: true) },
            applyReviewedDisplayName: { _ in }
        )

        controller.start()
        controller.start()

        #expect(controller.authState == .localOnly)
        #expect(!controller.isAuthenticationAvailable)
        #expect(controller.accountSyncHealthStatus.condition == .off)
        #expect(controller.statusDetail.contains("not configured"))
    }

    @Test
    func secureSessionRestoreRunsExactlyOnce() async {
        let service = TestProductAuthService(initialState: .localOnly)
        let controller = makeController(service: service)

        controller.start()
        controller.start()

        await waitUntil { await service.restoreCallCount() == 1 }
        #expect(await service.restoreCallCount() == 1)
        controller.stop()
    }

    @Test
    func providerSuggestionIsNotAppliedBeforeNameReviewAndWorkspaceChoice() async {
        let existingAccount = UUID()
        let incomingAccount = UUID()
        let session = ProductAccountSession(
            accountID: incomingAccount,
            provider: .google,
            onboardingDisplayNameSuggestion: OnboardingDisplayNameSuggestion(providerValue: "Priya"),
            expiresAt: .distantFuture
        )
        let service = TestProductAuthService(initialState: .localOnly, googleSession: session)
        let interactions = TestAccountInteractions()
        var appliedNames: [String] = []
        let controller = makeController(
            service: service,
            context: FounderOfficeLocalAccountContext(
                hasCustomerData: true,
                boundAccountID: existingAccount
            ),
            interactions: interactions.hooks,
            applyName: { appliedNames.append($0) }
        )
        controller.start()
        await waitUntil { await service.restoreCallCount() == 1 }

        controller.signInWithGoogle()
        await waitUntil { controller.setupStage == .reviewDisplayName }

        #expect(controller.reviewedDisplayNameDraft == "Priya")
        #expect(appliedNames.isEmpty)
        #expect(interactions.events == [
            .began(suspendsHost: true),
            .ended,
            .began(suspendsHost: false)
        ])

        controller.reviewedDisplayNameDraft = "  Asha  "
        controller.confirmReviewedDisplayName()
        await waitUntil { controller.setupStage == .chooseWorkspace }

        #expect(appliedNames == ["Asha"])
        #expect(
            controller.workspacePlan == .requiresCustomerChoice([
                .keepLocalOnly,
                .claimAsNewWorkspace,
                .switchWorkspace,
                .exportAndReplace
            ])
        )
        #expect(!controller.isWorkspaceChoiceEnabled(.claimAsNewWorkspace))
        controller.chooseWorkspaceDisposition(.claimAsNewWorkspace)
        #expect(controller.setupStage == .chooseWorkspace)
        #expect(controller.operationMessage?.contains("unavailable") == true)

        controller.chooseWorkspaceDisposition(.keepLocalOnly)
        #expect(controller.setupStage == .none)
        #expect(controller.selectedWorkspaceChoice == .keepLocalOnly)
        #expect(controller.accountSyncHealthStatus.condition == .off)
        #expect(controller.accountSyncHealthStatus.detail == "Signed in; sync is off")
        #expect(interactions.events.last == .ended)
        controller.stop()
    }

    @Test
    func reviewedAccountNameStillDoesNotReplaceLocalWorkspaceBeforeDisposition() async throws {
        let reviewed = try ReviewedDisplayName(reviewedInput: "Account Name")
        let session = ProductAccountSession(
            accountID: UUID(),
            provider: .apple,
            reviewedDisplayName: reviewed,
            onboardingDisplayNameSuggestion: nil,
            expiresAt: .distantFuture
        )
        let service = TestProductAuthService(initialState: .signedIn(session))
        var appliedNames: [String] = []
        let controller = makeController(
            service: service,
            context: FounderOfficeLocalAccountContext(hasCustomerData: true),
            applyName: { appliedNames.append($0) }
        )

        controller.start()
        await waitUntil { controller.setupStage == .chooseWorkspace }

        #expect(appliedNames.isEmpty)
        #expect(controller.reviewedDisplayNameDraft == "Account Name")
        #expect(controller.accountSyncHealthStatus.detail == "Finish account setup")
        controller.stop()
    }

    @Test
    func appleAuthorizationUsesTheNativeAuthorizerAndCancellationRestoresTheNotch() async {
        let session = ProductAccountSession(
            accountID: UUID(),
            provider: .apple,
            onboardingDisplayNameSuggestion: nil,
            expiresAt: .distantFuture
        )
        let service = TestProductAuthService(initialState: .localOnly, appleSession: session)
        let authorizer = TestAppleAuthorizer(
            result: .success(
                AppleIdentityAuthorization(
                    identityToken: "identity-token",
                    rawNonce: "nonce",
                    onboardingDisplayNameSuggestion: nil
                )
            )
        )
        let interactions = TestAccountInteractions()
        let controller = makeController(
            service: service,
            authorizer: authorizer,
            interactions: interactions.hooks
        )
        controller.start()
        await waitUntil { await service.restoreCallCount() == 1 }

        controller.signInWithApple()
        await waitUntil { controller.setupStage == .reviewDisplayName }

        #expect(authorizer.callCount == 1)
        #expect(await service.appleSignInCallCount() == 1)
        #expect(interactions.events.prefix(2) == [.began(suspendsHost: true), .ended])
        controller.cancelAccountSetup()
        await waitUntil { controller.authState == .localOnly }
        #expect(interactions.events.last == .ended)
        controller.stop()
    }

    @Test
    func invalidReviewedNameDoesNotReachTheAuthService() async {
        let session = ProductAccountSession(
            accountID: UUID(),
            provider: .google,
            onboardingDisplayNameSuggestion: nil,
            expiresAt: .distantFuture
        )
        let service = TestProductAuthService(initialState: .signedIn(session))
        let controller = makeController(service: service)
        controller.start()
        await waitUntil { controller.setupStage == .reviewDisplayName }

        controller.reviewedDisplayNameDraft = "\n"
        controller.confirmReviewedDisplayName()

        #expect(controller.displayNameError == "The name cannot contain control characters or line breaks.")
        #expect(await service.reviewedNameUpdateCount() == 0)
        controller.stop()
    }

    private func makeController(
        service: TestProductAuthService,
        authorizer: (any AppleIdentityAuthorizing)? = nil,
        context: FounderOfficeLocalAccountContext = FounderOfficeLocalAccountContext(
            hasCustomerData: false,
            boundAccountID: nil
        ),
        interactions: FounderOfficeAccountInteractionHooks? = nil,
        applyName: @escaping (String) -> Void = { _ in }
    ) -> FounderOfficeAccountController {
        FounderOfficeAccountController(
            availability: .available,
            service: service,
            appleAuthorizer: authorizer,
            localContext: { context },
            applyReviewedDisplayName: applyName,
            interactions: interactions
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: @escaping @MainActor () async -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Timed out waiting for account state")
    }
}

private actor TestProductAuthService: ProductAuthServing {
    private var state: ProductAuthState
    private let googleSession: ProductAccountSession?
    private let appleSession: ProductAccountSession?
    private var continuations: [UUID: AsyncStream<ProductAuthState>.Continuation] = [:]
    private var restoreCalls = 0
    private var appleSignInCalls = 0
    private var reviewedNameUpdates = 0

    init(
        initialState: ProductAuthState,
        googleSession: ProductAccountSession? = nil,
        appleSession: ProductAccountSession? = nil
    ) {
        state = initialState
        self.googleSession = googleSession
        self.appleSession = appleSession
    }

    func currentState() -> ProductAuthState { state }

    func stateChanges() -> AsyncStream<ProductAuthState> {
        let identifier = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: ProductAuthState.self)
        continuations[identifier] = continuation
        continuation.yield(state)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(identifier) }
        }
        return stream
    }

    func restoreSession() async {
        restoreCalls += 1
        publish(state)
    }

    func signInWithGoogle() async {
        publish(.signingIn(.google))
        if let googleSession {
            publish(.signedIn(googleSession))
        }
    }

    func signInWithApple(_ authorization: AppleIdentityAuthorization) async {
        _ = authorization
        appleSignInCalls += 1
        publish(.signingIn(.apple))
        if let appleSession {
            publish(.signedIn(appleSession))
        }
    }

    func updateReviewedDisplayName(_ displayName: ReviewedDisplayName) async throws {
        reviewedNameUpdates += 1
        guard case let .signedIn(session) = state else { return }
        publish(
            .signedIn(
                ProductAccountSession(
                    accountID: session.accountID,
                    provider: session.provider,
                    reviewedDisplayName: displayName,
                    onboardingDisplayNameSuggestion: nil,
                    expiresAt: session.expiresAt
                )
            )
        )
    }

    func accessToken() async throws -> String { "test-token" }

    func signOut() async {
        publish(.localOnly)
    }

    func restoreCallCount() -> Int { restoreCalls }
    func appleSignInCallCount() -> Int { appleSignInCalls }
    func reviewedNameUpdateCount() -> Int { reviewedNameUpdates }

    private func publish(_ next: ProductAuthState) {
        state = next
        for continuation in continuations.values {
            continuation.yield(next)
        }
    }

    private func removeContinuation(_ identifier: UUID) {
        continuations.removeValue(forKey: identifier)
    }
}

@MainActor
private final class TestAppleAuthorizer: AppleIdentityAuthorizing {
    let result: Result<AppleIdentityAuthorization, Error>
    private(set) var callCount = 0

    init(result: Result<AppleIdentityAuthorization, Error>) {
        self.result = result
    }

    func authorize() async throws -> AppleIdentityAuthorization {
        callCount += 1
        return try result.get()
    }
}

@MainActor
private final class TestAccountInteractions {
    enum Event: Equatable {
        case began(suspendsHost: Bool)
        case ended
    }

    private(set) var events: [Event] = []
    private var active: Set<UUID> = []

    var hooks: FounderOfficeAccountInteractionHooks {
        FounderOfficeAccountInteractionHooks(
            begin: { [weak self] _, suspendsHost in
                let lease = UUID()
                self?.active.insert(lease)
                self?.events.append(.began(suspendsHost: suspendsHost))
                return lease
            },
            end: { [weak self] lease in
                guard self?.active.remove(lease) != nil else { return }
                self?.events.append(.ended)
            }
        )
    }
}
