import AppKit
import FounderOfficeCore
import SwiftUI

struct DragEdgeScrollPolicy: Equatable {
    var edgeExtent: CGFloat = 88
    var minimumSpeed: CGFloat = 96
    var maximumSpeed: CGFloat = 640

    func velocity(pointerY: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        guard viewportHeight > 0, edgeExtent > 0, maximumSpeed > 0 else { return 0 }

        let resolvedExtent = min(edgeExtent, viewportHeight / 2)
        if pointerY < resolvedExtent {
            return -speed(for: (resolvedExtent - pointerY) / resolvedExtent)
        }

        let lowerEdge = viewportHeight - resolvedExtent
        if pointerY > lowerEdge {
            return speed(for: (pointerY - lowerEdge) / resolvedExtent)
        }

        return 0
    }

    private func speed(for rawProgress: CGFloat) -> CGFloat {
        let progress = min(max(rawProgress, 0), 1)
        let easedProgress = progress * progress * (3 - 2 * progress)
        let floor = min(max(minimumSpeed, 0), maximumSpeed)
        return floor * progress + (maximumSpeed - floor) * easedProgress
    }
}

struct PriorityDropLane: Equatable {
    var priority: LoopPriority
    var minY: CGFloat
    var maxY: CGFloat
}

enum PriorityDropTargetPolicy {
    static func target(
        pointerY: CGFloat,
        lanes: [PriorityDropLane],
        current: LoopPriority?,
        hysteresis: CGFloat = 12
    ) -> LoopPriority? {
        let validLanes = lanes
            .filter { $0.minY.isFinite && $0.maxY.isFinite && $0.maxY >= $0.minY }
            .sorted { lhs, rhs in
                if lhs.minY == rhs.minY { return lhs.priority.rank < rhs.priority.rank }
                return lhs.minY < rhs.minY
            }
        guard !validLanes.isEmpty else { return nil }

        if let containingLane = validLanes.first(where: {
            pointerY >= $0.minY && pointerY <= $0.maxY
        }) {
            return containingLane.priority
        }

        if let current,
           let currentLane = validLanes.first(where: { $0.priority == current }),
           pointerY >= currentLane.minY - hysteresis,
           pointerY <= currentLane.maxY + hysteresis {
            return current
        }

        return validLanes.min { lhs, rhs in
            distance(from: pointerY, to: lhs) < distance(from: pointerY, to: rhs)
        }?.priority
    }

    private static func distance(from pointerY: CGFloat, to lane: PriorityDropLane) -> CGFloat {
        if pointerY < lane.minY { return lane.minY - pointerY }
        if pointerY > lane.maxY { return pointerY - lane.maxY }
        return 0
    }
}

@MainActor
final class PriorityDragAutoScroller: ObservableObject {
    private weak var scrollView: NSScrollView?
    private var timer: Timer?
    private var localEventMonitor: Any?
    private var globalMouseMonitor: Any?
    private var sessionEnd: (() -> Void)?
    private var pointerUpdate: ((CGFloat?) -> Void)?
    private var releaseRequest: ((UUID, CGFloat?) -> Void)?
    private var pendingRelease: DispatchWorkItem?
    private var velocity: CGFloat = 0
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private let policy: DragEdgeScrollPolicy
    private let pointerExitMargin: CGFloat
    private let releaseGraceInterval: TimeInterval
    private(set) var pointerY: CGFloat?
    private(set) var draggedMoveID: UUID?
    var isAutoScrolling: Bool { timer != nil }

    init(
        policy: DragEdgeScrollPolicy = DragEdgeScrollPolicy(),
        pointerExitMargin: CGFloat = 96,
        releaseGraceInterval: TimeInterval = 0.12
    ) {
        self.policy = policy
        self.pointerExitMargin = pointerExitMargin
        self.releaseGraceInterval = releaseGraceInterval
    }

    func attach(_ scrollView: NSScrollView?) {
        // SwiftUI can briefly dismantle and recreate representable backgrounds
        // while a LazyVStack scrolls. Do not detach the live drag from a valid
        // viewport during that transient relayout.
        if scrollView == nil,
           draggedMoveID != nil,
           self.scrollView?.window != nil {
            return
        }
        guard self.scrollView !== scrollView else { return }
        let existingPointerY = pointerY
        stop()
        self.scrollView = scrollView
        if let existingPointerY, scrollView != nil {
            update(pointerY: existingPointerY)
        }
    }

    func update(pointerY: CGFloat) {
        guard let scrollView else {
            stop()
            return
        }

        self.pointerY = pointerY
        pointerUpdate?(pointerY)
        velocity = policy.velocity(
            pointerY: pointerY,
            viewportHeight: scrollView.contentView.bounds.height
        )
        if abs(velocity) < 0.5 {
            stopTimer()
        } else {
            startTimerIfNeeded()
        }
    }

    /// Converts native drag events into stable viewport coordinates. The last
    /// validated value remains authoritative while a stationary pointer drives
    /// auto-scroll; polling the global cursor can diverge from synthesized or
    /// accessibility-driven mouse events.
    @discardableResult
    func update(pointerInWindow point: NSPoint) -> Bool {
        guard let scrollView, scrollView.window != nil else { return false }
        let clipView = scrollView.contentView
        let converted = clipView.convert(point, from: nil)
        let bounds = clipView.bounds
        let localX = converted.x - bounds.minX
        let rawLocalY = converted.y - bounds.minY
        let isNearViewport = localX >= -pointerExitMargin
            && localX <= bounds.width + pointerExitMargin
            && rawLocalY >= -pointerExitMargin
            && rawLocalY <= bounds.height + pointerExitMargin

        guard isNearViewport else {
            leaveViewport()
            return false
        }

        let topOriginY = clipView.isFlipped
            ? rawLocalY
            : bounds.height - rawLocalY
        update(pointerY: topOriginY)
        return true
    }

    @discardableResult
    func refreshPointerFromWindow() -> Bool {
        guard let window = scrollView?.window else { return false }
        return update(pointerInWindow: window.mouseLocationOutsideOfEventStream)
    }

    func stop() {
        velocity = 0
        stopTimer()
    }

    func leaveViewport() {
        pointerY = nil
        pointerUpdate?(nil)
        stop()
    }

    func beginSession(
        moveID: UUID,
        onPointerUpdate: @escaping (CGFloat?) -> Void = { _ in },
        onRelease: @escaping (UUID, CGFloat?) -> Void = { _, _ in },
        onEnd: @escaping () -> Void
    ) {
        endSession()
        draggedMoveID = moveID
        pointerUpdate = onPointerUpdate
        releaseRequest = onRelease
        sessionEnd = onEnd

        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDragged, .leftMouseUp, .keyDown]
        ) { [weak self] event in
            if event.type == .leftMouseDragged {
                DispatchQueue.main.async {
                    guard let self else { return }
                    if event.window === self.scrollView?.window {
                        self.update(pointerInWindow: event.locationInWindow)
                    } else {
                        self.refreshPointerFromWindow()
                    }
                }
            }
            if event.type == .leftMouseUp {
                let releasePoint = event.window === self?.scrollView?.window
                    ? event.locationInWindow
                    : nil
                DispatchQueue.main.async {
                    self?.scheduleRelease(pointerInWindow: releasePoint)
                }
            } else if event.type == .keyDown && event.keyCode == 53 {
                DispatchQueue.main.async {
                    self?.endSession()
                }
            }
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            DispatchQueue.main.async {
                self?.scheduleRelease()
            }
        }
    }

    func endSession() {
        pendingRelease?.cancel()
        pendingRelease = nil
        stop()
        pointerY = nil
        draggedMoveID = nil
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        let completion = sessionEnd
        pointerUpdate = nil
        releaseRequest = nil
        sessionEnd = nil
        completion?()
    }

    /// Native mouse-up monitors run before SwiftUI's gesture completion. Give
    /// the gesture one short grace period to commit first, then perform the same
    /// in-app fallback commit when the pointer is still over the viewport.
    func scheduleRelease(pointerInWindow: NSPoint? = nil) {
        guard pendingRelease == nil, draggedMoveID != nil else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, let moveID = self.draggedMoveID else { return }
            let isInsideViewport = pointerInWindow.map(self.update(pointerInWindow:))
                ?? (self.pointerY != nil)
            if isInsideViewport {
                self.releaseRequest?(moveID, self.pointerY)
            }
            self.endSession()
        }
        pendingRelease = workItem
        if releaseGraceInterval > 0 {
            DispatchQueue.main.asyncAfter(
                deadline: .now() + releaseGraceInterval,
                execute: workItem
            )
        } else {
            workItem.perform()
        }
    }

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        lastTick = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard draggedMoveID != nil, pointerY != nil else {
            stop()
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = min(max(now - lastTick, 1 / 240), 1 / 15)
        lastTick = now
        advance(elapsed: elapsed)
    }

    /// Kept internal so direction and boundary behaviour can be verified
    /// without making tests depend on wall-clock timer scheduling.
    func advance(elapsed: TimeInterval) {
        guard let scrollView,
              let documentView = scrollView.documentView,
              abs(velocity) >= 0.5,
              elapsed > 0
        else {
            stop()
            return
        }

        let coordinateVelocity = documentView.isFlipped ? velocity : -velocity
        var proposedBounds = scrollView.contentView.bounds
        proposedBounds.origin.y += coordinateVelocity * elapsed
        let constrainedBounds = scrollView.contentView.constrainBoundsRect(proposedBounds)

        guard abs(constrainedBounds.origin.y - scrollView.contentView.bounds.origin.y) > 0.01 else {
            velocity = 0
            stopTimer()
            return
        }
        scrollView.contentView.scroll(to: constrainedBounds.origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)

        // `NSClipView` may align every proposed origin to backing pixels or
        // content insets. That correction is not a document boundary. Probe a
        // point beyond the document in the active direction and stop only when
        // the constrained origin has actually reached that terminal position.
        var boundaryProbe = constrainedBounds
        let probeDistance = max(documentView.bounds.height, constrainedBounds.height, 1)
        boundaryProbe.origin.y += coordinateVelocity > 0 ? probeDistance : -probeDistance
        let terminalBounds = scrollView.contentView.constrainBoundsRect(boundaryProbe)
        if abs(terminalBounds.origin.y - constrainedBounds.origin.y) <= 0.01 {
            velocity = 0
            stopTimer()
        }
    }
}

struct PriorityLaneFramePreferenceKey: PreferenceKey {
    static let defaultValue: [LoopPriority: CGRect] = [:]

    static func reduce(
        value: inout [LoopPriority: CGRect],
        nextValue: () -> [LoopPriority: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

struct PriorityScrollViewResolver: NSViewRepresentable {
    let onResolve: @MainActor (NSScrollView?) -> Void

    func makeNSView(context: Context) -> ResolverView {
        let view = ResolverView()
        view.onResolve = onResolve
        return view
    }

    func updateNSView(_ nsView: ResolverView, context: Context) {
        nsView.onResolve = onResolve
        nsView.resolveEnclosingScrollView()
    }

    static func dismantleNSView(_ nsView: ResolverView, coordinator: Void) {
        nsView.onResolve?(nil)
    }

    final class ResolverView: NSView {
        var onResolve: (@MainActor (NSScrollView?) -> Void)?

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            resolveEnclosingScrollView()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            resolveEnclosingScrollView()
        }

        func resolveEnclosingScrollView() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.onResolve?(self.enclosingScrollView)
            }
        }
    }
}
