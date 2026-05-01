import Foundation

/// Pluggable stem separator. Default impl talks to the bundled
/// `demucs_server` running on the user's Mac (or any host). Swap in
/// Moises / LALAL / AudioShake by conforming a new type to this protocol.
protocol StemSeparationService {
    /// Uploads `sourceURL` and returns four local file URLs once separation completes.
    /// `displayName` is what the user named the track — services that store
    /// metadata server-side (like `MiWwavStemService`) should pass it as the
    /// upload's `originalName` so the title round-trips on refresh.
    /// `onTrackIdAssigned` fires as soon as the cloud assigns an identifier
    /// for this upload (well before separation completes), so the library
    /// can stamp the local Track with its `remoteTrackId` immediately —
    /// preventing a refresh-mid-upload from creating a duplicate row.
    func separate(
        sourceURL: URL,
        displayName: String,
        onTrackIdAssigned: @escaping @MainActor (String) -> Void,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> StemSeparationResult
}

/// Outcome of a successful separation.
struct StemSeparationResult {
    /// Four local file URLs the audio engine reads from.
    let bundle: StemBundle
    /// Server-side trackId, if the service uses one. Lets the library map
    /// local uploads back to remote rows when refreshing from the server.
    let remoteTrackId: String?
}

enum StemSeparationError: LocalizedError {
    case serverUnreachable
    case badResponse
    case incompleteStems
    case ioFailure(String)

    var errorDescription: String? {
        switch self {
        case .serverUnreachable:  return "Couldn't reach the local Demucs server. Is it running?"
        case .badResponse:        return "Server returned an unexpected response."
        case .incompleteStems:    return "Server didn't return all four stems."
        case .ioFailure(let s):   return "I/O failure: \(s)"
        }
    }
}

/// Talks to the FastAPI server in `demucs_server/server.py`.
///
/// Endpoints expected:
///   POST  /separate    multipart "file" → returns JSON { job_id }
///   GET   /jobs/{id}   → JSON { state, progress, stems? }
///   GET   /jobs/{id}/stem/{name}  → WAV bytes
final class LocalDemucsService: StemSeparationService {

    /// Resolves to (in priority order):
    ///   1. `WWAVStemServerURL` from Info.plist (set this for device testing)
    ///   2. `http://127.0.0.1:8765` on simulator
    ///   3. `http://<host>.local:8765` on a real device, where <host> is your Mac's
    ///      Bonjour name. We can't auto-detect it, so falls back to 127.0.0.1
    ///      (which won't resolve from a phone) — set Info.plist if testing on device.
    let baseURL: URL

    init(baseURL: URL? = nil) {
        if let explicit = baseURL {
            self.baseURL = explicit
        } else if let s = Bundle.main.object(forInfoDictionaryKey: "WWAVStemServerURL") as? String,
                  let u = URL(string: s) {
            self.baseURL = u
        } else {
            #if targetEnvironment(simulator)
            self.baseURL = URL(string: "http://127.0.0.1:8765")!
            #else
            self.baseURL = URL(string: "http://wwav.local:8765")!
            #endif
        }
    }

    func separate(
        sourceURL: URL,
        displayName: String,
        onTrackIdAssigned: @escaping @MainActor (String) -> Void,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> StemSeparationResult {
        _ = displayName // local server doesn't store metadata
        _ = onTrackIdAssigned // local server doesn't expose a trackId
        let jobID = try await postSource(url: sourceURL)
        let stems = try await pollUntilDone(jobID: jobID, progress: progress)
        let bundle = try await downloadStems(jobID: jobID, stems: stems)
        return StemSeparationResult(bundle: bundle, remoteTrackId: nil)
    }

    // MARK: – Steps

    private func postSource(url: URL) async throws -> String {
        let endpoint = baseURL.appendingPathComponent("separate")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"

        let boundary = "WWAV-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")

        let fileData = try Data(contentsOf: url)
        var body = Data()
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(url.lastPathComponent)\"\r\n")
        body.append("Content-Type: application/octet-stream\r\n\r\n")
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n")

        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw StemSeparationError.badResponse
        }
        struct PostResp: Decodable { let job_id: String }
        guard let parsed = try? JSONDecoder().decode(PostResp.self, from: data) else {
            throw StemSeparationError.badResponse
        }
        return parsed.job_id
    }

    private func pollUntilDone(
        jobID: String,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> [String] {
        struct StatusResp: Decodable {
            let state: String
            let progress: Double?
            let stems: [String]?
            let error: String?
        }
        let statusURL = baseURL.appendingPathComponent("jobs/\(jobID)")
        while true {
            try Task.checkCancellation()
            let (data, response) = try await URLSession.shared.data(from: statusURL)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw StemSeparationError.serverUnreachable
            }
            let status = try JSONDecoder().decode(StatusResp.self, from: data)
            if let p = status.progress {
                await progress(p)
            }
            switch status.state {
            case "done":
                guard let stems = status.stems, stems.count == 4 else {
                    throw StemSeparationError.incompleteStems
                }
                return stems
            case "error":
                throw StemSeparationError.ioFailure(status.error ?? "unknown")
            default:
                try await Task.sleep(nanoseconds: 800_000_000)
            }
        }
    }

    private func downloadStems(jobID: String, stems: [String]) async throws -> StemBundle {
        let dir = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("stems/\(jobID)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var saved: [String: URL] = [:]
        for name in stems {
            let endpoint = baseURL.appendingPathComponent("jobs/\(jobID)/stem/\(name)")
            let (tmp, response) = try await URLSession.shared.download(from: endpoint)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw StemSeparationError.badResponse
            }
            let dest = dir.appendingPathComponent("\(name).wav")
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: tmp, to: dest)
            saved[name] = dest
        }

        guard let vox   = saved[StemKind.vox.demucsName],
              let bass  = saved[StemKind.bass.demucsName],
              let drum  = saved[StemKind.drum.demucsName],
              let synth = saved[StemKind.synth.demucsName] else {
            throw StemSeparationError.incompleteStems
        }
        return StemBundle(vox: vox, bass: bass, drum: drum, synth: synth)
    }
}

private extension Data {
    mutating func append(_ string: String) {
        append(Data(string.utf8))
    }
}
