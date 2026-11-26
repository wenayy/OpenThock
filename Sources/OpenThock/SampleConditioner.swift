import Foundation

/// Cleans up recorded samples when a switch set loads. The files on disk are never changed.
enum SampleConditioner {
    /// Keys may differ from the pack's median loudness by this much, so each key keeps some character.
    static let loudnessSpreadDB: Float = 3
    /// A sample this far below the median is treated as a bad recording and dropped.
    static let brokenBelowDB: Float = 20
    static let peakCeiling: Float = 0.9
    /// Only sound at least 30 dB below the peak counts as tail noise.
    static let tailGateCeiling: Float = 0.0316

    /// Trims leading silence (e.g. MP3 encoder padding) and the noise tail, then fades out.
    static func trim(_ clip: AudioIO.Clip) -> AudioIO.Clip {
        let n = clip.left.count
        guard n > 64 else { return clip }
        let env = envelope(clip)
        guard let peak = env.max(), peak > 0 else { return clip }

        let ms = Int(clip.sampleRate / 1000)
        let onset = env.firstIndex { $0 > peak * 0.1 } ?? 0
        let start = max(0, onset - ms)

        let blocks = stride(from: 0, to: n, by: ms).map { rms(env[$0..<min(n, $0 + ms)]) }
        let quietest = blocks.sorted()
        let floor = quietest[quietest.count / 10]
        let gate = min(max(floor * 2, peak * 0.001), peak * tailGateCeiling)
        let lastLoud = (blocks.lastIndex { $0 > gate } ?? (blocks.count - 1)) * ms + ms
        let end = min(n, max(lastLoud + 5 * ms, start + 20 * ms))

        var out = AudioIO.Clip(left: Array(clip.left[start..<end]),
                               right: clip.right.map { Array($0[start..<end]) },
                               sampleRate: clip.sampleRate)
        fadeOut(&out.left, frames: 4 * ms)
        if out.right != nil { fadeOut(&out.right!, frames: 4 * ms) }
        return peak > peakCeiling ? apply(peakCeiling / peak, to: out) : out
    }

    /// Per-sample gains that pull every clip toward the group's median loudness.
    /// Returns nil for a clip that looks broken.
    static func levelGains(_ clips: [AudioIO.Clip]) -> [Float?] {
        let levels = clips.map { attackLevelDB($0) }
        let sorted = levels.sorted()
        guard !sorted.isEmpty else { return [] }
        let median = sorted[sorted.count / 2]
        return zip(clips, levels).map { clip, level in
            let offset = level - median
            if offset < -brokenBelowDB { return nil }
            let target = min(max(offset, -loudnessSpreadDB), loudnessSpreadDB)
            var gain = pow(10, (target - offset) / 20)
            let peak = max(clip.left.map(abs).max() ?? 0, clip.right?.map(abs).max() ?? 0)
            if peak * gain > peakCeiling { gain = peakCeiling / max(peak, 1e-6) }
            return gain
        }
    }

    static func apply(_ gain: Float, to clip: AudioIO.Clip) -> AudioIO.Clip {
        guard gain != 1 else { return clip }
        return AudioIO.Clip(left: clip.left.map { $0 * gain },
                            right: clip.right?.map { $0 * gain },
                            sampleRate: clip.sampleRate)
    }

    private static func envelope(_ clip: AudioIO.Clip) -> [Float] {
        guard let right = clip.right else { return clip.left.map(abs) }
        return zip(clip.left, right).map { max(abs($0), abs($1)) }
    }

    private static func rms<C: Collection>(_ values: C) -> Float where C.Element == Float {
        guard !values.isEmpty else { return 0 }
        return (values.reduce(0) { $0 + $1 * $1 } / Float(values.count)).squareRoot()
    }

    /// Loudness of the first 50 ms, where the click is.
    private static func attackLevelDB(_ clip: AudioIO.Clip) -> Float {
        let env = envelope(clip)
        let window = env.prefix(Int(clip.sampleRate * 0.05))
        return 20 * log10(max(rms(window), 1e-6))
    }

    private static func fadeOut(_ samples: inout [Float], frames: Int) {
        let count = min(frames, samples.count)
        guard count > 1 else { return }
        let base = samples.count - count
        for i in 0..<count {
            let t = Float(i) / Float(count - 1)
            samples[base + i] *= 0.5 * (1 + cos(.pi * t))
        }
    }
}
