import Foundation
import Testing
@testable import FounderOfficeCore

struct CodableAndAppearanceTests {
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    @Test
    func testLegacyPersonalizationJSONDecodesWithoutInventingNewFields() throws {
        let json = #"{"schemaVersion":3,"displayName":"Founder's Office","accent":"blue","iconStyle":"system","milestones":[]}"#

        let profile = try decoder.decode(PersonalizationDocument.self, from: Data(json.utf8))

        #expect(profile.displayName == "Founder's Office")
        #expect(profile.resolvedPreferredName == nil)
        #expect(profile.resolvedWorkspaceName == "Founder's Office")
        #expect(profile.updatedAt == nil)
        #expect(profile.appearance == nil)
        #expect(profile.resolvedAppearance.presetID == .manish)
    }

    @Test
    func testLegacyMoveDecodesWithoutPlanningFieldClocks() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try #require(
            JSONSerialization.jsonObject(with: encoder.encode(TestFixtures.loop()))
                as? [String: Any]
        )
        object.removeValue(forKey: "priorityUpdatedAt")
        object.removeValue(forKey: "dueAtUpdatedAt")

        let decoded = try decoder.decode(
            OpenLoop.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        #expect(decoded.priorityUpdatedAt == nil)
        #expect(decoded.dueAtUpdatedAt == nil)
    }

    @Test
    func testUnknownAppearanceIdentifiersSurviveRoundTrip() throws {
        var appearance = AppearancePreferences.preset(.minimal)
        appearance.presetID = AppearancePresetID(rawValue: "future-theme")
        appearance.displayFontID = FontChoiceID(rawValue: "future-font")
        let profile = PersonalizationDocument(
            schemaVersion: 6,
            displayName: "Founder's Office",
            accent: .violet,
            iconStyle: .system,
            photoFileName: nil,
            primaryGoal: nil,
            milestones: [],
            appearance: appearance
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(profile)
        let decoded = try decoder.decode(PersonalizationDocument.self, from: data)

        #expect(decoded.appearance?.presetID.rawValue == "future-theme")
        #expect(decoded.appearance?.displayFontID.rawValue == "future-font")
        #expect(decoded.resolvedAppearance.accent.primaryColor.hex == "#74AA9C")
    }

    @Test
    func testInvalidRequiredEnumFailsClosed() {
        let json = #"{"schemaVersion":3,"displayName":"Office","accent":"not-a-colour","milestones":[]}"#

        #expect(throws: DecodingError.self) {
            try decoder.decode(PersonalizationDocument.self, from: Data(json.utf8))
        }
    }

    @Test
    func testResolvedNamesTrimWhitespaceAndIgnoreEmptyValues() {
        let profile = PersonalizationDocument(
            schemaVersion: 6,
            displayName: "  Legacy Office  ",
            accent: .blue,
            iconStyle: .system,
            photoFileName: nil,
            primaryGoal: nil,
            milestones: [],
            preferredName: "  Aanya  ",
            workspaceName: " \n "
        )

        #expect(profile.resolvedPreferredName == "Aanya")
        #expect(profile.resolvedWorkspaceName == "Legacy Office")
    }

    @Test
    func testRGBHexParsingNormalizesAndRejectsMalformedInput() {
        #expect(RGB24Color(hex: "#0a84ff")?.hex == "#0A84FF")
        #expect(RGB24Color(hex: " FFFFFF\n")?.hex == "#FFFFFF")
        #expect(RGB24Color(hex: "#12345") == nil)
        #expect(RGB24Color(hex: "#GGGGGG") == nil)
        #expect(RGB24Color(hex: "#11223344") == nil)
    }

    @Test
    func testAccentStyleClampsSortsLimitsAndWraps() {
        let colors = (0..<6).map { index in
            AccentStop(
                color: RGB24Color(red: UInt8(index), green: 0, blue: 0),
                location: Double(5 - index) / 4
            )
        }
        let accent = AccentStyle(mode: .gradient, stops: colors, angleDegrees: -450)

        #expect(accent.normalizedStops.count == 4)
        #expect(accent.normalizedStops.map { $0.location } == [0.5, 0.75, 1, 1])
        #expect(accent.angleDegrees == 270)
    }

    @Test
    func testEmptyAccentUsesSafeSystemBlueFallback() {
        let accent = AccentStyle(mode: .gradient, stops: [])

        #expect(accent.normalizedStops.count == 1)
        #expect(accent.primaryColor.hex == "#0A84FF")
        #expect(accent.secondaryColor.hex == "#0A84FF")
    }

    @Test
    func testWCAGRelativeLuminanceAndContrastUseSRGBMath() throws {
        let black = try #require(RGB24Color(hex: "#000000"))
        let white = try #require(RGB24Color(hex: "#FFFFFF"))

        #expect(abs(black.relativeLuminance - 0) < 0.000_001)
        #expect(abs(white.relativeLuminance - 1) < 0.000_001)
        #expect(abs(black.contrastRatio(with: white) - 21) < 0.000_001)
    }

    @Test
    func testBrightAccentChoosesDarkTextAndMeetsAAContrast() throws {
        let mint = try #require(RGB24Color(hex: "#7EFABE"))
        let foreground = mint.accessibleTextColor

        #expect(foreground.hex == "#000000")
        #expect(mint.contrastRatio(with: foreground) >= 4.5)
    }

    @Test
    func testDarkAccentChoosesLightTextAndMeetsAAContrast() throws {
        let violet = try #require(RGB24Color(hex: "#35205E"))
        let foreground = violet.accessibleTextColor

        #expect(foreground.hex == "#FFFFFF")
        #expect(violet.contrastRatio(with: foreground) >= 4.5)
    }

    @Test
    func testAutomaticTextContrastMeetsAAAcrossSampledRGBSpace() {
        for red in stride(from: 0, through: 255, by: 17) {
            for green in stride(from: 0, through: 255, by: 17) {
                for blue in stride(from: 0, through: 255, by: 17) {
                    let background = RGB24Color(
                        red: UInt8(red),
                        green: UInt8(green),
                        blue: UInt8(blue)
                    )
                    #expect(background.contrastRatio(with: background.accessibleTextColor) >= 4.5)
                }
            }
        }
    }

    @Test
    func testReadableAccentPreservesPassingColourAndFallsBackForDarkColour() throws {
        let panel = try #require(RGB24Color(hex: "#0E0F12"))
        let mint = try #require(RGB24Color(hex: "#7EFABE"))
        let violet = try #require(RGB24Color(hex: "#35205E"))

        #expect(mint.readableForeground(on: panel) == mint)
        #expect(violet.readableForeground(on: panel).hex == "#FFFFFF")
        #expect(violet.readableForeground(on: panel).contrastRatio(with: panel) >= 4.5)
    }

    @Test
    func testAccentStyleUsesItsRenderedPrimaryFillForTextContrast() throws {
        let mint = try #require(RGB24Color(hex: "#7EFABE"))
        let violet = try #require(RGB24Color(hex: "#35205E"))
        let accent = AccentStyle(
            mode: .gradient,
            stops: [
                AccentStop(color: mint, location: 0),
                AccentStop(color: violet, location: 1)
            ]
        )

        #expect(accent.primaryFillTextColor.hex == "#000000")
        #expect(accent.primaryColor.contrastRatio(with: accent.primaryFillTextColor) >= 4.5)
    }

    @Test
    func testFounderTypeScaleUsesOnlyTheRequestedThreeLevels() {
        let points = FounderTextRole.allCases.map(FounderTypeScale.points(for:))

        #expect(points.count == 3)
        #expect(abs(FounderTypeScale.primaryTitle / FounderTypeScale.secondary - 1.62) < 0.000_001)
        #expect(abs(FounderTypeScale.secondary / FounderTypeScale.tertiary - 1.6) < 0.000_001)
        #expect(FounderTypeScale.tertiary >= 10.8)
    }
}
