import AppKit
import FounderOfficeCore
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let founderOfficeMove = UTType(exportedAs: "com.manish.foundersoffice.move")
}

struct DragEdgeScrollPolicy: Equatable {
    var edgeExtent: CGFloat = 56
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
    private var velocity: CGFloat = 0
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private let policy: DragEdgeScrollPolicy
    private(set) var pointerY: CGFloat?
    private(set) var draggedMoveID: UUID?

    init(policy: DragEdgeScrollPolicy = DragEdgeScrollPolicy()) {
        self.policy = policy
    }

    func attach(_ scrollView: NSScrollView?) {
        guard self.scrollView !== scrollView else { return }
        stop()
        self.scrollView = scrollView
    }

    func update(pointerY: CGFloat) {
        guard let scrollView else {
            stop()
            return
        }

        self.pointerY = pointerY
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

    func stop() {
        velocity = 0
        stopTimer()
    }

    func leaveViewport() {
        pointerY = nil
        stop()
    }

    func beginSession(moveID: UUID, onEnd: @escaping () -> Void) {
        endSession()
        draggedMoveID = moveID
        sessionEnd = onEnd

        localEventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseUp, .keyDown]
        ) { [weak self] event in
            let shouldEnd = event.type == .leftMouseUp
                || (event.type == .keyDown && event.keyCode == 53)
            if shouldEnd {
                DispatchQueue.main.async {
                    self?.endSession()
                }
            }
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            DispatchQueue.main.async {
                self?.endSession()
            }
        }
    }

    func endSession() {
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
        sessionEnd = nil
        completion?()
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
            return
        }
        scrollView.contentView.scroll(to: constrainedBounds.origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
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

@MainActor
struct PriorityBoardDropDelegate: DropDelegate {
    var laneFrames: [LoopPriority: CGRect]
    var activeTarget: LoopPriority?
    var autoScroller: PriorityDragAutoScroller
    var onTargetChange: (LoopPriority?) -> Void
    var onDropMove: (UUID, LoopPriority) -> Bool

    func validateDrop(info: DropInfo) -> Bool {
        autoScroller.draggedMoveID != nil
            && !laneFrames.isEmpty
            && info.hasItemsConforming(to: [UTType.founderOfficeMove])
    }

    func dropEntered(info: DropInfo) {
        updateInteraction(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateInteraction(info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        autoScroller.leaveViewport()
        setTarget(nil)
    }

    func performDrop(info: DropInfo) -> Bool {
        autoScroller.stop()
        guard let target = resolvedTarget(pointerY: info.location.y) ?? activeTarget,
              info.itemProviders(for: [UTType.founderOfficeMove]).first != nil,
              let moveID = autoScroller.draggedMoveID
        else {
            setTarget(nil)
            autoScroller.endSession()
            return false
        }

        // The item provider is deliberately own-process. Committing the ID
        // captured when this drag began avoids an asynchronous provider load
        // from an older drag mutating a newer session.
        let didCommit = onDropMove(moveID, target)
        setTarget(nil)
        autoScroller.endSession()
        return didCommit
    }

    private func updateInteraction(_ info: DropInfo) {
        autoScroller.update(pointerY: info.location.y)
        setTarget(resolvedTarget(pointerY: info.location.y))
    }

    private func resolvedTarget(pointerY: CGFloat) -> LoopPriority? {
        PriorityDropTargetPolicy.target(
            pointerY: pointerY,
            lanes: laneFrames.map { priority, frame in
                PriorityDropLane(priority: priority, minY: frame.minY, maxY: frame.maxY)
            },
            current: activeTarget
        )
    }

    private func setTarget(_ target: LoopPriority?) {
        guard target != activeTarget else { return }
        onTargetChange(target)
    }
}
