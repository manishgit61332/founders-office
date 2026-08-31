import AuthenticationServices
import Foundation
import Supabase

public actor SupabaseProductAuthClient: ProductAuthServing {
    private let client: SupabaseClient
    private var state: ProductAuthState = .localOnly
    private var continuations: [UUID: AsyncStream<ProductAuthState>.Continuation] = [:]
    private var authObservationTask: Task<Void, Never>?

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
        publish(.signingIn(.apple))
        do {
            let session = try await client.auth.signInWithIdToken(
                credentials: .init(
                    provider: .apple,
                    idToken: authorization.identityToken,
                    nonce: authorization.rawNonce
                )
            )

            if let displayName = Self.validatedDisplayName(authorization.displayName) {
                _ = try await client.auth.update(
                    user: UserAttributes(data: ["display_name": .string(displayName)])
                )
            }
            let refreshed = client.auth.currentSession ?? session
            publish(.signedIn(Self.summary(refreshed, preferredProvider: .apple)))
        } catch {
            publish(.failed(Self.failure(from: error)))
        }
    }

    public func updateDisplayName(_ displayName: String) async throws {
        guard let cleanName = Self.validatedDisplayName(displayName) else {
            throw ProductIdentityError.invalidDisplayName
        }
        _ = try await client.auth.update(
            user: UserAttributes(data: ["display_name": .string(cleanName)])
        )
        let session = try await client.auth.session
        publish(.signedIn(Self.summary(session)))
    }

    public func accessToken() async throws -> String {
        try await client.auth.session.accessToken
    }

    public func signOut() async {
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
            publish(.signedIn(Self.summary(session)))
        } else {
            publish(.localOnly)
        }
    }

    private static func summary(
        _ session: Session,
        preferredProvider: ProductIdentityProvider? = nil
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

        let displayNames = ["display_name", "full_name", "name"]
            .compactMap { session.user.userMetadata[$0]?.stringValue }
            .compactMap(validatedDisplayName)
        let displayName: String? = displayNames.first

        return ProductAccountSession(
            accountID: session.user.id,
            provider: provider,
            displayName: displayName,
            expiresAt: Date(timeIntervalSince1970: session.expiresAt)
        )
    }

    private static func validatedDisplayName(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 80 else { return nil }
        return clean
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

public enum ProductIdentityError: Error, Equatable, Sendable {
    case invalidDisplayName
}

extension ProductIdentityError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidDisplayName:
            return "Enter a name between 1 and 80 characters."
        }
    }
}
