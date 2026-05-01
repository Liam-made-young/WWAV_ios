import Foundation
import AVFoundation

@MainActor
enum VideoOptimizer {
    struct Output { let url: URL; let duration: Double }

    enum OptimizerError: Error {
        case noVideoTrack
        case exportFailed(String)
        case cancelled
    }

    /// Compresses `source` to H.264 720p (AVAssetExportPreset1280x720).
    /// Skips transcoding when the video is already H.264 and within 1280px on
    /// the long edge — in that case the file is just copied to a fresh temp URL.
    /// `progress` is called on the main actor with values from 0.0 to 1.0.
    static func compress(
        source: URL,
        progress: @escaping @MainActor (Double) -> Void
    ) async throws -> Output {
        let asset = AVURLAsset(url: source)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = tracks.first else { throw OptimizerError.noVideoTrack }

        let (naturalSize, formatDescriptions) = try await videoTrack.load(.naturalSize, .formatDescriptions)
        let isH264 = (formatDescriptions as [CMFormatDescription]).contains {
            CMFormatDescriptionGetMediaSubType($0) == kCMVideoCodecType_H264
        }
        let needsTranscode = !isH264 || max(naturalSize.width, naturalSize.height) > 1280

        let outputURL = Self.freshTempURL()

        if !needsTranscode {
            progress(0)
            do {
                try FileManager.default.copyItem(at: source, to: outputURL)
            } catch {
                let data = try Data(contentsOf: source)
                try data.write(to: outputURL)
            }
            progress(1)
            return Output(url: outputURL, duration: try await asset.load(.duration).seconds)
        }

        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1280x720)
        else { throw OptimizerError.exportFailed("session init failed") }

        session.outputFileType = .mp4
        session.outputURL = outputURL
        session.shouldOptimizeForNetworkUse = true

        // AVAssetExportSession is not Sendable; we own it exclusively on this
        // @MainActor context so the unsafe annotation is safe here.
        nonisolated(unsafe) let exportSession = session

        // Poll progress every 100ms — AVAssetExportSession has no delegate/KVO.
        let pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                let p = Double(exportSession.progress)
                await MainActor.run { progress(p) }
                let s = exportSession.status
                if s == .completed || s == .failed || s == .cancelled { break }
            }
        }
        defer { pollTask.cancel() }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            exportSession.exportAsynchronously {
                switch exportSession.status {
                case .completed:
                    cont.resume()
                case .cancelled:
                    cont.resume(throwing: OptimizerError.cancelled)
                default:
                    cont.resume(throwing: OptimizerError.exportFailed(
                        exportSession.error?.localizedDescription ?? "unknown"
                    ))
                }
            }
        }

        progress(1.0)
        return Output(url: outputURL, duration: try await asset.load(.duration).seconds)
    }

    private static func freshTempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wwav-export-\(UUID().uuidString).mp4")
    }
}
