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
}

struct WWAVRemoteUpload: Decodable {
    let id: Int
    let trackId: String
    let originalName: String?
    let status: String
    let coverArtUrl: String?
    let createdAtRaw: String?
    let plays: Int?

    var parsedCreatedAt: Date? {
        DateParsers.remoteDate(createdAtRaw)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case trackId, originalName, status
        case coverArtUrl, cover_art_url
        case track, metadata
        case createdAt
        case created_at
        case plays, playCount, play_count
        case views, viewCount, view_count
    }

    private struct CoverWrapper: Decodable {
        let coverArtUrl: String?
        let cover_art_url: String?
        var any: String? { coverArtUrl ?? cover_art_url }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        trackId = try c.decode(String.self, forKey: .trackId)
        originalName = try c.decodeIfPresent(String.self, forKey: .originalName)
        status = try c.decode(String.self, forKey: .status)
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
        ])
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

    var parsedCreatedAt: Date? {
        DateParsers.remoteDate(createdAtRaw)
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, title, content, images, videoUrl, coverImageUrl
        case created_at, createdAt
        case plays, playCount, play_count
        case views, viewCount, view_count
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
