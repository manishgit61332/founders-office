import Foundation
import Security
import Supabase

/// The auth storage contract treats an absent item as a normal signed-out
/// state. Supabase 2.54.1's Keychain adapter instead throws for that status.
/// Interpret only errSecItemNotFound as absence; all other errors fail closed.
struct ProductKeychainStorage: AuthLocalStorage {
    let service: String
    private let access: any ProductKeychainAccess

    init(service: String, access: any ProductKeychainAccess = SystemProductKeychainAccess()) {
        self.service = service
        self.access = access
    }

    func retrieve(key: String) throws -> Data? {
        var query = baseQuery(key: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let result = access.read(query)
        if result.status == errSecItemNotFound { return nil }
        try requireSuccess(result.status)
        guard let data = result.data else {
            throw ProductKeychainError(status: errSecDecode)
        }
        return data
    }

    func store(key: String, value: Data) throws {
        let query = baseQuery(key: key)
        var attributes = query
        attributes[kSecValueData as String] = value
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = access.add(attributes)
        if status == errSecDuplicateItem {
            // Update in place: never delete a valid prior session before a
            // replacement write has succeeded.
            try requireSuccess(access.update(query, attributes: [kSecValueData as String: value]))
        } else {
            try requireSuccess(status)
        }
    }

    func remove(key: String) throws {
        let status = access.remove(baseQuery(key: key))
        if status != errSecItemNotFound { try requireSuccess(status) }
    }

    private func baseQuery(key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
    }

    private func requireSuccess(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw ProductKeychainError(status: status) }
    }
}

/// Contains only an OS status, never a key, token, account, or query.
struct ProductKeychainError: Error, Equatable {
    let status: OSStatus
}

struct ProductKeychainRead: Sendable {
    let status: OSStatus
    let data: Data?
}

protocol ProductKeychainAccess: Sendable {
    func read(_ query: [String: Any]) -> ProductKeychainRead
    func add(_ attributes: [String: Any]) -> OSStatus
    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus
    func remove(_ query: [String: Any]) -> OSStatus
}

struct SystemProductKeychainAccess: ProductKeychainAccess {
    func read(_ query: [String: Any]) -> ProductKeychainRead {
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        return ProductKeychainRead(status: status, data: value as? Data)
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    }

    func remove(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}
