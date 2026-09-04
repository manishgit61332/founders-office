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
    func appleSignInAvailabilityRequiresAConfiguredAuthorizer() {
        let service = TestProductAuthService(initialState: .localOnly)
        let unavailable = makeController(service: service)
        let available = makeController(
            service: service,
            authorizer: TestAppleAuthorizer(
                result: .failure(AppleIdentityAuthorizationError.cancelled)
            )
        )

        #expect(!unavailable.isAppleSignInAvailable)
        #expect(available.isAppleSignInAvailable)
    }

    @Test
    func secureSessionRestoreRunsExactlyOnce() async {
        let service = TestProductAuthService(initialState: .localOnly)
        let controller = makeController(service: service)

        controller.start()
        controller.start()

        await controller.waitForPendingOperations()
        #expect(await service.restoreCallCount() == 1)
        controller.stop()
    }

    @Test
    func signInCannotRaceTheInitialSecureSessionRestore() async {
        let session = ProductAccountSession(
            accountID: UUID(),
            provider: .google,
            onboardingDisplayNameSuggestion: nil,
            expiresAt: .distantFuture
        )
        let service = TestProductAuthService(initialState: .localOnly, googleSession: session)
        let controller = makeController(service: service)

        controller.start()
        #expect(controller.authState == .restoring)
        controller.signInWithGoogle()

        #expect(await service.googleSignInCallCount() == 0)
        await controller.waitForPendingOperations()
        #expect(await service.restoreCallCount() == 1)
        controller.stop()
    }

    @Test
    func staleSigningInEventCannotReplaceAuthoritativeTerminalState() async {
        let session = ProductAccountSession(
            accountID: UUID(),
            provider: .google,
            onboardingDisplayNameSuggestion: nil,
            expiresAt: .distantFuture
        )
        let service = TestProductAuthService(
            initialState: .localOnly,
            googleSession: session,
            emitGoogleTerminalEvent: false
        )
        let controller = makeController(service: service)
        controller.start()
        await controller.waitForPendingOperations()

        controller.signInWithGoogle()
        await controller.waitForPendingOperations()

        #expect(controller.authState == .signedIn(session))
        #expect(controller.statusTitle == "Finish account setup")
        controller.stop()
    }

    @Test
    func crossAccountNameReviewDoesNotMutateLocalWorkspace() async {
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
        await controller.waitForPendingOperations()

        controller.signInWithGoogle()
        await controller.waitForPendingOperations()

        #expect(controller.reviewedDisplayNameDraft == "Priya")
        #expect(appliedNames.isEmpty)
        #expect(interactions.events == [
            .began(suspendsHost: true),
            .ended,
            .began(suspendsHost: false)
        ])

        controller.reviewedDisplayNameDraft = "  Asha  "
        controller.confirmReviewedDisplayName()
        await controller.waitForPendingOperations()

        #expect(appliedNames.isEmpty)
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
        #expect(appliedNames.isEmpty)
        #expect(interactions.events.last == .ended)
        controller.stop()
    }

    @Test
    func reviewedNameMayPopulateAnEmptyUnboundWorkspace() async throws {
        let reviewed = try ReviewedDisplayName(reviewedInput: "Asha")
        let session = ProductAccountSession(
            accountID: UUID(),
            provider: .google,
            reviewedDisplayName: reviewed,
            onboardingDisplayNameSuggestion: nil,
            expiresAt: .distantFuture
        )
        let service = TestProductAuthService(initialState: .signedIn(session))
        var appliedNames: [String] = []
        let controller = makeController(
            service: service,
            context: FounderOfficeLocalAccountContext(
                hasCustomerData: false,
                boundAccountID: nil
            ),
            applyName: { appliedNames.append($0) }
        )

        controller.start()
        await controller.waitForPendingOperations()

        #expect(controller.setupStage == .none)
        #expect(appliedNames == ["Asha"])
        #expect(controller.accountSyncHealthStatus.detail == "Signed in; sync is off")
        controller.stop()
    }

    @Test
    func identityChangeDuringNameSaveCannotApplyThePriorAccountsName() async {
        let firstSession = ProductAccountSession(
            accountID: UUID(),
            provider: .google,
            onboardingDisplayNameSuggestion: OnboardingDisplayNameSuggestion(providerValue: "Asha"),
            expiresAt: .distantFuture
        )
        let replacementSession = ProductAccountSession(
            accountID: UUID(),
            provider: .apple,
            onboardingDisplayNameSuggestion: nil,
            expiresAt: .distantFuture
        )
        let service = TestProductAuthService(
            initialState: .signedIn(firstSession),
            replacementSessionAfterNameUpdate: replacementSession
        )
        var appliedNames: [String] = []
        let controller = makeController(
            service: service,
            applyName: { appliedNames.append($0) }
        )
        controller.start()
        await controller.waitForPendingOperations()

        controller.reviewedDisplayNameDraft = "Asha"
        controller.confirmReviewedDisplayName()
        await controller.waitForPendingOperations()

        #expect(appliedNames.isEmpty)
        #expect(controller.workspacePlan == nil)
        #expect(controller.reviewedDisplayNameDraft.isEmpty)
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
        await controller.waitForPendingOperations()

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
        await controller.waitForPendingOperations()

        controller.signInWithApple()
        await controller.waitForPendingOperations()

        #expect(authorizer.callCount == 1)
        #expect(await service.appleSignInCallCount() == 1)
        #expect(interactions.events.prefix(2) == [.began(suspendsHost: true), .ended])
        controller.cancelAccountSetup()
        await controller.waitForPendingOperations()
        #expect(controller.authState == .localOnly)
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
        await controller.waitForPendingOperations()

        controller.reviewedDisplayNameDraft = "\n"
        controller.confirmReviewedDisplayName()

        #expect(controller.displayNameError == "The name cannot contain control characters or line breaks.")
        #expect(await service.reviewedNameUpdateCount() == 0)
        controller.stop()
    }

    @Test
    func configuredCloudClaimsLocalWorkspaceOnlyAfterExplicitChoice() async throws {
        let reviewed = try ReviewedDisplayName(reviewedInput: "Asha")
        let accountID = UUID()
        let session = ProductAccountSession(
            accountID: accountID,
            provider: .google,
            reviewedDisplayName: reviewed,
            onboardingDisplayNameSuggestion: nil,
            expiresAt: .distantFuture
        )
        let binding = try WorkspaceSyncBinding(
            accountID: FounderAccountID(rawValue: accountID),
            workspaceID: WorkspaceID(rawValue: UUID()),
            deviceID: DeviceID(rawValue: UUID()),
            identityProvider: .google
        )
        let cloud = TestCloudSyncService(
            initialBinding: nil,
            activation: FounderOfficeCloudSyncActivation(
                binding: binding,
                outcome: .synchronized
            )
        )
        let service = TestProductAuthService(initialState: .signedIn(session))
        var appliedNames: [String] = []
        let controller = makeController(
            service: service,
            cloudSync: cloud,
            context: FounderOfficeLocalAccountContext(hasCustomerData: true),
            workspaceName: { "Studio" },
            applyName: { appliedNames.append($0) }
        )

        controller.start()
        await controller.waitForPendingOperations()

        #expect(controller.setupStage == .chooseWorkspace)
        #expect(controller.isWorkspaceChoiceEnabled(.claimAsNewWorkspace))
        #expect(await cloud.provisionCallCount() == 0)

        controller.chooseWorkspaceDisposition(.claimAsNewWorkspace)
        await controller.waitForPendingOperations()

        #expect(await cloud.provisionCallCount() == 1)
        #expect(await cloud.lastWorkspaceName() == "Studio")
        #expect(await cloud.lastDispositionIsClaim())
        #expect(controller.setupStage == .none)
        #expect(controller.syncStatus.phase == .idle)
        #expect(controller.accountSyncHealthStatus.condition == .ready)
        #expect(appliedNames == ["Asha"])
        controller.stop()
    }

    @Test
    func restoredBindingForAnotherAccountCannotBeClaimedOrResumed() async throws {
        let localAccountID = UUID()
        let incomingAccountID = UUID()
        let binding = try WorkspaceSyncBinding(
            accountID: FounderAccountID(rawValue: localAccountID),
            workspaceID: WorkspaceID(rawValue: UUID()),
            deviceID: DeviceID(rawValue: UUID()),
            identityProvider: .google
        )
        let incoming = ProductAccountSession(
            accountID: incomingAccountID,
            provider: .google,
            reviewedDisplayName: try ReviewedDisplayName(reviewedInput: "Asha"),
            onboardingDisplayNameSuggestion: nil,
            expiresAt: .distantFuture
        )
        let cloud = TestCloudSyncService(
            initialBinding: binding,
            activation: FounderOfficeCloudSyncActivation(
                binding: binding,
                outcome: .synchronized
            )
        )
        let controller = makeController(
            service: TestProductAuthService(initialState: .signedIn(incoming)),
            cloudSync: cloud,
            context: FounderOfficeLocalAccountContext(hasCustomerData: true)
        )

        controller.start()
        await controller.waitForPendingOperations()

        #expect(controller.setupStage == .chooseWorkspace)
        #expect(!controller.isWorkspaceChoiceEnabled(.claimAsNewWorkspace))
        #expect(!controller.isWorkspaceChoiceEnabled(.switchWorkspace))
        #expect(await cloud.resumeCallCount() == 0)
        #expect(await cloud.provisionCallCount() == 0)
        controller.stop()
    }

    @Test
    func unreadableBindingCannotBeTreatedAsAnUnboundWorkspace() async throws {
        let accountID = UUID()
        let binding = try WorkspaceSyncBinding(
            accountID: FounderAccountID(rawValue: accountID),
            workspaceID: WorkspaceID(rawValue: UUID()),
            deviceID: DeviceID(rawValue: UUID()),
            identityProvider: .google
        )
        let session = ProductAccountSession(
            accountID: accountID,
            provider: .google,
            reviewedDisplayName: try ReviewedDisplayName(reviewedInput: "Asha"),
            onboardingDisplayNameSuggestion: nil,
            expiresAt: .distantFuture
        )
        let cloud = TestCloudSyncService(
            initialBinding: binding,
            activation: FounderOfficeCloudSyncActivation(
                binding: binding,
                outcome: .synchronized
            ),
            bindingReadFails: true
        )
        let controller = makeController(
            service: TestProductAuthService(initialState: .signedIn(session)),
            cloudSync: cloud,
            context: FounderOfficeLocalAccountContext(hasCustomerData: true)
        )

        controller.start()
        await controller.waitForPendingOperations()

        #expect(controller.setupStage == .chooseWorkspace)
        #expect(controller.isWorkspaceChoiceEnabled(.keepLocalOnly))
        #expect(!controller.isWorkspaceChoiceEnabled(.claimAsNewWorkspace))
        #expect(!controller.isWorkspaceChoiceEnabled(.switchWorkspace))
        #expect(controller.accountSyncHealthStatus.condition == .attention)
        #expect(controller.statusTitle == "Device sync needs attention")
        #expect(await cloud.resumeCallCount() == 0)
        #expect(await cloud.provisionCallCount() == 0)
        controller.stop()
    }

    @Test
    func signOutStopsCloudRuntimeAndPreservesLocalBinding() async throws {
        let accountID = UUID()
        let binding = try WorkspaceSyncBinding(
            accountID: FounderAccountID(rawValue: accountID),
            workspaceID: WorkspaceID(rawValue: UUID()),
            deviceID: DeviceID(rawValue: UUID()),
            identityProvider: .google
        )
        let session = ProductAccountSession(
            accountID: accountID,
            provider: .google,
            reviewedDisplayName: try ReviewedDisplayName(reviewedInput: "Asha"),
            onboardingDisplayNameSuggestion: nil,
            expiresAt: .distantFuture
        )
        let cloud = TestCloudSyncService(
            initialBinding: binding,
            activation: FounderOfficeCloudSyncActivation(
                binding: binding,
                outcome: .synchronized
            )
        )
        let controller = makeController(
            service: TestProductAuthService(initialState: .signedIn(session)),
            cloudSync: cloud,
            context: FounderOfficeLocalAccountContext(hasCustomerData: true)
        )

        controller.start()
        await controller.waitForPendingOperations()
        #expect(await cloud.resumeCallCount() == 1)

        controller.signOut()
        await controller.waitForPendingOperations()

        #expect(controller.authState == .localOnly)
        #expect(await cloud.stopCallCount() >= 1)
        #expect(try await cloud.currentBinding() == binding)
        controller.stop()
    }

    private func makeController(
        service: TestProductAuthService,
        cloudSync: (any FounderOfficeCloudSyncServing)? = nil,
        authorizer: (any AppleIdentityAuthorizing)? = nil,
        context: FounderOfficeLocalAccountContext = FounderOfficeLocalAccountContext(
            hasCustomerData: false,
            boundAccountID: nil
        ),
        interactions: FounderOfficeAccountInteractionHooks? = nil,
        workspaceName: @escaping () -> String = { "Founder's Office" },
        applyName: @escaping (String) -> Void = { _ in }
    ) -> FounderOfficeAccountController {
        FounderOfficeAccountController(
            availability: .available,
            service: service,
            cloudSync: cloudSync,
            appleAuthorizer: authorizer,
            localContext: { context },
            workspaceName: workspaceName,
            applyReviewedDisplayName: applyName,
            interactions: interactions
        )
    }

}

private actor TestCloudSyncService: FounderOfficeCloudSyncServing {
    private var binding: WorkspaceSyncBinding?
    private let activation: FounderOfficeCloudSyncActivation
    private var provisionCalls = 0
    private var resumeCalls = 0
    private var stopCalls = 0
    private var capturedWorkspaceName: String?
    private var capturedDisposition: WorkspaceProvisioningDisposition?
    private var status = try! WorkspaceSyncStatus(phase: .idle)
    private let bindingReadFails: Bool

    init(
        initialBinding: WorkspaceSyncBinding?,
        activation: FounderOfficeCloudSyncActivation,
        bindingReadFails: Bool = false
    ) {
        binding = initialBinding
        self.activation = activation
        self.bindingReadFails = bindingReadFails
    }

    func currentBinding() async throws -> WorkspaceSyncBinding? {
        if bindingReadFails { throw TestCloudSyncFailure.bindingUnavailable }
        return binding
    }

    func resume(
        account: ProductAccountSession
    ) async throws -> FounderOfficeCloudSyncActivation? {
        _ = account
        resumeCalls += 1
        return binding == nil ? nil : activation
    }

    func provision(
        account: ProductAccountSession,
        disposition: WorkspaceProvisioningDisposition,
        workspaceName: String,
        reviewedDisplayName: ReviewedDisplayName?
    ) async throws -> FounderOfficeCloudSyncActivation {
        _ = account
        _ = reviewedDisplayName
        provisionCalls += 1
        capturedDisposition = disposition
        capturedWorkspaceName = workspaceName
        binding = activation.binding
        return activation
    }

    func currentStatus() async throws -> WorkspaceSyncStatus { status }

    func stop() async { stopCalls += 1 }

    func provisionCallCount() -> Int { provisionCalls }
    func resumeCallCount() -> Int { resumeCalls }
    func stopCallCount() -> Int { stopCalls }
    func lastWorkspaceName() -> String? { capturedWorkspaceName }
    func lastDispositionIsClaim() -> Bool {
        guard let capturedDisposition else { return false }
        if case .claimLocalAsNew = capturedDisposition { return true }
        return false
    }
}

private enum TestCloudSyncFailure: Error {
    case bindingUnavailable
}

private actor TestProductAuthService: ProductAuthServing {
    private var state: ProductAuthState
    private let googleSession: ProductAccountSession?
    private let appleSession: ProductAccountSession?
    private let emitGoogleTerminalEvent: Bool
    private let replacementSessionAfterNameUpdate: ProductAccountSession?
    private var continuations: [UUID: AsyncStream<ProductAuthState>.Continuation] = [:]
    private var restoreCalls = 0
    private var googleSignInCalls = 0
    private var appleSignInCalls = 0
    private var reviewedNameUpdates = 0

    init(
        initialState: ProductAuthState,
        googleSession: ProductAccountSession? = nil,
        appleSession: ProductAccountSession? = nil,
        emitGoogleTerminalEvent: Bool = true,
        replacementSessionAfterNameUpdate: ProductAccountSession? = nil
    ) {
        state = initialState
        self.googleSession = googleSession
        self.appleSession = appleSession
        self.emitGoogleTerminalEvent = emitGoogleTerminalEvent
        self.replacementSessionAfterNameUpdate = replacementSessionAfterNameUpdate
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
        googleSignInCalls += 1
        publish(.signingIn(.google))
        if let googleSession {
            if emitGoogleTerminalEvent {
                publish(.signedIn(googleSession))
            } else {
                state = .signedIn(googleSession)
            }
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
        if let replacementSessionAfterNameUpdate {
            publish(.signedIn(replacementSessionAfterNameUpdate))
            return
        }
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
    func googleSignInCallCount() -> Int { googleSignInCalls }
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
