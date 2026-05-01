import Foundation
import AVFoundation

/// Generates one real, playable demo track on first launch — four synced WAV
/// stems written to disk so the audio engine can prove sample-locked stem
/// playback works end to end without bundling copyrighted audio.
///
/// vox  → a stepped melody (sine)
/// bass → a slow pulse (low sine)
/// drum → a four-on-the-floor click (filtered noise)
/// synth → a sustained chord (three-tone sine)
enum SampleTrackBuilder {

    static let sampleRate: Double = 44_100
    static let durationSeconds: Double = 32        // long enough to hear stems mix
    static let bpm: Double = 96

    /// Returns local file URLs for the four stems, generating them if needed.
    static func ensureBuilt(in storage: StorageService) async throws -> StemBundle {
        let kinds: [StemKind] = StemKind.allCases
        var urls: [StemKind: URL] = [:]

        for kind in kinds {
            let key = "samples/sample-v1/\(kind.demucsName).wav"
            do {
                urls[kind] = try await storage.localURL(for: key)
            } catch {
                let data = try render(stem: kind)
                urls[kind] = try await storage.put(data, key: key, contentType: "audio/wav")
            }
        }

        return StemBundle(
            vox:   urls[.vox]!,
            bass:  urls[.bass]!,
            drum:  urls[.drum]!,
            synth: urls[.synth]!
        )
    }

    // MARK: – Synthesis

    private static func render(stem: StemKind) throws -> Data {
        let frameCount = Int(durationSeconds * sampleRate)
        var samples = [Float](repeating: 0, count: frameCount)

        switch stem {
        case .vox:
            // simple stepped melody every half-bar
            let melody: [Double] = [523.25, 587.33, 659.25, 587.33,
                                    523.25, 493.88, 440.00, 493.88]
            let stepFrames = Int(sampleRate * 60.0 / bpm)        // 1 beat each
            for f in 0..<frameCount {
                let stepIdx = (f / stepFrames) % melody.count
                let freq = melody[stepIdx]
                let env = envelope(frame: f % stepFrames, length: stepFrames, attack: 0.02, release: 0.25)
                let v = sin(2 * .pi * freq * Double(f) / sampleRate)
                samples[f] = Float(0.42 * env * v)
            }
        case .bass:
            // pulsing low note
            let beats: [Double] = [82.41, 82.41, 110.00, 82.41]   // E2 / E2 / A2 / E2
            let beatFrames = Int(sampleRate * 60.0 / bpm * 2)     // half-time
            for f in 0..<frameCount {
                let idx = (f / beatFrames) % beats.count
                let freq = beats[idx]
                let env = envelope(frame: f % beatFrames, length: beatFrames, attack: 0.01, release: 0.6)
                let v = sin(2 * .pi * freq * Double(f) / sampleRate)
                samples[f] = Float(0.55 * env * v)
            }
        case .drum:
            // four-on-the-floor: short noise pop on every beat
            let beatFrames = Int(sampleRate * 60.0 / bpm)
            let popLen = Int(sampleRate * 0.06)
            for b in stride(from: 0, to: frameCount, by: beatFrames) {
                for i in 0..<popLen {
                    let f = b + i
                    if f >= frameCount { break }
                    let env = envelope(frame: i, length: popLen, attack: 0.002, release: 0.05)
                    let v = Double.random(in: -1...1)
                    samples[f] = Float(0.55 * env * v)
                }
            }
            // off-beat snap (mid-noise) on 2 and 4
            let snapLen = Int(sampleRate * 0.04)
            var beatIdx = 0
            for b in stride(from: 0, to: frameCount, by: beatFrames) {
                defer { beatIdx += 1 }
                guard beatIdx % 2 == 1 else { continue }
                for i in 0..<snapLen {
                    let f = b + i
                    if f >= frameCount { break }
                    let env = envelope(frame: i, length: snapLen, attack: 0.001, release: 0.04)
                    let v = Double.random(in: -1...1)
                    samples[f] += Float(0.4 * env * v)
                }
            }
        case .synth:
            // sustained C major chord with slow LFO swell
            let chord: [Double] = [261.63, 329.63, 392.00]
            for f in 0..<frameCount {
                let t = Double(f) / sampleRate
                let lfo = 0.5 + 0.5 * sin(2 * .pi * 0.18 * t)  // 0..1
                var v: Double = 0
                for freq in chord {
                    v += sin(2 * .pi * freq * t)
                }
                v /= Double(chord.count)
                samples[f] = Float(0.32 * lfo * v)
            }
        }

        return wavData(monoFloat: samples, sampleRate: sampleRate)
    }

    private static func envelope(frame: Int, length: Int,
                                 attack: Double, release: Double) -> Double {
        let t = Double(frame) / Double(max(length, 1))
        if t < attack { return t / attack }
        if t > 1 - release { return (1 - t) / release }
        return 1.0
    }

    // MARK: – WAV writer

    private static func wavData(monoFloat samples: [Float], sampleRate: Double) -> Data {
        let bitsPerSample: UInt16 = 16
        let channels: UInt16 = 1
        let byteRate = UInt32(sampleRate) * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = UInt32(samples.count) * UInt32(blockAlign)

        var data = Data()
        data.append("RIFF".data(using: .ascii)!)
        data.append(uint32LE(36 + dataSize))
        data.append("WAVE".data(using: .ascii)!)
        data.append("fmt ".data(using: .ascii)!)
        data.append(uint32LE(16))                   // PCM fmt chunk size
        data.append(uint16LE(1))                    // PCM format
        data.append(uint16LE(channels))
        data.append(uint32LE(UInt32(sampleRate)))
        data.append(uint32LE(byteRate))
        data.append(uint16LE(blockAlign))
        data.append(uint16LE(bitsPerSample))
        data.append("data".data(using: .ascii)!)
        data.append(uint32LE(dataSize))

        for s in samples {
            let clipped = max(-1, min(1, s))
            let pcm = Int16(clipped * 32767)
            data.append(int16LE(pcm))
        }
        return data
    }

    private static func uint32LE(_ v: UInt32) -> Data {
        var x = v.littleEndian
        return Data(bytes: &x, count: 4)
    }
    private static func uint16LE(_ v: UInt16) -> Data {
        var x = v.littleEndian
        return Data(bytes: &x, count: 2)
    }
    private static func int16LE(_ v: Int16) -> Data {
        var x = v.littleEndian
        return Data(bytes: &x, count: 2)
    }
}
