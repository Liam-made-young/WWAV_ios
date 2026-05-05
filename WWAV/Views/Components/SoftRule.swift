import SwiftUI

struct SoftRule: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.0),
                        .init(color: theme.muted.opacity(0.30), location: 0.2),
                        .init(color: theme.muted.opacity(0.30), location: 0.8),
                        .init(color: .clear, location: 1.0),
                    ],
                    startPoint: .leading, endPoint: .trailing
                )
            )
            .frame(height: 1)
    }
}
