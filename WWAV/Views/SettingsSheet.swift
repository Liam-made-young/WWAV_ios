import SwiftUI

struct SettingsSheet: View {
    @EnvironmentObject var auth: AuthManager
    @EnvironmentObject var themeManager: ThemeManager
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            theme.centerRadial.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    HStack {
                        Text("settings").wwavTitle(size: 36)
                        Spacer()
                        Button {
                            dismiss()
                        } label: {
                            Text("done")
                                .font(.wwav(13, weight: .light, italic: true))
                                .foregroundStyle(theme.muted)
                        }
                        .buttonStyle(.plain)
                    }

                    paletteSection
                    typefaceSection

                    accountSection

                    Spacer(minLength: 16)
                }
                .padding(.horizontal, 28)
                .padding(.top, 24)
                .padding(.bottom, 36)
            }
        }
    }

    private var paletteSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("palette").wwavLabel(size: 10, tracking: 2.5)

            VStack(spacing: 10) {
                ForEach(Palette.all, id: \.id) { p in
                    PaletteRow(
                        palette: p,
                        active: p.id == themeManager.palette.id
                    ) {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            themeManager.choose(p)
                        }
                    }
                }
            }
        }
    }

    private var typefaceSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("font").wwavLabel(size: 10, tracking: 2.5)

            VStack(spacing: 10) {
                ForEach(WWAVTypeface.allCases) { typeface in
                    TypefaceRow(
                        typeface: typeface,
                        active: typeface.id == themeManager.typeface.id
                    ) {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            themeManager.choose(typeface)
                        }
                    }
                }
            }
        }
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("account").wwavLabel(size: 10, tracking: 2.5)

            if let u = auth.user {
                HStack(spacing: 14) {
                    ProfileAvatar(url: u.profilePictureURL, size: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(u.username).wwavTitle(size: 22)
                        if let email = u.email {
                            Text(email)
                                .font(.wwav(12, weight: .light))
                                .foregroundStyle(theme.muted)
                        }
                    }
                    Spacer()
                }
                .padding(.bottom, 6)
            }

            Button {
                auth.logout()
                dismiss()
            } label: {
                Text("sign out")
                    .font(.wwav(13, weight: .regular, italic: true))
                    .tracking(2)
                    .foregroundStyle(theme.glow)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(
                        Capsule().fill(LinearGradient(
                            colors: [theme.clay, theme.clayDeep],
                            startPoint: .top, endPoint: .bottom
                        ))
                    )
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
            }
            .buttonStyle(.plain)
        }
    }
}

private struct PaletteRow: View {
    let palette: Palette
    let active: Bool
    let onTap: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                swatch
                VStack(alignment: .leading, spacing: 2) {
                    Text(palette.displayName)
                        .font(.wwav(16, weight: .light, italic: true))
                        .foregroundStyle(theme.ink)
                    Text(active ? "active" : "tap to apply")
                        .font(.wwav(10, weight: .light))
                        .tracking(1.5)
                        .foregroundStyle(theme.muted)
                }
                Spacer()
                Circle()
                    .stroke(theme.muted.opacity(0.4), lineWidth: 1)
                    .frame(width: 18, height: 18)
                    .overlay(
                        Circle()
                            .fill(theme.accent)
                            .frame(width: 10, height: 10)
                            .opacity(active ? 1 : 0)
                    )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14).fill(
                    LinearGradient(colors: [theme.sand, theme.sandDeep.opacity(0.6)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(active ? theme.accent.opacity(0.7) : theme.muted.opacity(0.2),
                            lineWidth: active ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    /// Three-dot swatch of the palette's clayDeep / accent / glow.
    private var swatch: some View {
        ZStack {
            Circle().fill(palette.clayDeep).frame(width: 26, height: 26)
                .offset(x: -10)
            Circle().fill(palette.accent).frame(width: 22, height: 22)
            Circle().fill(palette.glow).frame(width: 14, height: 14)
                .offset(x: 9)
                .overlay(Circle().stroke(palette.clayDeep.opacity(0.2), lineWidth: 0.5)
                            .frame(width: 14, height: 14)
                            .offset(x: 9))
        }
        .frame(width: 50, height: 26)
    }
}

private struct TypefaceRow: View {
    let typeface: WWAVTypeface
    let active: Bool
    let onTap: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                Text("Aa")
                    .font(typeface.font(size: 22, weight: .medium, italic: false))
                    .foregroundStyle(active ? theme.glow : theme.ink)
                    .frame(width: 50, height: 34)
                    .background(
                        Capsule().fill(active ? theme.accent : theme.muted.opacity(0.12))
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(typeface.displayName)
                        .font(typeface.font(size: 16, weight: .light, italic: true))
                        .foregroundStyle(theme.ink)
                    Text(active ? "active" : "tap to apply")
                        .font(typeface.font(size: 10, weight: .light, italic: false))
                        .tracking(1.5)
                        .foregroundStyle(theme.muted)
                }

                Spacer()

                Circle()
                    .stroke(theme.muted.opacity(0.4), lineWidth: 1)
                    .frame(width: 18, height: 18)
                    .overlay(
                        Circle()
                            .fill(theme.accent)
                            .frame(width: 10, height: 10)
                            .opacity(active ? 1 : 0)
                    )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14).fill(
                    LinearGradient(colors: [theme.sand, theme.sandDeep.opacity(0.6)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(active ? theme.accent.opacity(0.7) : theme.muted.opacity(0.2),
                            lineWidth: active ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }
}
