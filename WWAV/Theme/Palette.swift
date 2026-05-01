import SwiftUI

/// One color theme. The set of named colors mirrors the original `Theme.*`
/// statics so views just swap `Theme.x` → `theme.x`.
struct Palette: Equatable {
    let id: String
    let displayName: String

    let sand: Color
    let sandDeep: Color
    let clay: Color
    let clayDeep: Color
    let ink: Color
    let muted: Color
    let glow: Color
    let accent: Color

    /// SceneKit / sphere body color (used by the 3-D widget).
    let sphere: Color
    let sphereEmissive: Color

    var pageRadial: RadialGradient {
        RadialGradient(
            colors: [sand, sandDeep],
            center: UnitPoint(x: 0.5, y: 0.0),
            startRadius: 60,
            endRadius: 600
        )
    }

    var centerRadial: RadialGradient {
        RadialGradient(
            colors: [sand, sandDeep],
            center: UnitPoint(x: 0.5, y: 0.45),
            startRadius: 60,
            endRadius: 600
        )
    }
}

extension Palette {
    /// Existing pastel light-blue palette — the iOS shell shipped with this.
    static let lightBlue = Palette(
        id: "lightBlue",
        displayName: "light blue",
        sand:     Color(red: 0.839, green: 0.902, blue: 0.961),
        sandDeep: Color(red: 0.698, green: 0.820, blue: 0.922),
        clay:     Color(red: 0.420, green: 0.651, blue: 0.820),
        clayDeep: Color(red: 0.196, green: 0.396, blue: 0.588),
        ink:      Color(red: 0.102, green: 0.196, blue: 0.310),
        muted:    Color(red: 0.400, green: 0.561, blue: 0.690),
        glow:     Color(red: 0.878, green: 0.941, blue: 1.000),
        accent:   Color(red: 0.275, green: 0.569, blue: 0.780),
        sphere:         Color(red: 0.118, green: 0.306, blue: 0.376),  // #1E4E60
        sphereEmissive: Color(red: 0.055, green: 0.157, blue: 0.188)   // #0E2830
    )

    /// Sage green (web bg #6e8877) — accent is the website's mauve dot.
    static let sage = Palette(
        id: "sage",
        displayName: "sage",
        sand:     Color(red: 0.875, green: 0.910, blue: 0.882),  // pale sage haze
        sandDeep: Color(red: 0.741, green: 0.804, blue: 0.761),
        clay:     Color(red: 0.431, green: 0.533, blue: 0.467),
        clayDeep: Color(red: 0.239, green: 0.369, blue: 0.290),  // #3d5e4a
        ink:      Color(red: 0.118, green: 0.220, blue: 0.157),
        muted:    Color(red: 0.392, green: 0.494, blue: 0.430),
        glow:     Color(red: 0.961, green: 0.918, blue: 0.945),  // pinky glow on sage
        accent:   Color(red: 0.831, green: 0.659, blue: 0.769),  // #d4a8c4 mauve
        sphere:         Color(red: 0.239, green: 0.369, blue: 0.290),
        sphereEmissive: Color(red: 0.118, green: 0.220, blue: 0.157)
    )

    /// Royal purple (web bg #4a3568).
    static let royalPurple = Palette(
        id: "royalPurple",
        displayName: "royal purple",
        sand:     Color(red: 0.886, green: 0.847, blue: 0.929),
        sandDeep: Color(red: 0.706, green: 0.631, blue: 0.808),
        clay:     Color(red: 0.439, green: 0.267, blue: 0.690),  // #7044b0
        clayDeep: Color(red: 0.290, green: 0.208, blue: 0.408),  // #4a3568
        ink:      Color(red: 0.118, green: 0.071, blue: 0.220),  // #1E1238
        muted:    Color(red: 0.502, green: 0.439, blue: 0.624),
        glow:     Color(red: 0.965, green: 0.929, blue: 1.000),
        accent:   Color(red: 0.769, green: 0.627, blue: 0.831),  // #c4a0d4
        sphere:         Color(red: 0.227, green: 0.145, blue: 0.345),  // #3a2558
        sphereEmissive: Color(red: 0.118, green: 0.071, blue: 0.220)
    )

    /// Earth orange (web bg #7a6540).
    static let orange = Palette(
        id: "orange",
        displayName: "orange",
        sand:     Color(red: 0.953, green: 0.910, blue: 0.835),
        sandDeep: Color(red: 0.875, green: 0.804, blue: 0.682),
        clay:     Color(red: 0.769, green: 0.529, blue: 0.165),  // #c4872a
        clayDeep: Color(red: 0.420, green: 0.243, blue: 0.094),  // #6b3e18
        ink:      Color(red: 0.239, green: 0.125, blue: 0.031),  // #3d2008
        muted:    Color(red: 0.561, green: 0.475, blue: 0.349),
        glow:     Color(red: 1.000, green: 0.949, blue: 0.847),
        accent:   Color(red: 0.910, green: 0.659, blue: 0.376),  // #e8a860
        sphere:         Color(red: 0.420, green: 0.243, blue: 0.094),
        sphereEmissive: Color(red: 0.239, green: 0.125, blue: 0.031)
    )

    static let all: [Palette] = [.lightBlue, .sage, .royalPurple, .orange]
}

// MARK: – Environment plumbing

private struct ThemeKey: EnvironmentKey {
    static let defaultValue: Palette = .lightBlue
}

extension EnvironmentValues {
    var theme: Palette {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}
