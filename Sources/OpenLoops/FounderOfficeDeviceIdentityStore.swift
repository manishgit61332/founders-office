import Foundation
import FounderOfficeCore

/// Persists one opaque, non-secret device identifier per installation. It is
/// never used as an authentication credential and contains no hardware serial,
/// account identifier, or customer content.
enum FounderOfficeDeviceIdentityStore {
    static let defaultsKey = "FounderOfficeDeviceID.v1"

    static func loadOrCreate(defaults: UserDefaults = .standard) -> DeviceID {
        if let stored = defaults.string(forKey: defaultsKey),
           let identifier = UUID(uuidString: stored) {
            return DeviceID(rawValue: identifier)
        }

        let created = DeviceID(rawValue: UUID())
        defaults.set(created.rawValue.uuidString.lowercased(), forKey: defaultsKey)
        return created
    }
}
