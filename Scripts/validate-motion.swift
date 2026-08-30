import Foundation

struct Result {
    let duration: Double
    let finalProgress: Double
    let peakProgress: Double
    let finalVelocity: Double
}

func simulate(
    progress initialProgress: Double,
    velocity initialVelocity: Double,
    target: Double,
    stiffness: Double,
    damping: Double,
    maximumDuration: Double = 2
) -> Result {
    let deltaTime = 1.0 / 120.0
    var progress = initialProgress
    var velocity = initialVelocity
    var peak = progress
    var elapsed = 0.0

    while elapsed < maximumDuration {
        let acceleration = (target - progress) * stiffness - velocity * damping
        velocity += acceleration * deltaTime
        progress += velocity * deltaTime
        peak = max(peak, progress)
        elapsed += deltaTime

        if target == 0, progress <= 0, velocity < 0 {
            progress = 0
            velocity = 0
            break
        }

        if abs(target - progress) < 0.0015, abs(velocity) < 0.035 {
            progress = target
            velocity = 0
            break
        }
    }

    return Result(duration: elapsed, finalProgress: progress, peakProgress: peak, finalVelocity: velocity)
}

let opening = simulate(progress: 0, velocity: 3.4, target: 1, stiffness: 240, damping: 24)
let closing = simulate(progress: 1, velocity: -1.8, target: 0, stiffness: 340, damping: 30)

let partialClose = simulate(
    progress: 1,
    velocity: -1.8,
    target: 0,
    stiffness: 340,
    damping: 30,
    maximumDuration: 0.12
)
let reversal = simulate(
    progress: partialClose.finalProgress,
    velocity: partialClose.finalVelocity,
    target: 1,
    stiffness: 240,
    damping: 24
)

let panelWidth = 720.0
let panelHeight = 350.0
let notchWidth = 185.0
let notchHeight = 32.0

func smoothstep(_ value: Double) -> Double {
    let clamped = min(max(value, 0), 1)
    return clamped * clamped * (3 - 2 * clamped)
}

func morph(at progress: Double) -> (width: Double, topWidth: Double, height: Double, content: Double, pull: Double, visibility: Double) {
    let settled = min(max(progress, 0), 1)
    let widthProgress = pow(settled, 0.62)
    let heightProgress = pow(settled, 1.28)
    let width = notchWidth + (panelWidth - notchWidth) * widthProgress
    let height = notchHeight + (panelHeight - notchHeight) * heightProgress
    let neckProgress = smoothstep((settled - 0.18) / 0.82)
    let topWidth = notchWidth + (width - notchWidth) * neckProgress
    let content = smoothstep((settled - 0.66) / 0.28)
    let pullPhase = min(max((settled - 0.06) / 0.46, 0), 1)
    let pull = sin(.pi * pullPhase)
    let visibility = smoothstep(settled / 0.06)
    return (width, topWidth, height, content, pull, visibility)
}

let collapsedMorph = morph(at: 0)
let earlyMorph = morph(at: 0.20)
let settledMorph = morph(at: 1)
let samples = stride(from: 0.0, through: 1.0, by: 0.02).map(morph)
let widthsAreMonotonic = zip(samples, samples.dropFirst()).allSatisfy { $0.width <= $1.width }
let heightsAreMonotonic = zip(samples, samples.dropFirst()).allSatisfy { $0.height <= $1.height }
let topWidthsAreMonotonic = zip(samples, samples.dropFirst()).allSatisfy { $0.topWidth <= $1.topWidth }
let earlyWidthProgress = (earlyMorph.width - notchWidth) / (panelWidth - notchWidth)
let earlyHeightProgress = (earlyMorph.height - notchHeight) / (panelHeight - notchHeight)

let checks = [
    opening.duration > 0.20 && opening.duration < 0.80,
    opening.peakProgress >= 1.0 && opening.peakProgress <= 1.06,
    closing.duration > 0.10 && closing.duration < 0.45,
    closing.finalProgress == 0,
    partialClose.finalProgress > 0 && partialClose.finalProgress < 1,
    reversal.duration > 0.15 && reversal.duration < 0.80,
    reversal.finalProgress == 1,
    abs(collapsedMorph.width - notchWidth) < 0.001,
    abs(collapsedMorph.topWidth - notchWidth) < 0.001,
    abs(collapsedMorph.height - notchHeight) < 0.001,
    abs(collapsedMorph.pull) < 0.000_001,
    collapsedMorph.visibility == 0,
    earlyMorph.topWidth < earlyMorph.width,
    earlyWidthProgress > earlyHeightProgress,
    earlyMorph.pull > 0,
    abs(morph(at: 0.52).pull) < 0.000_001,
    abs(settledMorph.pull) < 0.000_001,
    settledMorph.visibility == 1,
    morph(at: 0.65).content == 0,
    morph(at: 0.94).content == 1,
    abs(settledMorph.width - panelWidth) < 0.001,
    abs(settledMorph.topWidth - panelWidth) < 0.001,
    abs(settledMorph.height - panelHeight) < 0.001,
    widthsAreMonotonic,
    heightsAreMonotonic,
    topWidthsAreMonotonic,
]

print(String(format: "open %.3fs, peak %.4f", opening.duration, opening.peakProgress))
print(String(format: "close %.3fs", closing.duration))
print(String(format: "reverse from %.4f in %.3fs", partialClose.finalProgress, reversal.duration))
print(String(format: "morph %.0fx%.0f notch → %.0fx%.0f panel", collapsedMorph.width, collapsedMorph.height, settledMorph.width, settledMorph.height))
print(String(format: "early shoulders %.0f top / %.0f body", earlyMorph.topWidth, earlyMorph.width))

if checks.contains(false) {
    fputs("Motion validation failed.\n", stderr)
    exit(1)
}

print("Motion validation passed.")
