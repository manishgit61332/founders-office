import Foundation

struct NotchMorphMetrics {
    static let panelWidth: CGFloat = 720
    static let panelHeight: CGFloat = 350

    let settledProgress: CGFloat
    let contentProgress: CGFloat
    let shellWidth: CGFloat
    let shellHeight: CGFloat
    let topWidth: CGFloat
    let topRadius: CGFloat
    let bottomRadius: CGFloat
    let shoulderDepth: CGFloat
    let pullEnvelope: CGFloat
    let shellVisibility: CGFloat

    var isInteractive: Bool { settledProgress > 0.90 }

    init(progress: CGFloat, notchWidth rawNotchWidth: CGFloat, notchHeight rawNotchHeight: CGFloat) {
        settledProgress = min(max(progress, 0), 1)

        let notchWidth = min(max(rawNotchWidth, 160), 260)
        let notchHeight = min(max(rawNotchHeight, 24), 44)
        let widthProgress = pow(settledProgress, 0.62)
        let heightProgress = pow(settledProgress, 1.28)

        shellWidth = notchWidth + (Self.panelWidth - notchWidth) * widthProgress
        shellHeight = notchHeight + (Self.panelHeight - notchHeight) * heightProgress

        let neckProgress = Self.smoothstep((settledProgress - 0.18) / 0.82)
        let topCornerProgress = Self.smoothstep((settledProgress - 0.42) / 0.58)
        let bottomCornerProgress = Self.smoothstep(settledProgress)
        topWidth = notchWidth + (shellWidth - notchWidth) * neckProgress
        topRadius = 30 * topCornerProgress
        bottomRadius = 11 + 19 * bottomCornerProgress
        shoulderDepth = notchHeight + (30 - notchHeight) * settledProgress
        contentProgress = Self.smoothstep((settledProgress - 0.66) / 0.28)
        shellVisibility = Self.smoothstep(settledProgress / 0.06)

        // The physical notch stays pinned. Only the content-free shoulder phase
        // leans toward the cursor, and the pull is gone before UI content arrives.
        let pullPhase = min(max((settledProgress - 0.06) / 0.46, 0), 1)
        pullEnvelope = sin(.pi * pullPhase)
    }

    private static func smoothstep(_ value: CGFloat) -> CGFloat {
        let clamped = min(max(value, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }
}
