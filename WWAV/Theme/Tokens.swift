import SwiftUI

// Discipline tokens — every magic number that recurs across screens has a name here.
// Goal: one vocabulary for opacity, radii, spacing, shadows, and the single
// "light source" that ties orbs, avatars, capsules, and cards together.

enum WWAVOpacity {
    static let hair: Double = 0.06
    static let veil: Double = 0.12
    static let soft: Double = 0.20
    static let muted: Double = 0.42
    static let firm: Double = 0.66
    static let solid: Double = 0.90
}

enum WWAVRadius {
    static let chip: CGFloat = 6
    static let button: CGFloat = 10
    static let card: CGFloat = 14
    static let sheet: CGFloat = 22
}

enum WWAVSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

enum WWAVShadow {
    case sm, md, lg, glow

    var color: Color {
        switch self {
        case .sm:   return .black.opacity(0.10)
        case .md:   return .black.opacity(0.16)
        case .lg:   return .black.opacity(0.24)
        case .glow: return .black.opacity(0.30)
        }
    }
    var radius: CGFloat {
        switch self {
        case .sm: return 4
        case .md: return 14
        case .lg: return 22
        case .glow: return 28
        }
    }
    var y: CGFloat {
        switch self {
        case .sm: return 2
        case .md: return 8
        case .lg: return 14
        case .glow: return 18
        }
    }
}

extension View {
    func wwavShadow(_ level: WWAVShadow) -> some View {
        shadow(color: level.color, radius: level.radius, y: level.y)
    }
}

// Single "sun" — the upper-left light source used by every orb, avatar,
// post button, and slider thumb in the app. Importing this keeps the
// luminance direction consistent.
enum WWAVLight {
    static let sun = UnitPoint(x: 0.30, y: 0.25)
}

// 1pt stroke that fades from glow (top) to muted (bottom) — simulates a
// single light source catching the upper edge.
struct WWAVGradientStroke<S: InsettableShape>: ViewModifier {
    @Environment(\.theme) private var theme
    let shape: S
    let lineWidth: CGFloat

    func body(content: Content) -> some View {
        content.overlay(
            shape
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            theme.glow.opacity(0.40),
                            theme.muted.opacity(WWAVOpacity.soft),
                        ],
                        startPoint: .top, endPoint: .bottom
                    ),
                    lineWidth: lineWidth
                )
        )
    }
}

extension View {
    func wwavGradientStroke<S: InsettableShape>(_ shape: S, lineWidth: CGFloat = 1) -> some View {
        modifier(WWAVGradientStroke(shape: shape, lineWidth: lineWidth))
    }
}
