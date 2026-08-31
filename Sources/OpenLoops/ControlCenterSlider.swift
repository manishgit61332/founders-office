import SwiftUI

/// A compact, accessible slider for Control Center-style grouped surfaces.
/// The thumb stays quiet at rest and returns for pointer, keyboard, and drag use.
struct ControlCenterSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let tint: Color
    let focusTint: Color
    let onEditingChanged: (Bool) -> Void

    @State private var isDragging = false
    @State private var isHovered = false
    @FocusState private var isFocused: Bool

    private let knobSize: CGFloat = 10
    private let trackHeight: CGFloat = 4

    private var progress: Double {
        let distance = range.upperBound - range.lowerBound
        guard distance > 0 else { return 0 }
        return min(max((value - range.lowerBound) / distance, 0), 1)
    }

    var body: some View {
        GeometryReader { proxy in
            let travel = max(proxy.size.width - knobSize, 0)
            let knobOffset = travel * progress

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.14))
                    .frame(height: trackHeight)

                Capsule()
                    .fill(tint)
                    .frame(width: max(proxy.size.width * progress, trackHeight), height: trackHeight)

                Circle()
                    .fill(Color.white.opacity(0.94))
                    .frame(width: knobSize, height: knobSize)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.28), lineWidth: 0.5)
                    )
                    .shadow(color: Color.black.opacity(0.34), radius: 2.5, y: 1)
                    .scaleEffect(isDragging ? 1.08 : isHovered ? 1.04 : 1)
                    .opacity(isDragging || isHovered || isFocused ? 1 : 0)
                    .offset(x: knobOffset)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isFocused ? focusTint.opacity(0.78) : Color.clear, lineWidth: 1)
            )
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !isDragging {
                            onEditingChanged(true)
                        }
                        isDragging = true
                        updateValue(at: gesture.location.x, width: proxy.size.width)
                    }
                    .onEnded { gesture in
                        updateValue(at: gesture.location.x, width: proxy.size.width)
                        onEditingChanged(false)
                        withAnimation(.spring(response: 0.20, dampingFraction: 0.78)) {
                            isDragging = false
                        }
                    }
            )
        }
        .frame(height: 20)
        .focusable()
        .focused($isFocused)
        .focusEffectDisabled()
        .onMoveCommand { direction in
            switch direction {
            case .left, .down:
                adjust(by: -step)
            case .right, .up:
                adjust(by: step)
            default:
                break
            }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                adjust(by: step)
            case .decrement:
                adjust(by: -step)
            @unknown default:
                break
            }
        }
        .onDisappear {
            if isDragging {
                onEditingChanged(false)
            }
        }
    }

    private func updateValue(at location: CGFloat, width: CGFloat) {
        guard step > 0 else { return }
        let travel = max(width - knobSize, 1)
        let resolvedLocation = min(max(location - knobSize / 2, 0), travel)
        let rawValue = range.lowerBound + (resolvedLocation / travel) * (range.upperBound - range.lowerBound)
        let steppedValue = ((rawValue - range.lowerBound) / step).rounded() * step + range.lowerBound
        value = min(max(steppedValue, range.lowerBound), range.upperBound)
    }

    private func adjust(by amount: Double) {
        guard step > 0 else { return }
        onEditingChanged(true)
        value = min(max(value + amount, range.lowerBound), range.upperBound)
        onEditingChanged(false)
    }
}
