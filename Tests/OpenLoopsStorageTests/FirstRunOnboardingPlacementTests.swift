import AppKit
import SwiftUI
import Testing
@testable import OpenLoops

@MainActor
struct FirstRunOnboardingPlacementTests {
    @Test
    func hostingControllerFrameCollapseCannotMoveOnboardingOffscreen() {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: FirstRunOnboardingPlacement.panelSize),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        defer { panel.close() }

        panel.contentViewController = NSHostingController(
            rootView: Color.clear.frame(
                width: FirstRunOnboardingPlacement.panelSize.width,
                height: FirstRunOnboardingPlacement.panelSize.height
            )
        )
        panel.setFrame(NSRect(origin: .zero, size: .zero), display: false)

        let visibleFrame = NSRect(x: 0, y: 66, width: 1_728, height: 1_018)
        panel.setFrame(
            FirstRunOnboardingPlacement.frame(visibleFrame: visibleFrame),
            display: false
        )

        #expect(panel.frame.size == FirstRunOnboardingPlacement.panelSize)
        #expect(visibleFrame.contains(panel.frame))
        #expect(panel.frame.maxY == visibleFrame.maxY - FirstRunOnboardingPlacement.screenMargin)
    }

    @Test
    func placementUsesVisibleFrameWithNegativeScreenOrigin() {
        let visibleFrame = NSRect(x: -1_920, y: 23, width: 1_920, height: 1_057)

        let frame = FirstRunOnboardingPlacement.frame(visibleFrame: visibleFrame)

        #expect(visibleFrame.contains(frame))
        #expect(frame.midX == visibleFrame.midX)
        #expect(frame.maxY == visibleFrame.maxY - FirstRunOnboardingPlacement.screenMargin)
    }

    @Test
    func placementUsesVisibleFrameOnVerticallyStackedDisplay() {
        let visibleFrame = NSRect(x: 120, y: 1_117, width: 1_440, height: 860)

        let frame = FirstRunOnboardingPlacement.frame(visibleFrame: visibleFrame)

        #expect(visibleFrame.contains(frame))
        #expect(frame.midX == visibleFrame.midX)
        #expect(frame.maxY == visibleFrame.maxY - FirstRunOnboardingPlacement.screenMargin)
    }

    @Test
    func compactDisplayReducesMarginWithoutCroppingThePanel() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 740, height: 520)

        let frame = FirstRunOnboardingPlacement.frame(visibleFrame: visibleFrame)

        #expect(visibleFrame.contains(frame))
        #expect(frame.origin == NSPoint(x: 10, y: 10))
    }

    @Test
    func autoHiddenMenuBarStillKeepsOnboardingBelowTheHardwareNotch() {
        let screenFrame = NSRect(x: 0, y: 0, width: 1_728, height: 1_117)
        let safeVisibleFrame = FirstRunOnboardingPlacement.safeVisibleFrame(
            screenFrame: screenFrame,
            visibleFrame: screenFrame,
            safeAreaInsets: NSEdgeInsets(top: 38, left: 0, bottom: 0, right: 0)
        )

        let frame = FirstRunOnboardingPlacement.frame(visibleFrame: safeVisibleFrame)

        #expect(safeVisibleFrame.maxY == 1_079)
        #expect(frame.maxY == safeVisibleFrame.maxY - FirstRunOnboardingPlacement.screenMargin)
        #expect(screenFrame.contains(frame))
    }
}
