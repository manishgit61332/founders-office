import AuthenticationServices
import Foundation
import Supabase

public actor SupabaseProductAuthClient: ProductAuthServing {
    private let client: SupabaseClient
    private var state: ProductAuthState = .localOnly
    private var continuations: [UUID: AsyncStream<ProductAuthState>.Continuation] = [:]
    private var authObservationTask: Task<Void, Never>?
    private var ephemeralProviderSuggestion: OnboardingDisplayNameSuggestion?

    public init(configuration: ProductAuthConfiguration) {
        client = SupabaseClient(
            supabaseURL: configuration.endpoint,
            supabaseKey: configuration.publishableKey,
            options: .init(
                auth: .init(
                    storage: KeychainLocalStorage(service: configuration.keychainService),
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
        publish(.signedIn(Self.summary(session)))
    }

    public func accessToken() async throws -> String {
        try await client.auth.session.accessToken
    }

    public func signOut() async {
        ephemeralProviderSuggestion = nil
        do {
            try await client.auth.signOut(scope: .local)
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
            publish(
                .signedIn(
                    Self.summary(
                        session,
                        preferredSuggestion: ephemeralProviderSuggestion
                    )
                )
            )
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

        let metadataSuggestions = ["display_name", "full_name", "name"]
            .compactMap { session.user.userMetadata[$0]?.stringValue }
            .compactMap(OnboardingDisplayNameSuggestion.init(providerValue:))
        let onboardingSuggestion = preferredSuggestion ?? metadataSuggestions.first

        return ProductAccountSession(
            accountID: session.user.id,
            provider: provider,
            onboardingDisplayNameSuggestion: onboardingSuggestion,
            expiresAt: Date(timeIntervalSince1970: session.expiresAt)
        )
    }

    private static func failure(from error: Error) -> ProductAuthFailure {
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
