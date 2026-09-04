import Foundation
import Testing
@testable import OpenLoops

@Suite("Opaque device identity")
struct FounderOfficeDeviceIdentityStoreTests {
    @Test("Device identity is stable and contains no hardware or account data")
    func persistsOpaqueIdentifier() throws {
        let suite = "FounderOfficeDeviceIdentityStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = FounderOfficeDeviceIdentityStore.loadOrCreate(defaults: defaults)
        let second = FounderOfficeDeviceIdentityStore.loadOrCreate(defaults: defaults)

        #expect(first == second)
        #expect(
            defaults.string(forKey: FounderOfficeDeviceIdentityStore.defaultsKey)
                == first.rawValue.uuidString.lowercased()
        )
    }

    @Test("Malformed persisted identity is replaced without exposing it")
    func replacesMalformedValue() throws {
        let suite = "FounderOfficeDeviceIdentityStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("not-a-device-id", forKey: FounderOfficeDeviceIdentityStore.defaultsKey)

        let recovered = FounderOfficeDeviceIdentityStore.loadOrCreate(defaults: defaults)

        #expect(
            defaults.string(forKey: FounderOfficeDeviceIdentityStore.defaultsKey)
                == recovered.rawValue.uuidString.lowercased()
        )
    }
}
