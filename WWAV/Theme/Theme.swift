import SwiftUI
import UIKit

enum WWAVTypeface: String, CaseIterable, Identifiable {
    case nunito
    case courierNew
    case palatino

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .nunito: return "nunito"
        case .courierNew: return "courier new"
        case .palatino: return "palatino"
        }
    }

    func fontName(weight: Font.Weight, italic: Bool) -> String {
        switch self {
        case .nunito:
            let prefix = italic ? "NunitoItalic" : "Nunito"
            switch weight {
            case .bold, .heavy, .black: return "\(prefix)-Bold"
            case .semibold: return "\(prefix)-SemiBold"
            case .medium: return "\(prefix)-Medium"
            case .ultraLight, .thin: return "\(prefix)-ExtraLight"
            case .light: return "\(prefix)-Light"
            default: return "\(prefix)-Regular"
            }
        case .courierNew:
            switch (weight, italic) {
            case (.bold, true), (.heavy, true), (.black, true), (.semibold, true):
                return "CourierNewPS-BoldItalicMT"
            case (.bold, false), (.heavy, false), (.black, false), (.semibold, false):
                return "CourierNewPS-BoldMT"
            case (_, true):
                return "CourierNewPS-ItalicMT"
            default:
                return "CourierNewPSMT"
            }
        case .palatino:
            switch (weight, italic) {
            case (.bold, true), (.heavy, true), (.black, true), (.semibold, true):
                return "Palatino-BoldItalic"
            case (.bold, false), (.heavy, false), (.black, false), (.semibold, false):
                return "Palatino-Bold"
            case (_, true):
                return "Palatino-Italic"
            default:
                return "Palatino-Roman"
            }
        }
    }

    func font(size: CGFloat, weight: Font.Weight, italic: Bool) -> Font {
        let name = fontName(weight: weight, italic: italic)
        if UIFont(name: name, size: size) != nil {
            return Font.custom(name, size: size, relativeTo: .body)
        }
        let design: Font.Design = self == .courierNew ? .monospaced : .rounded
        let base = Font.system(size: size, weight: weight, design: design)
        return italic ? base.italic() : base
    }
}

enum WWAVFontRegistry {
    static var current: WWAVTypeface = .nunito
}

extension Font {
    static func wwav(_ size: CGFloat, weight: Font.Weight = .light, italic: Bool = false) -> Font {
        WWAVFontRegistry.current.font(size: size, weight: weight, italic: italic)
    }
}

private struct WWAVTypefaceKey: EnvironmentKey {
    static let defaultValue: WWAVTypeface = .nunito
}

extension EnvironmentValues {
    var wwavTypeface: WWAVTypeface {
        get { self[WWAVTypefaceKey.self] }
        set { self[WWAVTypefaceKey.self] = newValue }
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
