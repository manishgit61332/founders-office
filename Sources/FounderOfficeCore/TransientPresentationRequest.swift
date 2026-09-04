import Foundation

/// Portable categories understood by native presentation adapters.
public enum TransientPresentationKind: String, Codable, CaseIterable, Sendable {
    case colorPanel
    case datePicker
    case menu
    case fileChooser
    case popover
    case inNotchEditor
    case systemAlert
}

/// Whether a transient stays inside the expanded surface or temporarily
/// collapses that surface while native UI is presented above it.
public enum TransientHostDisposition: String, Codable, CaseIterable, Sendable {
    case retainExpandedHost
    case suspendExpandedHost
}

public enum TransientPresentationRequestError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case unknownField(String)
}

/// A platform-neutral request for one transient presentation lease.
///
/// The request deliberately contains no AppKit, UIKit, WinUI, or Android UI
/// object. Native adapters retain ownership of their windows and controls.
/// Unknown fields and schema versions fail closed so a newer producer cannot
/// silently change popup lifecycle semantics on an older client.
public struct TransientPresentationRequest: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let kind: TransientPresentationKind
    public let hostDisposition: TransientHostDisposition

    public init(
        kind: TransientPresentationKind,
        hostDisposition: TransientHostDisposition
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.kind = kind
        self.hostDisposition = hostDisposition
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion
        case kind
        case hostDisposition
    }

    private struct AnyCodingKey: CodingKey {
        let stringValue: String
        let intValue: Int?

        init?(stringValue: String) {
            self.stringValue = stringValue
            intValue = nil
        }

        init?(intValue: Int) {
            stringValue = String(intValue)
            self.intValue = intValue
        }
    }

    public init(from decoder: any Decoder) throws {
        let dynamic = try decoder.container(keyedBy: AnyCodingKey.self)
        let allowed = Set(CodingKeys.allCases.map(\.rawValue))
        if let unknown = dynamic.allKeys
            .map(\.stringValue)
            .filter({ !allowed.contains($0) })
            .sorted()
            .first {
            throw TransientPresentationRequestError.unknownField(unknown)
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard decodedVersion == Self.currentSchemaVersion else {
            throw TransientPresentationRequestError.unsupportedSchemaVersion(decodedVersion)
        }
        schemaVersion = decodedVersion
        kind = try container.decode(TransientPresentationKind.self, forKey: .kind)
        hostDisposition = try container.decode(
            TransientHostDisposition.self,
            forKey: .hostDisposition
        )
    }
}
