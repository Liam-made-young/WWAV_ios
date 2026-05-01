import Foundation

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
    static let base = "https://www.mi-wwav.com"

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
