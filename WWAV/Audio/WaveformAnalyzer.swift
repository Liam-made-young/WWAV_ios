import Foundation
import AVFoundation

/// Resamples an audio file into a fixed number of peak buckets, [0...1].
/// Mirrors the web client's `computePeaks` so the circular waveform reads
/// identically across platforms.
enum WaveformAnalyzer {
    /// Compute `count` peak amplitudes by max-absolute over each bucket of
    /// channel-0 samples. Returns nil on read failure (caller can fall back).
    static func peaks(for url: URL, count: Int = 240) -> [Float]? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount)
        else { return nil }
        do {
            try file.read(into: buffer)
        } catch {
            return nil
        }
        guard let channelData = buffer.floatChannelData?[0] else { return nil }

        let total = Int(buffer.frameLength)
        let bucket = max(1, total / count)
        var out = [Float](repeating: 0, count: count)

        for i in 0..<count {
            let start = i * bucket
            let end = min(start + bucket, total)
            if start >= end { break }
            var localMax: Float = 0
            for j in start..<end {
                let v = abs(channelData[j])
                if v > localMax { localMax = v }
            }
            out[i] = min(1, localMax)
        }
        return out
    }

    /// Stylized fallback when no audio is loaded — same shape the JSX uses.
    static func placeholderPeaks(count: Int = 240) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            out[i] = 0.18 + Float(abs(sin(Double(i) * 0.19))) * 0.28
        }
        return out
    }
}
