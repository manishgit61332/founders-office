import Foundation
import Testing
@testable import FounderOfficeCore

struct GoalDecimalTests {
    @Test
    func eightPlaceValueRoundTripsAsAnExactJSONNumber() throws {
        let value = try GoalDecimal(userInput: "3000.12345678")
        let encoder = JSONEncoder()
        let encoded = try encoder.encode(value)

        #expect(String(decoding: encoded, as: UTF8.self) == "3000.12345678")

        let reopened = try JSONDecoder().decode(GoalDecimal.self, from: encoded)
        #expect(reopened == value)
        #expect(reopened.canonicalString == "3000.12345678")
    }

    @Test
    func maximumMagnitudeAndScaleAreEnforcedAtBothBoundaries() throws {
        let maximum = try GoalDecimal(userInput: GoalDecimal.maximumCanonicalString)
        #expect(maximum == .maximum)
        #expect(maximum.canonicalString == GoalDecimal.maximumCanonicalString)

        #expect(throws: GoalDecimal.ValidationError.outOfRange) {
            try GoalDecimal(userInput: "10000000000000000000000")
        }
        #expect(throws: GoalDecimal.ValidationError.tooManyFractionDigits) {
            try GoalDecimal(userInput: "0.000000001")
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                GoalDecimal.self,
                from: Data("10000000000000000000000".utf8)
            )
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(GoalDecimal.self, from: Data("0.000000001".utf8))
        }
    }

    @Test
    func legacyJSONIntegersAndFractionsMigrateWithoutBinaryDigits() throws {
        struct LegacyDoubleValue: Encodable {
            let value: Double
        }
        struct ExactValue: Decodable {
            let value: GoalDecimal
        }

        for (source, expected) in [
            (#"{"value":3000}"#, "3000"),
            (#"{"value":0.1}"#, "0.1"),
            (#"{"value":3000.125}"#, "3000.125"),
            (#"{"value":3.00012345678e3}"#, "3000.12345678")
        ] {
            let decoded = try JSONDecoder().decode(ExactValue.self, from: Data(source.utf8))
            #expect(decoded.value.canonicalString == expected)
        }

        let legacyBytes = try JSONEncoder().encode(LegacyDoubleValue(value: 0.1))
        let migrated = try JSONDecoder().decode(ExactValue.self, from: legacyBytes)
        #expect(migrated.value.canonicalString == "0.1")
        #expect(String(decoding: try JSONEncoder().encode(migrated.value), as: UTF8.self) == "0.1")
    }

    @Test
    func invalidUserInputFailsClosedWithoutPartialParsing() {
        let invalid: [(String, GoalDecimal.ValidationError)] = [
            ("", .empty),
            ("-1", .negative),
            ("1.2oops", .invalidSyntax),
            ("1,2", .invalidSyntax),
            ("1e3", .invalidSyntax),
            ("NaN", .invalidSyntax),
            ("Infinity", .invalidSyntax),
            ("1.", .invalidSyntax),
            (".", .invalidSyntax),
            ("१२", .invalidSyntax),
            ("1.000000000", .tooManyFractionDigits)
        ]

        for (input, expectedError) in invalid {
            #expect(throws: expectedError) {
                try GoalDecimal(userInput: input)
            }
        }

        #expect(throws: GoalDecimal.ValidationError.nonFinite) {
            try GoalDecimal(validating: .nan)
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(GoalDecimal.self, from: Data(#""3000.12""#.utf8))
        }
    }

    @Test
    func editingAndDisplayFormattingKeepAllMeaningfulDigits() throws {
        let value = try GoalDecimal(userInput: "$3,000.12345678")

        #expect(value.canonicalString == "3000.12345678")
        #expect(value.formatted(locale: Locale(identifier: "en_US")) == "3,000.12345678")
        #expect(GoalValueUnit.usd.format(value, locale: Locale(identifier: "en_US")) == "$3,000.12345678")
        #expect(GoalValueUnit.percent.format(value, locale: Locale(identifier: "en_US")) == "3,000.12345678%")
        #expect(try GoalDecimal(userInput: "₹ 3,000.12345678") == value)
        #expect(try GoalDecimal(userInput: "3,000.12345678%") == value)
    }
}
