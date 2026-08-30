import AppKit
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
}

@MainActor
final class NotchWindowController {
    private enum PanelState {
        case hidden
        case opening
        case open
        case closing
    }

    private let store: OpenLoopStore
    private let codexRunner: CodexRunner
    private let personalization: PersonalizationStore
    private let calendarProvider: CalendarProvider
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
    private var systemObservers: [NSObjectProtocol] = []

    init(store: OpenLoopStore) {
        self.store = store
        codexRunner = CodexRunner(founderOfficeURL: store.rootURL.deletingLastPathComponent())
        personalization = PersonalizationStore(rootURL: store.rootURL)
        calendarProvider = CalendarProvider()
        panel = NotchPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 350),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.level = .statusBar
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
        panel.contentViewController = NSHostingController(
            rootView: NotchBoardView(
                store: store,
                codexRunner: codexRunner,
                personalization: personalization,
                calendarProvider: calendarProvider,
                presentation: presentation
            ) { [weak self] in self?.hide(force: true) }
        )

        startHoverMonitor()
        startSystemObservers()
    }

    var isVisible: Bool { state != .hidden }

    func show(preview: Bool = false, manual: Bool = false) {
        previewMode = preview
        if manual {
            awaitingManualEntry = true
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

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
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
        previewMode = false
        awaitingManualEntry = false
        if force {
            suppressHoverRevealUntilHidden = true
        }
        exitStartedAt = nil
        state = .closing
        panel.ignoresMouseEvents = true

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
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
            hide(force: true)
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

    private func startSystemObservers() {
        let center = NotificationCenter.default
        systemObservers.append(
            center.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.repositionVisiblePanel()
                }
            }
        )
        systemObservers.append(
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.repositionVisiblePanel()
                }
            }
        )
    }

    private func repositionVisiblePanel() {
        guard state != .hidden, let screen = targetScreen() else { return }
        position(on: screen)
    }

    private func checkPointer() {
        guard !previewMode, let screen = targetScreen() else { return }
        let pointer = NSEvent.mouseLocation
        let hotZone = revealZone(on: screen)
        let interactionZone = visibleShellFrame().insetBy(dx: -12, dy: -12)
        let isInside = hotZone.contains(pointer) || (state != .hidden && interactionZone.contains(pointer))

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
