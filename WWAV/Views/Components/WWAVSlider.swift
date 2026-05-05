import SwiftUI
import UIKit

/// Custom horizontal slider for FX dry/wet panels and any other continuous
/// control that needs to feel native to the WWAV language.
///
/// Geometry:
/// - 2pt track, full width, capsule-clipped.
/// - Filled portion uses an accent → clay gradient so the user sees the
///   value bleed in from the left.
/// - 22pt thumb is a glassy radial-gradient orb lit from `WWAVLight.sun`
///   (same upper-left light source as the player coin and avatars).
struct WWAVSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1

    @Environment(\.theme) private var theme
    @State private var isDragging = false

    private let trackHeight: CGFloat = 2
    private let thumbDiameter: CGFloat = 22

    var body: some View {
        GeometryReader { geo in
            let usable = max(geo.size.width - thumbDiameter, 1)
            let normalized = ((value - range.lowerBound) / (range.upperBound - range.lowerBound))
                .clamped(to: 0...1)
            let thumbX = thumbDiameter / 2 + CGFloat(normalized) * usable

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(theme.muted.opacity(WWAVOpacity.veil))
                    .frame(height: trackHeight)

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [theme.accent, theme.clay],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )
                    .frame(width: thumbX, height: trackHeight)

                thumb
                    .position(x: thumbX, y: geo.size.height / 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        if !isDragging {
                            isDragging = true
                            UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.6)
                        }
                        let x = (drag.location.x - thumbDiameter / 2).clamped(to: 0...usable)
                        let n = Double(x / usable)
                        value = range.lowerBound + n * (range.upperBound - range.lowerBound)
                    }
                    .onEnded { _ in isDragging = false }
            )
        }
        .frame(height: thumbDiameter)
    }

    private var thumb: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        theme.glow.opacity(0.85),
                        theme.accent,
                        theme.clayDeep,
                    ],
                    center: WWAVLight.sun,
                    startRadius: 1,
                    endRadius: thumbDiameter * 0.95
                )
            )
            .frame(width: thumbDiameter, height: thumbDiameter)
            .overlay(
                Circle().stroke(theme.glow.opacity(0.45), lineWidth: 0.5)
            )
            .shadow(color: theme.clayDeep.opacity(0.30), radius: 6, y: 3)
            .scaleEffect(isDragging ? 1.08 : 1.0)
            .animation(.spring(response: 0.18, dampingFraction: 0.85), value: isDragging)
    }
}

private extension Comparable {
    func clamped(to limits: ClosedRange<Self>) -> Self {
        min(max(self, limits.lowerBound), limits.upperBound)
    }
}
