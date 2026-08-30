import Foundation

public struct RGB24Color: Codable, Hashable, Sendable {
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
