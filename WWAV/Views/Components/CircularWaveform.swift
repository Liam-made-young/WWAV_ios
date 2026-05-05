import SwiftUI

/// Circular waveform ring around the 3-D stem widget.
///
/// Direct port of `MiWWAVV2Page.jsx :: drawWave` — 240 radial bars going
/// outward from the centered sphere. Played bars are bright with an
/// accent-colored glow, unplayed bars are accent-colored at lower opacity.
/// Bar zero starts at the top (12 o'clock) and the ring sweeps clockwise.
///
/// Doubles as the scrub bar: tap or drag anywhere in the ring (the donut
/// area between `innerRadius` and the outer edge) to seek. Taps inside the
/// donut hole pass through to whatever sits below in the ZStack.
struct CircularWaveform: View {
    let peaks: [Float]
    let progress: Double          // 0...1
    let canvasSize: CGFloat
    let innerRadius: CGFloat      // matches the visual edge of the 3-D sphere
    let maxBarHeight: CGFloat
    var onSeek: ((Double) -> Void)? = nil

    @Environment(\.theme) private var theme

    var body: some View {
        Canvas { ctx, size in
            let cx = size.width / 2
            let cy = size.height / 2
            let n = peaks.count
            guard n > 0 else { return }

            for i in 0..<n {
                let angle = (Double(i) / Double(n)) * .pi * 2 - .pi / 2
                let peak = CGFloat(peaks[i])
                let barH = max(2, peak * maxBarHeight)
                let played = (Double(i) / Double(n)) <= progress

                let x0 = cx + cos(angle) * innerRadius
                let y0 = cy + sin(angle) * innerRadius
                let x1 = cx + cos(angle) * (innerRadius + barH)
                let y1 = cy + sin(angle) * (innerRadius + barH)

                var path = Path()
                path.move(to: CGPoint(x: x0, y: y0))
                path.addLine(to: CGPoint(x: x1, y: y1))

                if played {
                    var glow = ctx
                    glow.addFilter(.shadow(color: theme.accent.opacity(0.9), radius: 6))
                    glow.stroke(
                        path,
                        with: .color(.white),
                        style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
                    )
                } else {
                    ctx.stroke(
                        path,
                        with: .color(theme.accent.opacity(0.42)),
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                    )
                }
            }
        }
        .frame(width: canvasSize, height: canvasSize)
        // Donut hit area: ring catches gestures, center hole passes through
        // to whatever is below in the ZStack (the 3-D widget).
        .contentShape(
            DonutShape(
                innerRadius: max(0, innerRadius * 0.92),
                outerRadius: canvasSize / 2 + 8
            ),
            eoFill: true
        )
        .gesture(seekGesture)
    }

    private var seekGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                handleSeek(at: value.location)
            }
    }

    private func handleSeek(at point: CGPoint) {
        guard let onSeek else { return }
        let center = canvasSize / 2
        let dx = point.x - center
        let dy = point.y - center
        // atan2 returns -π..π with 0 at 3 o'clock, +π/2 at 6 o'clock.
        // Convert to a 0..1 progress where 0 = 12 o'clock, sweeping clockwise.
        var angle = atan2(dy, dx) + .pi / 2
        if angle < 0 { angle += 2 * .pi }
        let frac = max(0, min(1, angle / (2 * .pi)))
        onSeek(frac)
    }
}

/// Annulus shape used as a hit-test region. Two concentric ellipses
/// combined with `eoFill: true` produce a donut: inside outer + inside
/// inner = 0 (excluded), inside outer + outside inner = 1 (included).
struct DonutShape: Shape {
    let innerRadius: CGFloat
    let outerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let center = CGPoint(x: rect.midX, y: rect.midY)
        p.addEllipse(in: CGRect(
            x: center.x - outerRadius, y: center.y - outerRadius,
            width: outerRadius * 2, height: outerRadius * 2
        ))
        p.addEllipse(in: CGRect(
            x: center.x - innerRadius, y: center.y - innerRadius,
            width: innerRadius * 2, height: innerRadius * 2
        ))
        return p
    }
}
