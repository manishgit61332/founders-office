import CloudKit
import Foundation

@MainActor
final class CloudAccountMonitor: ObservableObject {
    enum State: Equatable {
        case checking
        case available
        case unavailable

        var title: String {
            switch self {
            case .checking: return "Checking iCloud"
            case .available: return "iCloud available"
            case .unavailable: return "Sign in to iCloud"
            }
        }
    }

    @Published private(set) var state: State = .checking

    private let container = CKContainer(identifier: "iCloud.com.manish.foundersoffice")

    init() {
        refresh()
    }

    func refresh() {
        state = .checking
        container.accountStatus { [weak self] status, _ in
            Task { @MainActor in
                self?.state = status == .available ? .available : .unavailable
            }
        }
    }
}
