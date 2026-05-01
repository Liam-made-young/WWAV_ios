import Foundation

/// Hosted stem separation backed by the WWAV cloud (mi-wwav.com).
///
/// Flow (matches `server/routes/uploads.js`):
///   1. GET  /api/upload/sign?fileType=audio/wav     → { signedUrl, s3Key, trackId }
///   2. PUT  signedUrl                                ← raw audio bytes (S3 directly)
///   3. POST /api/upload/process { trackId, s3Key, originalName }
///        → server fires Replicate (htdemucs) with a webhook
///   4. GET  /api/user/uploads (poll)                 → status: processing|ready|failed
///   5. GET  /stems/{trackId}/{drums|bass|vocals|other}.mp3
///
/// The token for protected calls is fetched per-request via `tokenProvider`,
/// so it always reflects the current AuthManager state.
final class MiWwavStemService: StemSeparationService {

    /// Returns the current bearer token, or nil if logged out. Runs on the
    /// main actor because `AuthManager` lives there.
    typealias TokenProvider = @MainActor @Sendable () -> String?

    private let tokenProvider: TokenProvider
    private let pollInterval: UInt64 = 2_500_000_000   // 2.5s
    private let pollTimeoutSeconds: TimeInterval = 60 * 8 // 8 minutes hard cap

    init(tokenProvider: @escaping TokenProvider) {
        self.tokenProvider = tokenProvider
    }

    func separate(
        sourceURL: URL,
        displayName: String,
        onTrackIdAssigned: @escaping @MainActor (String) -> Void,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> StemSeparationResult {
        guard let token = await MainActor.run(body: { tokenProvider() }) else {
            throw StemSeparationError.ioFailure("Not signed in.")
        }

        await progress(0.02)

        // 1. Sign + upload to S3. As soon as the server assigns a trackId,
        // surface it so the library can stamp the local Track — this closes
        // the race where a refresh during upload would create a duplicate.
        let signed = try await sign(token: token, fileType: "audio/wav")
        await onTrackIdAssigned(signed.trackId)
        await progress(0.08)
        try await putToS3(localFile: sourceURL, signedURL: signed.signedUrl)
        await progress(0.30)

        // 2. Trigger Replicate. We send the user's chosen title as
        // `originalName` so the server stores it and refresh-from-server
        // shows the right name on a fresh device or after reinstall.
        let nameForServer = displayName.isEmpty ? sourceURL.lastPathComponent : displayName
        try await triggerProcess(
            token: token,
            trackId: signed.trackId,
            s3Key: signed.s3Key,
            originalName: nameForServer
        )
        await progress(0.35)

        // 3. Poll until ready.
        try await waitUntilReady(token: token, trackId: signed.trackId, progress: progress)
        await progress(0.92)

        // 4. Download stems.
        let bundle = try await downloadStems(trackId: signed.trackId)
        await progress(1.0)
        return StemSeparationResult(bundle: bundle, remoteTrackId: signed.trackId)
    }

    // MARK: – 1. Sign

    private struct SignResponse: Decodable {
        let signedUrl: String
        let s3Key: String
        let trackId: String
    }

    private func sign(token: String, fileType: String) async throws -> SignResponse {
        let escaped = fileType.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? fileType
        do {
            let data = try await API.get("/api/upload/sign?fileType=\(escaped)", token: token)
            return try JSONDecoder().decode(SignResponse.self, from: data)
        } catch let e as APIError {
            throw mapAPIError(e)
        }
    }

    // MARK: – 2. PUT to S3

    private func putToS3(localFile: URL, signedURL: String) async throws {
        guard let url = URL(string: signedURL) else {
            throw StemSeparationError.ioFailure("Invalid presigned URL.")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        // Stream file from disk — works for big tracks without loading into memory.
        let (_, response) = try await URLSession.shared.upload(for: req, fromFile: localFile)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw StemSeparationError.ioFailure("S3 upload failed (\(code))")
        }
    }

    // MARK: – 3. Trigger

    private func triggerProcess(
        token: String,
        trackId: String,
        s3Key: String,
        originalName: String
    ) async throws {
        do {
            _ = try await API.post(
                "/api/upload/process",
                body: [
                    "trackId": trackId,
                    "s3Key": s3Key,
                    "originalName": originalName,
                ],
                token: token
            )
        } catch let e as APIError {
            throw mapAPIError(e)
        }
    }

    // MARK: – 4. Poll

    private struct UploadRow: Decodable {
        let trackId: String
        let status: String
        let originalName: String?
    }

    private func waitUntilReady(
        token: String,
        trackId: String,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws {
        let start = Date()
        // While we don't know the real progress, ramp asymptotically toward 0.9.
        var fakeProgress = 0.40
        while true {
            try Task.checkCancellation()
            if Date().timeIntervalSince(start) > pollTimeoutSeconds {
                throw StemSeparationError.ioFailure("Separation timed out.")
            }

            do {
                let data = try await API.get("/api/user/uploads", token: token)
                let rows = try JSONDecoder().decode([UploadRow].self, from: data)
                if let row = rows.first(where: { $0.trackId == trackId }) {
                    switch row.status {
                    case "ready":
                        return
                    case "failed":
                        throw StemSeparationError.ioFailure("Separation failed on the server.")
                    default:
                        break
                    }
                }
            } catch let e as APIError {
                throw mapAPIError(e)
            } catch let e as StemSeparationError {
                throw e
            } catch is DecodingError {
                throw StemSeparationError.badResponse
            }

            fakeProgress = min(0.90, fakeProgress + 0.02)
            await progress(fakeProgress)
            try await Task.sleep(nanoseconds: pollInterval)
        }
    }

    // MARK: – 5. Download

    private func downloadStems(trackId: String) async throws -> StemBundle {
        let dir = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("stems/\(trackId)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Map StemKind → server filename.
        var saved: [StemKind: URL] = [:]
        for kind in StemKind.allCases {
            let remote = "\(API.base)/stems/\(trackId)/\(kind.demucsName).mp3"
            guard let url = URL(string: remote) else {
                throw StemSeparationError.ioFailure("Bad stem URL")
            }
            let (tmp, response) = try await URLSession.shared.download(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw StemSeparationError.incompleteStems
            }
            let dest = dir.appendingPathComponent("\(kind.demucsName).mp3")
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: tmp, to: dest)
            saved[kind] = dest
        }

        guard let vox = saved[.vox], let bass = saved[.bass],
              let drum = saved[.drum], let synth = saved[.synth] else {
            throw StemSeparationError.incompleteStems
        }
        return StemBundle(vox: vox, bass: bass, drum: drum, synth: synth)
    }

    // MARK: – Error mapping

    private func mapAPIError(_ e: APIError) -> StemSeparationError {
        switch e {
        case .unauthorized:
            return .ioFailure("Sign in again to upload.")
        case .forbidden(let msg):
            // The server rejects non-PRO accounts here.
            return .ioFailure(msg)
        case .server(let code, let msg):
            return .ioFailure(msg ?? "Server error (\(code))")
        case .decode:
            return .badResponse
        case .unknown:
            return .serverUnreachable
        }
    }
}
