import Foundation

/// Validates app-owned asset names before they are joined to a storage URL.
///
/// Product data stores opaque basenames only. A cloud payload or edited JSON
/// document must never turn an asset field into an arbitrary filesystem path.
public enum AssetFileName {
    private static let allowedCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_ ."
    )
    private static let allowedExtensions: Set<String> = [
        "gif", "heic", "heif", "jpeg", "jpg", "png", "tif", "tiff", "webp"
    ]

    public static func validated(_ value: String) -> String? {
        guard !value.isEmpty, value.utf8.count <= 180 else { return nil }
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        guard value != ".", value != "..", !value.hasPrefix(".") else { return nil }
        guard !value.contains("/"), !value.contains("\\"), !value.contains(":") else { return nil }
        guard value.unicodeScalars.allSatisfy(allowedCharacters.contains) else { return nil }
        guard URL(fileURLWithPath: value).lastPathComponent == value else { return nil }
        guard allowedExtensions.contains((value as NSString).pathExtension.lowercased()) else { return nil }
        return value
    }
}
