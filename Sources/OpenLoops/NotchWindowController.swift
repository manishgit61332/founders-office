import AppKit
import FounderOfficeCore
import SwiftUI

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class NotchPresentationModel: ObservableObject {
    @Published var progress: CGFloat = 0
    @Published var horizontalPull: CGFloat = 0
    @Published var notchWidth: CGFloat = 185
    @Published var notchHeight: CGFloat = 32
    let transients = TransientPresentationCoordinator()

    var preventsAutoDismiss: Bool { transients.preventsAutoDismiss }

    @discardableResult
    func beginInteraction(_ reason: String, suspendsHost: Bool = false) -> UUID {
        transients.begin(reason, suspendsHost: suspendsHost)
    }

    func endInteraction(_ lease: UUID) {
        transients.end(lease)
    }

    func clearInteractions() {
        transients.cancelAll()
    }

    func closeNativeColorPanels() {
        transients.closeNativeColorPanels()
    }
}

@MainActor
final class NotchWindowController {
    private enum PanelState {
        case hidden
        case opening
        case open
        case suspended
        case closing
    }

    private let store: OpenLoopStore
    #if !FOUNDER_OFFICE_DISTRIBUTION
    private let codexRunner: CodexRunner
    #endif
    private let personalization: PersonalizationStore
    private let calendarProvider: CalendarProvider
    private let account: FounderOfficeAccountController
    private let health: FounderOfficeHealthModel
    private let presentation = NotchPresentationModel()
    private let panel: NotchPanel

    private var hoverTimer: Timer?
    private var springTimer: Timer?
    private var exitStartedAt: Date?
    private var lastSpringFrameAt: Date?
    private var springVelocity: CGFloat = 0
    private var springTarget: CGFloat = 0
    private var state: PanelState = .hidden
    private var previewMode = false
    private var awaitingManualEntry = false
    private var suppressHoverRevealUntilHidden = false
    private var isResolvingAppearanceExit = false
    private var pendingRepositionAfterTransient = false
    private var escapeMonitor: Any?
    private var systemObservers: [NSObjectProtocol] = []

    init(
        store: OpenLoopStore,
        personalization: PersonalizationStore? = nil,
        calendarMode: CalendarProvider.Mode = .live
    ) {
        #if !FOUNDER_OFFICE_DISTRIBUTION
        let runner = CodexRunner(founderOfficeURL: store.rootURL)
        #endif
        let personalizationStore = personalization ?? PersonalizationStore(session: store.session)
        let calendar = CalendarProvider(mode: calendarMode)
        self.store = store
        #if !FOUNDER_OFFICE_DISTRIBUTION
        codexRunner = runner
        #endif
        self.personalization = personalizationStore
        calendarProvider = calendar
        panel = NotchPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 350),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.level = .statusBar
        panel.title = "Founder's Office"
        panel.identifier = NSUserInterfaceItemIdentifier("foundersOffice.notch")
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        account = FounderOfficeAccountController.live(
            infoDictionary: Bundle.main.infoDictionary ?? [:],
            hostWindow: panel,
            presentation: presentation,
            localContext: { [weak store, weak personalizationStore] in
                guard let store, let personalizationStore else {
                    return FounderOfficeLocalAccountContext(
                        hasCustomerData: false,
                        boundAccountID: nil
                    )
                }
                let hasMoves = store.items.contains { $0.deletedAt == nil }
                let hasPersonalization = !personalizationStore.preferredName.isEmpty
                    || personalizationStore.workspaceName != "Founder's Office"
                    || personalizationStore.photoURL != nil
                    || personalizationStore.primaryGoal != nil
                    || !personalizationStore.milestones.isEmpty
                return FounderOfficeLocalAccountContext(
                    hasCustomerData: hasMoves || hasPersonalization,
                    boundAccountID: nil
                )
            },
            applyReviewedDisplayName: { [weak personalizationStore] name in
                personalizationStore?.updatePreferredName(name)
            }
        )
        #if FOUNDER_OFFICE_DISTRIBUTION
        health = FounderOfficeHealthModel(
            store: store,
            personalization: personalizationStore,
            calendar: calendar,
            accountSync: account
        )
        #else
        health = FounderOfficeHealthModel(
            store: store,
            personalization: personalizationStore,
            calendar: calendar,
            assistant: runner,
            accountSync: account
        )
        #endif
        #if FOUNDER_OFFICE_DISTRIBUTION
        panel.contentViewController = NSHostingController(
            rootView: NotchBoardView(
                store: store,
                personalization: self.personalization,
                calendarProvider: calendarProvider,
                account: account,
                health: health,
                presentation: presentation
            ) { [weak self] in self?.requestExplicitClose() }
        )
        #else
        panel.contentViewController = NSHostingController(
            rootView: NotchBoardView(
                store: store,
                codexRunner: codexRunner,
                personalization: self.personalization,
                calendarProvider: calendarProvider,
                account: account,
                health: health,
                presentation: presentation
            ) { [weak self] in self?.requestExplicitClose() }
        )
        #endif
        presentation.transients.configure(
            hostWindow: panel,
            isHostExpanded: { [weak self] in
                guard let self else { return false }
                return self.state == .opening || self.state == .open
            },
            suspendHost: { [weak self] in
                self?.suspendForTransientPresentation()
            },
            restoreHost: { [weak self] in
                self?.restoreAfterTransientPresentation()
            }
        )

        startHoverMonitor()
        startSystemObservers()
        startEscapeMonitor()
        account.start()
    }

    var isVisible: Bool { state != .hidden }
    var hasUnsavedAppearanceChanges: Bool { personalization.hasUnsavedAppearanceChanges }
    var hasPendingWorkspaceWrites: Bool {
        store.hasPendingWrites
            || personalization.hasPendingWrites
            || store.hasUnresolvedWriteFailure
            || personalization.hasUnresolvedWriteFailure
    }
    private var shouldReduceMotion: Bool {
        #if FOUNDER_OFFICE_DISTRIBUTION
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #else
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            || ProcessInfo.processInfo.environment["OPENLOOPS_UI_TEST_REDUCE_MOTION"] == "1"
        #endif
    }

    func resolveUnsavedAppearanceForTermination() async -> Bool {
        if state == .hidden || state == .closing {
            show(manual: true)
        }
        guard await resolveAppearanceDraftForExit(
            title: "Save your appearance before quitting?",
            detail: "The current preview has not been saved to this Mac.",
            cancelsRestorationOnAccept: false
        ) else { return false }
        let canTerminate = await finishPendingWritesBeforeTermination()
        if canTerminate {
            presentation.clearInteractions()
        }
        return canTerminate
    }

    private func resolveAppearanceDraftForExit(
        title: String,
        detail: String,
        cancelsRestorationOnAccept: Bool = true
    ) async -> Bool {
        guard personalization.hasUnsavedAppearanceChanges else { return true }
        guard !isResolvingAppearanceExit else { return false }
        isResolvingAppearanceExit = true
        defer { isResolvingAppearanceExit = false }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "Save Changes")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")

        presentation.transients.present(
            alert.window,
            request: TransientPresentationRequest(
                kind: .systemAlert,
                hostDisposition: .suspendExpandedHost
            )
        )
        let response = alert.runModal()
        let choice: AppearanceTerminationChoice
        switch response {
        case .alertFirstButtonReturn:
            choice = .save
        case .alertSecondButtonReturn:
            choice = .discard
        default:
            choice = .cancel
        }

        switch choice {
        case .save:
            let result = await personalization.saveAppearanceChanges()
            let decision = AppearanceTerminationPolicy.decision(for: choice, saveResult: result)
            guard decision == .terminate else {
                presentation.transients.endScoped(to: alert.window)
                return false
            }
            if cancelsRestorationOnAccept {
                presentation.clearInteractions()
            } else {
                presentation.transients.endScoped(to: alert.window)
            }
            return true
        case .discard:
            personalization.discardAppearanceChanges()
            if cancelsRestorationOnAccept {
                presentation.clearInteractions()
            } else {
                presentation.transients.endScoped(to: alert.window)
            }
            return true
        case .cancel:
            presentation.transients.endScoped(to: alert.window)
            return false
        }
    }

    private func finishPendingWritesBeforeTermination() async -> Bool {
        async let movesSaved = store.waitForPendingWrites()
        async let personalizationSaved = personalization.waitForPendingWrites()
        guard await movesSaved, await personalizationSaved else {
            if state == .hidden || state == .closing {
                show(manual: true)
            }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Founder’s Office is still saving"
            alert.informativeText = "A workspace change could not be safely committed. Review the save message and try again before quitting."
            alert.addButton(withTitle: "Keep Editing")
            _ = runSystemAlert(alert)
            return false
        }
        return true
    }

    func prepareForTermination() {
        #if !FOUNDER_OFFICE_DISTRIBUTION
        codexRunner.prepareForTermination()
        #endif
        account.stop()
        personalization.discardAppearanceChanges()
        presentation.clearInteractions()
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
    }

    func runSystemAlert(_ alert: NSAlert) -> NSApplication.ModalResponse {
        presentation.transients.present(
            alert.window,
            request: TransientPresentationRequest(
                kind: .systemAlert,
                hostDisposition: .suspendExpandedHost
            )
        )
        defer { presentation.transients.endScoped(to: alert.window) }
        return alert.runModal()
    }

    func show(preview: Bool = false, manual: Bool = false) {
        // A status-item Open action can arrive while a native panel is still
        // active. Keep the host suspended until the coordinator releases the
        // final lease instead of revealing the notch behind that panel.
        guard state != .suspended || !presentation.preventsAutoDismiss else { return }
        previewMode = preview
        if manual {
            awaitingManualEntry = true
            // A deliberate reopen supersedes the post-close hover suppression
            // used to stop the same pointer position from reopening the notch.
            suppressHoverRevealUntilHidden = false
        }
        guard let screen = targetScreen() else { return }
        exitStartedAt = nil
        calendarProvider.syncOnOpen()

        if state == .hidden {
            position(on: screen)
            presentation.progress = 0
            presentation.horizontalPull = magneticPull(on: screen)
            springVelocity = 3.4
            panel.orderFrontRegardless()
        }

        if shouldReduceMotion {
            springTimer?.invalidate()
            springTimer = nil
            presentation.progress = 1
            presentation.horizontalPull = 0
            springVelocity = 0
            panel.ignoresMouseEvents = false
            state = .open
            return
        }

        state = .opening
        animateSpring(to: 1)
    }

    func showSnapshot() {
        previewMode = true
        guard let screen = targetScreen() else { return }
        calendarProvider.syncOnOpen()
        springTimer?.invalidate()
        springTimer = nil
        exitStartedAt = nil
        lastSpringFrameAt = nil
        springVelocity = 0
        springTarget = 1
        position(on: screen)
        presentation.progress = 1
        presentation.horizontalPull = 0
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
        panel.displayIfNeeded()
        state = .open
    }

    func hide(force: Bool = false) {
        guard state != .hidden, state != .closing else { return }
        guard force || !previewMode else { return }
        guard force || (
            !presentation.preventsAutoDismiss
                && !presentation.transients.hasVisiblePresentedWindow
        ) else { return }
        previewMode = false
        awaitingManualEntry = false
        if force {
            presentation.clearInteractions()
            suppressHoverRevealUntilHidden = true
            pendingRepositionAfterTransient = false
        }
        exitStartedAt = nil
        state = .closing
        panel.ignoresMouseEvents = true

        if shouldReduceMotion {
            springTimer?.invalidate()
            springTimer = nil
            presentation.progress = 0
            springVelocity = 0
            panel.orderOut(nil)
            state = .hidden
            return
        }

        if springVelocity > -1.8 {
            springVelocity = -1.8
        }
        animateSpring(to: 0)
    }

    func toggle() {
        if state == .hidden || state == .closing {
            show(manual: true)
        } else {
            requestExplicitClose()
        }
    }

    func requestExplicitClose() {
        guard state != .hidden, state != .closing else { return }
        guard personalization.hasUnsavedAppearanceChanges else {
            hide(force: true)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let shouldClose = await self.resolveAppearanceDraftForExit(
                title: "Save your appearance before closing?",
                detail: "The preview will stay available if you keep editing."
            )
            guard shouldClose else { return }
            self.hide(force: true)
        }
    }

    func capture(to url: URL) throws {
        guard let contentView = panel.contentView else { return }
        panel.displayIfNeeded()
        let bounds = contentView.bounds
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(bounds.width),
            pixelsHigh: Int(bounds.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return }
        bitmap.size = bounds.size
        contentView.cacheDisplay(in: bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
        try data.write(to: url, options: .atomic)
    }

    private func startHoverMonitor() {
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkPointer()
            }
        }
        timer.tolerance = 1.0 / 240.0
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    private func startEscapeMonitor() {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            let consumed = MainActor.assumeIsolated {
                guard let self,
                      let colourPanel = NSApp.keyWindow as? NSColorPanel,
                      self.presentation.transients.isTracking(colourPanel) else {
                    return false
                }
                colourPanel.orderOut(nil)
                self.presentation.transients.endScoped(to: colourPanel)
                return true
            }
            return consumed ? nil : event
        }
    }

    private func startSystemObservers() {
        let center = NotificationCenter.default
        systemObservers.append(
            center.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.repositionVisiblePanel()
                }
            }
        )
        systemObservers.append(
            center.addObserver(
                forName: NSMenu.didBeginTrackingNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let menu = notification.object as? NSMenu else { return }
                let menuID = ObjectIdentifier(menu)
                var ancestor: NSMenu? = menu
                var isStatusMenuTree = false
                while let candidate = ancestor {
                    if candidate.identifier == TransientPresentationCoordinator.statusMenuIdentifier {
                        isStatusMenuTree = true
                        break
                    }
                    ancestor = candidate.supermenu
                }
                MainActor.assumeIsolated {
                    guard let self,
                          self.presentation.transients.shouldTrackMenuOrigin(
                            isStatusMenuTree: isStatusMenuTree
                          ) else { return }
                    self.presentation.transients.present(
                        request: TransientPresentationRequest(
                            kind: .menu,
                            hostDisposition: .suspendExpandedHost
                        ),
                        scopedTo: menuID
                    )
                }
            }
        )
        systemObservers.append(
            center.addObserver(
                forName: NSMenu.didEndTrackingNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let menu = notification.object as? NSMenu else { return }
                let menuID = ObjectIdentifier(menu)
                MainActor.assumeIsolated {
                    self?.presentation.transients.endScoped(key: menuID)
                }
            }
        )
        systemObservers.append(
            center.addObserver(
                forName: NSPopover.willShowNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let popover = notification.object as? NSPopover else { return }
                MainActor.assumeIsolated {
                    guard let self,
                          self.presentation.transients.shouldTrack(popover) else { return }
                    self.presentation.transients.present(
                        request: TransientPresentationRequest(
                            kind: .popover,
                            hostDisposition: .suspendExpandedHost
                        ),
                        scopedTo: popover
                    )
                    DispatchQueue.main.async { [weak self, weak popover] in
                        guard let self, let popover,
                              let window = popover.contentViewController?.view.window else { return }
                        self.presentation.transients.elevate(window, scopedTo: popover)
                    }
                }
            }
        )
        systemObservers.append(
            center.addObserver(
                forName: NSPopover.didCloseNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let popover = notification.object as? NSPopover else { return }
                MainActor.assumeIsolated {
                    self?.presentation.transients.endScoped(to: popover)
                }
            }
        )
        systemObservers.append(
            center.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let window = notification.object as? NSWindow else { return }
                MainActor.assumeIsolated {
                    self?.presentation.transients.noteKeyResignation(window)
                }
            }
        )
        systemObservers.append(
            center.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let window = notification.object as? NSWindow,
                      window is NSColorPanel || window is NSOpenPanel || window is NSSavePanel else { return }
                MainActor.assumeIsolated {
                    guard let self,
                          self.presentation.transients.shouldTrack(window) else { return }
                    let kind: TransientPresentationKind = window is NSColorPanel
                        ? .colorPanel
                        : .fileChooser
                    self.presentation.transients.present(
                        window,
                        request: TransientPresentationRequest(
                            kind: kind,
                            hostDisposition: .suspendExpandedHost
                        )
                    )
                }
            }
        )
        systemObservers.append(
            center.addObserver(
                forName: NSWindow.willCloseNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let window = notification.object as? NSWindow else { return }
                MainActor.assumeIsolated {
                    guard let self,
                          self.presentation.transients.isTracking(window) else { return }
                    self.presentation.transients.endScoped(to: window)
                }
            }
        )
        systemObservers.append(
            center.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let window = notification.object as? NSWindow,
                      window is NSColorPanel || window is NSOpenPanel || window is NSSavePanel else { return }
                DispatchQueue.main.async { [weak self, weak window] in
                    guard let self, let window,
                          self.presentation.transients.isTracking(window) else { return }
                    guard !window.isVisible else { return }
                    self.presentation.transients.endScoped(to: window)
                }
            }
        )
        systemObservers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.repositionVisiblePanel()
                }
            }
        )
    }

    private func repositionVisiblePanel() {
        guard state != .hidden, let screen = targetScreen() else { return }
        guard !presentation.preventsAutoDismiss, state != .suspended else {
            pendingRepositionAfterTransient = true
            return
        }
        position(on: screen)
    }

    private func restoreAfterTransientPresentation() {
        exitStartedAt = nil
        if pendingRepositionAfterTransient, let screen = targetScreen() {
            pendingRepositionAfterTransient = false
            position(on: screen)
        }
        if state == .hidden || state == .closing || state == .suspended {
            show()
            return
        }
        panel.orderFrontRegardless()
        panel.ignoresMouseEvents = false
    }

    private func suspendForTransientPresentation() {
        guard state == .opening || state == .open else { return }
        springTimer?.invalidate()
        springTimer = nil
        lastSpringFrameAt = nil
        springVelocity = 0
        springTarget = 0
        exitStartedAt = nil
        presentation.horizontalPull = 0
        presentation.progress = 0
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()
        state = .suspended
    }

    private func checkPointer() {
        guard !previewMode, let screen = targetScreen() else { return }
        let pointer = NSEvent.mouseLocation
        let hotZone = revealZone(on: screen)
        let interactionZone = visibleShellFrame().insetBy(dx: -12, dy: -12)
        let isInside = hotZone.contains(pointer) || (state != .hidden && interactionZone.contains(pointer))

        if presentation.preventsAutoDismiss || presentation.transients.hasVisiblePresentedWindow {
            exitStartedAt = nil
            return
        }

        if suppressHoverRevealUntilHidden {
            if state != .hidden || hotZone.contains(pointer) {
                exitStartedAt = nil
                return
            }
            suppressHoverRevealUntilHidden = false
        }

        if awaitingManualEntry {
            if isInside {
                awaitingManualEntry = false
            } else {
                exitStartedAt = nil
                return
            }
        }

        if isInside {
            exitStartedAt = nil
            if state == .hidden || state == .closing {
                show()
            }
            return
        }

        guard state == .opening || state == .open else { return }
        if exitStartedAt == nil {
            exitStartedAt = Date()
            return
        }

        if Date().timeIntervalSince(exitStartedAt!) >= 0.24 {
            hide()
        }
    }

    private func animateSpring(to target: CGFloat) {
        springTarget = target
        springTimer?.invalidate()
        lastSpringFrameAt = Date()

        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.stepSpring()
            }
        }
        timer.tolerance = 1.0 / 480.0
        RunLoop.main.add(timer, forMode: .common)
        springTimer = timer
    }

    private func stepSpring() {
        let now = Date()
        let previous = lastSpringFrameAt ?? now
        let deltaTime = min(max(now.timeIntervalSince(previous), 1.0 / 240.0), 1.0 / 30.0)
        lastSpringFrameAt = now

        let opening = springTarget == 1
        let stiffness: CGFloat = opening ? 240 : 340
        let damping: CGFloat = opening ? 24 : 30
        let displacement = springTarget - presentation.progress
        let acceleration = displacement * stiffness - springVelocity * damping

        springVelocity += acceleration * deltaTime
        presentation.progress += springVelocity * deltaTime

        if opening {
            presentation.progress = min(max(presentation.progress, 0), 1.045)
        } else {
            presentation.progress = min(max(presentation.progress, -0.018), 1.045)
        }
        updatePanelMouseHandling()

        let isSettled = abs(springTarget - presentation.progress) < 0.0015 && abs(springVelocity) < 0.035
        let collapsedThroughNotch = !opening && presentation.progress <= 0 && springVelocity < 0

        if isSettled || collapsedThroughNotch {
            springTimer?.invalidate()
            springTimer = nil
            lastSpringFrameAt = nil
            presentation.progress = springTarget
            springVelocity = 0

            if opening {
                presentation.horizontalPull = 0
                panel.ignoresMouseEvents = false
                state = .open
            } else {
                panel.ignoresMouseEvents = true
                panel.orderOut(nil)
                state = .hidden
            }
        }
    }

    private func targetScreen() -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(pointer) }) ?? NSScreen.main
    }

    private func revealZone(on screen: NSScreen) -> NSRect {
        let menuHeight = max(34, screen.frame.maxY - screen.visibleFrame.maxY + 8)
        let width = max(180, notchSize(on: screen).width + 28)

        return NSRect(
            x: screen.frame.midX - width / 2,
            y: screen.frame.maxY - menuHeight,
            width: width,
            height: menuHeight
        )
    }

    private func magneticPull(on screen: NSScreen) -> CGFloat {
        let delta = NSEvent.mouseLocation.x - screen.frame.midX
        return min(max(delta * 0.16, -18), 18)
    }

    private func visibleShellFrame() -> NSRect {
        let metrics = NotchMorphMetrics(
            progress: presentation.progress,
            notchWidth: presentation.notchWidth,
            notchHeight: presentation.notchHeight
        )
        let bodyPull = presentation.horizontalPull * metrics.pullEnvelope
        return NSRect(
            x: panel.frame.midX - metrics.shellWidth / 2 + bodyPull,
            y: panel.frame.maxY - metrics.shellHeight,
            width: metrics.shellWidth,
            height: metrics.shellHeight
        )
    }

    private func updatePanelMouseHandling() {
        let metrics = NotchMorphMetrics(
            progress: presentation.progress,
            notchWidth: presentation.notchWidth,
            notchHeight: presentation.notchHeight
        )
        panel.ignoresMouseEvents = !metrics.isInteractive || state == .closing
    }

    private func position(on screen: NSScreen) {
        // The hosting controller can temporarily report a zero-sized frame
        // before its first layout pass, so use the panel's fixed product size.
        let size = NSSize(width: 720, height: 350)
        // The panel itself touches the physical top edge so the spring visibly
        // grows out of the notch. The board layout intentionally leaves the
        // centre-top hardware region empty; controls live in the safe areas on
        // either side of the cutout.
        let physicalTop = screen.frame.maxY
        let notchSize = notchSize(on: screen)
        presentation.notchWidth = notchSize.width
        presentation.notchHeight = notchSize.height
        let origin = NSPoint(
            x: screen.frame.midX - size.width / 2,
            y: physicalTop - size.height
        )
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func notchSize(on screen: NSScreen) -> NSSize {
        if #available(macOS 12.0, *),
           let leftArea = screen.auxiliaryTopLeftArea,
           let rightArea = screen.auxiliaryTopRightArea {
            return NSSize(
                width: max(160, rightArea.minX - leftArea.maxX),
                height: max(24, max(leftArea.height, rightArea.height))
            )
        }

        return NSSize(width: 185, height: 32)
    }
}
