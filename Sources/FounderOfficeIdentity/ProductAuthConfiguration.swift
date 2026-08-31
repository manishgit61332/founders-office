import Foundation

public struct ProductAuthConfiguration: Equatable, Sendable {
    public enum Environment: Equatable, Sendable {
        case production
        case localDevelopment
    }

    public static let endpointInfoKey = "FounderOfficeSupabaseURL"
    public static let publishableKeyInfoKey = "FounderOfficeSupabasePublishableKey"
    public static let callbackURLInfoKey = "FounderOfficeAuthCallbackURL"

    public let endpoint: URL
    public let publishableKey: String
    public let callbackURL: URL
    public let keychainService: String

    public init(
        endpoint: URL,
        publishableKey: String,
        callbackURL: URL,
        keychainService: String = "com.foundersoffice.product-auth",
        environment: Environment = .production
    ) throws {
        guard endpoint.user == nil,
              endpoint.password == nil,
              endpoint.query == nil,
              endpoint.fragment == nil else {
            throw ProductAuthConfigurationError.invalidEndpoint
        }

        switch environment {
        case .production:
            guard endpoint.scheme == "https", endpoint.host != nil else {
                throw ProductAuthConfigurationError.productionRequiresHTTPS
            }
        case .localDevelopment:
            guard ["http", "https"].contains(endpoint.scheme?.lowercased()),
                  let host = endpoint.host,
                  ["localhost", "127.0.0.1", "::1"].contains(host) else {
                throw ProductAuthConfigurationError.developmentRequiresLoopback
            }
        }

        let cleanKey = publishableKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isPublishableClientKey(cleanKey) else {
            throw ProductAuthConfigurationError.invalidPublishableKey
        }

        guard Self.isAllowedCallbackURL(callbackURL),
              callbackURL.user == nil,
              callbackURL.password == nil,
              callbackURL.query == nil,
              callbackURL.fragment == nil,
              !callbackURL.absoluteString.contains("$(") else {
            throw ProductAuthConfigurationError.invalidCallbackURL
        }

        let cleanService = keychainService.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanService.isEmpty else {
            throw ProductAuthConfigurationError.invalidKeychainService
        }

        self.endpoint = endpoint
        self.publishableKey = cleanKey
        self.callbackURL = callbackURL
        self.keychainService = cleanService
    }

    private static func isAllowedCallbackURL(_ callbackURL: URL) -> Bool {
        guard let scheme = callbackURL.scheme?.lowercased(),
              callbackURL.port == nil else { return false }

        switch scheme {
        case "founders-office", "founders-office-dev":
            return callbackURL.host?.lowercased() == "auth"
                && callbackURL.path == "/callback"
        default:
            // Supabase Swift's ASWebAuthenticationSession convenience API
            // completes by callback scheme. Universal links require a
            // separately reviewed associated-domain flow and must not be
            // accepted as if this client supported them.
            return false
        }
    }

    private static func isPublishableClientKey(_ key: String) -> Bool {
        guard !key.localizedCaseInsensitiveContains("placeholder"),
              !key.contains("$("),
              !key.hasPrefix("sb_secret_") else { return false }

        if key.hasPrefix("sb_publishable_") {
            return key.count >= 20
        }

        let components = key.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 3,
              let payload = decodeBase64URL(String(components[1])),
              let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              object["role"] as? String == "anon" else {
            return false
        }
        return true
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }

    /// Reads non-secret public client configuration. A missing or malformed
    /// configuration keeps Founder’s Office local-only instead of crashing.
    public static func load(
        infoDictionary: [String: Any],
        environment: Environment = .production
    ) -> Result<ProductAuthConfiguration, ProductAuthConfigurationError> {
        guard let endpointString = infoDictionary[endpointInfoKey] as? String,
              let publishableKey = infoDictionary[publishableKeyInfoKey] as? String,
              let callbackString = infoDictionary[callbackURLInfoKey] as? String else {
            return .failure(.missingConfiguration)
        }
        guard let endpoint = URL(string: endpointString),
              let callbackURL = URL(string: callbackString) else {
            return .failure(.malformedConfiguration)
        }

        do {
            return .success(
                try ProductAuthConfiguration(
                    endpoint: endpoint,
                    publishableKey: publishableKey,
                    callbackURL: callbackURL,
                    environment: environment
                )
            )
        } catch let error as ProductAuthConfigurationError {
            return .failure(error)
        } catch {
            return .failure(.malformedConfiguration)
        }
    }
}

public enum ProductAuthConfigurationError: Error, Equatable, Sendable {
    case missingConfiguration
    case malformedConfiguration
    case invalidEndpoint
    case productionRequiresHTTPS
    case developmentRequiresLoopback
    case invalidPublishableKey
    case invalidCallbackURL
    case invalidKeychainService
}

extension ProductAuthConfigurationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            return "Device sync is not configured in this build. Local-only mode is still available."
        case .malformedConfiguration, .invalidEndpoint:
            return "Device sync configuration is invalid. Local data was not changed."
        case .productionRequiresHTTPS:
            return "Production device sync requires a secure HTTPS endpoint."
        case .developmentRequiresLoopback:
            return "Local development sync may connect only to this device."
        case .invalidPublishableKey:
            return "The public sync key is missing or unsafe."
        case .invalidCallbackURL:
            return "This build does not have a reviewed sign-in callback. Your workspace stays on this Mac."
        case .invalidKeychainService:
            return "The secure session namespace is invalid."
        }
    }
}
