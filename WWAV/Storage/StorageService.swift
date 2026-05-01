import Foundation

/// Pluggable object storage. The default `LocalDiskStorage` keeps everything
/// inside the app's Application Support directory and behaves like a tiny S3:
/// objects are addressed by string keys, returned as local file URLs.
///
/// The `S3Storage` skeleton talks to a real S3 endpoint (or any S3-compatible
/// service: AWS, R2, MinIO). Inject it from `WWAVApp` once you have credentials.
protocol StorageService {
    /// Persists `data` under `key` and returns a local file URL clients can read.
    func put(_ data: Data, key: String, contentType: String) async throws -> URL
    /// Persists a file already on disk under `key`. Returns the cached local URL.
    func putFile(at sourceURL: URL, key: String, contentType: String) async throws -> URL
    /// Returns a local file URL for the given key, downloading if necessary.
    func localURL(for key: String) async throws -> URL
    /// Removes the object.
    func delete(key: String) async throws
}

enum StorageError: LocalizedError {
    case notFound(String)
    case ioFailure(String)
    case notConfigured(String)
    var errorDescription: String? {
        switch self {
        case .notFound(let k):       return "Storage object not found: \(k)"
        case .ioFailure(let s):      return "Storage I/O failure: \(s)"
        case .notConfigured(let s):  return "Storage not configured: \(s)"
        }
    }
}

// MARK: – Local disk impl

/// Stores objects under Application Support/wwav/objects/<key>.
/// Used by default so the whole app is functional with no credentials.
final class LocalDiskStorage: StorageService {
    private let root: URL

    init() {
        let base = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        self.root = (base ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("wwav/objects", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func put(_ data: Data, key: String, contentType: String) async throws -> URL {
        let dest = url(for: key)
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: dest, options: .atomic)
        return dest
    }

    func putFile(at sourceURL: URL, key: String, contentType: String) async throws -> URL {
        let dest = url(for: key)
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }
        do {
            try FileManager.default.copyItem(at: sourceURL, to: dest)
        } catch {
            // try reading + writing if copy fails (e.g. security-scoped)
            let data = try Data(contentsOf: sourceURL)
            try data.write(to: dest, options: .atomic)
        }
        return dest
    }

    func localURL(for key: String) async throws -> URL {
        let path = url(for: key)
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw StorageError.notFound(key)
        }
        return path
    }

    func delete(key: String) async throws {
        let path = url(for: key)
        if FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
        }
    }

    private func url(for key: String) -> URL {
        // Disallow path traversal — flatten and re-segment.
        let safe = key
            .replacingOccurrences(of: "..", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return root.appendingPathComponent(safe)
    }
}

// MARK: – S3-compatible impl (skeleton)

/// Plug your bucket + creds in via `S3Config`. Uses URLSession so we avoid an
/// AWS SDK dependency, but signing is intentionally left to your own backend
/// (presigned URLs) — never ship raw AWS keys inside an iOS app.
struct S3Config {
    var bucket: String
    var region: String
    /// Endpoint that returns presigned URLs for `PUT` and `GET` of a given key.
    /// Your backend (e.g. tiny FastAPI route) signs with the secret key.
    var presignerBaseURL: URL
    var localCacheRoot: URL
}

final class S3Storage: StorageService {
    let config: S3Config

    init(config: S3Config) {
        self.config = config
        try? FileManager.default.createDirectory(
            at: config.localCacheRoot, withIntermediateDirectories: true
        )
    }

    func put(_ data: Data, key: String, contentType: String) async throws -> URL {
        let presigned = try await fetchPresigned(method: "PUT", key: key, contentType: contentType)
        var req = URLRequest(url: presigned)
        req.httpMethod = "PUT"
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.upload(for: req, from: data)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw StorageError.ioFailure("S3 PUT failed for \(key)")
        }
        let local = cacheURL(for: key)
        try FileManager.default.createDirectory(
            at: local.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: local, options: .atomic)
        return local
    }

    func putFile(at sourceURL: URL, key: String, contentType: String) async throws -> URL {
        let data = try Data(contentsOf: sourceURL)
        return try await put(data, key: key, contentType: contentType)
    }

    func localURL(for key: String) async throws -> URL {
        let local = cacheURL(for: key)
        if FileManager.default.fileExists(atPath: local.path) { return local }
        let presigned = try await fetchPresigned(method: "GET", key: key, contentType: "")
        let (tmp, response) = try await URLSession.shared.download(from: presigned)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw StorageError.notFound(key)
        }
        try FileManager.default.createDirectory(
            at: local.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: local.path) {
            try FileManager.default.removeItem(at: local)
        }
        try FileManager.default.moveItem(at: tmp, to: local)
        return local
    }

    func delete(key: String) async throws {
        let local = cacheURL(for: key)
        if FileManager.default.fileExists(atPath: local.path) {
            try? FileManager.default.removeItem(at: local)
        }
        // Tell the backend to delete the remote object.
        var req = URLRequest(
            url: config.presignerBaseURL.appendingPathComponent("objects/\(key)")
        )
        req.httpMethod = "DELETE"
        _ = try await URLSession.shared.data(for: req)
    }

    private func cacheURL(for key: String) -> URL {
        config.localCacheRoot.appendingPathComponent(key)
    }

    private func fetchPresigned(method: String, key: String, contentType: String) async throws -> URL {
        var comps = URLComponents(
            url: config.presignerBaseURL.appendingPathComponent("presign"),
            resolvingAgainstBaseURL: false
        )!
        comps.queryItems = [
            URLQueryItem(name: "method", value: method),
            URLQueryItem(name: "bucket", value: config.bucket),
            URLQueryItem(name: "key", value: key),
            URLQueryItem(name: "contentType", value: contentType),
        ]
        guard let url = comps.url else {
            throw StorageError.notConfigured("bad presigner URL")
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw StorageError.notConfigured("presigner returned \(response)")
        }
        struct Resp: Decodable { let url: String }
        let r = try JSONDecoder().decode(Resp.self, from: data)
        guard let u = URL(string: r.url) else {
            throw StorageError.notConfigured("presigner returned invalid URL")
        }
        return u
    }
}
