import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct PersonalizationImageLimits: Equatable, Sendable {
    public static let maximumDisplayVariantBytes: Int64 = 12 * 1_024 * 1_024
    public static let maximumSyncVariantBytes: Int64 = 5 * 1_024 * 1_024
    public var maximumSourceBytes: Int64
    public var maximumSourceDimension: Int
    public var maximumSourcePixels: Int64
    public var maximumFrameCount: Int
    public var displayMaximumPixelSize: Int
    public var syncMaximumPixelSize: Int
    public var displayMaximumBytes: Int64
    public var syncMaximumBytes: Int64
    public var displayJPEGQuality: Double
    public var syncJPEGQuality: Double

    public init(
        maximumSourceBytes: Int64 = PersonalizationImageAsset.maximumSourceBytes,
        maximumSourceDimension: Int = PersonalizationImageAsset.maximumSourceDimension,
        maximumSourcePixels: Int64 = PersonalizationImageAsset.maximumSourcePixels,
        maximumFrameCount: Int = 256,
        displayMaximumPixelSize: Int = 1_600,
        syncMaximumPixelSize: Int = 960,
        displayMaximumBytes: Int64 = 8 * 1_024 * 1_024,
        syncMaximumBytes: Int64 = 3 * 1_024 * 1_024,
        displayJPEGQuality: Double = 0.82,
        syncJPEGQuality: Double = 0.76
    ) {
        self.maximumSourceBytes = maximumSourceBytes
        self.maximumSourceDimension = maximumSourceDimension
        self.maximumSourcePixels = maximumSourcePixels
        self.maximumFrameCount = maximumFrameCount
        self.displayMaximumPixelSize = displayMaximumPixelSize
        self.syncMaximumPixelSize = syncMaximumPixelSize
        self.displayMaximumBytes = displayMaximumBytes
        self.syncMaximumBytes = syncMaximumBytes
        self.displayJPEGQuality = displayJPEGQuality
        self.syncJPEGQuality = syncJPEGQuality
    }

    fileprivate var isValid: Bool {
        maximumSourceBytes > 0
            && maximumSourceBytes <= PersonalizationImageAsset.maximumSourceBytes
            && maximumSourceDimension > 0
            && maximumSourceDimension <= PersonalizationImageAsset.maximumSourceDimension
            && maximumSourcePixels > 0
            && maximumSourcePixels <= PersonalizationImageAsset.maximumSourcePixels
            && (1...256).contains(maximumFrameCount)
            && (64...2_048).contains(displayMaximumPixelSize)
            && (64...displayMaximumPixelSize).contains(syncMaximumPixelSize)
            && displayMaximumBytes > 0
            && displayMaximumBytes <= Self.maximumDisplayVariantBytes
            && syncMaximumBytes > 0
            && syncMaximumBytes <= Self.maximumSyncVariantBytes
            && (0...1).contains(displayJPEGQuality)
            && (0...1).contains(syncJPEGQuality)
    }
}

public enum PersonalizationImageStoreError: Error, Equatable, Sendable {
    case invalidConfiguration
    case invalidSource
    case unsupportedFormat
    case sourceTooLarge
    case unsafeDimensions
    case tooManyFrames
    case corruptImage
    case variantEncodingFailed
    case variantTooLarge
    case invalidAsset
    case originalUnavailable
    case operationInProgress
    case canonicalChanged
    case storageFailure
}

public struct PersonalizationImageReplacement<Value: Sendable>: Sendable {
    public let asset: PersonalizationImageAsset
    public let commitValue: Value
    /// Cleanup is retried by launch reconciliation. It never rolls back a
    /// canonical commit that already succeeded.
    public let cleanupNeeded: Bool
}

public struct PersonalizationImageRemoval<Value: Sendable>: Sendable {
    public let commitValue: Value
    public let cleanupNeeded: Bool
}

public struct PersonalizationImageReconciliation: Equatable, Sendable {
    public let removedFileCount: Int
    public let removedStagingDirectoryCount: Int
    public let failureCount: Int
}

/// Owns local vision-image files and their bounded variants.
///
/// This actor never loads the source bytes into `Data` and never constructs an
/// `NSImage` from the original. ImageIO reads metadata without caching, then
/// creates transformed thumbnails capped before decoding. Original bytes are
/// copied as a file and are reachable only through `exportOriginal`.
public actor PersonalizationImageStore {
    private let rootURL: URL
    private let limits: PersonalizationImageLimits
    private var transactionInProgress = false
    private var protectedFileNames: Set<String> = []
    #if DEBUG || FOUNDER_OFFICE_TESTING
    private let testingBeforeCommit: (@Sendable () async -> Void)?
    #endif

    public init(rootURL: URL, limits: PersonalizationImageLimits = PersonalizationImageLimits()) {
        self.rootURL = rootURL.standardizedFileURL
        self.limits = limits
        #if DEBUG || FOUNDER_OFFICE_TESTING
        testingBeforeCommit = nil
        #endif
    }

    #if DEBUG || FOUNDER_OFFICE_TESTING
    init(
        rootURL: URL,
        limits: PersonalizationImageLimits = PersonalizationImageLimits(),
        testingBeforeCommit: @escaping @Sendable () async -> Void
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.limits = limits
        self.testingBeforeCommit = testingBeforeCommit
    }
    #endif

    public func replace<Value: Sendable>(
        sourceURL: URL,
        currentAsset: PersonalizationImageAsset?,
        currentLegacyFileName: String?,
        assetID: UUID = UUID(),
        importedAt: Date = Date(),
        commit: @escaping @Sendable (PersonalizationImageAsset) async throws -> Value
    ) async throws -> PersonalizationImageReplacement<Value> {
        guard limits.isValid else { throw PersonalizationImageStoreError.invalidConfiguration }
        guard !transactionInProgress else { throw PersonalizationImageStoreError.operationInProgress }
        transactionInProgress = true
        defer { transactionInProgress = false }

        let prepared = try prepare(sourceURL: sourceURL, assetID: assetID, importedAt: importedAt)
        let newFileNames = Set(prepared.asset.ownedFileNames)
        protectedFileNames.formUnion(newFileNames)
        defer { protectedFileNames.subtract(newFileNames) }

        do {
            try activate(prepared)
        } catch {
            discardStagingDirectory(prepared.stagingDirectoryURL)
            throw mapStorageError(error)
        }

        do {
            #if DEBUG || FOUNDER_OFFICE_TESTING
            await testingBeforeCommit?()
            #endif
            let commitValue = try await commit(prepared.asset)
            let cleanupNeeded = !retire(
                asset: currentAsset,
                legacyFileName: currentLegacyFileName,
                excluding: newFileNames
            )
            return PersonalizationImageReplacement(
                asset: prepared.asset,
                commitValue: commitValue,
                cleanupNeeded: cleanupNeeded
            )
        } catch {
            _ = retire(asset: prepared.asset, legacyFileName: nil, excluding: [])
            throw error
        }
    }

    /// Commits removal first, then retires every app-owned variant. A commit
    /// failure preserves the canonical image and all of its files.
    public func remove<Value: Sendable>(
        currentAsset: PersonalizationImageAsset?,
        currentLegacyFileName: String?,
        commit: @escaping @Sendable () async throws -> Value
    ) async throws -> PersonalizationImageRemoval<Value> {
        guard !transactionInProgress else { throw PersonalizationImageStoreError.operationInProgress }
        transactionInProgress = true
        defer { transactionInProgress = false }

        let commitValue = try await commit()
        let cleanupNeeded = !retire(
            asset: currentAsset,
            legacyFileName: currentLegacyFileName,
            excluding: []
        )
        return PersonalizationImageRemoval(
            commitValue: commitValue,
            cleanupNeeded: cleanupNeeded
        )
    }

    /// Copies exact original bytes only after an explicit user export action.
    public func exportOriginal(
        asset: PersonalizationImageAsset,
        to destinationURL: URL
    ) throws {
        guard try validate(asset: asset) else {
            throw PersonalizationImageStoreError.invalidAsset
        }
        let sourceURL = try ownedURL(for: asset.originalFileName)
        guard FileManager.default.fileExists(atPath: sourceURL.path) else {
            throw PersonalizationImageStoreError.originalUnavailable
        }

        let parent = destinationURL.deletingLastPathComponent().standardizedFileURL
        guard destinationURL.standardizedFileURL != sourceURL.standardizedFileURL else {
            throw PersonalizationImageStoreError.storageFailure
        }
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let temporaryURL = parent.appendingPathComponent(".founders-office-export-\(UUID().uuidString.lowercased())")
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            try FileManager.default.copyItem(at: sourceURL, to: temporaryURL)
            try setPrivateFilePermissions(at: temporaryURL)
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                _ = try FileManager.default.replaceItemAt(destinationURL, withItemAt: temporaryURL)
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
            }
        } catch let error as PersonalizationImageStoreError {
            throw error
        } catch {
            throw PersonalizationImageStoreError.storageFailure
        }
    }

    /// Removes only strict app-owned or stale staging entries. A legacy image
    /// with a user-controlled basename is never swept.
    public func reconcile(
        referencedAsset: PersonalizationImageAsset?,
        referencedLegacyFileName: String?
    ) -> PersonalizationImageReconciliation {
        do {
            try ensureRootDirectory()
        } catch {
            return PersonalizationImageReconciliation(
                removedFileCount: 0,
                removedStagingDirectoryCount: 0,
                failureCount: 1
            )
        }

        var protected = protectedFileNames
        var protectedStemPrefixes: Set<String> = []
        if let referencedAsset, (try? validate(asset: referencedAsset)) == true {
            protected.formUnion(referencedAsset.ownedFileNames)
        }
        if let referencedLegacyFileName {
            if let legacy = AssetFileName.validatedLegacyVisionAsset(referencedLegacyFileName) {
                protected.insert(legacy)
            } else if let stem = Self.ownedVariantStemPrefix(referencedLegacyFileName) {
                // An older client can retain the bounded display compatibility
                // field while dropping optional v1 metadata. Preserve every
                // sibling so that situation never destroys a local original.
                protectedStemPrefixes.insert(stem)
            }
        }

        var removedFiles = 0
        var removedStages = 0
        var failures = 0
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsSubdirectoryDescendants]
            )
        } catch {
            return PersonalizationImageReconciliation(
                removedFileCount: 0,
                removedStagingDirectoryCount: 0,
                failureCount: 1
            )
        }

        for entry in entries {
            let name = entry.lastPathComponent
            if name.hasPrefix(Self.stagingPrefix) {
                do {
                    try FileManager.default.removeItem(at: entry)
                    removedStages += 1
                } catch {
                    failures += 1
                }
                continue
            }
            guard Self.isOwnedVariantFileName(name),
                  !protected.contains(name),
                  !protectedStemPrefixes.contains(where: { name.hasPrefix("\($0)-") }) else { continue }
            do {
                try FileManager.default.removeItem(at: entry)
                removedFiles += 1
            } catch {
                failures += 1
            }
        }
        return PersonalizationImageReconciliation(
            removedFileCount: removedFiles,
            removedStagingDirectoryCount: removedStages,
            failureCount: failures
        )
    }

    public nonisolated static func isOwnedVariantFileName(_ value: String) -> Bool {
        guard let value = AssetFileName.validated(value) else { return false }
        let nsValue = value as NSString
        let stem = nsValue.deletingPathExtension
        let components = stem.split(separator: "-")
        // vision + five UUID components + role
        guard components.count == 7, components[0] == "vision" else { return false }
        let role = components[6]
        guard role == "original" || role == "display" || role == "sync" else { return false }
        let uuidText = components[1...5].joined(separator: "-")
        guard UUID(uuidString: uuidText) != nil else { return false }
        if role == "display" || role == "sync" {
            return nsValue.pathExtension.lowercased() == "jpg"
        }
        return AssetFileName.isSupportedImageExtension(nsValue.pathExtension)
    }

    private nonisolated static func ownedVariantStemPrefix(_ value: String) -> String? {
        guard isOwnedVariantFileName(value) else { return nil }
        let stem = (value as NSString).deletingPathExtension
        guard let roleSeparator = stem.lastIndex(of: "-") else { return nil }
        return String(stem[..<roleSeparator])
    }

    private struct PreparedImage {
        let asset: PersonalizationImageAsset
        let stagingDirectoryURL: URL
    }

    private struct SourceMetadata {
        let fileExtension: String
        let byteCount: Int64
        let pixelWidth: Int
        let pixelHeight: Int
    }

    private static let stagingPrefix = ".vision-stage-"
    private func prepare(sourceURL: URL, assetID: UUID, importedAt: Date) throws -> PreparedImage {
        try ensureRootDirectory()
        let values: URLResourceValues
        do {
            values = try sourceURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey
            ])
        } catch {
            throw PersonalizationImageStoreError.invalidSource
        }
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let sourceBytes = values.fileSize, sourceBytes > 0 else {
            throw PersonalizationImageStoreError.invalidSource
        }
        guard Int64(sourceBytes) <= limits.maximumSourceBytes else {
            throw PersonalizationImageStoreError.sourceTooLarge
        }

        let stagingDirectoryURL = rootURL.appendingPathComponent(
            "\(Self.stagingPrefix)\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: stagingDirectoryURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw PersonalizationImageStoreError.storageFailure
        }

        do {
            let stagingOriginalURL = stagingDirectoryURL.appendingPathComponent("source")
            try FileManager.default.copyItem(at: sourceURL, to: stagingOriginalURL)
            try setPrivateFilePermissions(at: stagingOriginalURL)
            let metadata = try inspectSource(at: stagingOriginalURL)
            let asset = try PersonalizationImageAsset(
                id: assetID,
                originalFileExtension: metadata.fileExtension,
                originalByteCount: metadata.byteCount,
                pixelWidth: metadata.pixelWidth,
                pixelHeight: metadata.pixelHeight,
                importedAt: importedAt
            )

            let namedOriginalURL = stagingDirectoryURL.appendingPathComponent(asset.originalFileName)
            try FileManager.default.moveItem(at: stagingOriginalURL, to: namedOriginalURL)
            try renderVariant(
                from: namedOriginalURL,
                to: stagingDirectoryURL.appendingPathComponent(asset.displayFileName),
                maximumPixelSize: limits.displayMaximumPixelSize,
                maximumBytes: limits.displayMaximumBytes,
                quality: limits.displayJPEGQuality
            )
            try renderVariant(
                from: namedOriginalURL,
                to: stagingDirectoryURL.appendingPathComponent(asset.syncFileName),
                maximumPixelSize: limits.syncMaximumPixelSize,
                maximumBytes: limits.syncMaximumBytes,
                quality: limits.syncJPEGQuality
            )
            return PreparedImage(asset: asset, stagingDirectoryURL: stagingDirectoryURL)
        } catch {
            discardStagingDirectory(stagingDirectoryURL)
            if let imageError = error as? PersonalizationImageStoreError { throw imageError }
            if error is PersonalizationImageAssetError {
                throw PersonalizationImageStoreError.unsafeDimensions
            }
            throw PersonalizationImageStoreError.storageFailure
        }
    }

    private func inspectSource(at url: URL) throws -> SourceMetadata {
        let byteCount: Int64
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            guard let fileSize = values.fileSize, fileSize > 0 else {
                throw PersonalizationImageStoreError.invalidSource
            }
            byteCount = Int64(fileSize)
        } catch let error as PersonalizationImageStoreError {
            throw error
        } catch {
            throw PersonalizationImageStoreError.invalidSource
        }
        guard byteCount <= limits.maximumSourceBytes else {
            throw PersonalizationImageStoreError.sourceTooLarge
        }
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            throw PersonalizationImageStoreError.corruptImage
        }
        let frameCount = CGImageSourceGetCount(source)
        guard frameCount > 0 else { throw PersonalizationImageStoreError.corruptImage }
        guard frameCount <= limits.maximumFrameCount else {
            throw PersonalizationImageStoreError.tooManyFrames
        }
        guard let typeIdentifier = CGImageSourceGetType(source) as String?,
              let type = UTType(typeIdentifier),
              type.conforms(to: .image),
              let fileExtension = Self.safeExtension(for: type) else {
            throw PersonalizationImageStoreError.unsupportedFormat
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions) as? [CFString: Any],
              let width = Self.positiveInteger(properties[kCGImagePropertyPixelWidth]),
              let height = Self.positiveInteger(properties[kCGImagePropertyPixelHeight]) else {
            throw PersonalizationImageStoreError.corruptImage
        }
        guard width <= limits.maximumSourceDimension, height <= limits.maximumSourceDimension else {
            throw PersonalizationImageStoreError.unsafeDimensions
        }
        let (pixelCount, overflow) = Int64(width).multipliedReportingOverflow(by: Int64(height))
        guard !overflow, pixelCount <= limits.maximumSourcePixels else {
            throw PersonalizationImageStoreError.unsafeDimensions
        }
        return SourceMetadata(
            fileExtension: fileExtension,
            byteCount: byteCount,
            pixelWidth: width,
            pixelHeight: height
        )
    }

    private func renderVariant(
        from sourceURL: URL,
        to destinationURL: URL,
        maximumPixelSize: Int,
        maximumBytes: Int64,
        quality: Double
    ) throws {
        try autoreleasepool {
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, sourceOptions) else {
                throw PersonalizationImageStoreError.corruptImage
            }
            let options = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCache: false,
                kCGImageSourceShouldCacheImmediately: false,
                kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
            ] as CFDictionary
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
                throw PersonalizationImageStoreError.corruptImage
            }
            guard thumbnail.width <= maximumPixelSize, thumbnail.height <= maximumPixelSize else {
                throw PersonalizationImageStoreError.variantEncodingFailed
            }
            guard let destination = CGImageDestinationCreateWithURL(
                destinationURL as CFURL,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            ) else {
                throw PersonalizationImageStoreError.variantEncodingFailed
            }
            let properties = [
                kCGImageDestinationLossyCompressionQuality: quality,
                kCGImagePropertyOrientation: 1
            ] as CFDictionary
            CGImageDestinationAddImage(destination, thumbnail, properties)
            guard CGImageDestinationFinalize(destination) else {
                throw PersonalizationImageStoreError.variantEncodingFailed
            }
        }
        try setPrivateFilePermissions(at: destinationURL)
        do {
            let outputValues = try destinationURL.resourceValues(forKeys: [.fileSizeKey])
            guard let byteCount = outputValues.fileSize,
                  byteCount > 0,
                  Int64(byteCount) <= maximumBytes else {
                throw PersonalizationImageStoreError.variantTooLarge
            }
        } catch let error as PersonalizationImageStoreError {
            throw error
        } catch {
            throw PersonalizationImageStoreError.storageFailure
        }
    }

    private func activate(_ prepared: PreparedImage) throws {
        var activated: [URL] = []
        do {
            for name in prepared.asset.ownedFileNames {
                guard Self.isOwnedVariantFileName(name) else {
                    throw PersonalizationImageStoreError.invalidAsset
                }
                let sourceURL = prepared.stagingDirectoryURL.appendingPathComponent(name)
                let destinationURL = try ownedURL(for: name)
                guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
                    throw PersonalizationImageStoreError.storageFailure
                }
                try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
                activated.append(destinationURL)
            }
            try FileManager.default.removeItem(at: prepared.stagingDirectoryURL)
        } catch {
            for url in activated { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }

    @discardableResult
    private func retire(
        asset: PersonalizationImageAsset?,
        legacyFileName: String?,
        excluding excluded: Set<String>
    ) -> Bool {
        var names: Set<String> = []
        if let asset, (try? validate(asset: asset)) == true {
            names.formUnion(asset.ownedFileNames)
        }
        if let legacyFileName,
           let legacy = AssetFileName.validatedLegacyVisionAsset(legacyFileName) {
            names.insert(legacy)
        } else if let legacyFileName,
                  let stem = Self.ownedVariantStemPrefix(legacyFileName) {
            do {
                let entries = try FileManager.default.contentsOfDirectory(atPath: rootURL.path)
                names.formUnion(entries.filter {
                    $0.hasPrefix("\(stem)-") && Self.isOwnedVariantFileName($0)
                })
            } catch {
                return false
            }
        }
        names.subtract(excluded)

        var succeeded = true
        for name in names {
            do {
                let url = try ownedURL(for: name)
                if FileManager.default.fileExists(atPath: url.path) {
                    try FileManager.default.removeItem(at: url)
                }
            } catch {
                succeeded = false
            }
        }
        return succeeded
    }

    private func validate(asset: PersonalizationImageAsset) throws -> Bool {
        let encoded = try JSONEncoder().encode(asset)
        let decoded = try JSONDecoder().decode(PersonalizationImageAsset.self, from: encoded)
        return decoded == asset && asset.ownedFileNames.allSatisfy(Self.isOwnedVariantFileName)
    }

    private func ensureRootDirectory() throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: rootURL.path) {
            let values = try rootURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw PersonalizationImageStoreError.storageFailure
            }
        } else {
            try manager.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }

    private func ownedURL(for fileName: String) throws -> URL {
        guard AssetFileName.validated(fileName) == fileName else {
            throw PersonalizationImageStoreError.invalidAsset
        }
        let url = rootURL.appendingPathComponent(fileName, isDirectory: false).standardizedFileURL
        guard url.deletingLastPathComponent() == rootURL else {
            throw PersonalizationImageStoreError.invalidAsset
        }
        return url
    }

    private func discardStagingDirectory(_ url: URL) {
        guard url.deletingLastPathComponent().standardizedFileURL == rootURL,
              url.lastPathComponent.hasPrefix(Self.stagingPrefix) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private func setPrivateFilePermissions(at url: URL) throws {
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw PersonalizationImageStoreError.storageFailure
        }
    }

    private func mapStorageError(_ error: Error) -> Error {
        if error is PersonalizationImageStoreError { return error }
        return PersonalizationImageStoreError.storageFailure
    }

    private nonisolated static func positiveInteger(_ value: Any?) -> Int? {
        if let value = value as? NSNumber {
            let number = value.int64Value
            guard number > 0, number <= Int64(Int.max) else { return nil }
            return Int(number)
        }
        return nil
    }

    private nonisolated static func safeExtension(for type: UTType) -> String? {
        let preferred = type.preferredFilenameExtension?.lowercased()
        if let preferred, AssetFileName.isSupportedImageExtension(preferred) {
            return preferred == "jpeg" ? "jpg" : preferred
        }
        if type.conforms(to: .jpeg) { return "jpg" }
        if type.conforms(to: .png) { return "png" }
        if type.conforms(to: .tiff) { return "tiff" }
        if type.conforms(to: .gif) { return "gif" }
        if #available(macOS 11.0, iOS 14.0, *), type.conforms(to: .heic) { return "heic" }
        return nil
    }
}
