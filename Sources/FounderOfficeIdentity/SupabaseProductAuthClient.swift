import AuthenticationServices
import Foundation
import Supabase

public actor SupabaseProductAuthClient: ProductAuthServing {
    private let client: SupabaseClient
    private let durableStorage: VerifiedProductAuthStorage
    private var state: ProductAuthState = .localOnly
    private var continuations: [UUID: AsyncStream<ProductAuthState>.Continuation] = [:]
    private var authObservationTask: Task<Void, Never>?
    private var ephemeralProviderSuggestion: OnboardingDisplayNameSuggestion?

    public init(configuration: ProductAuthConfiguration) {
        let durableStorage = VerifiedProductAuthStorage(
            storage: KeychainLocalStorage(service: configuration.keychainService),
            sessionKey: "founders-office-session"
        )
        self.durableStorage = durableStorage
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
            publish(.localOnly)
        } catch {
            publish(.failed(Self.failure(from: error)))
        }
    }

    public func signInWithGoogle() async {
        startAuthStateObservationIfNeeded()
        ephemeralProviderSuggestion = nil
        publish(.signingIn(.google))
        do {
            let session = try await client.auth.signInWithOAuth(provider: .google)
            try durableStorage.verifyDurableSession(session)
            publish(.signedIn(Self.summary(session, preferredProvider: .google)))
        } catch {
            publish(.failed(Self.failure(from: error)))
        }
    }

    public func signInWithApple(_ authorization: AppleIdentityAuthorization) async {
        startAuthStateObservationIfNeeded()
        ephemeralProviderSuggestion = authorization.onboardingDisplayNameSuggestion
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
            publish(.localOnly)
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
            lock.withLock { latestStorageFailure = nil }
        } catch {
            lock.withLock { latestStorageFailure = .writeFailed }
            throw error
        }
    }

    func retrieve(key: String) throws -> Data? {
        do {
            let value = try storage.retrieve(key: key)
            lock.withLock { latestStorageFailure = nil }
            return value
        } catch {
            lock.withLock { latestStorageFailure = .readFailed }
            throw error
        }
    }

    func remove(key: String) throws {
        do {
            try storage.remove(key: key)
            lock.withLock { latestStorageFailure = nil }
        } catch {
            lock.withLock { latestStorageFailure = .deleteFailed }
            throw error
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
              persisted.user.id == expected.user.id,
              persisted.accessToken == expected.accessToken,
              persisted.refreshToken == expected.refreshToken else {
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
