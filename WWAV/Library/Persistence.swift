import Foundation
import Security

/// Tiny JSON-over-keychain helper used to persist library state that *must*
/// survive an app reinstall — tombstones for deleted posts and local edits
/// to title / bio / cover. Keychain items default to
/// `kSecAttrAccessibleAfterFirstUnlock` and persist across app deletes on
/// iOS, which is exactly the durability `library.json` lacks (Application
/// Support is wiped when the app is uninstalled).
enum WWAVKeychain {
    /// Namespaced service id so our entries don't collide with anything else
    /// the user has stored under a generic-password class.
    private static let service = "com.wwav.app.persistence"

    static func setData(_ data: Data, for key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func data(for key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return data
    }

    static func remove(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }

    static func setJSON<T: Encodable>(_ value: T, for key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        setData(data, for: key)
    }

    static func json<T: Decodable>(_ type: T.Type, for key: String) -> T? {
        guard let data = data(for: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}

/// Per-track local override. Whatever fields are non-nil here win over
/// what the server returns on refresh — so a title edit, cover swap, or
/// bio rewrite survives an app reinstall regardless of whether the
/// matching `PUT /api/tracks/<id>/metadata` ever made it through.
struct LocalEdit: Codable, Equatable {
    var title: String?
    var bio: String?
    var coverArtUrl: String?
}

enum WWAVKeychainKeys {
    static let tombstones  = "wwav.tombstones.v1"      // Set<String> trackIds
    static let localEdits  = "wwav.localEdits.v1"      // [String: LocalEdit]
}
