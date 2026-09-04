import AppKit
import FounderOfficeCore
import SwiftUI

extension RGB24Color {
    var swiftUIColor: Color {
        Color(
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255
        )
    }

    init?(swiftUIColor: Color) {
        guard let color = NSColor(swiftUIColor).usingColorSpace(.sRGB) else { return nil }
        self.init(
            red: UInt8((min(max(color.redComponent, 0), 1) * 255).rounded()),
            green: UInt8((min(max(color.greenComponent, 0), 1) * 255).rounded()),
            blue: UInt8((min(max(color.blueComponent, 0), 1) * 255).rounded())
        )
    }
}

struct FounderTheme {
    var appearance: AppearancePreferences
    var reduceTransparency: Bool

    static let fallback = FounderTheme(appearance: .manish(), reduceTransparency: false)

    var primaryAccent: Color { appearance.accent.primaryColor.swiftUIColor }
    var secondaryAccent: Color { appearance.accent.secondaryColor.swiftUIColor }
    var primaryAccentText: Color { appearance.accent.primaryFillTextColor.swiftUIColor }
    var readableAccentOnPanel: Color {
        appearance.accent.primaryColor
            .readableForeground(on: RGB24Color(red: 14, green: 15, blue: 18))
            .swiftUIColor
    }

    var accentGradient: LinearGradient {
        let stops = appearance.accent.normalizedStops.map {
            Gradient.Stop(color: $0.color.swiftUIColor, location: $0.location)
        }
        let radians = appearance.accent.angleDegrees * .pi / 180
        let dx = cos(radians) * 0.5
        let dy = sin(radians) * 0.5
        return LinearGradient(
            stops: stops,
            startPoint: UnitPoint(x: 0.5 - dx, y: 0.5 - dy),
            endPoint: UnitPoint(x: 0.5 + dx, y: 0.5 + dy)
        )
    }

    var effectiveSurfaceID: SurfaceStyleID {
        reduceTransparency ? .solidBlack : appearance.surfaceStyleID
    }

    var nodeRadius: CGFloat {
        switch appearance.nodeStyleID {
        case .native: return 12
        case .minimal: return 18
        case .pixel: return 2
        default: return 14
        }
    }

    var visionRadius: CGFloat {
        switch appearance.nodeStyleID {
        case .native: return 18
        case .minimal: return 26
        case .pixel: return 2
        default: return 25
        }
    }

    var groupedBackground: Color {
        switch appearance.nodeStyleID {
        case .minimal: return Color.white.opacity(0.055)
        case .pixel: return Color.white.opacity(0.085)
        default: return Color.white.opacity(0.042)
        }
    }

    var contentSurface: Color {
        switch appearance.nodeStyleID {
        case .native: return Color.white.opacity(0.072)
        case .minimal: return Color.white.opacity(0.052)
        case .pixel: return Color.white.opacity(0.08)
        default: return Color.white.opacity(0.06)
        }
    }

    var contentBorder: Color {
        switch appearance.nodeStyleID {
        case .minimal: return Color.white.opacity(0.075)
        case .pixel: return primaryAccent.opacity(0.44)
        default: return Color.white.opacity(0.10)
        }
    }

    func displayFont(_ role: FounderTextRole, weight: Font.Weight = .regular) -> Font {
        font(for: appearance.displayFontID, role: role, weight: weight)
    }

    func interfaceFont(_ role: FounderTextRole, weight: Font.Weight = .regular) -> Font {
        font(for: appearance.interfaceFontID, role: role, weight: weight)
    }

    func symbolFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        font(for: appearance.interfaceFontID, size: size, weight: weight)
    }

    private func font(for choice: FontChoiceID, role: FounderTextRole, weight: Font.Weight) -> Font {
        font(
            for: choice,
            size: CGFloat(FounderTypeScale.points(for: role)),
            weight: weight
        )
    }

    private func font(for choice: FontChoiceID, size: CGFloat, weight: Font.Weight) -> Font {
        switch choice {
        case .instrument:
            return .custom("Instrument Serif", size: size).weight(weight)
        case .serif:
            return .system(size: size, weight: weight, design: .serif)
        case .rounded:
            return .system(size: size, weight: weight, design: .rounded)
        case .monospaced:
            return .system(size: size, weight: weight, design: .monospaced)
        default:
            return .system(size: size, weight: weight, design: .default)
        }
    }
}

private struct FounderThemeKey: EnvironmentKey {
    static let defaultValue = FounderTheme.fallback
}

extension EnvironmentValues {
    var founderTheme: FounderTheme {
        get { self[FounderThemeKey.self] }
        set { self[FounderThemeKey.self] = newValue }
    }
}
