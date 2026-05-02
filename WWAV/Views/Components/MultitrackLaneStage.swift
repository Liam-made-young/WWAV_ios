import SwiftUI

// MARK: – MultitrackLaneStage
//
// Draws four vertical waveform lanes side by side, one per StemKind.
//
// Layout: newest samples appear at the TOP of each lane; older samples slide
// downward as new peaks arrive — matching the "Ableton turned 90°" brief.
// Each lane is rendered via SwiftUI Canvas for performance.
//
// Tapping a lane selects it (calls onSelectLane). The active lane glows;
// finished and idle lanes are dimmed.

struct MultitrackLaneStage: View {
    /// Rolling peak history per lane (newest first, max ~256 entries).
    let peaks: [StemKind: [Float]]
    /// Current recording state per lane.
    let laneStates: [StemKind: RecordLaneState]
    /// Which lane is currently focused / selected for recording.
    let focusedLane: StemKind
    /// Called when the user taps a lane header or column to focus it.
    let onSelectLane: (StemKind) -> Void

    @Environment(\.theme) private var theme

    private let lanes = StemKind.allCases

    var body: some View {
        HStack(spacing: 4) {
            ForEach(lanes) { kind in
                laneColumn(kind)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(
                    LinearGradient(
                        colors: [theme.clay.opacity(0.10), theme.clayDeep.opacity(0.06)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(theme.muted.opacity(0.22), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: Single lane column

    @ViewBuilder
    private func laneColumn(_ kind: StemKind) -> some View {
        let st = laneStates[kind] ?? .idle
        let isFocused = focusedLane == kind
        let isRecording = st == .recording
        let isDone = st == .done
        let dim = !isFocused && !isRecording

        VStack(spacing: 0) {
            // Label row
            Text(kind.label)
                .font(.wwav(9, weight: isFocused ? .medium : .light))
                .tracking(1.5)
                .foregroundStyle(isFocused ? theme.accent : theme.muted.opacity(0.7))
                .frame(height: 22)
                .frame(maxWidth: .infinity)
                .background(laneHeaderBg(isFocused: isFocused, isRecording: isRecording))

            // Waveform canvas
            GeometryReader { geo in
                Canvas { ctx, size in
                    drawVerticalLane(
                        ctx: ctx,
                        size: size,
                        peaks: peaks[kind] ?? [],
                        isRecording: isRecording,
                        isDone: isDone,
                        isFocused: isFocused,
                        theme: theme
                    )
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .overlay(
            // Focused lane border
            RoundedRectangle(cornerRadius: 6)
                .stroke(
                    isFocused ? theme.accent.opacity(0.6) : Color.clear,
                    lineWidth: 1.5
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .opacity(dim ? 0.55 : 1.0)
        .animation(.easeInOut(duration: 0.2), value: isFocused)
        .onTapGesture { onSelectLane(kind) }
    }

    private func laneHeaderBg(isFocused: Bool, isRecording: Bool) -> some View {
        if isRecording {
            return AnyView(Color.red.opacity(0.22))
        } else if isFocused {
            return AnyView(theme.clay.opacity(0.30))
        } else {
            return AnyView(theme.muted.opacity(0.07))
        }
    }
}

// MARK: – Vertical lane waveform drawing
//
// Peaks are drawn top-down: index 0 (newest) is at the TOP of the canvas.
// Each peak becomes a horizontal bar centred in the lane; wider = louder.
// A thin centre-line marks silence.

private func drawVerticalLane(
    ctx: GraphicsContext,
    size: CGSize,
    peaks: [Float],
    isRecording: Bool,
    isDone: Bool,
    isFocused: Bool,
    theme: Palette
) {
    let blockH: CGFloat = 3
    let gap: CGFloat = 1
    let stride = blockH + gap
    let maxBlocks = Int(size.height / stride)
    let centerX = size.width / 2
    let maxHalf = size.width * 0.46

    // Choose bar colour
    let barColor: Color
    if isRecording {
        barColor = Color.red.opacity(0.82)
    } else if isDone {
        barColor = Color(uiColor: UIColor(theme.accent)).opacity(0.72)
    } else if isFocused {
        barColor = Color(uiColor: UIColor(theme.clay)).opacity(0.78)
    } else {
        barColor = Color(uiColor: UIColor(theme.muted)).opacity(0.55)
    }

    // Centre baseline (always drawn)
    let baseRect = CGRect(x: centerX - 0.75, y: 0, width: 1.5, height: size.height)
    ctx.fill(Path(baseRect), with: .color(barColor.opacity(0.18)))

    // Draw each peak block.
    for i in 0..<min(maxBlocks, peaks.isEmpty ? 0 : peaks.count) {
        let rms = CGFloat(peaks[i])
        let half = rms * maxHalf
        let y = CGFloat(i) * stride
        // Ensure minimum visible width even at very low RMS.
        let visibleHalf = max(half, 1.0)
        let rect = CGRect(
            x: centerX - visibleHalf,
            y: y,
            width: visibleHalf * 2,
            height: blockH
        )
        ctx.fill(
            Path(roundedRect: rect, cornerRadius: 1),
            with: .color(barColor)
        )
    }

    // When idle/no data, draw a subtle dashed centre line.
    if peaks.isEmpty {
        let dashH: CGFloat = 4
        let dashGap: CGFloat = 4
        var yy: CGFloat = 0
        while yy < size.height {
            let r = CGRect(x: centerX - 0.75, y: yy, width: 1.5, height: dashH)
            ctx.fill(Path(r), with: .color(barColor.opacity(0.25)))
            yy += dashH + dashGap
        }
    }
}
