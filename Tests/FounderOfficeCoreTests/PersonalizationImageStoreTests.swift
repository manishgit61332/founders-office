import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import FounderOfficeCore

struct PersonalizationImageStoreTests {
    @Test
    func createsBoundedDisplayAndSyncVariantsWithoutChangingOriginalBytes() async throws {
        let fixture = try ImageFixture()
        defer { fixture.remove() }
        let sourceURL = fixture.root.appendingPathComponent("chosen-photo.jpg")
        try fixture.writeJPEG(width: 2_048, height: 1_024, to: sourceURL)
        let originalBytes = try Data(contentsOf: sourceURL)
        let store = PersonalizationImageStore(rootURL: fixture.assets)

        let replacement = try await store.replace(
            sourceURL: sourceURL,
            currentAsset: nil,
            currentLegacyFileName: nil
        ) { asset in
            #expect(FileManager.default.fileExists(atPath: fixture.assets.appendingPathComponent(asset.originalFileName).path))
            return asset.id
        }

        #expect(replacement.commitValue == replacement.asset.id)
        #expect(!replacement.cleanupNeeded)
        #expect(try fixture.dimensions(of: fixture.assets.appendingPathComponent(replacement.asset.displayFileName)) == PixelSize(width: 1_600, height: 800))
        #expect(try fixture.dimensions(of: fixture.assets.appendingPathComponent(replacement.asset.syncFileName)) == PixelSize(width: 960, height: 480))
        #expect(try Data(contentsOf: fixture.assets.appendingPathComponent(replacement.asset.originalFileName)) == originalBytes)
    }

    @Test
    func rejectsHugeDeclaredDimensionsBeforeCreatingAnyOwnedVariant() async throws {
        let fixture = try ImageFixture()
        defer { fixture.remove() }
        let sourceURL = fixture.root.appendingPathComponent("oversized.jpg")
        try fixture.writeJPEG(width: 2_048, height: 1_024, to: sourceURL)
        let store = PersonalizationImageStore(
            rootURL: fixture.assets,
            limits: PersonalizationImageLimits(
                maximumSourceDimension: 1_024,
                maximumSourcePixels: 1_048_576
            )
        )

        do {
            _ = try await store.replace(
                sourceURL: sourceURL,
                currentAsset: nil,
                currentLegacyFileName: nil
            ) { _ in true }
            Issue.record("Expected unsafe image dimensions to be rejected")
        } catch let error as PersonalizationImageStoreError {
            #expect(error == .unsafeDimensions)
        }

        #expect(try fixture.assetEntries().isEmpty)
    }

    @Test
    func metadataModelRejectsDecompressionBombDimensions() {
        #expect(throws: PersonalizationImageAssetError.invalidMetadata) {
            try PersonalizationImageAsset(
                id: UUID(),
                originalFileExtension: "jpg",
                originalByteCount: 1_024,
                pixelWidth: 50_000,
                pixelHeight: 50_000,
                importedAt: Date()
            )
        }
    }

    @Test
    func oldPersonalizationDocumentsDecodeWithoutAnImageManifest() throws {
        let data = Data(#"{"schemaVersion":6,"displayName":"Founder's Office","accent":"blue","milestones":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(PersonalizationDocument.self, from: data)
        #expect(decoded.visionImageAsset == nil)
        #expect(decoded.resolvedPhotoFileName == nil)
    }

    @Test
    func corruptInputFailsWithoutAStagingOrFinalFile() async throws {
        let fixture = try ImageFixture()
        defer { fixture.remove() }
        let sourceURL = fixture.root.appendingPathComponent("not-an-image.jpg")
        try Data("not an image".utf8).write(to: sourceURL)
        let store = PersonalizationImageStore(rootURL: fixture.assets)

        do {
            _ = try await store.replace(
                sourceURL: sourceURL,
                currentAsset: nil,
                currentLegacyFileName: nil
            ) { _ in true }
            Issue.record("Expected corrupt input to fail")
        } catch let error as PersonalizationImageStoreError {
            #expect(error == .corruptImage)
        }

        #expect(try fixture.assetEntries().isEmpty)
    }

    @Test
    func outputCapsCannotBeConfiguredAboveReviewedBounds() async throws {
        let fixture = try ImageFixture()
        defer { fixture.remove() }
        let oversizedDisplay = PersonalizationImageStore(
            rootURL: fixture.assets,
            limits: PersonalizationImageLimits(
                displayMaximumBytes: PersonalizationImageLimits.maximumDisplayVariantBytes + 1
            )
        )
        let oversizedSync = PersonalizationImageStore(
            rootURL: fixture.assets,
            limits: PersonalizationImageLimits(
                syncMaximumBytes: PersonalizationImageLimits.maximumSyncVariantBytes + 1
            )
        )

        for store in [oversizedDisplay, oversizedSync] {
            do {
                _ = try await store.replace(
                    sourceURL: fixture.root.appendingPathComponent("missing.jpg"),
                    currentAsset: nil,
                    currentLegacyFileName: nil
                ) { _ in true }
                Issue.record("Expected an invalid output cap to fail closed")
            } catch let error as PersonalizationImageStoreError {
                #expect(error == .invalidConfiguration)
            }
        }
    }

    @Test
    func sparseSourceAboveFileLimitIsRejectedBeforeImageParsing() async throws {
        let fixture = try ImageFixture()
        defer { fixture.remove() }
        let sourceURL = fixture.root.appendingPathComponent("oversized.jpg")
        #expect(FileManager.default.createFile(atPath: sourceURL.path, contents: nil))
        let handle = try FileHandle(forWritingTo: sourceURL)
        try handle.truncate(atOffset: UInt64(PersonalizationImageAsset.maximumSourceBytes + 1))
        try handle.close()
        let store = PersonalizationImageStore(rootURL: fixture.assets)

        do {
            _ = try await store.replace(
                sourceURL: sourceURL,
                currentAsset: nil,
                currentLegacyFileName: nil
            ) { _ in true }
            Issue.record("Expected the source file cap to fail closed")
        } catch let error as PersonalizationImageStoreError {
            #expect(error == .sourceTooLarge)
        }
        #expect(try fixture.assetEntries().isEmpty)
    }

    @Test
    func repositoryFailureRollsBackEveryNewFileAndKeepsCurrentAsset() async throws {
        let fixture = try ImageFixture()
        defer { fixture.remove() }
        let firstURL = fixture.root.appendingPathComponent("first.jpg")
        let secondURL = fixture.root.appendingPathComponent("second.jpg")
        try fixture.writeJPEG(width: 800, height: 600, to: firstURL, red: 20)
        try fixture.writeJPEG(width: 900, height: 600, to: secondURL, red: 180)
        let store = PersonalizationImageStore(rootURL: fixture.assets)
        let first = try await store.replace(
            sourceURL: firstURL,
            currentAsset: nil,
            currentLegacyFileName: nil,
            assetID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        ) { _ in true }

        do {
            _ = try await store.replace(
                sourceURL: secondURL,
                currentAsset: first.asset,
                currentLegacyFileName: first.asset.displayFileName,
                assetID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
            ) { _ in
                throw SimulatedCommitFailure.failed
            }
            Issue.record("Expected the canonical commit to fail")
        } catch let error as SimulatedCommitFailure {
            #expect(error == .failed)
        }

        for name in first.asset.ownedFileNames {
            #expect(FileManager.default.fileExists(atPath: fixture.assets.appendingPathComponent(name).path))
        }
        let owned = try fixture.assetEntries().filter(PersonalizationImageStore.isOwnedVariantFileName)
        #expect(Set(owned) == Set(first.asset.ownedFileNames))
    }

    @Test
    func removalDeletesOwnedFilesOnlyAfterCanonicalCommit() async throws {
        let fixture = try ImageFixture()
        defer { fixture.remove() }
        let sourceURL = fixture.root.appendingPathComponent("source.jpg")
        try fixture.writeJPEG(width: 640, height: 480, to: sourceURL)
        let store = PersonalizationImageStore(rootURL: fixture.assets)
        let installed = try await store.replace(
            sourceURL: sourceURL,
            currentAsset: nil,
            currentLegacyFileName: nil
        ) { _ in true }

        let removed = try await store.remove(
            currentAsset: installed.asset,
            currentLegacyFileName: installed.asset.displayFileName
        ) {
            for name in installed.asset.ownedFileNames {
                #expect(FileManager.default.fileExists(atPath: fixture.assets.appendingPathComponent(name).path))
            }
            return true
        }

        #expect(removed.commitValue)
        #expect(!removed.cleanupNeeded)
        for name in installed.asset.ownedFileNames {
            #expect(!FileManager.default.fileExists(atPath: fixture.assets.appendingPathComponent(name).path))
        }
    }

    @Test
    func assetSurvivesStoreRelaunchAndOriginalExportsExactly() async throws {
        let fixture = try ImageFixture()
        defer { fixture.remove() }
        let sourceURL = fixture.root.appendingPathComponent("source.jpg")
        try fixture.writeJPEG(width: 512, height: 384, to: sourceURL)
        let sourceBytes = try Data(contentsOf: sourceURL)
        var installedAsset: PersonalizationImageAsset?
        do {
            let store = PersonalizationImageStore(rootURL: fixture.assets)
            installedAsset = try await store.replace(
                sourceURL: sourceURL,
                currentAsset: nil,
                currentLegacyFileName: nil
            ) { $0 }.asset
        }

        let asset = try #require(installedAsset)
        let relaunched = PersonalizationImageStore(rootURL: fixture.assets)
        let reconciliation = await relaunched.reconcile(
            referencedAsset: asset,
            referencedLegacyFileName: asset.displayFileName
        )
        #expect(reconciliation == PersonalizationImageReconciliation(
            removedFileCount: 0,
            removedStagingDirectoryCount: 0,
            failureCount: 0
        ))
        let exportURL = fixture.root.appendingPathComponent("explicit-export.jpg")
        try await relaunched.exportOriginal(asset: asset, to: exportURL)
        #expect(try Data(contentsOf: exportURL) == sourceBytes)
    }

    @Test
    func reconciliationAndFilenameChecksCannotEscapeTheOwnedDirectory() async throws {
        let fixture = try ImageFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.assets, withIntermediateDirectories: true)
        let unrelated = fixture.assets.appendingPathComponent("notes.jpg")
        let outside = fixture.root.appendingPathComponent("outside.jpg")
        try Data("keep".utf8).write(to: unrelated)
        try Data("keep".utf8).write(to: outside)
        let store = PersonalizationImageStore(rootURL: fixture.assets)

        #expect(!PersonalizationImageStore.isOwnedVariantFileName("../outside.jpg"))
        #expect(!PersonalizationImageStore.isOwnedVariantFileName("vision-nope-display.jpg"))
        #expect(!PersonalizationImageStore.isOwnedVariantFileName("notes.jpg"))
        _ = await store.reconcile(referencedAsset: nil, referencedLegacyFileName: "../outside.jpg")
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test
    func legacyDisplayPointerPreservesAndCanRetireAllBoundedSiblings() async throws {
        let fixture = try ImageFixture()
        defer { fixture.remove() }
        let sourceURL = fixture.root.appendingPathComponent("source.jpg")
        try fixture.writeJPEG(width: 640, height: 480, to: sourceURL)
        let store = PersonalizationImageStore(rootURL: fixture.assets)
        let installed = try await store.replace(
            sourceURL: sourceURL,
            currentAsset: nil,
            currentLegacyFileName: nil
        ) { _ in true }

        let reconciliation = await store.reconcile(
            referencedAsset: nil,
            referencedLegacyFileName: installed.asset.displayFileName
        )
        #expect(reconciliation.removedFileCount == 0)
        for name in installed.asset.ownedFileNames {
            #expect(FileManager.default.fileExists(atPath: fixture.assets.appendingPathComponent(name).path))
        }

        _ = try await store.remove(
            currentAsset: nil,
            currentLegacyFileName: installed.asset.displayFileName
        ) { true }
        for name in installed.asset.ownedFileNames {
            #expect(!FileManager.default.fileExists(atPath: fixture.assets.appendingPathComponent(name).path))
        }
    }
}

private enum SimulatedCommitFailure: Error, Equatable {
    case failed
}

private struct PixelSize: Equatable {
    var width: Int
    var height: Int
}

private struct ImageFixture {
    let root: URL
    let assets: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("founder-office-image-tests-\(UUID().uuidString.lowercased())", isDirectory: true)
        assets = root.appendingPathComponent("Personalization", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func assetEntries() throws -> [String] {
        guard FileManager.default.fileExists(atPath: assets.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: assets.path).sorted()
    }

    func writeJPEG(width: Int, height: Int, to url: URL, red: UInt8 = 80) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        context.setFillColor(CGColor(
            colorSpace: colorSpace,
            components: [CGFloat(red) / 255, 0.35, 0.65, 1]
        )!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.jpeg.identifier as CFString,
                1,
                nil
              ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.9
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    func dimensions(of url: URL) throws -> PixelSize {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary))
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        )
        let width = try #require((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue)
        let height = try #require((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue)
        return PixelSize(width: width, height: height)
    }

}
