import SwiftUI

// One source of truth for the small status pills that appear on post cards,
// library tiles, and profile rows. Sizing was inconsistent before — every
// call site had its own padding/tracking/fill numbers. They now share one
// vocabulary so a feed badge and a profile badge feel like the same family.

/// Solid LIVE pill — used on profile rows and library tiles for published tracks.
struct LiveBadge: View {
    @Environment(\.theme) private var theme
    var body: some View {
        Text("LIVE")
            .font(.wwav(9, weight: .medium))
            .tracking(1.5)
            .foregroundStyle(theme.glow)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(theme.accent))
    }
}

/// Dot-and-text capsule for the published-vs-draft state on library tiles.
struct StateBadge: View {
    let isDraft: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isDraft ? theme.accent : theme.glow)
                .frame(width: 5, height: 5)
            Text(isDraft ? "draft" : "live")
                .font(.wwav(9, weight: .medium))
                .tracking(1.1)
        }
        .foregroundStyle(isDraft ? theme.ink : theme.glow)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(
                isDraft
                    ? AnyShapeStyle(theme.glow.opacity(WWAVOpacity.firm))
                    : AnyShapeStyle(theme.ink.opacity(0.78))
            )
        )
    }
}

/// Tiny uppercase chip that names a non-music post kind ("text", "image", "video").
struct KindBadge: View {
    let label: String
    @Environment(\.theme) private var theme

    var body: some View {
        Text(label)
            .font(.wwav(9, weight: .medium))
            .tracking(1.2)
            .foregroundStyle(theme.muted)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(theme.muted.opacity(WWAVOpacity.veil)))
    }
}
