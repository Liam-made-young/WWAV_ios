import Foundation

/// One comment on a track, returned by `/api/social/comments/<id>`.
struct WWAVComment: Codable, Identifiable, Equatable {
    let id: Int
    let text: String
    let userId: Int?
    let username: String?
    let profilePicture: String?
    let createdAt: String?
    /// Server-side parent reference for threading. Null = top-level comment.
    /// Will be populated once the backend `Comment.parentId` migration ships.
    let parentId: Int?

    enum RootCodingKeys: String, CodingKey {
        case id, text, content, body, userId, parentId
        case createdAt
        case created_at
        case username, handle, profilePicture, profile_picture, avatar, avatarUrl
        case User
    }

    enum NestedUserKeys: String, CodingKey {
        case username, profilePicture
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: RootCodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        text = (try? c.decode(String.self, forKey: .text))
            ?? (try? c.decode(String.self, forKey: .content))
            ?? (try? c.decode(String.self, forKey: .body))
            ?? ""
        userId = try? c.decode(Int.self, forKey: .userId)
        parentId = try? c.decode(Int.self, forKey: .parentId)
        createdAt = (try? c.decode(String.self, forKey: .createdAt))
            ?? (try? c.decode(String.self, forKey: .created_at))
        // The server `include`s the User association under the key "User".
        if let nested = try? c.nestedContainer(keyedBy: NestedUserKeys.self, forKey: .User) {
            username = try? nested.decode(String.self, forKey: .username)
            profilePicture = try? nested.decode(String.self, forKey: .profilePicture)
        } else {
            username = (try? c.decode(String.self, forKey: .username))
                ?? (try? c.decode(String.self, forKey: .handle))
            profilePicture = (try? c.decode(String.self, forKey: .profilePicture))
                ?? (try? c.decode(String.self, forKey: .profile_picture))
                ?? (try? c.decode(String.self, forKey: .avatar))
                ?? (try? c.decode(String.self, forKey: .avatarUrl))
        }
    }

    init(
        id: Int,
        text: String,
        userId: Int? = nil,
        username: String? = nil,
        profilePicture: String? = nil,
        createdAt: String? = nil,
        parentId: Int? = nil
    ) {
        self.id = id
        self.text = text
        self.userId = userId
        self.username = username
        self.profilePicture = profilePicture
        self.createdAt = createdAt
        self.parentId = parentId
    }

    func encode(to encoder: Encoder) throws {
        // Encoding only used for local persistence; round-trip not required
        // since the server is authoritative. No-op to satisfy Codable.
    }

    /// Resolved profile picture URL ready for `AsyncImage`.
    var profilePictureURL: URL? {
        guard let raw = profilePicture, !raw.isEmpty else { return nil }
        if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            return URL(string: raw)
        }
        if raw.hasPrefix("/") {
            return URL(string: "\(API.base)\(raw)")
        }
        let filename = raw.split(separator: "/").last.map(String.init) ?? raw
        return URL(string: "\(API.base)/api/images/\(filename)")
    }

    var displayName: String { username ?? "—" }

    var timeAgo: String {
        guard let s = createdAt else { return "" }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = f.date(from: s)
            ?? ISO8601DateFormatter().date(from: s)
        guard let date else { return "" }
        let diff = Date().timeIntervalSince(date)
        if diff < 60 { return "now" }
        if diff < 3600 { return "\(Int(diff/60))m" }
        if diff < 86400 { return "\(Int(diff/3600))h" }
        return "\(Int(diff/86400))d"
    }
}
