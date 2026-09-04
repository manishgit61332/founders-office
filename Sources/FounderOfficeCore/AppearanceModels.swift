import Foundation

public struct RGB24Color: Codable, Hashable, Sendable {
    public static let accessibleDarkText = RGB24Color(red: 0, green: 0, blue: 0)
    public static let accessibleLightText = RGB24Color(red: 255, green: 255, blue: 255)

    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public init?(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.count == 6, let number = UInt32(value, radix: 16) else { return nil }
        self.init(
            red: UInt8((number >> 16) & 0xFF),
            green: UInt8((number >> 8) & 0xFF),
            blue: UInt8(number & 0xFF)
        )
    }

    public var hex: String {
        String(format: "#%02X%02X%02X", red, green, blue)
    }

    /// WCAG relative luminance in the sRGB colour space.
    public var relativeLuminance: Double {
        let red = Self.linearizedSRGB(red)
        let green = Self.linearizedSRGB(green)
        let blue = Self.linearizedSRGB(blue)
        return 0.2126 * red + 0.7152 * green + 0.0722 * blue
    }

    public func contrastRatio(with other: RGB24Color) -> Double {
        let lighter = max(relativeLuminance, other.relativeLuminance)
        let darker = min(relativeLuminance, other.relativeLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// Black or white, whichever creates the stronger WCAG contrast.
    /// One of these colours always reaches at least 4.5:1 on an opaque sRGB fill.
    public var accessibleTextColor: RGB24Color {
        let darkRatio = contrastRatio(with: Self.accessibleDarkText)
        let lightRatio = contrastRatio(with: Self.accessibleLightText)
        return darkRatio >= lightRatio ? Self.accessibleDarkText : Self.accessibleLightText
    }

    /// Preserve the requested colour when it is readable; otherwise fall back
    /// to the highest-contrast neutral foreground for that surface.
    public func readableForeground(
        on background: RGB24Color,
        minimumContrast: Double = 4.5
    ) -> RGB24Color {
        contrastRatio(with: background) >= minimumContrast
            ? self
            : background.accessibleTextColor
    }

    private static func linearizedSRGB(_ component: UInt8) -> Double {
        let value = Double(component) / 255
        return value <= 0.04045
            ? value / 12.92
            : pow((value + 0.055) / 1.055, 2.4)
    }
}

public enum FounderTextRole: String, CaseIterable, Sendable {
    case primaryTitle
    case secondary
    case tertiary
}

/// The complete Founder’s Office text scale. Visual hierarchy comes from three
/// deliberate levels instead of one-off point sizes scattered through the UI.
public enum FounderTypeScale {
    public static let primaryTitle = 28.0
    public static let secondary = primaryTitle / 1.62
    public static let tertiary = secondary / 1.6

    public static func points(for role: FounderTextRole) -> Double {
        switch role {
        case .primaryTitle: return primaryTitle
        case .secondary: return secondary
        case .tertiary: return tertiary
        }
    }
}

public struct AccentStop: Codable, Hashable, Sendable {
    public var color: RGB24Color
    public var location: Double

    public init(color: RGB24Color, location: Double) {
        self.color = color
        self.location = min(max(location, 0), 1)
    }
}

public enum AccentMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case solid
    case gradient

    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
}

public struct AccentStyle: Codable, Hashable, Sendable {
    public var mode: AccentMode
    public var stops: [AccentStop]
    public var angleDegrees: Double

    public init(mode: AccentMode, stops: [AccentStop], angleDegrees: Double = 90) {
        self.mode = mode
        self.stops = Self.normalized(stops)
        let wrappedAngle = angleDegrees.truncatingRemainder(dividingBy: 360)
        self.angleDegrees = wrappedAngle < 0 ? wrappedAngle + 360 : wrappedAngle
    }

    public var normalizedStops: [AccentStop] {
        Self.normalized(stops)
    }

    public var primaryColor: RGB24Color {
        normalizedStops.first?.color ?? RGB24Color(red: 10, green: 132, blue: 255)
    }

    public var secondaryColor: RGB24Color {
        guard mode == .gradient else { return primaryColor }
        return normalizedStops.last?.color ?? primaryColor
    }

    /// Foreground for controls filled with the primary accent colour.
    public var primaryFillTextColor: RGB24Color {
        primaryColor.accessibleTextColor
    }

    private static func normalized(_ stops: [AccentStop]) -> [AccentStop] {
        let resolved = Array(stops.prefix(4)).map {
            AccentStop(color: $0.color, location: $0.location)
        }
        .sorted { $0.location < $1.location }

        if resolved.isEmpty {
            return [AccentStop(color: RGB24Color(red: 10, green: 132, blue: 255), location: 0)]
        }
        return resolved
    }
}

public protocol AppearanceIdentifier: RawRepresentable, Codable, Hashable, Sendable, Identifiable where RawValue == String {}

public extension AppearanceIdentifier {
    var id: String { rawValue }
}

public struct AppearancePresetID: AppearanceIdentifier {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let manish = Self(rawValue: "manish")
    public static let native = Self(rawValue: "native")
    public static let minimal = Self(rawValue: "minimal")
    public static let pixel = Self(rawValue: "pixel")
    public static let custom = Self(rawValue: "custom")

    public static let builtIns: [Self] = [.manish, .native, .minimal, .pixel]

    public var title: String {
        switch self {
        case .manish: return "Manish"
        case .native: return "Native"
        case .minimal: return "Soft AI"
        case .pixel: return "Pixel"
        case .custom: return "Custom"
        default: return "Custom"
        }
    }
}

public struct FontChoiceID: AppearanceIdentifier {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let instrument = Self(rawValue: "instrument-serif")
    public static let system = Self(rawValue: "system")
    public static let serif = Self(rawValue: "system-serif")
    public static let rounded = Self(rawValue: "system-rounded")
    public static let monospaced = Self(rawValue: "system-monospaced")

    public static let builtIns: [Self] = [.instrument, .system, .serif, .rounded, .monospaced]

    public var title: String {
        switch self {
        case .instrument: return "Instrument"
        case .system: return "SF Pro"
        case .serif: return "Serif"
        case .rounded: return "Rounded"
        case .monospaced: return "Mono"
        default: return "SF Pro"
        }
    }
}

public struct NodeStyleID: AppearanceIdentifier {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let manish = Self(rawValue: "manish")
    public static let native = Self(rawValue: "native")
    public static let minimal = Self(rawValue: "minimal")
    public static let pixel = Self(rawValue: "pixel")

    public static let builtIns: [Self] = [.manish, .native, .minimal, .pixel]

    public var title: String {
        switch self {
        case .manish: return "Manish"
        case .native: return "Native"
        case .minimal: return "Soft"
        case .pixel: return "Pixel"
        default: return "Manish"
        }
    }
}

public struct SurfaceStyleID: AppearanceIdentifier {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let glass = Self(rawValue: "glassmorphism")
    public static let frosted = Self(rawValue: "frosted-glass")
    public static let solidBlack = Self(rawValue: "solid-black")

    public static let builtIns: [Self] = [.glass, .frosted, .solidBlack]

    public var title: String {
        switch self {
        case .glass: return "Glass"
        case .frosted: return "Frosted"
        case .solidBlack: return "Black"
        default: return "Frosted"
        }
    }
}

public struct AppearancePreferences: Codable, Hashable, Sendable {
    public var presetID: AppearancePresetID
    public var accent: AccentStyle
    public var displayFontID: FontChoiceID
    public var interfaceFontID: FontChoiceID
    public var nodeStyleID: NodeStyleID
    public var surfaceStyleID: SurfaceStyleID
    public var updatedAt: Date?

    public init(
        presetID: AppearancePresetID,
        accent: AccentStyle,
        displayFontID: FontChoiceID,
        interfaceFontID: FontChoiceID,
        nodeStyleID: NodeStyleID,
        surfaceStyleID: SurfaceStyleID,
        updatedAt: Date? = nil
    ) {
        self.presetID = presetID
        self.accent = accent
        self.displayFontID = displayFontID
        self.interfaceFontID = interfaceFontID
        self.nodeStyleID = nodeStyleID
        self.surfaceStyleID = surfaceStyleID
        self.updatedAt = updatedAt
    }

    public static func manish(accent: RGB24Color = RGB24Color(red: 10, green: 132, blue: 255)) -> Self {
        Self(
            presetID: .manish,
            accent: AccentStyle(mode: .solid, stops: [AccentStop(color: accent, location: 0)]),
            displayFontID: .instrument,
            interfaceFontID: .system,
            nodeStyleID: .manish,
            surfaceStyleID: .frosted
        )
    }

    public static func preset(_ preset: AppearancePresetID) -> Self {
        switch preset {
        case .native:
            return Self(
                presetID: .native,
                accent: AccentStyle(mode: .solid, stops: [AccentStop(color: RGB24Color(red: 10, green: 132, blue: 255), location: 0)]),
                displayFontID: .system,
                interfaceFontID: .system,
                nodeStyleID: .native,
                surfaceStyleID: .frosted
            )
        case .minimal:
            return Self(
                presetID: .minimal,
                accent: AccentStyle(
                    mode: .gradient,
                    stops: [
                        AccentStop(color: RGB24Color(red: 116, green: 170, blue: 156), location: 0),
                        AccentStop(color: RGB24Color(red: 126, green: 87, blue: 194), location: 1)
                    ],
                    angleDegrees: 45
                ),
                displayFontID: .serif,
                interfaceFontID: .system,
                nodeStyleID: .minimal,
                surfaceStyleID: .glass
            )
        case .pixel:
            return Self(
                presetID: .pixel,
                accent: AccentStyle(
                    mode: .gradient,
                    stops: [
                        AccentStop(color: RGB24Color(red: 101, green: 190, blue: 75), location: 0),
                        AccentStop(color: RGB24Color(red: 49, green: 118, blue: 176), location: 1)
                    ],
                    angleDegrees: 90
                ),
                displayFontID: .monospaced,
                interfaceFontID: .system,
                nodeStyleID: .pixel,
                surfaceStyleID: .solidBlack
            )
        default:
            return .manish()
        }
    }
}

public extension AccentPalette {
    var rgb24: RGB24Color {
        switch self {
        case .blue: return RGB24Color(red: 10, green: 132, blue: 255)
        case .green: return RGB24Color(red: 135, green: 163, blue: 20)
        case .terracotta: return RGB24Color(red: 186, green: 79, blue: 56)
        case .violet: return RGB24Color(red: 175, green: 82, blue: 222)
        case .graphite: return RGB24Color(red: 135, green: 145, blue: 161)
        }
    }
}
