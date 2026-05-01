import Foundation
import AVFoundation

/// Compresses or copies a video file to a temp mp4 suitable for upload,
/// reporting progress back on the main actor.
@MainActor
enum VideoOptimizer {
    struct Output {
        let url: URL
        let duration: Double
    }

    enum OptimizerError: Error {
        case noVideoTrack
        case exportFailed(String)
        case cancelled
    }

    /// Compress `source` to H.264 720p ~4 Mbps mp4 in the temp directory.
    /// Calls `progress` on the main actor with values in 0...1.
    /// If the source is already small/H.264/<=720p, copies it instead and
    /// reports progress in a single 0->1 tick.
    static func compress(
        source: URL,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> Output {
        let asset = AVURLAsset(url: source)

        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = tracks.first else {
            throw OptimizerError.noVideoTrack
        }

        let (naturalSize, formatDescriptions) = try await videoTrack.load(
            .naturalSize,
            .formatDescriptions
        )

        // Check whether re-encoding can be skipped: source is already H.264
        // and fits within the 720p envelope (1280 px on the longer edge).
        let isH264 = (formatDescriptions as [CMFormatDescription]).contains { desc in
            CMFormatDescriptionGetMediaSubType(desc) == kCMVideoCodecType_H264
        }
        let longerDimension = max(naturalSize.width, naturalSize.height)
        let needsTranscode = !isH264 || longerDimension > 1280

        let outputURL = Self.freshTempURL()

        if !needsTranscode {
            // Fast path: copy the file without re-encoding.
            progress(0)
            do {
                try FileManager.default.copyItem(at: source, to: outputURL)
            } catch {
                // Security-scoped URLs may deny FileManager.copyItem; fall back
                // to a full data round-trip which respects the bookmark's access.
                let data = try Data(contentsOf: source)
                try data.write(to: outputURL)
            }
            progress(1)
            let duration = try await asset.load(.duration).seconds
            return Output(url: outputURL, duration: duration)
        }

        // Full transcode path.
        guard let session = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPreset1280x720
        ) else {
            throw OptimizerError.exportFailed("session init failed")
        }

        session.outputFileType = .mp4
        session.outputURL = outputURL
        session.shouldOptimizeForNetworkUse = true

        // Poll session.progress on a background loop and forward to the caller.
        let pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                let p = Double(session.progress)
                await MainActor.run { progress(p) }
                let s = session.status
                if s == .completed || s == .failed || s == .cancelled { break }
            }
        }

        defer {
            pollTask.cancel()
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            session.exportAsynchronously {
                switch session.status {
                case .completed:
                    continuation.resume()
                case .cancelled:
                    continuation.resume(throwing: OptimizerError.cancelled)
                default:
                    let message = session.error?.localizedDescription ?? "unknown"
                    continuation.resume(throwing: OptimizerError.exportFailed(message))
                }
            }
        }

        progress(1.0)
        let duration = try await asset.load(.duration).seconds
        return Output(url: outputURL, duration: duration)
    }

    // MARK: – Helpers

    private static func freshTempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wwav-export-\(UUID().uuidString).mp4")
    }
}
