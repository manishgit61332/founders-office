import FounderOfficeCore
import SwiftUI

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

extension Font {
    static var founderDisplay: Font {
        .custom("Instrument Serif", size: 40, relativeTo: .largeTitle)
    }
}
