import AppKit
import FounderOfficeCore
import Testing
@testable import OpenLoops

struct PriorityDragInteractionTests {
    @Test
    func edgeScrollIsIdleInTheCenterAndAtTheThreshold() {
        let policy = DragEdgeScrollPolicy(
            edgeExtent: 50,
            minimumSpeed: 100,
            maximumSpeed: 600
        )

        #expect(policy.velocity(pointerY: 50, viewportHeight: 300) == 0)
        #expect(policy.velocity(pointerY: 150, viewportHeight: 300) == 0)
        #expect(policy.velocity(pointerY: 250, viewportHeight: 300) == 0)
    }

    @Test
    func edgeScrollAcceleratesSmoothlyTowardEitherEdgeAndCapsOutside() {
        let policy = DragEdgeScrollPolicy(
            edgeExtent: 50,
            minimumSpeed: 100,
            maximumSpeed: 600
        )

        let nearTop = policy.velocity(pointerY: 45, viewportHeight: 300)
        let deepTop = policy.velocity(pointerY: 10, viewportHeight: 300)
        let nearBottom = policy.velocity(pointerY: 255, viewportHeight: 300)
        let deepBottom = policy.velocity(pointerY: 290, viewportHeight: 300)

        #expect(nearTop < 0)
        #expect(deepTop < nearTop)
        #expect(nearBottom > 0)
        #expect(deepBottom > nearBottom)
        #expect(policy.velocity(pointerY: -80, viewportHeight: 300) == -600)
        #expect(policy.velocity(pointerY: 380, viewportHeight: 300) == 600)
    }

    @Test
    func edgeScrollHandlesShortAndInvalidViewportsWithoutUndefinedValues() {
        let policy = DragEdgeScrollPolicy()

        #expect(policy.velocity(pointerY: 5, viewportHeight: 20).isFinite)
        #expect(policy.velocity(pointerY: 15, viewportHeight: 20).isFinite)
        #expect(policy.velocity(pointerY: 0, viewportHeight: 0) == 0)
    }

    @Test
    func directLaneContainmentWinsAndInputOrderDoesNotMatter() {
        let lanes = [
            PriorityDropLane(priority: .p2, minY: 220, maxY: 300),
            PriorityDropLane(priority: .p0, minY: 10, maxY: 90),
            PriorityDropLane(priority: .p1, minY: 110, maxY: 200)
        ]

        #expect(PriorityDropTargetPolicy.target(pointerY: 60, lanes: lanes, current: nil) == .p0)
        #expect(PriorityDropTargetPolicy.target(pointerY: 150, lanes: lanes, current: .p0) == .p1)
        #expect(PriorityDropTargetPolicy.target(pointerY: 260, lanes: lanes, current: .p1) == .p2)
    }

    @Test
    func gutterRetainsTheCurrentMagneticTargetWithinHysteresis() {
        let lanes = [
            PriorityDropLane(priority: .p0, minY: 10, maxY: 90),
            PriorityDropLane(priority: .p1, minY: 110, maxY: 200)
        ]

        #expect(
            PriorityDropTargetPolicy.target(
                pointerY: 98,
                lanes: lanes,
                current: .p0,
                hysteresis: 12
            ) == .p0
        )
        #expect(
            PriorityDropTargetPolicy.target(
                pointerY: 106,
                lanes: lanes,
                current: .p1,
                hysteresis: 12
            ) == .p1
        )
    }

    @Test
    func gutterAndViewportEdgesSnapToTheNearestLaneDeterministically() {
        let lanes = [
            PriorityDropLane(priority: .p0, minY: 10, maxY: 90),
            PriorityDropLane(priority: .p1, minY: 110, maxY: 200)
        ]

        #expect(PriorityDropTargetPolicy.target(pointerY: -20, lanes: lanes, current: nil) == .p0)
        #expect(PriorityDropTargetPolicy.target(pointerY: 100, lanes: lanes, current: nil) == .p0)
        #expect(PriorityDropTargetPolicy.target(pointerY: 240, lanes: lanes, current: nil) == .p1)
        #expect(PriorityDropTargetPolicy.target(pointerY: 40, lanes: [], current: .p0) == nil)
    }
}

@MainActor
struct PriorityDragAutoScrollerTests {
    private final class FlippedDocumentView: NSView {
        override var isFlipped: Bool { true }
    }

    @Test
    func stationaryPointerNearBottomContinuouslyScrollsUntilStopped() {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 180))
        scrollView.documentView = FlippedDocumentView(
            frame: NSRect(x: 0, y: 0, width: 300, height: 1_200)
        )
        let scroller = PriorityDragAutoScroller(
            policy: DragEdgeScrollPolicy(
                edgeExtent: 50,
                minimumSpeed: 120,
                maximumSpeed: 700
            )
        )
        scroller.attach(scrollView)
        let startingOffset = scrollView.contentView.bounds.origin.y

        scroller.update(pointerY: 179)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.12))
        let scrolledOffset = scrollView.contentView.bounds.origin.y
        scroller.stop()

        #expect(scrolledOffset > startingOffset + 10)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.06))
        #expect(abs(scrollView.contentView.bounds.origin.y - scrolledOffset) < 0.5)
    }

    @Test
    func flippedViewportScrollsBothDirectionsAndClampsAtItsBounds() {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 300, height: 180))
        scrollView.documentView = FlippedDocumentView(
            frame: NSRect(x: 0, y: 0, width: 300, height: 1_200)
        )
        let scroller = PriorityDragAutoScroller(
            policy: DragEdgeScrollPolicy(
                edgeExtent: 50,
                minimumSpeed: 120,
                maximumSpeed: 700
            )
        )
        scroller.attach(scrollView)
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: 500))

        scroller.update(pointerY: 1)
        scroller.advance(elapsed: 0.25)
        #expect(scrollView.contentView.bounds.origin.y < 500)

        let upwardOffset = scrollView.contentView.bounds.origin.y
        scroller.update(pointerY: 179)
        scroller.advance(elapsed: 0.25)
        #expect(scrollView.contentView.bounds.origin.y > upwardOffset)

        scroller.advance(elapsed: 10)
        let maximumOffset = scrollView.documentView!.bounds.height
            - scrollView.contentView.bounds.height
        #expect(abs(scrollView.contentView.bounds.origin.y - maximumOffset) < 0.5)
        scroller.stop()
    }

    @Test
    func sessionCompletionIsBalancedAndIdempotent() {
        let scroller = PriorityDragAutoScroller()
        var completionCount = 0
        let moveID = UUID()

        scroller.beginSession(moveID: moveID) { completionCount += 1 }
        #expect(scroller.draggedMoveID == moveID)
        scroller.endSession()
        scroller.endSession()

        #expect(completionCount == 1)
        #expect(scroller.pointerY == nil)
        #expect(scroller.draggedMoveID == nil)
    }

    @Test
    func beginningANewDragInvalidatesThePreviousMoveBeforeItCanCommit() {
        let scroller = PriorityDragAutoScroller()
        let firstID = UUID()
        let secondID = UUID()
        var endedIDs: [UUID] = []

        scroller.beginSession(moveID: firstID) { endedIDs.append(firstID) }
        scroller.beginSession(moveID: secondID) { endedIDs.append(secondID) }

        #expect(endedIDs == [firstID])
        #expect(scroller.draggedMoveID == secondID)

        scroller.endSession()
        #expect(endedIDs == [firstID, secondID])
        #expect(scroller.draggedMoveID == nil)
    }
}
