import Foundation

/// An exact, nonnegative base-10 value accepted by the primary-goal contract.
///
/// The public sync contract and PostgreSQL both use `numeric(30,8)`. Keeping
/// this constraint in the domain model prevents a value from becoming a
/// binary `Double` before it reaches either boundary. Encoding deliberately
/// remains a JSON number so version-1 JSON readers keep the same wire shape.
public struct GoalDecimal: Codable, Hashable, Comparable, Sendable,
    ExpressibleByIntegerLiteral, CustomStringConvertible
{
    public enum ValidationError: Error, Equatable, Sendable {
        case empty
        case invalidSyntax
        case negative
        case tooManyFractionDigits
        case outOfRange
        case nonFinite
    }

    public typealias IntegerLiteralType = Int64

    public static let scale = 8
    public static let precision = 30
    public static let maximumCanonicalString = "9999999999999999999999.99999999"

    private static let maximumDecimal = Decimal(
        string: maximumCanonicalString,
        locale: Locale(identifier: "en_US_POSIX")
    )!

    public static let zero = GoalDecimal(unchecked: .zero)
    public static let maximum = GoalDecimal(unchecked: maximumDecimal)

    private let value: Decimal

    public init(validating value: Decimal) throws {
        guard !value.isNaN else { throw ValidationError.nonFinite }
        guard value >= 0 else { throw ValidationError.negative }
        guard value <= Self.maximumDecimal else { throw ValidationError.outOfRange }

        var source = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &source, Self.scale, .plain)
        guard rounded == value else { throw ValidationError.tooManyFractionDigits }

        self.value = value
    }

    /// Parses the exact text a person entered. Grouping separators are allowed
    /// only in complete groups, and scale is checked before Decimal can trim
    /// trailing zeroes. Exponents are intentionally not accepted in the UI.
    public init(userInput: String) throws {
        var source = userInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { throw ValidationError.empty }

        if source.first == "$" || source.first == "₹" {
            source.removeFirst()
            source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if source.last == "%" {
            source.removeLast()
            source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if source.first == "+" {
            source.removeFirst()
        }
        guard !source.isEmpty else { throw ValidationError.empty }
        if source.first == "-" { throw ValidationError.negative }

        let components = source.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count <= 2 else { throw ValidationError.invalidSyntax }

        let integerText = String(components[0])
        let fractionText = components.count == 2 ? String(components[1]) : nil
        guard !integerText.isEmpty || !(fractionText ?? "").isEmpty else {
            throw ValidationError.invalidSyntax
        }
        if let fractionText {
            guard !fractionText.isEmpty else { throw ValidationError.invalidSyntax }
            guard fractionText.utf8.count <= Self.scale else {
                throw ValidationError.tooManyFractionDigits
            }
            guard fractionText.utf8.allSatisfy(Self.isASCIIDigit) else {
                throw ValidationError.invalidSyntax
            }
        }

        let ungroupedInteger: String
        if integerText.contains(",") {
            let groups = integerText.split(separator: ",", omittingEmptySubsequences: false)
            guard let first = groups.first,
                  (1...3).contains(first.utf8.count),
                  first.utf8.allSatisfy(Self.isASCIIDigit),
                  groups.dropFirst().allSatisfy({
                      $0.utf8.count == 3 && $0.utf8.allSatisfy(Self.isASCIIDigit)
                  }) else {
                throw ValidationError.invalidSyntax
            }
            ungroupedInteger = groups.joined()
        } else {
            guard integerText.utf8.allSatisfy(Self.isASCIIDigit) else {
                throw ValidationError.invalidSyntax
            }
            ungroupedInteger = integerText
        }

        let normalizedInteger = ungroupedInteger.isEmpty ? "0" : ungroupedInteger
        let normalized = fractionText.map { "\(normalizedInteger).\($0)" } ?? normalizedInteger
        guard let decimal = Decimal(
            string: normalized,
            locale: Locale(identifier: "en_US_POSIX")
        ) else {
            throw ValidationError.invalidSyntax
        }
        try self.init(validating: decimal)
    }

    public init(integerLiteral value: Int64) {
        precondition(value >= 0, "Primary-goal values cannot be negative")
        self.init(unchecked: Decimal(value))
    }

    private init(unchecked value: Decimal) {
        self.value = value
    }

    public var decimalValue: Decimal { value }

    /// Exact, locale-independent text for editing and deterministic fixtures.
    public var canonicalString: String {
        NSDecimalNumber(decimal: value).stringValue
    }

    public var description: String { canonicalString }

    /// A lossy projection used only for bounded progress-bar rendering.
    public var doubleValue: Double {
        NSDecimalNumber(decimal: value).doubleValue
    }

    public func formatted(locale: Locale = .current) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = Self.scale
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? canonicalString
    }

    public static func < (lhs: GoalDecimal, rhs: GoalDecimal) -> Bool {
        lhs.value < rhs.value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let decoded: Decimal
        do {
            decoded = try container.decode(Decimal.self)
        } catch {
            throw DecodingError.typeMismatch(
                Decimal.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Primary-goal values must be JSON numbers",
                    underlyingError: error
                )
            )
        }

        do {
            try self.init(validating: decoded)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Primary-goal value is not numeric(30,8)-compatible"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    private static func isASCIIDigit(_ byte: UInt8) -> Bool {
        (48...57).contains(byte)
    }
}
