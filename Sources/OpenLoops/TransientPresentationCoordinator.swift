import AppKit
import FounderOfficeCore

@MainActor
final class TransientPresentationCoordinator {
    nonisolated static let statusMenuIdentifier = NSUserInterfaceItemIdentifier(
        "foundersOffice.status-menu"
    )

    @MainActor
    private final class TrackedWindow {
        let window: NSWindow
        let originalLevel: NSWindow.Level
        let originalCollectionBehavior: NSWindow.CollectionBehavior
        let wasChildOfHost: Bool

        init(window: NSWindow, hostWindow: NSWindow) {
            self.window = window
            originalLevel = window.level
            originalCollectionBehavior = window.collectionBehavior
            wasChildOfHost = window.parent === hostWindow
        }
    }

    private var session = TransientPresentationSession()
    private weak var hostWindow: NSWindow?
    private weak var capturedFirstResponder: NSResponder?
    private var suspendHost: (() -> Void)?
    private var restoreHost: (() -> Void)?
    private var isHostExpanded: (() -> Bool)?
    private var objectLeases: [ObjectIdentifier: UUID] = [:]
    private var trackedWindows: [ObjectIdentifier: TrackedWindow] = [:]
    private var pendingNativePanelOrigin: UUID?

    var phase: TransientPresentationPhase { session.phase }
    var preventsAutoDismiss: Bool { session.isActive }
    var activeCount: Int { session.activeCount }
    var hasVisiblePresentedWindow: Bool {
        trackedWindows.values.contains { $0.window.isVisible }
    }

    func configure(
        hostWindow: NSWindow,
        isHostExpanded: @escaping () -> Bool,
        suspendHost: @escaping () -> Void,
        restoreHost: @escaping () -> Void
    ) {
        self.hostWindow = hostWindow
        self.isHostExpanded = isHostExpanded
        self.suspendHost = suspendHost
        self.restoreHost = restoreHost
    }

    @discardableResult
    func begin(_ reason: String, suspendsHost: Bool = false) -> UUID {
        if !session.isActive {
            capturedFirstResponder = hostWindow?.firstResponder
        }
        let shouldSuspend = suspendsHost && !session.hostSuspensionRequested
        let lease = session.begin(
            reason,
            hostIsExpanded: isHostExpanded?() == true,
            suspendsHost: suspendsHost
        )
        if shouldSuspend, session.hostWasExpanded {
            suspendHost?()
        }
        return lease
    }

    func end(_ lease: UUID) {
        guard session.end(lease) else { return }
        restoreAfterLastPresentation()
    }

    @discardableResult
    func beginScoped(
        to object: AnyObject,
        reason: String,
        suspendsHost: Bool = true
    ) -> UUID {
        beginScoped(
            key: ObjectIdentifier(object),
            reason: reason,
            suspendsHost: suspendsHost
        )
    }

    @discardableResult
    func beginScoped(
        key: ObjectIdentifier,
        reason: String,
        suspendsHost: Bool = true
    ) -> UUID {
        if let existing = objectLeases[key] { return existing }
        let lease = begin(reason, suspendsHost: suspendsHost)
        objectLeases[key] = lease
        return lease
    }

    func endScoped(to object: AnyObject) {
        endScoped(key: ObjectIdentifier(object))
    }

    func endScoped(key: ObjectIdentifier) {
        if let tracked = trackedWindows.removeValue(forKey: key) {
            restoreWindow(tracked)
        }
        guard let lease = objectLeases.removeValue(forKey: key) else { return }
        end(lease)
    }

    func present(_ window: NSWindow, reason: String) {
        let key = ObjectIdentifier(window)
        guard trackedWindows[key] == nil else {
            elevate(window)
            return
        }
        _ = beginScoped(to: window, reason: reason, suspendsHost: true)
        guard let hostWindow else {
            endScoped(key: key)
            return
        }
        trackedWindows[key] = TrackedWindow(window: window, hostWindow: hostWindow)
        elevate(window)
    }

    func elevate(_ window: NSWindow, scopedTo owner: AnyObject) {
        guard let hostWindow else { return }
        let key = ObjectIdentifier(owner)
        guard objectLeases[key] != nil else { return }
        if trackedWindows[key] == nil {
            trackedWindows[key] = TrackedWindow(window: window, hostWindow: hostWindow)
        }
        elevate(window)
    }

    func elevate(_ window: NSWindow) {
        guard let hostWindow, window !== hostWindow else { return }
        let elevatedLevel = NSWindow.Level(rawValue: hostWindow.level.rawValue + 1)
        if window.level.rawValue < elevatedLevel.rawValue {
            window.level = elevatedLevel
        }
        window.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
        if window.parent == nil, hostWindow.isVisible {
            hostWindow.addChildWindow(window, ordered: .above)
        }
        // Keep the transient independently visible at its elevated level. A
        // modal must not depend only on child ordering while the host is
        // visually collapsed into the notch.
        window.orderFrontRegardless()
    }

    /// SwiftUI menus and popovers do not expose their source view. Scope their
    /// process-wide notifications to the notch or to a window already owned by
    /// this coordinator. The app's status menu is explicitly excluded because
    /// it does not originate from the notch window.
    func shouldTrack(_ menu: NSMenu) -> Bool {
        var current: NSMenu? = menu
        while let candidate = current {
            if candidate.identifier == Self.statusMenuIdentifier {
                return shouldTrackMenuOrigin(isStatusMenuTree: true)
            }
            current = candidate.supermenu
        }
        return shouldTrackMenuOrigin(isStatusMenuTree: false)
    }

    func shouldTrackMenuOrigin(isStatusMenuTree: Bool) -> Bool {
        !isStatusMenuTree && shouldTrackCurrentOrigin()
    }

    func shouldTrack(_ popover: NSPopover) -> Bool {
        _ = popover
        return shouldTrackCurrentOrigin()
    }

    /// File panels are registered explicitly before they are shown. A native
    /// colour panel is owned only when it was already registered or when it was
    /// opened from the visible notch. `originatingWindow` preserves the old key
    /// window so keyboard activation is not incorrectly reduced to the current
    /// mouse position.
    func shouldTrack(_ window: NSWindow) -> Bool {
        shouldTrack(window, originatingWindow: NSApp.keyWindow)
    }

    func shouldTrack(_ window: NSWindow, originatingWindow: NSWindow?) -> Bool {
        if owns(window) { return true }
        guard window is NSColorPanel, let hostWindow, hostWindow.isVisible else {
            return false
        }
        if let originatingWindow,
           originatingWindow === hostWindow || owns(originatingWindow) {
            return true
        }
        if pendingNativePanelOrigin != nil {
            pendingNativePanelOrigin = nil
            return true
        }
        return hostWindow.frame.insetBy(dx: -12, dy: -12).contains(NSEvent.mouseLocation)
    }

    /// AppKit announces the old key window before the new colour panel becomes
    /// key. Retain that provenance for the next run-loop turn so a keyboard-
    /// opened ColorPicker is scoped to the notch even when the pointer is far
    /// away. The one-shot marker expires and cannot claim a later panel.
    func noteKeyResignation(_ window: NSWindow) {
        guard let hostWindow, window === hostWindow else { return }
        let marker = UUID()
        pendingNativePanelOrigin = marker
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard self?.pendingNativePanelOrigin == marker else { return }
            self?.pendingNativePanelOrigin = nil
        }
    }

    func isTracking(_ window: NSWindow) -> Bool {
        objectLeases[ObjectIdentifier(window)] != nil || owns(window)
    }

    private func shouldTrackCurrentOrigin() -> Bool {
        guard let hostWindow, hostWindow.isVisible else { return false }
        if hostWindow.isKeyWindow || NSApp.keyWindow === hostWindow {
            return true
        }
        if let keyWindow = NSApp.keyWindow, owns(keyWindow) {
            return true
        }
        return hostWindow.frame.insetBy(dx: -12, dy: -12).contains(NSEvent.mouseLocation)
    }

    func closeNativeColorPanels() {
        let panels = trackedWindows.values.filter { $0.window is NSColorPanel }
        for tracked in panels {
            tracked.window.orderOut(nil)
            endScoped(to: tracked.window)
        }
    }

    func cancelAll() {
        for tracked in trackedWindows.values {
            tracked.window.orderOut(nil)
            restoreWindow(tracked)
        }
        trackedWindows.removeAll()
        objectLeases.removeAll()
        pendingNativePanelOrigin = nil
        capturedFirstResponder = nil
        session.cancelAll()
    }

    private func restoreAfterLastPresentation() {
        let shouldRestoreHost = session.hostWasExpanded
        if shouldRestoreHost {
            restoreHost?()
            if let hostWindow {
                hostWindow.orderFrontRegardless()
                hostWindow.makeKey()
                if let capturedFirstResponder {
                    hostWindow.makeFirstResponder(capturedFirstResponder)
                }
            }
        }
        capturedFirstResponder = nil
        session.finishRestoring()
    }

    private func restoreWindow(_ tracked: TrackedWindow) {
        if let hostWindow, tracked.window.parent === hostWindow {
            if !tracked.wasChildOfHost {
                hostWindow.removeChildWindow(tracked.window)
            }
        }
        tracked.window.level = tracked.originalLevel
        tracked.window.collectionBehavior = tracked.originalCollectionBehavior
    }

    private func owns(_ window: NSWindow) -> Bool {
        guard let hostWindow else { return false }
        if window === hostWindow { return true }
        if trackedWindows.values.contains(where: { $0.window === window }) {
            return true
        }

        var ancestor = window.parent ?? window.sheetParent
        while let current = ancestor {
            if current === hostWindow { return true }
            ancestor = current.parent ?? current.sheetParent
        }
        return false
    }
}
