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
}
