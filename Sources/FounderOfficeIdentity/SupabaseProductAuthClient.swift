import AuthenticationServices
import Foundation
import Supabase

public actor SupabaseProductAuthClient: ProductAuthServing {
    private let client: SupabaseClient
    private let configuration: ProductAuthConfiguration
    private let oauthPresentationAnchor: @MainActor @Sendable () -> ASPresentationAnchor?
    private let durableStorage: VerifiedProductAuthStorage
    private var state: ProductAuthState = .localOnly
    private var continuations: [UUID: AsyncStream<ProductAuthState>.Continuation] = [:]
    private var authObservationTask: Task<Void, Never>?
    private var ephemeralProviderSuggestion: OnboardingDisplayNameSuggestion?

    public init(
        configuration: ProductAuthConfiguration,
        presentationAnchor: @escaping @MainActor @Sendable () -> ASPresentationAnchor? = { nil }
    ) {
        let durableStorage = VerifiedProductAuthStorage(
            storage: ProductKeychainStorage(service: configuration.keychainService),
            sessionKey: "founders-office-session"
        )
        self.durableStorage = durableStorage
        self.configuration = configuration
        oauthPresentationAnchor = presentationAnchor
        client = SupabaseClient(
            supabaseURL: configuration.endpoint,
            supabaseKey: configuration.publishableKey,
            options: .init(
                auth: .init(
                    storage: durableStorage,
                    redirectToURL: configuration.callbackURL,
                    storageKey: "founders-office-session",
                    flowType: .pkce,
                    emitLocalSessionAsInitialSession: true
                )
            )
        )
    }

    public func currentState() -> ProductAuthState { state }

    public func stateChanges() -> AsyncStream<ProductAuthState> {
        let identifier = UUID()
        let initialState = state
        return AsyncStream { continuation in
            continuations[identifier] = continuation
            continuation.yield(initialState)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(identifier) }
            }
        }
    }

    public func restoreSession() async {
        startAuthStateObservationIfNeeded()
        ephemeralProviderSuggestion = nil
        publish(.restoring)
        do {
            let session = try await client.auth.session
            try durableStorage.verifyDurableSession(session)
            publish(.signedIn(Self.summary(session)))
        } catch AuthError.sessionMissing {
            do {
                try durableStorage.verifyNoRecordedFailure()
                publish(.localOnly)
            } catch {
                publish(.failed(Self.failure(from: error)))
            }
        } catch {
            publish(.failed(Self.failure(from: error)))
        }
    }

    public func signInWithGoogle() async {
        startAuthStateObservationIfNeeded()
        ephemeralProviderSuggestion = nil
        let stateBeforeSignIn = state
        publish(.signingIn(.google))
        do {
            let callbackConfiguration = configuration
            let presentationAnchor = oauthPresentationAnchor
            let session = try await client.auth.signInWithOAuth(
                provider: .google,
                scopes: ProductAuthConfiguration.googleProductIdentityScopes
            ) { authorizationURL in
                try await Self.launchOAuthSession(
                    authorizationURL: authorizationURL,
                    configuration: callbackConfiguration,
                    presentationAnchor: presentationAnchor
                )
            }
            try durableStorage.verifyDurableSession(session)
            publish(.signedIn(Self.summary(session, preferredProvider: .google)))
        } catch is CancellationError {
            publish(stateBeforeSignIn)
        } catch {
            publish(.failed(Self.failure(from: error)))
        }
    }

    public func signInWithApple(_ authorization: AppleIdentityAuthorization) async {
        startAuthStateObservationIfNeeded()
        ephemeralProviderSuggestion = authorization.onboardingDisplayNameSuggestion
        let stateBeforeSignIn = state
        publish(.signingIn(.apple))
        do {
            let session = try await client.auth.signInWithIdToken(
                credentials: .init(
                    provider: .apple,
                    idToken: authorization.identityToken,
                    nonce: authorization.rawNonce
                )
            )

            let refreshed = client.auth.currentSession ?? session
            try durableStorage.verifyDurableSession(refreshed)
            publish(
                .signedIn(
                    Self.summary(
                        refreshed,
                        preferredProvider: .apple,
                        preferredSuggestion: ephemeralProviderSuggestion
                    )
                )
            )
        } catch is CancellationError {
            ephemeralProviderSuggestion = nil
            publish(stateBeforeSignIn)
        } catch {
            ephemeralProviderSuggestion = nil
            publish(.failed(Self.failure(from: error)))
        }
    }

    public func updateReviewedDisplayName(_ displayName: ReviewedDisplayName) async throws {
        _ = try await client.auth.update(
            user: UserAttributes(data: ["display_name": .string(displayName.value)])
        )
        ephemeralProviderSuggestion = nil
        let session = try await client.auth.session
        try durableStorage.verifyDurableSession(session)
        publish(.signedIn(Self.summary(session)))
    }

    public func accessToken() async throws -> String {
        let session = try await client.auth.session
        try durableStorage.verifyDurableSession(session)
        return session.accessToken
    }

    public func signOut() async {
        ephemeralProviderSuggestion = nil
        do {
            try await client.auth.signOut(scope: .local)
            try durableStorage.verifySessionRemoved()
            publish(.localOnly)
        } catch {
            publish(.failed(Self.failure(from: error)))
        }
    }

    private func publish(_ nextState: ProductAuthState) {
        state = nextState
        for continuation in continuations.values {
            continuation.yield(nextState)
        }
    }

    private func removeContinuation(_ identifier: UUID) {
        continuations.removeValue(forKey: identifier)
    }

    private func startAuthStateObservationIfNeeded() {
        guard authObservationTask == nil else { return }
        let changes = client.auth.authStateChanges
        authObservationTask = Task { [weak self] in
            for await (_, session) in changes {
                guard let self else { return }
                await self.receiveAuthSession(session)
            }
        }
    }

    private func receiveAuthSession(_ session: Session?) {
        if let session {
            do {
                try durableStorage.verifyDurableSession(session)
                publish(
                    .signedIn(
                        Self.summary(
                            session,
                            preferredSuggestion: ephemeralProviderSuggestion
                        )
                    )
                )
            } catch {
                publish(.failed(Self.failure(from: error)))
            }
        } else {
            ephemeralProviderSuggestion = nil
            do {
                // SDK events are advisory. A nil event can arrive before a
                // failed Keychain deletion, so signed-out UI requires proof
                // that the durable session is actually absent.
                try durableStorage.verifySessionRemoved()
                publish(.localOnly)
            } catch {
                publish(.failed(Self.failure(from: error)))
            }
        }
    }

    private static func summary(
        _ session: Session,
        preferredProvider: ProductIdentityProvider? = nil,
        preferredSuggestion: OnboardingDisplayNameSuggestion? = nil
    ) -> ProductAccountSession {
        let metadataProvider = session.user.appMetadata["provider"]?.stringValue
            .flatMap(ProductIdentityProvider.init(rawValue:))
        let provider = preferredProvider
            ?? session.user.identities?
                .sorted { ($0.lastSignInAt ?? .distantPast) > ($1.lastSignInAt ?? .distantPast) }
                .compactMap { ProductIdentityProvider(rawValue: $0.provider) }
                .first
            ?? metadataProvider
            ?? .unknown

        let reviewedDisplayName = session.user.userMetadata["display_name"]?.stringValue
            .flatMap { try? ReviewedDisplayName(reviewedInput: $0) }
        let metadataSuggestions = ["full_name", "name"]
            .compactMap { session.user.userMetadata[$0]?.stringValue }
            .compactMap(OnboardingDisplayNameSuggestion.init(providerValue:))
        let onboardingSuggestion = preferredSuggestion ?? metadataSuggestions.first

        return ProductAccountSession(
            accountID: session.user.id,
            provider: provider,
            reviewedDisplayName: reviewedDisplayName,
            onboardingDisplayNameSuggestion: onboardingSuggestion,
            expiresAt: Date(timeIntervalSince1970: session.expiresAt)
        )
    }

    private static func failure(from error: Error) -> ProductAuthFailure {
        if error is ProductAuthSecureStorageError {
            return ProductAuthFailure(
                code: .secureStorage,
                recoveryMessage: "Secure session storage is unavailable. Your workspace stays on this Mac."
            )
        }
        if let authenticationError = error as? ASWebAuthenticationSessionError,
           authenticationError.code == .canceledLogin {
            return ProductAuthFailure(
                code: .cancelled,
                recoveryMessage: "Sign-in was cancelled. Your local workspace was not changed."
            )
        }
        if let callbackError = error as? ProductAuthCallbackError {
            switch callbackError {
            case .unexpectedResponse:
                return ProductAuthFailure(
                    code: .rejected,
                    recoveryMessage: "The sign-in callback was rejected. Your local workspace was not changed."
                )
            case .invalidConfiguration, .missingPresentationAnchor, .couldNotStart:
                return ProductAuthFailure(
                    code: .configuration,
                    recoveryMessage: "The secure sign-in window could not open. Your local workspace was not changed."
                )
            }
        }
        if error is URLError {
            return ProductAuthFailure(
                code: .network,
                recoveryMessage: "Could not reach device sync. Your local workspace is safe; try again when online."
            )
        }
        if error is AuthError {
            return ProductAuthFailure(
                code: .rejected,
                recoveryMessage: "Sign-in could not be completed. Check the account and try again."
            )
        }
        return ProductAuthFailure(
            code: .unknown,
            recoveryMessage: "Sign-in could not be completed. Your local workspace was not changed."
        )
    }

    @MainActor
    private static func launchOAuthSession(
        authorizationURL: URL,
        configuration: ProductAuthConfiguration,
        presentationAnchor: @escaping @MainActor @Sendable () -> ASPresentationAnchor?
    ) async throws -> URL {
        guard let callbackScheme = configuration.callbackURL.scheme else {
            throw ProductAuthCallbackError.invalidConfiguration
        }
        guard let anchor = presentationAnchor() else {
            throw ProductAuthCallbackError.missingPresentationAnchor
        }

        let runner = OAuthWebAuthenticationSessionRunner(
            anchor: anchor,
            configuration: configuration
        )
        return try await runner.run(
            authorizationURL: authorizationURL,
            callbackScheme: callbackScheme
        )
    }
}

@MainActor
private final class OAuthWebAuthenticationSessionRunner: NSObject,
    ASWebAuthenticationPresentationContextProviding
{
    private let anchor: ASPresentationAnchor
    private let configuration: ProductAuthConfiguration
    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, Error>?

    init(anchor: ASPresentationAnchor, configuration: ProductAuthConfiguration) {
        self.anchor = anchor
        self.configuration = configuration
    }

    func run(authorizationURL: URL, callbackScheme: String) async throws -> URL {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                let session = ASWebAuthenticationSession(
                    url: authorizationURL,
                    callbackURLScheme: callbackScheme
                ) { [weak self] responseURL, error in
                    guard let self else { return }
                    if let error {
                        finish(with: .failure(error))
                        return
                    }
                    guard let responseURL,
                          configuration.acceptsCallbackResponse(responseURL) else {
                        finish(with: .failure(ProductAuthCallbackError.unexpectedResponse))
                        return
                    }
                    finish(with: .success(responseURL))
                }
                self.session = session
                session.presentationContextProvider = self
                guard session.start() else {
                    finish(with: .failure(ProductAuthCallbackError.couldNotStart))
                    return
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel()
            }
        }
    }

    private func finish(with result: Result<URL, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        session?.presentationContextProvider = nil
        session = nil
        continuation.resume(with: result)
    }

    private func cancel() {
        session?.cancel()
        finish(with: .failure(CancellationError()))
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        _ = session
        return anchor
    }
}

enum ProductAuthCallbackError: Error, Equatable, Sendable {
    case invalidConfiguration
    case missingPresentationAnchor
    case unexpectedResponse
    case couldNotStart
}

/// Supabase Swift intentionally treats local-storage failures as recoverable
/// implementation details. Product identity cannot: publishing a signed-in
/// state before the session survives a Keychain read-back makes a restart look
/// authenticated when it is not. This wrapper records storage failures and
/// exposes a token-free durability check to the auth client.
final class VerifiedProductAuthStorage: AuthLocalStorage, @unchecked Sendable {
    private let storage: any AuthLocalStorage
    private let sessionKey: String
    private let lock = NSLock()
    private var latestStorageFailure: ProductAuthSecureStorageError?

    init(storage: any AuthLocalStorage, sessionKey: String) {
        self.storage = storage
        self.sessionKey = sessionKey
    }

    func store(key: String, value: Data) throws {
        do {
            try storage.store(key: key, value: value)
            if key == sessionKey {
                lock.withLock { latestStorageFailure = nil }
            }
        } catch {
            if key == sessionKey {
                lock.withLock { latestStorageFailure = .writeFailed }
            }
            throw error
        }
    }

    func retrieve(key: String) throws -> Data? {
        do {
            let value = try storage.retrieve(key: key)
            if key == sessionKey {
                lock.withLock { latestStorageFailure = nil }
            }
            return value
        } catch {
            if key == sessionKey {
                lock.withLock { latestStorageFailure = .readFailed }
            }
            throw error
        }
    }

    func remove(key: String) throws {
        do {
            try storage.remove(key: key)
            if key == sessionKey {
                lock.withLock { latestStorageFailure = nil }
            }
        } catch {
            if key == sessionKey {
                lock.withLock { latestStorageFailure = .deleteFailed }
            }
            throw error
        }
    }

    func verifyNoRecordedFailure() throws {
        if let failure = lock.withLock({ latestStorageFailure }) {
            throw failure
        }
    }

    func verifyDurableSession(_ expected: Session) throws {
        if let failure = lock.withLock({ latestStorageFailure }) {
            throw failure
        }
        let data: Data
        do {
            guard let stored = try storage.retrieve(key: sessionKey) else {
                throw ProductAuthSecureStorageError.missingReadBack
            }
            data = stored
        } catch let error as ProductAuthSecureStorageError {
            throw error
        } catch {
            throw ProductAuthSecureStorageError.readFailed
        }

        guard let persisted = try? JSONDecoder().decode(Session.self, from: data),
              persisted == expected else {
            throw ProductAuthSecureStorageError.mismatchedReadBack
        }
    }

    func verifySessionRemoved() throws {
        if let failure = lock.withLock({ latestStorageFailure }) {
            throw failure
        }
        do {
            guard try storage.retrieve(key: sessionKey) == nil else {
                throw ProductAuthSecureStorageError.deleteFailed
            }
        } catch let error as ProductAuthSecureStorageError {
            throw error
        } catch {
            throw ProductAuthSecureStorageError.readFailed
        }
    }
}

enum ProductAuthSecureStorageError: Error, Equatable, Sendable {
    case writeFailed
    case readFailed
    case deleteFailed
    case missingReadBack
    case mismatchedReadBack
}
