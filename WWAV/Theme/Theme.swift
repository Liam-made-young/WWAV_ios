import SwiftUI

// Type ramp — Fraunces with a refined serif fallback.
private let kFraunces = "Fraunces"

extension Font {
    static func wwav(_ size: CGFloat, weight: Font.Weight = .light, italic: Bool = false) -> Font {
        let f = Font.custom(kFraunces, size: size, relativeTo: .body)
        let weighted = f.weight(weight)
        return italic ? weighted.italic() : weighted
    }
}

// MARK: – Themed text modifiers
//
// These read the active palette from the environment so they re-render when
// the user picks a new theme.

private struct WWAVLabel: ViewModifier {
    @Environment(\.theme) private var theme
    let size: CGFloat
    let tracking: CGFloat

    func body(content: Content) -> some View {
        content
            .font(.wwav(size, weight: .light))
            .tracking(tracking)
            .textCase(.uppercase)
            .foregroundStyle(theme.muted)
    }
}

private struct WWAVTitle: ViewModifier {
    @Environment(\.theme) private var theme
    let size: CGFloat
    let italic: Bool

    func body(content: Content) -> some View {
        content
            .font(.wwav(size, weight: .light, italic: italic))
            .foregroundStyle(theme.ink)
            .lineSpacing(0)
    }
}

extension Text {
    func wwavLabel(size: CGFloat = 11, tracking: CGFloat = 2.5) -> some View {
        modifier(WWAVLabel(size: size, tracking: tracking))
    }

    func wwavTitle(size: CGFloat, italic: Bool = true) -> some View {
        modifier(WWAVTitle(size: size, italic: italic))
    }
}
