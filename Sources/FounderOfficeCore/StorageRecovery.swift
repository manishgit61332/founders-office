import Foundation

public enum WorkspaceStorageComponent: String, CaseIterable, Sendable {
    case openLoops
    case personalization

    public var title: String {
        switch self {
        case .openLoops: return "tasks"
        case .personalization: return "personalization"
        }
    }
}

/// The app must not replace a damaged canonical file with an empty document.
public struct WorkspaceRecoveryState: Equatable, Sendable {
    public let affectedComponents: [WorkspaceStorageComponent]
    public let preservedCopyNames: [String]

    public init(
        affectedComponents: [WorkspaceStorageComponent] = [],
        preservedCopyNames: [String] = []
    ) {
        self.affectedComponents = Array(Set(affectedComponents)).sorted { $0.rawValue < $1.rawValue }
        self.preservedCopyNames = Array(Set(preservedCopyNames)).sorted()
    }

    public static let ready = WorkspaceRecoveryState()

    public var requiresRecovery: Bool { !affectedComponents.isEmpty }

    public var message: String {
        guard requiresRecovery else { return "Storage ready" }
        let names = affectedComponents.map(\.title)
        let safeguard = preservedCopyNames.isEmpty
            ? "Writes and cloud sync are stopped."
            : "A recovery copy was preserved; writes and cloud sync are stopped."
        if names.count == 1 {
            let subject = names[0].capitalized
            let verb = affectedComponents[0] == .personalization ? "needs" : "need"
            return "\(subject) \(verb) recovery. \(safeguard)"
        }
        let subject = names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "data")
        let capitalizedSubject = subject.prefix(1).uppercased() + String(subject.dropFirst())
        return "\(capitalizedSubject) need recovery. \(safeguard)"
    }

    public func merging(_ other: WorkspaceRecoveryState) -> WorkspaceRecoveryState {
        WorkspaceRecoveryState(
            affectedComponents: affectedComponents + other.affectedComponents,
            preservedCopyNames: preservedCopyNames + other.preservedCopyNames
        )
    }
}

public enum CorruptFileQuarantine {
    /// Copies a damaged canonical file into a sibling Recovery directory without
    /// replacing any existing backup. The source remains in place as a write and
    /// cloud-sync fail-safe until an explicit recovery replaces it.
    @discardableResult
    public static func preserve(
        _ sourceURL: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let recoveryDirectory = sourceURL
            .deletingLastPathComponent()
            .appendingPathComponent("Recovery", isDirectory: true)
        try fileManager.createDirectory(at: recoveryDirectory, withIntermediateDirectories: true)

        let stem = sourceURL.deletingPathExtension().lastPathComponent
        let fileExtension = sourceURL.pathExtension
        let identifier = UUID().uuidString.lowercased()
        let suffix = fileExtension.isEmpty ? "" : ".\(fileExtension)"
        let destinationURL = recoveryDirectory
            .appendingPathComponent("\(stem)-corrupt-\(identifier)\(suffix)")

        try fileManager.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }
}
