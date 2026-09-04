import Foundation
import Security
import Testing
@testable import FounderOfficeIdentity

@Suite("Product Keychain storage")
struct ProductKeychainStorageTests {
    @Test("An empty Keychain is signed out, not a secure-storage failure")
    func absentItemIsNormal() throws {
        let storage = ProductKeychainStorage(service: "test", access: StubKeychain())
        let verified = VerifiedProductAuthStorage(storage: storage, sessionKey: "session")
        #expect(try verified.retrieve(key: "session") == nil)
        try verified.verifyNoRecordedFailure()
        try verified.verifySessionRemoved()
        try verified.remove(key: "session")
        try verified.remove(key: "session")
        try verified.verifySessionRemoved()
    }

    @Test("Real read and delete failures are never treated as missing", arguments: [
        errSecInteractionNotAllowed, errSecAuthFailed, errSecNotAvailable,
        errSecDecode, errSecMissingEntitlement
    ])
    func accessFailuresStayClosed(status: OSStatus) throws {
        let access = StubKeychain(readStatus: status, deleteStatus: status)
        let storage = ProductKeychainStorage(service: "test", access: access)
        #expect(throws: ProductKeychainError(status: status)) {
            _ = try storage.retrieve(key: "session")
        }
        #expect(throws: ProductKeychainError(status: status)) {
            try storage.remove(key: "session")
        }
        let verified = VerifiedProductAuthStorage(storage: storage, sessionKey: "session")
        #expect(throws: ProductKeychainError(status: status)) {
            _ = try verified.retrieve(key: "session")
        }
        #expect(throws: ProductAuthSecureStorageError.readFailed) {
            try verified.verifyNoRecordedFailure()
        }
    }

    @Test("A successful read without data is corrupt, not signed out")
    func missingSuccessfulPayloadIsCorrupt() {
        let storage = ProductKeychainStorage(
            service: "test", access: StubKeychain(readStatus: errSecSuccess)
        )
        #expect(throws: ProductKeychainError(status: errSecDecode)) {
            _ = try storage.retrieve(key: "session")
        }
    }

    @Test("Replacement writes update existing items and preserve update errors")
    func duplicateWriteUsesUpdate() throws {
        let storage = ProductKeychainStorage(service: "test", access: StubKeychain(
            addStatus: errSecDuplicateItem, updateStatus: errSecSuccess
        ))
        try storage.store(key: "session", value: Data([1]))

        let failed = ProductKeychainStorage(service: "test", access: StubKeychain(
            addStatus: errSecDuplicateItem, updateStatus: errSecInteractionNotAllowed
        ))
        #expect(throws: ProductKeychainError(status: errSecInteractionNotAllowed)) {
            try failed.store(key: "session", value: Data([2]))
        }
    }

    @Test("Add failures are not converted to updates or success")
    func addFailureIsPreserved() {
        let storage = ProductKeychainStorage(service: "test", access: StubKeychain(
            addStatus: errSecAuthFailed, updateStatus: errSecSuccess
        ))
        #expect(throws: ProductKeychainError(status: errSecAuthFailed)) {
            try storage.store(key: "session", value: Data([1]))
        }
    }

    @Test("Real Keychain supports fresh sessions, updates, namespace isolation, and repeated sign-out")
    func nativeKeychainRoundTrip() throws {
        let namespace = "com.foundersoffice.tests.\(UUID().uuidString)"
        let storage = ProductKeychainStorage(service: namespace)
        let other = ProductKeychainStorage(service: namespace + ".other")
        // Only this test's random namespace is ever read or removed.
        defer { try? storage.remove(key: "session") }
        #expect(try storage.retrieve(key: "session") == nil)
        try storage.remove(key: "session")
        try storage.store(key: "session", value: Data([1, 2, 3]))
        #expect(try storage.retrieve(key: "session") == Data([1, 2, 3]))
        #expect(try other.retrieve(key: "session") == nil)
        try storage.store(key: "session", value: Data([4, 5]))
        #expect(try storage.retrieve(key: "session") == Data([4, 5]))
        try storage.remove(key: "session")
        try storage.remove(key: "session")
        #expect(try storage.retrieve(key: "session") == nil)
    }
}

private struct StubKeychain: ProductKeychainAccess {
    var readStatus: OSStatus = errSecItemNotFound
    var addStatus: OSStatus = errSecSuccess
    var updateStatus: OSStatus = errSecSuccess
    var deleteStatus: OSStatus = errSecItemNotFound

    func read(_ query: [String: Any]) -> ProductKeychainRead {
        #expect(query[kSecAttrService as String] as? String == "test")
        #expect(query[kSecAttrAccount as String] as? String == "session")
        return ProductKeychainRead(status: readStatus, data: nil)
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        #expect(attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        return addStatus
    }

    func update(_ query: [String: Any], attributes: [String: Any]) -> OSStatus {
        #expect(query[kSecAttrService as String] as? String == "test")
        #expect(query[kSecAttrAccount as String] as? String == "session")
        #expect(Set(attributes.keys) == [kSecValueData as String])
        return updateStatus
    }

    func remove(_ query: [String: Any]) -> OSStatus {
        #expect(query[kSecAttrService as String] as? String == "test")
        #expect(query[kSecAttrAccount as String] as? String == "session")
        return deleteStatus
    }
}
