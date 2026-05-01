import SwiftUI

/// Owns the active palette. Persists the choice to UserDefaults.
@MainActor
final class ThemeManager: ObservableObject {
    @Published var palette: Palette {
        didSet {
            UserDefaults.standard.set(palette.id, forKey: Self.storageKey)
        }
    }

    private static let storageKey = "wwav.palette.id"

    init() {
        let id = UserDefaults.standard.string(forKey: Self.storageKey) ?? Palette.lightBlue.id
        self.palette = Palette.all.first { $0.id == id } ?? .lightBlue
    }

    func choose(_ p: Palette) { palette = p }
}
