import Foundation

/// Metadata for one app-owned vision image.
///
/// Filenames are derived from an opaque UUID instead of accepted from a cloud
/// payload. The original is local-only and is read solely by explicit export.
/// Display and sync consumers use separate bounded JPEG variants.
public struct PersonalizationImageAsset: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let maximumSourceBytes: Int64 = 96 * 1_024 * 1_024
    public static let maximumSourceDimension = 32_768
    public static let maximumSourcePixels: Int64 = 120_000_000

    public let schemaVersion: Int
    public let id: UUID
    public let originalFileExtension: String
    public let originalByteCount: Int64
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let importedAt: Date

    public init(
        schemaVersion: Int = PersonalizationImageAsset.currentSchemaVersion,
        id: UUID,
        originalFileExtension: String,
        originalByteCount: Int64,
        pixelWidth: Int,
        pixelHeight: Int,
        importedAt: Date
    ) throws {
        let normalizedExtension = originalFileExtension.lowercased()
        guard schemaVersion == Self.currentSchemaVersion,
              AssetFileName.isSupportedImageExtension(normalizedExtension),
              originalByteCount > 0,
              originalByteCount <= Self.maximumSourceBytes,
              pixelWidth > 0,
              pixelHeight > 0,
              pixelWidth <= Self.maximumSourceDimension,
              pixelHeight <= Self.maximumSourceDimension,
              importedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw PersonalizationImageAssetError.invalidMetadata
        }
        let (pixels, overflow) = Int64(pixelWidth).multipliedReportingOverflow(by: Int64(pixelHeight))
        guard !overflow, pixels <= Self.maximumSourcePixels else {
            throw PersonalizationImageAssetError.invalidMetadata
        }

        self.schemaVersion = schemaVersion
        self.id = id
        self.originalFileExtension = normalizedExtension
        self.originalByteCount = originalByteCount
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.importedAt = importedAt
    }

    public var originalFileName: String {
        "\(fileStem)-original.\(originalFileExtension)"
    }

    public var displayFileName: String {
        "\(fileStem)-display.jpg"
    }

    public var syncFileName: String {
        "\(fileStem)-sync.jpg"
    }

    public var ownedFileNames: [String] {
        [originalFileName, displayFileName, syncFileName]
    }

    private var fileStem: String {
        "vision-\(id.uuidString.lowercased())"
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id
        case originalFileExtension
        case originalByteCount
        case pixelWidth
        case pixelHeight
        case importedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: values.decode(Int.self, forKey: .schemaVersion),
            id: values.decode(UUID.self, forKey: .id),
            originalFileExtension: values.decode(String.self, forKey: .originalFileExtension),
            originalByteCount: values.decode(Int64.self, forKey: .originalByteCount),
            pixelWidth: values.decode(Int.self, forKey: .pixelWidth),
            pixelHeight: values.decode(Int.self, forKey: .pixelHeight),
            importedAt: values.decode(Date.self, forKey: .importedAt)
        )
    }
}

public enum PersonalizationImageAssetError: Error, Equatable, Sendable {
    case invalidMetadata
}
