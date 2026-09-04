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

protocol FounderOfficeCloudSyncServing: Actor {
    func currentBinding() async throws -> WorkspaceSyncBinding?
    func resume(account: ProductAccountSession) async throws -> FounderOfficeCloudSyncActivation?
    func provision(
        account: ProductAccountSession,
        disposition: WorkspaceProvisioningDisposition,
        workspaceName: String,
        reviewedDisplayName: ReviewedDisplayName?
    ) async throws -> FounderOfficeCloudSyncActivation
    func currentStatus() async throws -> WorkspaceSyncStatus
    func stop() async
}

extension FounderOfficeCloudSyncRuntime: FounderOfficeCloudSyncServing {}

/// Product identity and explicit workspace-provisioning state for the Mac
/// surface. Authentication alone never uploads, replaces, or claims local data.
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
    @Published private(set) var syncStatus: WorkspaceSyncStatus = .localOnly
    @Published private(set) var cloudStateFailureMessage: String?

    private let service: (any ProductAuthServing)?
    private let cloudSync: (any FounderOfficeCloudSyncServing)?
    private let appleAuthorizer: (any AppleIdentityAuthorizing)?
    private let localContext: () -> FounderOfficeLocalAccountContext
    private let workspaceName: () -> String
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
    private var runtimeBoundAccountID: UUID?
    private var cloudStateVerified: Bool

    init(
        availability: FounderOfficeAccountAvailability,
        service: (any ProductAuthServing)?,
        cloudSync: (any FounderOfficeCloudSyncServing)? = nil,
        appleAuthorizer: (any AppleIdentityAuthorizing)?,
        localContext: @escaping () -> FounderOfficeLocalAccountContext,
        workspaceName: @escaping () -> String = { "Founder's Office" },
        applyReviewedDisplayName: @escaping (String) -> Void,
        interactions: FounderOfficeAccountInteractionHooks? = nil
    ) {
        self.availability = availability
        self.service = service
        self.cloudSync = cloudSync
        self.appleAuthorizer = appleAuthorizer
        self.localContext = localContext
        self.workspaceName = workspaceName
        self.applyReviewedDisplayName = applyReviewedDisplayName
        self.cloudStateVerified = cloudSync == nil
        self.interactions = interactions ?? FounderOfficeAccountInteractionHooks(
            begin: { _, _ in UUID() },
            end: { _ in }
        )
    }

    static func live(
        infoDictionary: [String: Any],
        hostWindow: NSWindow,
        presentation: NotchPresentationModel,
        repository: SQLiteWorkspaceRepository,
        localContext: @escaping () -> FounderOfficeLocalAccountContext,
        workspaceName: @escaping () -> String,
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
            let cloudSync: FounderOfficeCloudSyncRuntime
            do {
                let transport = try SupabaseWorkspaceSyncTransport(
                    configuration: configuration,
                    tokenProvider: service
                )
                cloudSync = try FounderOfficeCloudSyncRuntime(
                    repository: repository,
                    auth: service,
                    transport: transport,
                    deviceID: FounderOfficeDeviceIdentityStore.loadOrCreate()
                )
            } catch {
                return localOnlyController(
                    detail: "Device sync is unavailable in this build. Your workspace stays on this Mac.",
                    localContext: localContext,
                    workspaceName: workspaceName,
                    applyReviewedDisplayName: applyReviewedDisplayName,
                    presentation: presentation
                )
            }
            let authorizer: (any AppleIdentityAuthorizing)? =
                infoDictionary["FounderOfficeAppleSignInEnabled"] as? Bool == true
                ? AppleIdentityAuthorizer { [weak hostWindow] in hostWindow ?? NSApp.keyWindow }
                : nil
            return FounderOfficeAccountController(
                availability: .available,
                service: service,
                cloudSync: cloudSync,
                appleAuthorizer: authorizer,
                localContext: localContext,
                workspaceName: workspaceName,
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
            return localOnlyController(
                detail: detail,
                localContext: localContext,
                workspaceName: workspaceName,
                applyReviewedDisplayName: applyReviewedDisplayName,
                presentation: presentation
            )
        }
    }

    private static func localOnlyController(
        detail: String,
        localContext: @escaping () -> FounderOfficeLocalAccountContext,
        workspaceName: @escaping () -> String,
        applyReviewedDisplayName: @escaping (String) -> Void,
        presentation: NotchPresentationModel
    ) -> FounderOfficeAccountController {
        FounderOfficeAccountController(
            availability: .localOnly(detail),
            service: nil,
            cloudSync: nil,
            appleAuthorizer: nil,
            localContext: localContext,
            workspaceName: workspaceName,
            applyReviewedDisplayName: applyReviewedDisplayName,
            interactions: FounderOfficeAccountInteractionHooks(
                begin: { reason, suspendsHost in
                    presentation.beginInteraction(reason, suspendsHost: suspendsHost)
                },
                end: presentation.endInteraction
            )
        )
    }

    var isAuthenticationAvailable: Bool {
        availability == .available && service != nil
    }

    var isAppleSignInAvailable: Bool {
        isAuthenticationAvailable && appleAuthorizer != nil
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
            if cloudStateFailureMessage != nil { return "Device sync needs attention" }
            if setupStage != .none { return "Finish account setup" }
            if selectedWorkspaceChoice == .keepLocalOnly {
                return "Signed in · sync off"
            }
            if syncStatus.phase == .idle || syncStatus.phase == .syncing {
                return syncStatus.phase == .syncing ? "Syncing securely" : "Synced securely"
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
            if let cloudStateFailureMessage { return cloudStateFailureMessage }
            if setupStage == .reviewDisplayName {
                return "Review your name before it is saved to the account."
            }
            if setupStage == .chooseWorkspace {
                return "Choose what happens to this Mac’s existing workspace."
            }
            if selectedWorkspaceChoice == .keepLocalOnly {
                return "The account is connected, but this workspace remains local-only."
            }
            switch syncStatus.phase {
            case .idle:
                return "Your approved workspace is available on your signed-in devices."
            case .syncing:
                return "Sending and receiving workspace changes securely."
            case .retryScheduled:
                return "Sync will retry automatically; local changes remain safe."
            case .authenticationRequired:
                return "Sign in again to continue device sync."
            case .conflictReviewRequired:
                return "A sync conflict needs your review before it can continue."
            case .adapterBlocked, .contractBlocked:
                return "Device sync stopped safely and needs attention."
            case .localOnly:
                return "Choose how this workspace should sync before anything is uploaded."
            }
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
        if cloudStateFailureMessage != nil {
            return HealthComponentStatus(
                component: .sync,
                condition: .attention,
                detail: "Device sync state is unavailable"
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
            let condition: HealthCondition
            let detail: String
            switch syncStatus.phase {
            case .idle:
                condition = .ready
                detail = "Device sync ready"
            case .syncing, .retryScheduled:
                condition = .working
                detail = syncStatus.phase == .syncing ? "Syncing" : "Retry scheduled"
            case .authenticationRequired, .conflictReviewRequired,
                 .adapterBlocked, .contractBlocked:
                condition = .attention
                detail = "Device sync needs attention"
            case .localOnly:
                condition = .off
                detail = "Signed in; sync is off"
            }
            return HealthComponentStatus(
                component: .sync,
                condition: condition,
                detail: detail
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
        restoreTask = Task { [weak self, service, cloudSync] in
            if let cloudSync {
                do {
                    let binding = try await cloudSync.currentBinding()
                    guard !Task.isCancelled, let self else { return }
                    runtimeBoundAccountID = binding?.accountID.rawValue
                    syncStatus = (try? await cloudSync.currentStatus()) ?? .localOnly
                    cloudStateVerified = true
                    cloudStateFailureMessage = nil
                } catch {
                    guard !Task.isCancelled, let self else { return }
                    // Never treat an unreadable durable binding as "unbound".
                    // That could offer a claim/attach action which assigns local
                    // data to the wrong account. Local use remains available.
                    runtimeBoundAccountID = nil
                    syncStatus = .localOnly
                    cloudStateVerified = false
                    cloudStateFailureMessage = "Device sync state couldn’t be verified. Your workspace remains on this Mac."
                }
            }
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
        if let cloudSync {
            Task { await cloudSync.stop() }
        }
        releaseNativeInteraction()
        releaseSetupInteraction()
    }

    /// Provides a deterministic synchronization point for state-machine tests.
    /// It waits only for finite restore or customer-initiated operations; the
    /// long-lived authentication observation stream remains active.
    func waitForPendingOperations() async {
        while restoreTask != nil || operationTask != nil {
            let pendingRestore = restoreTask
            let pendingOperation = operationTask
            if let pendingRestore {
                await pendingRestore.value
            }
            if let pendingOperation {
                await pendingOperation.value
            }
        }
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
        guard isWorkspaceChoiceEnabled(choice) else {
            operationMessage = "That option is unavailable because it is not safe for this workspace yet."
            return
        }
        if choice == .keepLocalOnly {
            selectedWorkspaceChoice = choice
            operationMessage = "This workspace remains only on this Mac."
            pendingReviewedDisplayName = nil
            setupStage = .none
            syncStatus = .localOnly
            releaseSetupInteraction()
            if let cloudSync {
                Task { await cloudSync.stop() }
            }
            return
        }

        guard let cloudSync, let session = activeSession else { return }
        let disposition: WorkspaceProvisioningDisposition
        switch choice {
        case .claimAsNewWorkspace:
            disposition = .claimLocalAsNew
        case .switchWorkspace:
            disposition = .attachExisting(.freshDevice)
        case .keepLocalOnly, .exportAndReplace:
            return
        }

        selectedWorkspaceChoice = choice
        operationMessage = "Connecting this workspace securely…"
        operationTask = Task { [weak self, cloudSync] in
            guard let self else { return }
            do {
                let activation = try await cloudSync.provision(
                    account: session,
                    disposition: disposition,
                    workspaceName: workspaceName(),
                    reviewedDisplayName: session.reviewedDisplayName
                )
                guard !Task.isCancelled else { return }
                let status = (try? await cloudSync.currentStatus()) ?? .localOnly
                runtimeBoundAccountID = activation.binding.accountID.rawValue
                syncStatus = status
                operationTask = nil
                operationMessage = Self.message(for: activation.outcome)
                applyPendingReviewedDisplayName()
                setupStage = .none
                releaseSetupInteraction()
            } catch {
                guard !Task.isCancelled else { return }
                operationTask = nil
                selectedWorkspaceChoice = nil
                operationMessage = error.localizedDescription
            }
        }
    }

    func isWorkspaceChoiceEnabled(_ choice: LocalWorkspaceAccountChoice) -> Bool {
        guard choice != .keepLocalOnly else { return true }
        guard cloudStateVerified,
              cloudSync != nil,
              let context = claimContextAtSignIn else { return false }
        switch choice {
        case .keepLocalOnly:
            return true
        case .claimAsNewWorkspace:
            return context.hasCustomerData && context.boundAccountID == nil
        case .switchWorkspace:
            return !context.hasCustomerData && context.boundAccountID == nil
        case .exportAndReplace:
            // Requires a separately coordinated native export destination.
            return false
        }
    }

    func cancelAccountSetup() {
        signOut()
    }

    func signOut() {
        guard operationTask == nil, let service else { return }
        releaseSetupInteraction()
        setupStage = .none
        operationTask = Task { [weak self, service, cloudSync] in
            if let cloudSync {
                await cloudSync.stop()
            }
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
            var context = localContext()
            if let runtimeBoundAccountID {
                context.boundAccountID = runtimeBoundAccountID
            }
            claimContextAtSignIn = context
            selectedWorkspaceChoice = nil
            workspacePlan = nil
            operationMessage = cloudStateFailureMessage
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
        guard cloudStateVerified else {
            workspacePlan = .requiresCustomerChoice([.keepLocalOnly])
            setupStage = .chooseWorkspace
            operationMessage = cloudStateFailureMessage
            ensureSetupInteraction()
            return
        }
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
        case .bootstrapRemoteWorkspace:
            guard cloudSync != nil else {
                applyPendingReviewedDisplayName()
                setupStage = .none
                releaseSetupInteraction()
                return
            }
            // Even a fresh device requires one visible decision before remote
            // discovery creates or attaches a workspace.
            setupStage = .chooseWorkspace
            ensureSetupInteraction()
        case .continueBoundWorkspace:
            if cloudSync == nil {
                applyPendingReviewedDisplayName()
                setupStage = .none
                releaseSetupInteraction()
            } else {
                resumeCloudSync(for: activeSession)
            }
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
        syncStatus = .localOnly
        if let cloudSync {
            Task { await cloudSync.stop() }
        }
        releaseSetupInteraction()
    }

    private func resumeCloudSync(for session: ProductAccountSession?) {
        guard cloudStateVerified,
              let cloudSync,
              let session,
              operationTask == nil else {
            operationMessage = "Device sync is unavailable. Local data was not changed."
            return
        }
        operationMessage = "Checking for changes…"
        operationTask = Task { [weak self, cloudSync] in
            guard let self else { return }
            do {
                guard let activation = try await cloudSync.resume(account: session) else {
                    operationTask = nil
                    setupStage = .chooseWorkspace
                    ensureSetupInteraction()
                    return
                }
                guard !Task.isCancelled else { return }
                runtimeBoundAccountID = activation.binding.accountID.rawValue
                syncStatus = (try? await cloudSync.currentStatus()) ?? .localOnly
                operationTask = nil
                operationMessage = Self.message(for: activation.outcome)
                applyPendingReviewedDisplayName()
                setupStage = .none
                releaseSetupInteraction()
            } catch {
                guard !Task.isCancelled else { return }
                operationTask = nil
                syncStatus = (try? await cloudSync.currentStatus()) ?? .localOnly
                operationMessage = error.localizedDescription
            }
        }
    }

    private static func message(for outcome: WorkspaceSyncRunOutcome) -> String {
        switch outcome {
        case .synchronized:
            return "Workspace synced."
        case let .conflicts(count):
            return count == 1 ? "One change needs review." : "\(count) changes need review."
        case .retryScheduled:
            return "Sync will retry automatically. Local changes remain safe."
        case .authenticationRequired:
            return "Sign in again to continue device sync."
        case .blocked:
            return "Device sync stopped safely and needs attention."
        case .localOnly:
            return "This workspace remains only on this Mac."
        case .stateChanged:
            return "Workspace connected; finishing initial sync."
        case .cancelled:
            return "Sync was cancelled. Local changes remain safe."
        }
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
