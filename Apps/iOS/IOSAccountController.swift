import AuthenticationServices
import Combine
import FounderOfficeCore
import FounderOfficeIdentity
import Foundation
import UIKit

enum IOSAccountAvailability: Equatable {
    case preparing
    case available
    case localOnly(String)
}

enum IOSAccountSetupStage: Equatable {
    case none
    case reviewDisplayName
    case chooseWorkspace
}

struct IOSSyncConflict: Identifiable, Equatable {
    let id: UUID
    let entityLabel: String
    let fields: [String]
}

/// The iPhone account surface owns product identity and the explicit workspace
/// decision. Authentication by itself never bootstraps, uploads, replaces, or
/// otherwise changes the local workspace.
@MainActor
final class IOSAccountController: ObservableObject {
    @Published private(set) var availability: IOSAccountAvailability = .preparing
    @Published private(set) var authState: ProductAuthState = .localOnly
    @Published private(set) var setupStage: IOSAccountSetupStage = .none
    @Published private(set) var syncStatus: WorkspaceSyncStatus = .localOnly
    @Published private(set) var conflicts: [IOSSyncConflict] = []
    @Published private(set) var operationMessage: String?
    @Published private(set) var displayNameError: String?
    @Published var reviewedDisplayNameDraft = ""

    private var service: SupabaseProductAuthClient?
    private var runtime: FounderOfficeCloudSyncRuntime?
    private var appleAuthorizer: AppleIdentityAuthorizer?
    private var repository: SQLiteWorkspaceRepository?
    private var activeAccount: ProductAccountSession?
    private var boundAccountID: UUID?
    private var didResumeAccountID: UUID?
    private var isRestoringSession = false
    private var observeTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var hasLocalCustomerData: (() -> Bool)?
    private var workspaceName: (() -> String)?
    private var workspaceChanged: (() -> Void)?

    deinit {
        observeTask?.cancel()
        operationTask?.cancel()
    }

    var isBusy: Bool {
        if case .restoring = authState { return true }
        if case .signingIn = authState { return true }
        return operationTask != nil
    }

    var isGoogleSignInAvailable: Bool {
        availability == .available && service != nil && !isBusy
    }

    var isAppleSignInAvailable: Bool {
        isGoogleSignInAvailable && appleAuthorizer != nil
    }

    var availableWorkspaceChoices: [LocalWorkspaceAccountChoice] {
        guard setupStage == .chooseWorkspace else { return [] }
        guard boundAccountID == nil else { return [.keepLocalOnly] }
        if hasLocalCustomerData?() == true {
            return [.keepLocalOnly, .claimAsNewWorkspace]
        }
        return [.keepLocalOnly, .switchWorkspace]
    }

    var statusTitle: String {
        switch availability {
        case .preparing: return "Preparing local workspace"
        case let .localOnly(message): return message
        case .available: break
        }
        switch authState {
        case .localOnly: return "Stored on this iPhone"
        case .restoring: return "Checking this iPhone"
        case let .signingIn(provider): return "Opening (provider.title)"
        case .failed: return "Sign-in needs attention"
        case .signedIn:
            if setupStage != .none { return "Choose device sync" }
            switch syncStatus.phase {
            case .idle: return "Device sync ready"
            case .syncing: return "Syncing securely"
            case .retryScheduled: return "Sync retry scheduled"
            case .conflictReviewRequired: return "A change needs review"
            case .authenticationRequired: return "Sign in again to sync"
            case .adapterBlocked, .contractBlocked: return "Device sync needs attention"
            case .localOnly: return "Signed in · sync off"
            }
        }
    }

    var statusDetail: String {
        if let operationMessage { return operationMessage }
        switch availability {
        case .preparing: return "Opening your on-device workspace first."
        case let .localOnly(message): return message
        case .available: break
        }
        switch authState {
        case .localOnly:
            return "No account is required. Sign in only when you want this workspace on another device."
        case .restoring:
            return "Checking the secure session saved on this iPhone."
        case .signingIn:
            return "Your local workspace will not be uploaded or replaced."
        case let .failed(failure):
            return failure.recoveryMessage
        case .signedIn:
            switch syncStatus.phase {
            case .idle: return "Changes stay available offline and sync when this iPhone can connect."
            case .syncing: return "Sending and receiving only your approved workspace changes."
            case .retryScheduled: return "Local changes are safe. This iPhone will retry without polling."
            case .conflictReviewRequired: return "Choose which value to keep for each overlapping change."
            case .authenticationRequired: return "Sign in again before this iPhone can sync."
            case .adapterBlocked, .contractBlocked:
                return "Sync stopped safely. Your on-device workspace is unchanged."
            case .localOnly:
                return "Sign-in does not upload existing data. Choose an explicit workspace action first."
            }
        }
    }

    func configure(
        repository: SQLiteWorkspaceRepository,
        hasLocalCustomerData: @escaping () -> Bool,
        workspaceName: @escaping () -> String,
        workspaceChanged: @escaping () -> Void
    ) {
        guard self.repository == nil else { return }
        self.repository = repository
        self.hasLocalCustomerData = hasLocalCustomerData
        self.workspaceName = workspaceName
        self.workspaceChanged = workspaceChanged

        switch ProductAuthConfiguration.load(infoDictionary: Bundle.main.infoDictionary ?? [:]) {
        case let .failure(error):
            availability = .localOnly(error.localizedDescription)
        case let .success(configuration):
            let service = SupabaseProductAuthClient(
                configuration: configuration,
                presentationAnchor: Self.presentationAnchor
            )
            do {
                let transport = try SupabaseWorkspaceSyncTransport(
                    configuration: configuration,
                    tokenProvider: service
                )
                runtime = try FounderOfficeCloudSyncRuntime(
                    repository: repository,
                    auth: service,
                    transport: transport,
                    deviceID: IOSDeviceIdentityStore.loadOrCreate()
                )
                self.service = service
                if (Bundle.main.object(forInfoDictionaryKey: "FounderOfficeAppleSignInEnabled") as? Bool) == true {
                    appleAuthorizer = AppleIdentityAuthorizer(presentationAnchor: Self.presentationAnchor)
                }
                availability = .available
                start()
            } catch {
                availability = .localOnly("Device sync is unavailable in this build. Your workspace stays on this iPhone.")
            }
        }
    }

    func signInWithGoogle() {
        guard let service, isGoogleSignInAvailable else { return }
        operationMessage = nil
        operationTask = Task { [weak self, service] in
            await service.signInWithGoogle()
            guard !Task.isCancelled else { return }
            let state = await service.currentState()
            self?.operationTask = nil
            self?.receive(state)
        }
    }

    func signInWithApple() {
        guard let service, let appleAuthorizer, isAppleSignInAvailable else { return }
        operationMessage = nil
        operationTask = Task { [weak self, service, appleAuthorizer] in
            do {
                let authorization = try await appleAuthorizer.authorize()
                guard !Task.isCancelled else { return }
                await service.signInWithApple(authorization)
            } catch {
                guard !Task.isCancelled else { return }
                let failure: ProductAuthFailure
                if let error = error as? AppleIdentityAuthorizationError, error == .cancelled {
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
                self?.operationTask = nil
                self?.receive(.failed(failure))
                return
            }
            guard !Task.isCancelled else { return }
            let state = await service.currentState()
            self?.operationTask = nil
            self?.receive(state)
        }
    }

    func saveReviewedDisplayName() {
        guard let service, let account = activeAccount, operationTask == nil else { return }
        let isInitialWorkspaceReview = setupStage == .reviewDisplayName
        let reviewed: ReviewedDisplayName
        do {
            reviewed = try ReviewedDisplayName(reviewedInput: reviewedDisplayNameDraft)
        } catch {
            displayNameError = error.localizedDescription
            return
        }
        displayNameError = nil
        operationMessage = "Saving your reviewed name…"
        operationTask = Task { [weak self, service] in
            do {
                try await service.updateReviewedDisplayName(reviewed)
                guard !Task.isCancelled, let self else { return }
                operationTask = nil
                let state = await service.currentState()
                guard case let .signedIn(updated) = state, updated.accountID == account.accountID else {
                    receive(state)
                    return
                }
                activeAccount = updated
                reviewedDisplayNameDraft = reviewed.value
                operationMessage = nil
                if isInitialWorkspaceReview {
                    chooseWorkspace(for: updated)
                } else {
                    operationMessage = "Your product account name was updated."
                }
            } catch {
                guard let self else { return }
                operationTask = nil
                displayNameError = "Couldn’t save that name. Try again."
            }
        }
    }

    func chooseWorkspace(_ choice: LocalWorkspaceAccountChoice) {
        guard availableWorkspaceChoices.contains(choice),
              let runtime,
              let account = activeAccount else { return }
        if choice == .keepLocalOnly {
            setupStage = .none
            syncStatus = .localOnly
            operationMessage = "This workspace remains only on this iPhone."
            Task { await runtime.stop() }
            return
        }

        let disposition: WorkspaceProvisioningDisposition = choice == .claimAsNewWorkspace
            ? .claimLocalAsNew
            : .attachExisting(.freshDevice)
        operationMessage = "Connecting this workspace securely…"
        operationTask = Task { [weak self, runtime] in
            do {
                _ = try await runtime.provision(
                    account: account,
                    disposition: disposition,
                    workspaceName: self?.workspaceName?() ?? "Founder's Office",
                    reviewedDisplayName: account.reviewedDisplayName
                )
                guard !Task.isCancelled, let self else { return }
                operationTask = nil
                setupStage = .none
                didResumeAccountID = account.accountID
                syncStatus = (try? await runtime.currentStatus()) ?? .localOnly
                operationMessage = "Workspace connected."
                await refreshConflicts()
                workspaceChanged?()
            } catch {
                guard let self else { return }
                operationTask = nil
                operationMessage = error.localizedDescription
            }
        }
    }

    func syncNow() {
        guard let runtime, case .signedIn = authState, operationTask == nil else { return }
        operationMessage = "Checking for changes…"
        operationTask = Task { [weak self, runtime] in
            _ = await runtime.synchronizeNow()
            guard !Task.isCancelled, let self else { return }
            operationTask = nil
            syncStatus = (try? await runtime.currentStatus()) ?? .localOnly
            operationMessage = nil
            await refreshConflicts()
            workspaceChanged?()
        }
    }

    func resolve(_ conflict: IOSSyncConflict, keepingLocalValue: Bool) {
        guard let repository, let runtime, operationTask == nil else { return }
        operationMessage = "Saving your conflict choice…"
        operationTask = Task { [weak self, repository, runtime] in
            do {
                _ = try await repository.resolveSyncConflict(
                    id: conflict.id,
                    resolution: keepingLocalValue ? .keepMine : .useLatest
                )
                _ = await runtime.synchronizeNow()
                guard !Task.isCancelled, let self else { return }
                operationTask = nil
                syncStatus = (try? await runtime.currentStatus()) ?? .localOnly
                operationMessage = nil
                await refreshConflicts()
                workspaceChanged?()
            } catch {
                guard let self else { return }
                operationTask = nil
                operationMessage = "That conflict could not be resolved. Local data is unchanged."
            }
        }
    }

    func signOut() {
        guard let service, operationTask == nil else { return }
        operationMessage = "Signing out on this iPhone…"
        operationTask = Task { [weak self, service] in
            if let runtime = self?.runtime { await runtime.stop() }
            await service.signOut()
            guard !Task.isCancelled else { return }
            let state = await service.currentState()
            self?.operationTask = nil
            self?.receive(state)
        }
    }

    private func start() {
        guard let service, observeTask == nil else { return }
        authState = .restoring
        isRestoringSession = true
        observeTask = Task { [weak self, service] in
            let states = await service.stateChanges()
            for await state in states {
                guard !Task.isCancelled else { return }
                self?.receive(state)
            }
        }
        Task { [weak self, service] in
            await service.restoreSession()
            guard let self else { return }
            isRestoringSession = false
            receive(await service.currentState())
        }
    }

    private func receive(_ state: ProductAuthState) {
        if isRestoringSession {
            if case .restoring = state { authState = state }
            return
        }
        authState = state
        switch state {
        case let .signedIn(account):
            activeAccount = account
            if let reviewed = account.reviewedDisplayName {
                reviewedDisplayNameDraft = reviewed.value
            }
            inspectBinding(for: account)
        case .localOnly, .failed:
            activeAccount = nil
            boundAccountID = nil
            didResumeAccountID = nil
            setupStage = .none
            syncStatus = .localOnly
            conflicts = []
        case .restoring, .signingIn:
            break
        }
    }

    private func inspectBinding(for account: ProductAccountSession) {
        guard let runtime else { return }
        Task { [weak self, runtime] in
            let binding = try? await runtime.currentBinding()
            guard let self, activeAccount?.accountID == account.accountID else { return }
            boundAccountID = binding?.accountID.rawValue
            if binding?.accountID.rawValue == account.accountID {
                if account.reviewedDisplayName == nil {
                    setupStage = .reviewDisplayName
                    reviewedDisplayNameDraft = account.onboardingDisplayNameSuggestion?.suggestedValue ?? ""
                } else {
                    resume(account)
                }
            } else if account.reviewedDisplayName == nil {
                setupStage = .reviewDisplayName
                reviewedDisplayNameDraft = account.onboardingDisplayNameSuggestion?.suggestedValue ?? ""
            } else {
                chooseWorkspace(for: account)
            }
        }
    }

    private func chooseWorkspace(for account: ProductAccountSession) {
        guard activeAccount?.accountID == account.accountID else { return }
        setupStage = .chooseWorkspace
        operationMessage = boundAccountID == nil
            ? "Choose what this iPhone should do with its local workspace."
            : "This iPhone is already connected to a different account. Local data was not changed."
    }

    private func resume(_ account: ProductAccountSession) {
        guard let runtime, didResumeAccountID != account.accountID, operationTask == nil else { return }
        didResumeAccountID = account.accountID
        operationMessage = "Checking for changes…"
        operationTask = Task { [weak self, runtime] in
            do {
                _ = try await runtime.resume(account: account)
                guard !Task.isCancelled, let self else { return }
                operationTask = nil
                setupStage = .none
                syncStatus = (try? await runtime.currentStatus()) ?? .localOnly
                operationMessage = nil
                await refreshConflicts()
                workspaceChanged?()
            } catch {
                guard let self else { return }
                operationTask = nil
                didResumeAccountID = nil
                chooseWorkspace(for: account)
            }
        }
    }

    private func refreshConflicts() async {
        guard let repository else { return }
        let stored = (try? await repository.persistedSyncConflicts(limit: 20)) ?? []
        conflicts = stored.map {
            IOSSyncConflict(
                id: $0.id,
                entityLabel: $0.conflict.entityType.rawValue.capitalized,
                fields: $0.conflict.conflictingFields.sorted()
            )
        }
    }

    private static func presentationAnchor() -> ASPresentationAnchor? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
    }
}

private enum IOSDeviceIdentityStore {
    private static let defaultsKey = "FounderOffice.iOSDeviceID.v1"

    static func loadOrCreate(defaults: UserDefaults = .standard) -> DeviceID {
        if let value = defaults.string(forKey: defaultsKey),
           let identifier = UUID(uuidString: value) {
            return DeviceID(rawValue: identifier)
        }
        let identifier = DeviceID(rawValue: UUID())
        defaults.set(identifier.rawValue.uuidString.lowercased(), forKey: defaultsKey)
        return identifier
    }
}
