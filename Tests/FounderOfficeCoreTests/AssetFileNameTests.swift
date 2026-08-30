import Testing
@testable import FounderOfficeCore

struct AssetFileNameTests {
    @Test
    func testAcceptsOpaqueImageBasenames() {
        let validNames = [
            "vision-00000000-0000-0000-0000-000000000000.jpg",
            "Dream car 2.HEIC",
            "logo_final-3.webp",
            "portrait.tiff"
        ]

        for name in validNames {
            #expect(AssetFileName.validated(name) == name, Comment(rawValue: name))
        }
    }

    @Test
    func testRejectsPathTraversalAndPathSyntax() {
        let invalidNames = [
            "../secret.jpg",
            "../../Library/secret.jpg",
            "folder/vision.jpg",
            "folder\\vision.jpg",
            "C:vision.jpg",
            ".hidden.jpg",
            ".",
            ".."
        ]

        for name in invalidNames {
            #expect(AssetFileName.validated(name) == nil, Comment(rawValue: name))
        }
    }

    @Test
    func testRejectsAmbiguousOrUnsupportedNames() {
        let invalidNames = [
            "",
            " logo.png",
            "logo.png ",
            "logo",
            "logo.exe",
            "logo.png.exe",
            "logo%2Fsecret.png",
            "dream-car-🚗.png",
            "line\nbreak.png"
        ]

        for name in invalidNames {
            #expect(AssetFileName.validated(name) == nil, Comment(rawValue: name))
        }
    }

    @Test
    func testEnforcesByteLengthInsteadOfCharacterCount() {
        let maximumLength = String(repeating: "a", count: 176) + ".png"
        let tooLong = String(repeating: "a", count: 177) + ".png"

        #expect(AssetFileName.validated(maximumLength) == maximumLength)
        #expect(AssetFileName.validated(tooLong) == nil)
    }
}
