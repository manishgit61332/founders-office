import AppKit
import FounderOfficeCore

@MainActor
final class TransientPresentationCoordinator {
    nonisolated static let statusMenuIdentifier = NSUserInterfaceItemIdentifier(
        "foundersOffice.status-menu"
    )
    nonisolated static let nativeColorPanelIdentifier = NSUserInterfaceItemIdentifier(
        "foundersOffice.native-color-panel"
    )
    nonisolated static let nativeOpenPanelIdentifier = NSUserInterfaceItemIdentifier(
        "foundersOffice.native-open-panel"
    )
    nonisolated static let nativeSavePanelIdentifier = NSUserInterfaceItemIdentifier(
        "foundersOffice.native-save-panel"
    )

    @MainActor
    private final class TrackedWindow {
        let window: NSWindow
        let originalLevel: NSWindow.Level
        let originalCollectionBehavior: NSWindow.CollectionBehavior
        let originalIdentifier: NSUserInterfaceItemIdentifier?
        let originalAccessibilityIdentifier: String
        let wasChildOfHost: Bool

        init(window: NSWindow, hostWindow: NSWindow) {
            self.window = window
            originalLevel = window.level
            originalCollectionBehavior = window.collectionBehavior
            originalIdentifier = window.identifier
            originalAccessibilityIdentifier = window.accessibilityIdentifier()
            wasChildOfHost = window.parent === hostWindow
        }
    }

    private var session = TransientPresentationSession()
    private weak var hostWindow: NSWindow?
    private weak var capturedFirstResponder: NSResponder?
    private var capturedHostWasKey = false
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
            capturedHostWasKey = hostWindow?.isKeyWindow == true && NSApp.isActive
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

    /// Starts an unscoped portable presentation request. The caller owns the
    /// returned lease and must balance it with `end(_:)`.
    @discardableResult
    func present(request: TransientPresentationRequest) -> UUID {
        begin(
            "transient.\(request.kind.rawValue)",
            suspendsHost: request.hostDisposition == .suspendExpandedHost
        )
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

    /// Starts a portable request whose lifetime is scoped to one native owner.
    @discardableResult
    func present(
        request: TransientPresentationRequest,
        scopedTo object: AnyObject
    ) -> UUID {
        present(request: request, scopedTo: ObjectIdentifier(object))
    }

    /// Starts a portable request whose lifetime is scoped to an existing
    /// AppKit object identity without putting that identity in FounderOfficeCore.
    @discardableResult
    func present(
        request: TransientPresentationRequest,
        scopedTo key: ObjectIdentifier
    ) -> UUID {
        if let existing = objectLeases[key] { return existing }
        let lease = present(request: request)
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

    func present(_ window: NSWindow, request: TransientPresentationRequest) {
        let key = ObjectIdentifier(window)
        guard trackedWindows[key] == nil else {
            promoteIfVisible(window)
            return
        }
        _ = present(request: request, scopedTo: window)
        guard let hostWindow else {
            endScoped(key: key)
            return
        }
        trackedWindows[key] = TrackedWindow(window: window, hostWindow: hostWindow)
        applyManagedIdentity(to: window)
        // `NSOpenPanel.begin`, `NSSavePanel.begin`, and `NSAlert.runModal`
        // may reset their running level and order. Registration intentionally
        // does not display an invisible window; promotion happens after AppKit
        // has ordered the native transient on screen.
        promoteIfVisible(window)
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.isTracking(window) else { return }
            self.promoteIfVisible(window)
        }
    }

    func elevate(_ window: NSWindow, scopedTo owner: AnyObject) {
        guard let hostWindow else { return }
        let key = ObjectIdentifier(owner)
        guard objectLeases[key] != nil else { return }
        if trackedWindows[key] == nil {
            trackedWindows[key] = TrackedWindow(window: window, hostWindow: hostWindow)
        }
        promoteIfVisible(window)
    }

    /// Reasserts the post-presentation stacking invariant. Call this from
    /// the post-`begin` main-loop turn/`didBecomeKey` (and after a popover's
    /// `didShow`) so AppKit cannot settle a running panel below the host.
    func promoteIfVisible(_ window: NSWindow) {
        guard window.isVisible else { return }
        guard let hostWindow, window !== hostWindow else { return }
        applyManagedIdentity(to: window)
        // Independent native panels use AppKit's normal application-modal
        // ordering while the status-bar host is fully removed. Raising them
        // above the status bar would make them float over unrelated apps and
        // Spaces for no product benefit.
        guard hostWindow.isVisible else { return }
        let elevatedLevel = NSWindow.Level(rawValue: hostWindow.level.rawValue + 1)
        if window.level.rawValue < elevatedLevel.rawValue {
            window.level = elevatedLevel
        }
        window.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
        // Do not reparent AppKit-owned popover/menu windows. Native file,
        // colour, and alert panels remain independently visible while the host
        // is suspended; their elevated level is the ordering guarantee.
        window.orderFrontRegardless()
    }

    /// Ends a native window lease only after the window is no longer visible,
    /// preventing the host from restoring in front of a completion callback
    /// whose AppKit panel has not yet left the screen.
    func dismissAndEnd(_ window: NSWindow) {
        window.orderOut(nil)
        endScoped(to: window)
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

    @discardableResult
    func closeNativeColorPanels() -> Bool {
        var panels = trackedWindows.values.compactMap { $0.window as? NSColorPanel }
        for panel in NSApp.windows.compactMap({ $0 as? NSColorPanel })
        where panel.isVisible && !panels.contains(where: { $0 === panel }) {
            panels.append(panel)
        }
        guard !panels.isEmpty else { return false }
        for panel in panels {
            panel.orderOut(nil)
            if isTracking(panel) {
                endScoped(to: panel)
            }
        }
        return true
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
        capturedHostWasKey = false
        session.cancelAll()
    }

    private func restoreAfterLastPresentation() {
        let shouldRestoreHost = session.hostWasExpanded
        if shouldRestoreHost {
            restoreHost?()
            if let hostWindow {
                hostWindow.orderFrontRegardless()
                if capturedHostWasKey, NSApp.isActive {
                    hostWindow.makeKey()
                }
                if capturedHostWasKey, NSApp.isActive, let capturedFirstResponder {
                    hostWindow.makeFirstResponder(capturedFirstResponder)
                }
            }
        }
        capturedFirstResponder = nil
        capturedHostWasKey = false
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
        tracked.window.identifier = tracked.originalIdentifier
        tracked.window.setAccessibilityIdentifier(tracked.originalAccessibilityIdentifier)
    }

    private func applyManagedIdentity(to window: NSWindow) {
        let identifier: NSUserInterfaceItemIdentifier?
        if window is NSColorPanel {
            identifier = Self.nativeColorPanelIdentifier
        } else if window is NSOpenPanel {
            identifier = Self.nativeOpenPanelIdentifier
        } else if window is NSSavePanel {
            identifier = Self.nativeSavePanelIdentifier
        } else {
            identifier = nil
        }
        guard let identifier else { return }
        window.identifier = identifier
        window.setAccessibilityIdentifier(identifier.rawValue)
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
