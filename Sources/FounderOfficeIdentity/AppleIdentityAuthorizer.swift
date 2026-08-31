import AuthenticationServices
import CryptoKit
import Foundation
import Security

@MainActor
public final class AppleIdentityAuthorizer: NSObject {
    private let presentationAnchor: () -> ASPresentationAnchor
    private var continuation: CheckedContinuation<AppleIdentityAuthorization, Error>?
    private var rawNonce: String?

    public init(presentationAnchor: @escaping () -> ASPresentationAnchor) {
        self.presentationAnchor = presentationAnchor
    }

    public func authorize() async throws -> AppleIdentityAuthorization {
        guard continuation == nil else {
            throw AppleIdentityAuthorizationError.requestAlreadyActive
        }

        let nonce = try Self.makeNonce()
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName]
        request.nonce = Self.sha256(nonce)

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        rawNonce = nonce

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            controller.performRequests()
        }
    }

    private func finish(with result: Result<AppleIdentityAuthorization, Error>) {
        let continuation = continuation
        self.continuation = nil
        rawNonce = nil
        continuation?.resume(with: result)
    }

    private static func makeNonce(length: Int = 32) throws -> String {
        precondition(length > 0)
        let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        result.reserveCapacity(length)

        while result.count < length {
            var random: UInt8 = 0
            let status = SecRandomCopyBytes(kSecRandomDefault, 1, &random)
            guard status == errSecSuccess else {
                throw AppleIdentityAuthorizationError.secureRandomUnavailable
            }
            if random < alphabet.count {
                result.append(alphabet[Int(random)])
            }
        }
        return result
    }

    private static func sha256(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

extension AppleIdentityAuthorizer: ASAuthorizationControllerDelegate {
    public func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let tokenData = credential.identityToken,
              let token = String(data: tokenData, encoding: .utf8),
              let rawNonce else {
            finish(with: .failure(AppleIdentityAuthorizationError.invalidCredential))
            return
        }

        let onboardingSuggestion = credential.fullName.flatMap {
            let formatted = PersonNameComponentsFormatter().string(from: $0)
            return OnboardingDisplayNameSuggestion(providerValue: formatted)
        }
        finish(
            with: .success(
                AppleIdentityAuthorization(
                    identityToken: token,
                    rawNonce: rawNonce,
                    onboardingDisplayNameSuggestion: onboardingSuggestion
                )
            )
        )
    }

    public func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        if let authorizationError = error as? ASAuthorizationError,
           authorizationError.code == .canceled {
            finish(with: .failure(AppleIdentityAuthorizationError.cancelled))
        } else {
            finish(with: .failure(AppleIdentityAuthorizationError.failed))
        }
    }
}

extension AppleIdentityAuthorizer: ASAuthorizationControllerPresentationContextProviding {
    public func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        presentationAnchor()
    }
}

public enum AppleIdentityAuthorizationError: Error, Equatable, Sendable {
    case requestAlreadyActive
    case secureRandomUnavailable
    case invalidCredential
    case cancelled
    case failed
}

extension AppleIdentityAuthorizationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .requestAlreadyActive:
            return "Apple sign-in is already open."
        case .secureRandomUnavailable:
            return "Apple sign-in could not start securely."
        case .invalidCredential, .failed:
            return "Apple sign-in could not be completed."
        case .cancelled:
            return "Apple sign-in was cancelled."
        }
    }
}
