import AppKit
import Combine
import FounderOfficeCore
import FounderOfficeIdentity
import Foundation

@MainActor
protocol AccountSyncStatusSignaling: AnyObject {
    var objectWillChange: ObservableObjectPublisher { get }
    var accountSyncHealthStatus: HealthComponentStatus { get }
}

enum FounderOfficeAccountAvailability: Equatable {
    case available
    case localOnly(String)
}

enum FounderOfficeAccountSetupStage: Equatable {
    case none
    case reviewDisplayName
    case chooseWorkspace
}

struct FounderOfficeLocalAccountContext: Equatable {
    var hasCustomerData: Bool
    var boundAccountID: UUID?

    init(hasCustomerData: Bool, boundAccountID: UUID? = nil) {
        self.hasCustomerData = hasCustomerData
        self.boundAccountID = boundAccountID
    }
}

struct FounderOfficeAccountInteractionHooks {
    var begin: @MainActor (_ reason: String, _ suspendsHost: Bool) -> UUID
    var end: @MainActor (_ lease: UUID) -> Void
}

/// Product identity for the Mac surface. This controller intentionally stops
/// before network workspace binding: authentication and an explicit local-data
/// disposition are prerequisites, not proof that device sync is active.
@MainActor
final class FounderOfficeAccountController: ObservableObject, AccountSyncStatusSignaling {
    @Published private(set) var availability: FounderOfficeAccountAvailability
    @Published private(set) var authState: ProductAuthState = .localOnly
    @Published private(set) var setupStage: FounderOfficeAccountSetupStage = .none
    @Published private(set) var workspacePlan: WorkspaceClaimPlan?
    @Published private(set) var selectedWorkspaceChoice: LocalWorkspaceAccountChoice?
    @Published var reviewedDisplayNameDraft = ""
    @Published private(set) var displayNameError: String?
    @Published private(set) var operationMessage: String?
    @Published private(set) var isSavingReviewedName = false

    private let service: (any ProductAuthServing)?
    private let appleAuthorizer: (any AppleIdentityAuthorizing)?
    private let localContext: () -> FounderOfficeLocalAccountContext
    private let applyReviewedDisplayName: (String) -> Void
    private let interactions: FounderOfficeAccountInteractionHooks
    private var observationTask: Task<Void, Never>?
    private var restoreTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var didStart = false
    private var isRestoringSession = false
    private var nativeInteractionLease: UUID?
    private var setupInteractionLease: UUID?
    private var deferredAuthState: ProductAuthState?
    private var activeSession: ProductAccountSession?
    private var reviewedAccountID: UUID?
    private var pendingReviewedDisplayName: ReviewedDisplayName?
    private var claimContextAtSignIn: FounderOfficeLocalAccountContext?

    init(
        availability: FounderOfficeAccountAvailability,
        service: (any ProductAuthServing)?,
        appleAuthorizer: (any AppleIdentityAuthorizing)?,
        localContext: @escaping () -> FounderOfficeLocalAccountContext,
        applyReviewedDisplayName: @escaping (String) -> Void,
        interactions: FounderOfficeAccountInteractionHooks? = nil
    ) {
        self.availability = availability
        self.service = service
        self.appleAuthorizer = appleAuthorizer
        self.localContext = localContext
        self.applyReviewedDisplayName = applyReviewedDisplayName
        self.interactions = interactions ?? FounderOfficeAccountInteractionHooks(
            begin: { _, _ in UUID() },
            end: { _ in }
        )
    }

    static func live(
        infoDictionary: [String: Any],
        hostWindow: NSWindow,
        presentation: NotchPresentationModel,
        localContext: @escaping () -> FounderOfficeLocalAccountContext,
        applyReviewedDisplayName: @escaping (String) -> Void
    ) -> FounderOfficeAccountController {
        let configuration = ProductAuthConfiguration.load(infoDictionary: infoDictionary)
        switch configuration {
        case let .success(configuration):
            let service = SupabaseProductAuthClient(
                configuration: configuration,
                presentationAnchor: { [weak hostWindow] in
                    hostWindow ?? NSApp.keyWindow
                }
            )
            let authorizer = AppleIdentityAuthorizer { [weak hostWindow] in
                hostWindow ?? NSApp.keyWindow
            }
            return FounderOfficeAccountController(
                availability: .available,
                service: service,
                appleAuthorizer: authorizer,
                localContext: localContext,
                applyReviewedDisplayName: applyReviewedDisplayName,
                interactions: FounderOfficeAccountInteractionHooks(
                    begin: { reason, suspendsHost in
                        presentation.beginInteraction(reason, suspendsHost: suspendsHost)
                    },
                    end: presentation.endInteraction
                )
            )
        case let .failure(error):
            let detail: String
            switch error {
            case .missingConfiguration:
                detail = "Sign-in is not configured in this build. Your workspace stays on this Mac."
            default:
                detail = "Sign-in is unavailable in this build. Your workspace stays on this Mac."
            }
            return FounderOfficeAccountController(
                availability: .localOnly(detail),
                service: nil,
                appleAuthorizer: nil,
                localContext: localContext,
                applyReviewedDisplayName: applyReviewedDisplayName,
                interactions: FounderOfficeAccountInteractionHooks(
                    begin: { reason, suspendsHost in
                        presentation.beginInteraction(reason, suspendsHost: suspendsHost)
                    },
                    end: presentation.endInteraction
                )
            )
        }
    }

    var isAuthenticationAvailable: Bool {
        availability == .available && service != nil
    }

    var isBusy: Bool {
        switch authState {
        case .restoring, .signingIn:
            return true
        case .localOnly, .signedIn, .failed:
            return isSavingReviewedName || operationTask != nil
        }
    }

    var requiresSetupOverlay: Bool { setupStage != .none }

    var signedInProviderTitle: String? {
        guard case let .signedIn(session) = authState else { return nil }
        return session.provider.title
    }

    var statusTitle: String {
        switch authState {
        case .localOnly:
            return "Stored on this Mac"
        case .restoring:
            return "Checking this Mac"
        case let .signingIn(provider):
            return "Opening \(provider.title)"
        case let .signedIn(session):
            if setupStage != .none { return "Finish account setup" }
            if selectedWorkspaceChoice == .keepLocalOnly {
                return "Signed in · sync off"
            }
            return "Signed in with \(session.provider.title)"
        case .failed:
            return "Sign-in needs attention"
        }
    }

    var statusDetail: String {
        if case let .localOnly(message) = availability { return message }
        switch authState {
        case .localOnly:
            return "No account is required. Sign in only when you want device sync."
        case .restoring:
            return "Reading the existing secure session once."
        case .signingIn:
            return "Your local workspace will not be uploaded or replaced."
        case .signedIn:
            if setupStage == .reviewDisplayName {
                return "Review your name before it is saved to the account."
            }
            if setupStage == .chooseWorkspace {
                return "Choose what happens to this Mac’s existing workspace."
            }
            if selectedWorkspaceChoice == .keepLocalOnly {
                return "The account is connected, but this workspace remains local-only."
            }
            return "No data was uploaded. Device sync is not active in this build."
        case let .failed(failure):
            return failure.recoveryMessage
        }
    }

    var accountSyncHealthStatus: HealthComponentStatus {
        if case .localOnly = availability {
            return HealthComponentStatus(
                component: .sync,
                condition: .off,
                detail: "Stored on this Mac"
            )
        }
        switch authState {
        case .restoring, .signingIn:
            return HealthComponentStatus(
                component: .sync,
                condition: .working,
                detail: "Checking account"
            )
        case .failed:
            return HealthComponentStatus(
                component: .sync,
                condition: .attention,
                detail: "Sign-in needs attention"
            )
        case .signedIn where setupStage != .none:
            return HealthComponentStatus(
                component: .sync,
                condition: .attention,
                detail: "Finish account setup"
            )
        case .signedIn:
            return HealthComponentStatus(
                component: .sync,
                condition: .off,
                detail: "Signed in; sync is off"
            )
        case .localOnly:
            return HealthComponentStatus(
                component: .sync,
                condition: .off,
                detail: "Stored on this Mac"
            )
        }
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        guard let service else { return }

        // Make restoration observable synchronously. Otherwise the sign-in
        // buttons can be activated before the restore task gets its first turn,
        // racing a Keychain session against a new provider flow.
        authState = .restoring
        isRestoringSession = true

        observationTask = Task { [weak self, service] in
            let changes = await service.stateChanges()
            for await state in changes {
                guard !Task.isCancelled else { return }
                self?.receive(state)
            }
        }
        restoreTask = Task { [weak self, service] in
            await service.restoreSession()
            guard !Task.isCancelled else { return }
            let restored = await service.currentState()
            guard let self else { return }
            isRestoringSession = false
            restoreTask = nil
            receive(restored)
        }
    }

    func stop() {
        observationTask?.cancel()
        restoreTask?.cancel()
        operationTask?.cancel()
        appleAuthorizer?.cancel()
        observationTask = nil
        restoreTask = nil
        operationTask = nil
        isRestoringSession = false
        releaseNativeInteraction()
        releaseSetupInteraction()
    }

    func signInWithGoogle() {
        guard isAuthenticationAvailable, !isBusy, operationTask == nil, let service else { return }
        beginNativeInteraction(reason: "google-sign-in")
        authState = .signingIn(.google)
        operationTask = Task { [weak self, service] in
            await service.signInWithGoogle()
            guard !Task.isCancelled else { return }
            let finalState = await service.currentState()
            self?.finishNativeAuthentication(with: finalState)
        }
    }

    func signInWithApple() {
        guard isAuthenticationAvailable,
              !isBusy,
              operationTask == nil,
              let service,
              let appleAuthorizer else { return }
        beginNativeInteraction(reason: "apple-sign-in")
        authState = .signingIn(.apple)
        operationTask = Task { [weak self, service, appleAuthorizer] in
            do {
                let authorization = try await appleAuthorizer.authorize()
                guard !Task.isCancelled else { return }
                await service.signInWithApple(authorization)
                let finalState = await service.currentState()
                self?.finishNativeAuthentication(with: finalState)
            } catch {
                guard !Task.isCancelled else { return }
                let failure: ProductAuthFailure
                if let appleError = error as? AppleIdentityAuthorizationError,
                   appleError == .cancelled {
                    failure = ProductAuthFailure(
                        code: .cancelled,
                        recoveryMessage: "Sign-in was cancelled. Your local workspace was not changed."
                    )
                } else {
                    failure = ProductAuthFailure(
                        code: .unknown,
                        recoveryMessage: "Apple sign-in could not be completed. Your local workspace was not changed."
                    )
                }
                self?.finishNativeAuthentication(with: .failed(failure))
            }
        }
    }

    func confirmReviewedDisplayName() {
        guard operationTask == nil,
              let service,
              let session = activeSession else { return }
        let reviewed: ReviewedDisplayName
        do {
            reviewed = try ReviewedDisplayName(reviewedInput: reviewedDisplayNameDraft)
        } catch {
            displayNameError = error.localizedDescription
            return
        }

        displayNameError = nil
        operationMessage = nil
        isSavingReviewedName = true
        operationTask = Task { [weak self, service] in
            do {
                try await service.updateReviewedDisplayName(reviewed)
                let finalState = await service.currentState()
                guard !Task.isCancelled, let self else { return }
                isSavingReviewedName = false
                operationTask = nil
                guard case let .signedIn(finalSession) = finalState,
                      finalSession.accountID == session.accountID else {
                    // The active identity changed (or secure persistence
                    // failed) while the profile write was in flight. Never
                    // apply the prior account's reviewed value locally.
                    receive(finalState)
                    return
                }
                reviewedAccountID = session.accountID
                reviewedDisplayNameDraft = reviewed.value
                pendingReviewedDisplayName = reviewed
                receive(finalState)
            } catch {
                guard let self else { return }
                isSavingReviewedName = false
                operationTask = nil
                displayNameError = "Couldn’t save that name. Try again."
            }
        }
    }

    func chooseWorkspaceDisposition(_ choice: LocalWorkspaceAccountChoice) {
        guard setupStage == .chooseWorkspace else { return }
        guard choice == .keepLocalOnly else {
            operationMessage = "This option stays unavailable until secure device sync passes its release gate."
            return
        }
        selectedWorkspaceChoice = choice
        operationMessage = "This workspace remains only on this Mac."
        pendingReviewedDisplayName = nil
        setupStage = .none
        releaseSetupInteraction()
    }

    func isWorkspaceChoiceEnabled(_ choice: LocalWorkspaceAccountChoice) -> Bool {
        choice == .keepLocalOnly
    }

    func cancelAccountSetup() {
        signOut()
    }

    func signOut() {
        guard operationTask == nil, let service else { return }
        releaseSetupInteraction()
        setupStage = .none
        operationTask = Task { [weak self, service] in
            await service.signOut()
            guard !Task.isCancelled else { return }
            let finalState = await service.currentState()
            self?.operationTask = nil
            self?.receive(finalState)
        }
    }

    private func beginNativeInteraction(reason: String) {
        releaseNativeInteraction()
        nativeInteractionLease = interactions.begin(reason, true)
        deferredAuthState = nil
        displayNameError = nil
        operationMessage = nil
    }

    private func finishNativeAuthentication(with fallback: ProductAuthState) {
        releaseNativeInteraction()
        operationTask = nil
        // currentState() is sampled after the provider operation completes and
        // is authoritative. The AsyncStream may still contain an earlier
        // `.signingIn` value, which must not overwrite a terminal result.
        let finalState = fallback
        deferredAuthState = nil
        receive(finalState)
    }

    private func receive(_ state: ProductAuthState) {
        if isRestoringSession {
            // The auth stream starts with its pre-restore cached value. Keep the
            // UI locked until restoreSession() has completed and currentState()
            // has been sampled, instead of briefly enabling a second sign-in.
            if case .restoring = state { authState = .restoring }
            return
        }
        if nativeInteractionLease != nil {
            deferredAuthState = state
            return
        }
        // Ignore delayed transient events after their owning operation ended.
        // Terminal events remain accepted so external sign-out/session expiry
        // still propagates normally.
        if case .restoring = state, restoreTask == nil { return }
        if case .signingIn = state, operationTask == nil { return }
        authState = state
        switch state {
        case let .signedIn(session):
            receiveSignedIn(session)
        case .localOnly, .failed:
            clearActiveAccount()
        case .restoring, .signingIn:
            break
        }
    }

    private func receiveSignedIn(_ session: ProductAccountSession) {
        let isNewIdentity = activeSession?.accountID != session.accountID
        activeSession = session
        if isNewIdentity {
            claimContextAtSignIn = localContext()
            selectedWorkspaceChoice = nil
            workspacePlan = nil
            operationMessage = nil
            displayNameError = nil
            if let reviewed = session.reviewedDisplayName {
                reviewedAccountID = session.accountID
                pendingReviewedDisplayName = reviewed
                reviewedDisplayNameDraft = reviewed.value
                applyWorkspacePlan(for: session.accountID)
            } else {
                reviewedAccountID = nil
                reviewedDisplayNameDraft = session.onboardingDisplayNameSuggestion?.suggestedValue ?? ""
                setupStage = .reviewDisplayName
                ensureSetupInteraction()
            }
            return
        }

        if reviewedAccountID == session.accountID {
            if workspacePlan == nil {
                applyWorkspacePlan(for: session.accountID)
            }
            return
        }
        setupStage = .reviewDisplayName
        ensureSetupInteraction()
    }

    private func applyWorkspacePlan(for accountID: UUID) {
        let context = claimContextAtSignIn ?? localContext()
        let plan = WorkspaceClaimPlanner.plan(
            for: WorkspaceClaimContext(
                localWorkspaceHasCustomerData: context.hasCustomerData,
                locallyBoundAccountID: context.boundAccountID,
                incomingAccountID: accountID
            )
        )
        workspacePlan = plan
        switch plan {
        case .requiresCustomerChoice:
            setupStage = .chooseWorkspace
            ensureSetupInteraction()
        case .bootstrapRemoteWorkspace, .continueBoundWorkspace:
            // Identity is ready, but this controller has no authority to bind,
            // upload, replace, or claim a workspace. The transport coordinator
            // may consume the reviewed plan in a later release.
            applyPendingReviewedDisplayName()
            setupStage = .none
            releaseSetupInteraction()
        }
    }

    private func clearActiveAccount() {
        activeSession = nil
        reviewedAccountID = nil
        pendingReviewedDisplayName = nil
        claimContextAtSignIn = nil
        workspacePlan = nil
        selectedWorkspaceChoice = nil
        reviewedDisplayNameDraft = ""
        displayNameError = nil
        setupStage = .none
        releaseSetupInteraction()
    }

    /// Account profile review and local workspace mutation are separate trust
    /// boundaries. A name may update the current workspace automatically only
    /// when the workspace is empty/unbound or already belongs to this identity.
    /// A cross-account/local-data choice must never mutate the local profile as
    /// a side effect of signing in.
    private func applyPendingReviewedDisplayName() {
        guard let pendingReviewedDisplayName else { return }
        self.pendingReviewedDisplayName = nil
        applyReviewedDisplayName(pendingReviewedDisplayName.value)
    }

    private func ensureSetupInteraction() {
        guard setupInteractionLease == nil else { return }
        setupInteractionLease = interactions.begin("account-setup", false)
    }

    private func releaseNativeInteraction() {
        guard let lease = nativeInteractionLease else { return }
        nativeInteractionLease = nil
        interactions.end(lease)
    }

    private func releaseSetupInteraction() {
        guard let lease = setupInteractionLease else { return }
        setupInteractionLease = nil
        interactions.end(lease)
    }
}
