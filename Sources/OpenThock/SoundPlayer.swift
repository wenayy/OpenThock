import CMixer
import Foundation

enum SpatialMode: String, CaseIterable, Identifiable {
    case auto, off, stereo, threeD
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: return "Auto"
        case .off: return "Off"
        case .stereo: return "2D"
        case .threeD: return "3D"
        }
    }
}

/// Turns a key event into a mixer trigger: picks the sample, applies the Tone Pad
/// (pitch + per-press variation) and places it in space by the key's position.
struct SoundPlayer {
    var pitch: Double = 0          // Tone Pad X, -1…1
    var variation: Double = 0.25   // Tone Pad Y, 0…1
    var spatial: SpatialMode = .auto
    var headphones = false
    var width: Double = 0.6

    /// Rate multiplier for the pitch axis: about ±4 semitones.
    var baseRate: Float { Float(pow(2, pitch * 4 / 12)) }

    func trigger(sample: Int32, key: KeyDef, gain: Float) {
        // Klack: "randomized rate support". Up to ±6% rate jitter at full variation.
        let jitter = Float(variation) * 0.06
        let rate = baseRate * (1 + Float.random(in: -jitter...jitter))
        let level = gain * (1 + Float.random(in: -jitter...jitter) * 1.5)
        var t = cm_trigger_t(sample: sample, rate: rate, gainL: level, gainR: level,
                             delayL: 0, delayR: 0, shadowL: 0, shadowR: 0)

        let mode: SpatialMode = spatial == .auto ? (headphones ? .threeD : .stereo) : spatial
        let pan = Float(KeyMap.pan(for: key) * width)
        switch mode {
        case .off, .auto:
            break
        case .stereo:
            // Constant-power pan, normalized so the center stays at unity.
            let angle = (pan + 1) * .pi / 4
            t.gainL = level * cos(angle) * Float(2).squareRoot()
            t.gainR = level * sin(angle) * Float(2).squareRoot()
        case .threeD:
            // Listener sits in front of the keyboard: up to ±70° azimuth.
            let azimuth = pan * 70 * .pi / 180
            let s = sin(azimuth)
            let itd = 0.00066 * abs(s) * 48_000   // Woodworth-style delay, in frames
            let near = 1 + 0.12 * abs(s), far = 1 - 0.38 * abs(s)
            let shadow = 0.65 * abs(s)
            if s > 0 {
                t.gainR = level * near; t.gainL = level * far; t.delayL = itd; t.shadowL = shadow
            } else {
                t.gainL = level * near; t.gainR = level * far; t.delayR = itd; t.shadowR = shadow
            }
            // Keys further away (top rows) are slightly quieter.
            let depth: Float = 1 - 0.03 * Float(max(0, 5 - min(key.row, 5)))
            t.gainL *= depth; t.gainR *= depth
        }
        cm_trigger(&t)
    }
}
