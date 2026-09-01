import AppKit
import SwiftUI
import Testing
@testable import OpenLoops

@MainActor
struct FirstRunOnboardingPlacementTests {
    @Test
    func onboardingChromeUsesOneTransparentSquircleWithoutAWindowShadow() throws {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: FirstRunOnboardingPlacement.panelSize),
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        defer { panel.close() }
        panel.hasShadow = true
        FirstRunOnboardingChrome.configure(panel)

        panel.contentViewController = NSHostingController(
            rootView: FirstRunOnboardingShell {
                Color.white
            }
        )
        panel.setFrame(
            NSRect(origin: .zero, size: FirstRunOnboardingPlacement.panelSize),
            display: false
        )
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.contentView?.displayIfNeeded()

        #expect(panel.styleMask.contains(.borderless))
        #expect(panel.styleMask.contains(.fullSizeContentView))
        #expect(panel.isOpaque == false)
        #expect(panel.backgroundColor.alphaComponent == 0)
        #expect(panel.hasShadow == false)

        for scale in [CGFloat(1), CGFloat(2)] {
            let bitmap = try #require(renderedBitmap(of: panel, scale: scale))
            let width = bitmap.pixelsWide
            let height = bitmap.pixelsHigh
            let sampleSpan = Int(7 * scale)
            for x in 0..<sampleSpan {
                for y in 0..<sampleSpan {
                    let xCoordinates = [x, width - 1 - x]
                    let yCoordinates = [y, height - 1 - y]
                    for sampleX in xCoordinates {
                        for sampleY in yCoordinates {
                            let point = (sampleX, sampleY)
                            let color = try #require(bitmap.colorAt(x: sampleX, y: sampleY))
                            #expect(
                                color.alphaComponent <= 0.01,
                                "Onboarding exterior must be transparent at \(point) at \(scale)x, not alpha \(color.alphaComponent)."
                            )
                        }
                    }
                }
            }

            let center = try #require(bitmap.colorAt(x: width / 2, y: height / 2))
            #expect(center.alphaComponent >= 0.99)
        }
    }

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

    private func renderedBitmap(of panel: NSPanel, scale: CGFloat) -> NSBitmapImageRep? {
        guard let contentView = panel.contentView else { return nil }
        let bounds = contentView.bounds
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(bounds.width * scale),
            pixelsHigh: Int(bounds.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        bitmap.size = bounds.size
        contentView.cacheDisplay(in: bounds, to: bitmap)
        return bitmap
    }
}
