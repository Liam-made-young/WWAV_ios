import SwiftUI

/// Owns the active palette. Persists the choice to UserDefaults.
@MainActor
final class ThemeManager: ObservableObject {
    @Published var palette: Palette {
        didSet {
            UserDefaults.standard.set(palette.id, forKey: Self.paletteStorageKey)
        }
    }

    @Published var typeface: WWAVTypeface {
        didSet {
            WWAVFontRegistry.current = typeface
            UserDefaults.standard.set(typeface.id, forKey: Self.typefaceStorageKey)
        }
    }

    private static let paletteStorageKey = "wwav.palette.id"
    private static let typefaceStorageKey = "wwav.typeface.id"

    init() {
        let paletteID = UserDefaults.standard.string(forKey: Self.paletteStorageKey) ?? Palette.lightBlue.id
        let typefaceID = UserDefaults.standard.string(forKey: Self.typefaceStorageKey) ?? WWAVTypeface.nunito.id
        self.palette = Palette.all.first { $0.id == paletteID } ?? .lightBlue
        self.typeface = WWAVTypeface.allCases.first { $0.id == typefaceID } ?? .nunito
        WWAVFontRegistry.current = self.typeface
    }

    func choose(_ p: Palette) { palette = p }
    func choose(_ f: WWAVTypeface) { typeface = f }
}
