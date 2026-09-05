import FounderOfficeCore
import SwiftUI
import UIKit

enum FounderIOSPalette {
    static let background = Color(
        uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 14 / 255, green: 15 / 255, blue: 18 / 255, alpha: 1)
                : UIColor(red: 245 / 255, green: 245 / 255, blue: 247 / 255, alpha: 1)
        }
    )

    static let card = Color(
        uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 1, alpha: 0.07)
                : UIColor.white
        }
    )

    static let border = Color(
        uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 1, alpha: 0.10)
                : UIColor(red: 17 / 255, green: 17 / 255, blue: 20 / 255, alpha: 0.08)
        }
    )

    static let primaryText = Color(
        uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 247 / 255, green: 247 / 255, blue: 247 / 255, alpha: 1)
                : UIColor(red: 17 / 255, green: 17 / 255, blue: 20 / 255, alpha: 1)
        }
    )

    static let secondaryText = Color(
        uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 1, alpha: 0.62)
                : UIColor(red: 17 / 255, green: 17 / 255, blue: 20 / 255, alpha: 0.58)
        }
    )

    static let accent = Color(
        uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 10 / 255, green: 132 / 255, blue: 1, alpha: 1)
                : UIColor(red: 0, green: 122 / 255, blue: 1, alpha: 1)
        }
    )

    static let accentWash = Color(
        uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 10 / 255, green: 132 / 255, blue: 1, alpha: 0.14)
                : UIColor(red: 0, green: 122 / 255, blue: 1, alpha: 0.10)
        }
    )
}

extension AccentPalette {
    var swiftUIColor: Color {
        switch self {
        case .blue: return .blue
        case .green: return .green
        case .terracotta: return Color(red: 0.76, green: 0.27, blue: 0.19)
        case .violet: return .purple
        case .graphite: return Color(uiColor: .darkGray)
        }
    }
}

extension LoopPriority {
    /// Product-facing priority labels. P2 remains the compatible persisted
    /// value while the interface uses the clearer "Medium" label.
    var customerTitle: String {
        switch self {
        case .p0: return "Critical"
        case .p1: return "High"
        case .p2: return "Medium"
        case .p3: return "Low"
        }
    }

    /// Fixed semantic colors keep priority legible even when the user changes
    /// the workspace accent. Text labels always accompany these colors.
    var laneColor: Color {
        switch self {
        case .p0: return Color(uiColor: .systemRed)
        case .p1: return Color(uiColor: .systemOrange)
        case .p2: return Color(uiColor: .systemBlue)
        case .p3: return Color(uiColor: .systemGray)
        }
    }

    var previousPriority: LoopPriority? {
        guard let index = Self.allCases.firstIndex(of: self), index > Self.allCases.startIndex else {
            return nil
        }
        return Self.allCases[Self.allCases.index(before: index)]
    }

    var nextPriority: LoopPriority? {
        guard let index = Self.allCases.firstIndex(of: self) else { return nil }
        let nextIndex = Self.allCases.index(after: index)
        guard nextIndex < Self.allCases.endIndex else { return nil }
        return Self.allCases[nextIndex]
    }
}

extension RGB24Color {
    var swiftUIColor: Color {
        Color(
            red: Double(red) / 255,
            green: Double(green) / 255,
            blue: Double(blue) / 255
        )
    }

    init?(swiftUIColor: Color) {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard UIColor(swiftUIColor).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        self.init(
            red: UInt8((min(max(red, 0), 1) * 255).rounded()),
            green: UInt8((min(max(green, 0), 1) * 255).rounded()),
            blue: UInt8((min(max(blue, 0), 1) * 255).rounded())
        )
    }
}

extension AppearancePreferences {
    var primaryAccentColor: Color { accent.primaryColor.swiftUIColor }
    var secondaryAccentColor: Color { accent.secondaryColor.swiftUIColor }
    var primaryAccentTextColor: Color { accent.primaryFillTextColor.swiftUIColor }

    var accentGradient: LinearGradient {
        let stops = accent.normalizedStops.map {
            Gradient.Stop(color: $0.color.swiftUIColor, location: $0.location)
        }
        let radians = accent.angleDegrees * .pi / 180
        let dx = cos(radians) * 0.5
        let dy = sin(radians) * 0.5
        return LinearGradient(
            stops: stops,
            startPoint: UnitPoint(x: 0.5 - dx, y: 0.5 - dy),
            endPoint: UnitPoint(x: 0.5 + dx, y: 0.5 + dy)
        )
    }

    var nodeCornerRadius: CGFloat {
        switch nodeStyleID {
        case .native: return 12
        case .minimal: return 18
        case .pixel: return 2
        default: return 14
        }
    }

    var visionCornerRadius: CGFloat {
        switch nodeStyleID {
        case .native: return 18
        case .minimal: return 26
        case .pixel: return 2
        default: return 22
        }
    }

    var nodeBackgroundColor: Color {
        switch nodeStyleID {
        case .minimal: return primaryAccentColor.opacity(0.09)
        case .pixel: return FounderIOSPalette.card
        default: return FounderIOSPalette.card
        }
    }

    var nodeBorderColor: Color {
        switch nodeStyleID {
        case .pixel: return primaryAccentColor.opacity(0.58)
        case .minimal: return primaryAccentColor.opacity(0.18)
        default: return FounderIOSPalette.border
        }
    }

    func displayFont(_ role: FounderTextRole, weight: Font.Weight = .regular) -> Font {
        resolvedFont(
            displayFontID,
            size: CGFloat(FounderTypeScale.points(for: role)),
            weight: weight
        )
    }

    func interfaceFont(_ role: FounderTextRole, weight: Font.Weight = .regular) -> Font {
        resolvedFont(
            interfaceFontID,
            size: CGFloat(FounderTypeScale.points(for: role)),
            weight: weight
        )
    }

    func symbolFont(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        resolvedFont(interfaceFontID, size: size, weight: weight)
    }

    private func resolvedFont(_ choice: FontChoiceID, size: CGFloat, weight: Font.Weight) -> Font {
        switch choice {
        case .instrument: return .custom("Instrument Serif", size: size).weight(weight)
        case .serif: return .system(size: size, weight: weight, design: .serif)
        case .rounded: return .system(size: size, weight: weight, design: .rounded)
        case .monospaced: return .system(size: size, weight: weight, design: .monospaced)
        default: return .system(size: size, weight: weight, design: .default)
        }
    }
}

private struct FounderSurfaceBackground: View {
    let appearance: AppearancePreferences

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        FounderIOSPalette.background
            .overlay(alignment: .topTrailing) {
                if !reduceTransparency, appearance.surfaceStyleID == .glass {
                    Circle()
                        .fill(FounderIOSPalette.accentWash)
                        .frame(width: 260, height: 260)
                        .blur(radius: 90)
                        .offset(x: 120, y: -130)
                        .accessibilityHidden(true)
                }
            }
    }
}

private struct FounderSurfaceModifier: ViewModifier {
    let appearance: AppearancePreferences

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(FounderSurfaceBackground(appearance: appearance).ignoresSafeArea())
            .font(appearance.interfaceFont(.secondary))
    }
}

extension View {
    func founderSurface(_ appearance: AppearancePreferences) -> some View {
        modifier(FounderSurfaceModifier(appearance: appearance))
    }

    func founderProminentButton(_ appearance: AppearancePreferences) -> some View {
        buttonStyle(.borderedProminent)
            .tint(appearance.primaryAccentColor)
            .foregroundStyle(appearance.primaryAccentTextColor)
    }
}

extension Font {
    static var founderDisplay: Font {
        .custom(
            "Instrument Serif",
            size: CGFloat(FounderTypeScale.primaryTitle),
            relativeTo: .largeTitle
        )
    }
}
