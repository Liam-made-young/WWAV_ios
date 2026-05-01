import SwiftUI

/// Round avatar that loads from a remote URL when available, falling back
/// to the themed gradient circle otherwise. Used on the profile screen and
/// in the settings sheet so a single change updates both.
struct ProfileAvatar: View {
    let url: URL?
    var size: CGFloat = 96

    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img):
                        img
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .empty, .failure:
                        fallback
                    @unknown default:
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(
            Circle().stroke(theme.muted.opacity(0.20), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.18), radius: 6, y: 4)
    }

    private var fallback: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [theme.sand, theme.clay, theme.clayDeep],
                    center: UnitPoint(x: 0.35, y: 0.30),
                    startRadius: 4, endRadius: size * 0.95
                )
            )
    }
}
