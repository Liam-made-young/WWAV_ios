import Foundation

/// Server-side user identity (distinct from the local `UserProfile`).
struct RemoteUser: Codable, Equatable {
    let id: Int
    let email: String?
    let username: String
    let bio: String?
    let profilePicture: String?
    let isPro: Bool?
    let proExpiresAt: String?

    /// Resolved URL for the profile picture, ready for `AsyncImage`.
    /// Server may store it as either a full URL, a `/api/images/...` path,
    /// or a bare s3 key — handle all three.
    var profilePictureURL: URL? {
        guard let raw = profilePicture, !raw.isEmpty else { return nil }
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            return URL(string: raw)
        }
        if raw.hasPrefix("/") {
            return URL(string: "\(API.base)\(raw)")
        }
        // Bare key like "profile_pictures/abc.jpg" — serve via /api/images/<filename>.
        let filename = raw.split(separator: "/").last.map(String.init) ?? raw
        return URL(string: "\(API.base)/api/images/\(filename)")
    }
}

struct LoginResponse: Codable {
    let token: String
    let user: RemoteUser
}
