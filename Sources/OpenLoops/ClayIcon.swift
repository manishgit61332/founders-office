import AppKit
import FounderOfficeCore
import SwiftUI

enum ClayIconName: String {
    case home
    case loops
    case calendar
    case settings
    case photo

    var systemFallback: String {
        switch self {
        case .home: return "house.fill"
        case .loops: return "checklist"
        case .calendar: return "calendar"
        case .settings: return "gearshape.fill"
        case .photo: return "photo.fill"
        }
    }
}

struct ClayIconView: View {
    let name: ClayIconName
    let style: IconStyle
    var size: CGFloat

    var body: some View {
        Group {
            if style == .clay, let image = ClayIconLibrary.image(named: name) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: name.systemFallback)
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.16)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private enum ClayIconLibrary {
    private static var cache: [ClayIconName: NSImage] = [:]

    static func image(named name: ClayIconName) -> NSImage? {
        if let cached = cache[name] { return cached }
        guard let url = url(for: name), let image = NSImage(contentsOf: url) else { return nil }
        cache[name] = image
        return image
    }

    private static func url(for name: ClayIconName) -> URL? {
        let fileManager = FileManager.default
        let candidates: [URL?] = [
            Bundle.main.resourceURL?
                .appendingPathComponent("ClayIcons", isDirectory: true)
                .appendingPathComponent("\(name.rawValue).png"),
            URL(fileURLWithPath: fileManager.currentDirectoryPath)
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent("ClayIcons", isDirectory: true)
                .appendingPathComponent("\(name.rawValue).png"),
            sourceRootURL
                .appendingPathComponent("Resources", isDirectory: true)
                .appendingPathComponent("ClayIcons", isDirectory: true)
                .appendingPathComponent("\(name.rawValue).png")
        ]

        return candidates.compactMap { $0 }.first { fileManager.fileExists(atPath: $0.path) }
    }

    private static var sourceRootURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
