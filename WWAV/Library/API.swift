import Foundation

struct AppEnvironment: Equatable {
    var apiBaseURL: URL

    static var production: AppEnvironment {
        AppEnvironment(apiBaseURL: URL(string: "https://www.mi-wwav.com")!)
    }

    static var current: AppEnvironment = {
        if let raw = Bundle.main.object(forInfoDictionaryKey: "WWAVAPIBaseURL") as? String,
           let url = URL(string: raw) {
            return AppEnvironment(apiBaseURL: url)
        }
        return .production
    }()
}

/// Tiny JSON HTTP client for the WWAV cloud (mi-wwav.com).
///
/// Mirrors the legacy `WWAV-App` client so it's a drop-in for the new shell.
/// Multipart / S3 uploads use `URLSession.upload` directly inside the
/// stem service — this layer is only for JSON endpoints.
enum APIError: LocalizedError {
    case unauthorized
    case forbidden(String)
    case server(Int, String?)
    case decode(Error)
    case unknown

    var errorDescription: String? {
        switch self {
        case .unauthorized:        return "Sign in again."
        case .forbidden(let msg):  return msg
        case .server(let c, let m): return m ?? "Server error (\(c))"
        case .decode(let e):       return "Decode failed: \(e.localizedDescription)"
        case .unknown:             return "Unknown error"
        }
    }
}

enum API {
    static var environment: AppEnvironment {
        get { AppEnvironment.current }
        set {
            AppEnvironment.current = newValue
            client = URLSessionWWAVAPIClient(environment: newValue)
        }
    }

    static var base: String { environment.apiBaseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
    static var client: WWAVAPIClient = URLSessionWWAVAPIClient(environment: .current)

    static func request(
        _ path: String,
        method: String = "GET",
        body: [String: Any]? = nil,
        token: String? = nil
    ) async throws -> Data {
        guard let url = URL(string: "\(base)\(path)") else { throw APIError.unknown }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw APIError.unknown }

        switch http.statusCode {
        case 200..<300:
            return data
        case 401:
            throw APIError.unauthorized
        case 403:
            let msg = decodeErrorMessage(data) ?? "Not allowed"
            throw APIError.forbidden(msg)
        default:
            throw APIError.server(http.statusCode, decodeErrorMessage(data))
        }
    }

    static func get(_ path: String, token: String? = nil) async throws -> Data {
        try await request(path, token: token)
    }

    static func post(_ path: String, body: [String: Any]? = nil, token: String? = nil) async throws -> Data {
        try await request(path, method: "POST", body: body, token: token)
    }

    private static func decodeErrorMessage(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["error"] as? String ?? obj["message"] as? String
    }
}

protocol WWAVAPIClient {
    func request(_ path: String, method: String, body: [String: Any]?, token: String?) async throws -> Data
    func get<T: Decodable>(_ type: T.Type, path: String, token: String?) async throws -> T
    func post<T: Decodable>(_ type: T.Type, path: String, body: [String: Any]?, token: String?) async throws -> T
    func me(token: String) async throws -> RemoteUser
    func login(email: String, password: String) async throws -> LoginResponse
    func globalUploads(token: String) async throws -> [WWAVRemoteUpload]
    func globalPosts(token: String) async throws -> [WWAVRemotePost]
    func userUploads(token: String) async throws -> [WWAVRemoteUpload]
    func userPosts(token: String) async throws -> [WWAVRemotePost]
}

struct URLSessionWWAVAPIClient: WWAVAPIClient {
    var environment: AppEnvironment
    var session: URLSession = .shared
    var decoder: JSONDecoder = JSONDecoder()

    func request(_ path: String, method: String = "GET", body: [String: Any]? = nil, token: String? = nil) async throws -> Data {
        guard let url = URL(string: "\(environment.apiBaseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")))\(path)") else {
            throw APIError.unknown
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw APIError.unknown }
        switch http.statusCode {
        case 200..<300:
            return data
        case 401:
            throw APIError.unauthorized
        case 403:
            throw APIError.forbidden(Self.decodeErrorMessage(data) ?? "Not allowed")
        default:
            throw APIError.server(http.statusCode, Self.decodeErrorMessage(data))
        }
    }

    func get<T: Decodable>(_ type: T.Type, path: String, token: String? = nil) async throws -> T {
        let data = try await request(path, token: token)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decode(error)
        }
    }

    func post<T: Decodable>(_ type: T.Type, path: String, body: [String: Any]? = nil, token: String? = nil) async throws -> T {
        let data = try await request(path, method: "POST", body: body, token: token)
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw APIError.decode(error)
        }
    }

    func me(token: String) async throws -> RemoteUser {
        try await get(RemoteUser.self, path: "/api/auth/me", token: token)
    }

    func login(email: String, password: String) async throws -> LoginResponse {
        try await post(LoginResponse.self, path: "/api/auth/login", body: [
            "email": email,
            "password": password,
        ], token: nil)
    }

    func globalUploads(token: String) async throws -> [WWAVRemoteUpload] {
        do {
            let browse = try await browseUploads(token: token)
            if !browse.isEmpty {
                let mine = (try? await userUploads(token: token)) ?? []
                return mergeUploads(primary: browse, additions: mine)
            }
        } catch {
            print("[API] browse feed unavailable for uploads: \(error)")
        }
        return try await getFirstList(WWAVRemoteUpload.self, paths: [
            "/api/uploads",
            "/api/feed/uploads",
            "/api/public/uploads",
            "/api/social/uploads",
            "/api/user/uploads/all",
        ], token: token)
    }

    func globalPosts(token: String) async throws -> [WWAVRemotePost] {
        try await getFirstList(WWAVRemotePost.self, paths: [
            "/api/posts",
            "/api/feed/posts",
            "/api/public/posts",
            "/api/social/posts",
            "/api/user/posts/all",
        ], token: token)
    }

    func userUploads(token: String) async throws -> [WWAVRemoteUpload] {
        try await get([WWAVRemoteUpload].self, path: "/api/user/uploads", token: token)
    }

    func userPosts(token: String) async throws -> [WWAVRemotePost] {
        try await get([WWAVRemotePost].self, path: "/api/user/posts", token: token)
    }

    private static func decodeErrorMessage(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["error"] as? String ?? obj["message"] as? String
    }

    private func getFirstList<T: Decodable>(
        _ type: T.Type,
        paths: [String],
        token: String
    ) async throws -> [T] {
        var lastError: Error?
        for path in paths {
            do {
                return try await getList(type, path: path, token: token)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? APIError.unknown
    }

    private func getList<T: Decodable>(
        _ type: T.Type,
        path: String,
        token: String
    ) async throws -> [T] {
        let data = try await request(path, token: token)
        do {
            if let array = try? decoder.decode([T].self, from: data) {
                return array
            }
            return try decoder.decode(APIListEnvelope<T>.self, from: data).values
        } catch {
            throw APIError.decode(error)
        }
    }

    private func browseUploads(token: String) async throws -> [WWAVRemoteUpload] {
        let data = try await request("/api/browse?blend=0.42&limit=200", token: token)
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(APIListEnvelope<WWAVBrowseFeedItem>.self, from: data) {
            return envelope.values.compactMap(\.upload)
        }
        let items = try decoder.decode([WWAVBrowseFeedItem].self, from: data)
        return items.compactMap(\.upload)
    }

    private func mergeUploads(
        primary: [WWAVRemoteUpload],
        additions: [WWAVRemoteUpload]
    ) -> [WWAVRemoteUpload] {
        var seen = Set(primary.map(\.trackId))
        var merged = primary
        for upload in additions where seen.insert(upload.trackId).inserted {
            merged.append(upload)
        }
        return merged
    }
}

private struct APIListEnvelope<T: Decodable>: Decodable {
    let values: [T]

    enum CodingKeys: String, CodingKey {
        case data, results, items, uploads, posts, feed
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        for key in [CodingKeys.data, .results, .items, .uploads, .posts, .feed] {
            if let values = try? c.decode([T].self, forKey: key) {
                self.values = values
                return
            }
            if let nested = try? c.decode(APIListEnvelope<T>.self, forKey: key) {
                self.values = nested.values
                return
            }
        }
        throw APIError.decode(DecodingError.keyNotFound(
            CodingKeys.data,
            DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "No list payload found")
        ))
    }
}

private struct WWAVBrowseFeedItem: Decodable {
    let upload: WWAVRemoteUpload?

    enum CodingKeys: String, CodingKey {
        case itemType, trackId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let itemType = (try? c.decode(String.self, forKey: .itemType))?.lowercased()
        let hasTrackId = (try? c.decode(String.self, forKey: .trackId)) != nil
        guard itemType == nil || itemType == "single" || hasTrackId else {
            upload = nil
            return
        }
        upload = try? WWAVRemoteUpload(from: decoder)
    }
}

struct WWAVRemoteAuthor: Decodable, Equatable {
    let id: Int?
    let username: String?
    let profilePicture: String?

    var hasIdentity: Bool {
        id != nil || username != nil || profilePicture != nil
    }

    var displayName: String? {
        guard let username else { return nil }
        let cleaned = username.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
        return cleaned.isEmpty ? nil : cleaned
    }

    enum CodingKeys: String, CodingKey {
        case id, userId, user_id
        case username, handle, name, displayName, display_name, email
        case profilePicture, profile_picture, avatar, avatarUrl, avatarURL, avatar_url
    }

    init(id: Int? = nil, username: String? = nil, profilePicture: String? = nil) {
        self.id = id
        self.username = username
        self.profilePicture = profilePicture
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.decodeFirstInt([.id, .userId, .user_id])
        let rawName = c.decodeFirstString([
            .username, .handle, .name, .displayName, .display_name, .email,
        ])
        if let rawName, rawName.contains("@"), rawName.contains(".") {
            username = rawName.split(separator: "@").first.map(String.init)
        } else {
            username = rawName
        }
        profilePicture = c.decodeFirstString([
            .profilePicture, .profile_picture, .avatar, .avatarUrl, .avatarURL, .avatar_url,
        ])
    }
}

struct WWAVRemoteUpload: Decodable {
    let id: Int?
    let publishedTrackId: Int?
    let trackId: String
    let originalName: String?
    let status: String
    let coverArtUrl: String?
    let createdAtRaw: String?
    let plays: Int?
    let author: WWAVRemoteAuthor?

    var parsedCreatedAt: Date? {
        DateParsers.remoteDate(createdAtRaw)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case trackId, originalName, title, status
        case coverArtUrl, cover_art_url
        case track, metadata
        case createdAt
        case created_at
        case plays, playCount, play_count
        case views, viewCount, view_count
        case likeCount, like_count
        case userUploadId, user_upload_id
        case publishedTrackId, published_track_id
        case itemType
        case User, user, owner, author, creator, uploader
        case userId, user_id, ownerId, owner_id, creatorId, creator_id, uploaderId, uploader_id
        case username, handle, name, displayName, display_name, email
        case profilePicture, profile_picture, avatar, avatarUrl, avatarURL, avatar_url
    }

    private struct CoverWrapper: Decodable {
        let coverArtUrl: String?
        let cover_art_url: String?
        var any: String? { coverArtUrl ?? cover_art_url }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rootId = try c.decode(Int.self, forKey: .id)
        let userUploadId = c.decodeFirstInt([.userUploadId, .user_upload_id])
        let itemType = (try? c.decode(String.self, forKey: .itemType))?.lowercased()
        id = userUploadId ?? (itemType == "single" ? nil : rootId)
        publishedTrackId = c.decodeFirstInt([.publishedTrackId, .published_track_id])
            ?? (itemType == "single" ? rootId : nil)
        trackId = try c.decode(String.self, forKey: .trackId)
        originalName = (try? c.decode(String.self, forKey: .originalName))
            ?? (try? c.decode(String.self, forKey: .title))
        status = (try? c.decode(String.self, forKey: .status)) ?? "ready"
        let directCover = (try? c.decode(String.self, forKey: .coverArtUrl))
            ?? (try? c.decode(String.self, forKey: .cover_art_url))
        let trackCover = (try? c.decode(CoverWrapper.self, forKey: .track))?.any
        let metaCover = (try? c.decode(CoverWrapper.self, forKey: .metadata))?.any
        coverArtUrl = directCover ?? trackCover ?? metaCover
        createdAtRaw = (try? c.decode(String.self, forKey: .createdAt))
            ?? (try? c.decode(String.self, forKey: .created_at))
        plays = Self.decodeMetric(from: c, keys: [
            .plays, .playCount, .play_count,
            .views, .viewCount, .view_count,
            .likeCount, .like_count,
        ])
        author = Self.decodeAuthor(from: c)
    }

    private static func decodeMetric(
        from container: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys]
    ) -> Int? {
        for key in keys {
            if let value = try? container.decode(Int.self, forKey: key) {
                return max(0, value)
            }
            if let value = try? container.decode(Double.self, forKey: key) {
                return max(0, Int(value))
            }
            if let raw = try? container.decode(String.self, forKey: key),
               let value = Int(raw) {
                return max(0, value)
            }
        }
        return nil
    }

    private static func decodeAuthor(
        from container: KeyedDecodingContainer<CodingKeys>
    ) -> WWAVRemoteAuthor? {
        let nested = (try? container.decode(WWAVRemoteAuthor.self, forKey: .User))
            ?? (try? container.decode(WWAVRemoteAuthor.self, forKey: .user))
            ?? (try? container.decode(WWAVRemoteAuthor.self, forKey: .owner))
            ?? (try? container.decode(WWAVRemoteAuthor.self, forKey: .author))
            ?? (try? container.decode(WWAVRemoteAuthor.self, forKey: .creator))
            ?? (try? container.decode(WWAVRemoteAuthor.self, forKey: .uploader))
        let rootId = container.decodeFirstInt([
            .userId, .user_id, .ownerId, .owner_id, .creatorId, .creator_id, .uploaderId, .uploader_id,
        ])
        let rootProfilePicture = container.decodeFirstString([
            .profilePicture, .profile_picture, .avatar, .avatarUrl, .avatarURL, .avatar_url,
        ])
        if let nested, nested.hasIdentity {
            return WWAVRemoteAuthor(
                id: nested.id ?? rootId,
                username: nested.username,
                profilePicture: nested.profilePicture ?? rootProfilePicture
            )
        }

        let root = WWAVRemoteAuthor(
            id: rootId,
            username: container.decodeFirstString([
                .username, .handle, .name, .displayName, .display_name, .email,
            ]),
            profilePicture: rootProfilePicture
        )
        return root.hasIdentity ? root : nil
    }
}

struct WWAVRemotePost: Decodable {
    let id: Int
    let kind: String?
    let title: String?
    let content: String?
    let images: [String]?
    let videoUrl: String?
    let coverImageUrl: String?
    let createdAtRaw: String?
    let plays: Int?
    let author: WWAVRemoteAuthor?

    var parsedCreatedAt: Date? {
        DateParsers.remoteDate(createdAtRaw)
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, title, content, images, videoUrl, coverImageUrl
        case created_at, createdAt
        case plays, playCount, play_count
        case views, viewCount, view_count
        case User, user, owner, author, creator, uploader
        case userId, user_id, ownerId, owner_id, creatorId, creator_id, uploaderId, uploader_id
        case username, handle, name, displayName, display_name, email
        case profilePicture, profile_picture, avatar, avatarUrl, avatarURL, avatar_url
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        content = try c.decodeIfPresent(String.self, forKey: .content)
        images = try c.decodeIfPresent([String].self, forKey: .images)
        videoUrl = try c.decodeIfPresent(String.self, forKey: .videoUrl)
        coverImageUrl = try c.decodeIfPresent(String.self, forKey: .coverImageUrl)
        createdAtRaw = (try? c.decode(String.self, forKey: .created_at))
            ?? (try? c.decode(String.self, forKey: .createdAt))
        plays = Self.decodeMetric(from: c, keys: [
            .plays, .playCount, .play_count,
            .views, .viewCount, .view_count,
        ])
        author = Self.decodeAuthor(from: c)
    }

    private static func decodeMetric(
        from container: KeyedDecodingContainer<CodingKeys>,
        keys: [CodingKeys]
    ) -> Int? {
        for key in keys {
            if let value = try? container.decode(Int.self, forKey: key) {
                return max(0, value)
            }
            if let value = try? container.decode(Double.self, forKey: key) {
                return max(0, Int(value))
            }
            if let raw = try? container.decode(String.self, forKey: key),
               let value = Int(raw) {
                return max(0, value)
            }
        }
        return nil
    }

    private static func decodeAuthor(
        from container: KeyedDecodingContainer<CodingKeys>
    ) -> WWAVRemoteAuthor? {
        let nested = (try? container.decode(WWAVRemoteAuthor.self, forKey: .User))
            ?? (try? container.decode(WWAVRemoteAuthor.self, forKey: .user))
            ?? (try? container.decode(WWAVRemoteAuthor.self, forKey: .owner))
            ?? (try? container.decode(WWAVRemoteAuthor.self, forKey: .author))
            ?? (try? container.decode(WWAVRemoteAuthor.self, forKey: .creator))
            ?? (try? container.decode(WWAVRemoteAuthor.self, forKey: .uploader))
        let rootId = container.decodeFirstInt([
            .userId, .user_id, .ownerId, .owner_id, .creatorId, .creator_id, .uploaderId, .uploader_id,
        ])
        let rootProfilePicture = container.decodeFirstString([
            .profilePicture, .profile_picture, .avatar, .avatarUrl, .avatarURL, .avatar_url,
        ])
        if let nested, nested.hasIdentity {
            return WWAVRemoteAuthor(
                id: nested.id ?? rootId,
                username: nested.username,
                profilePicture: nested.profilePicture ?? rootProfilePicture
            )
        }

        let root = WWAVRemoteAuthor(
            id: rootId,
            username: container.decodeFirstString([
                .username, .handle, .name, .displayName, .display_name, .email,
            ]),
            profilePicture: rootProfilePicture
        )
        return root.hasIdentity ? root : nil
    }
}

enum DateParsers {
    static func remoteDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFrac.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}

private extension KeyedDecodingContainer {
    func decodeFirstString(_ keys: [Key]) -> String? {
        for key in keys {
            if let value = try? decode(String.self, forKey: key) {
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
            if let value = try? decode(Int.self, forKey: key) {
                return "\(value)"
            }
        }
        return nil
    }

    func decodeFirstInt(_ keys: [Key]) -> Int? {
        for key in keys {
            if let value = try? decode(Int.self, forKey: key) {
                return value
            }
            if let raw = try? decode(String.self, forKey: key),
               let value = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
                return value
            }
        }
        return nil
    }
}
