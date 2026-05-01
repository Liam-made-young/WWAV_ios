import SwiftUI

struct MiniWaveform: View {
    var bars: [Int] = [3,7,12,8,16,22,18,11,6,9,14,20,16,10,5,8,13,18,14,7]
    var progress: Double = 0.4   // 0...1
    var accent: Bool = false

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .center, spacing: 1.5) {
            ForEach(Array(bars.enumerated()), id: \.offset) { idx, h in
                let played = Double(idx) / Double(bars.count) < progress
                Rectangle()
                    .fill(played
                          ? (accent ? theme.accent : theme.ink)
                          : (accent ? theme.accent.opacity(0.25) : theme.ink.opacity(0.18)))
                    .frame(width: 2, height: CGFloat(h))
                    .clipShape(RoundedRectangle(cornerRadius: 0.5))
            }
        }
        .frame(height: 22)
    }
}
