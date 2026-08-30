import SwiftUI

enum AppIconName: String {
    case home
    case loops
    case calendar
    case settings
    case photo

    var systemName: String {
        switch self {
        case .home: return "house.fill"
        case .loops: return "checklist"
        case .calendar: return "calendar"
        case .settings: return "gearshape.fill"
        case .photo: return "photo.fill"
        }
    }
}

/// Founder’s Office uses Apple’s native symbol language throughout the Mac UI.
/// Keeping this wrapper small gives every icon the same optical padding while
/// avoiding bundled novelty icon packs in customer builds.
struct SystemIconView: View {
    let name: AppIconName
    var size: CGFloat

    var body: some View {
        Image(systemName: name.systemName)
            .resizable()
            .scaledToFit()
            .padding(size * 0.16)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
