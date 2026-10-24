import Foundation

/// Procedurally generated switch sets so the app works out of the box without
/// redistributing anyone's recordings. Every key gets its *own* deterministic sound
/// (seeded by its key code), mirroring how a recorded set behaves.
/// For a truly authentic sound, record your own keyboard with the Recorder.
enum Synth {
    static let sampleRate = 48_000.0
    static let version = 4

    struct Style {
        let slug: String
        let name: String
        let description: String
        let colors: [String]
        let bodyHz: Float        // fundamental of the case/plate "thock"
        let bodyDecay: Float     // seconds
        let clickHz: Float       // center of the contact transient
        let clickAmount: Float
        let plateRatio: Float    // high plate mode relative to body
        let clickJacket: Bool    // blue-switch style click on press
        let upLevel: Float       // release loudness relative to press
    }

    static let styles: [Style] = [
        Style(slug: "synth-thock", name: "Synth Thock", description: "Deep, muted linear with a lubed, poppy bottom-out.",
              colors: ["#a8a29e", "#44403c"], bodyHz: 185, bodyDecay: 0.034, clickHz: 1500, clickAmount: 0.28,
              plateRatio: 6.8, clickJacket: false, upLevel: 0.5),
        Style(slug: "synth-clack", name: "Synth Clack", description: "Brighter, higher-pitched linear on a stiff plate.",
              colors: ["#fff3e6", "#fecf9a"], bodyHz: 320, bodyDecay: 0.022, clickHz: 2900, clickAmount: 0.55,
              plateRatio: 5.6, clickJacket: false, upLevel: 0.62),
        Style(slug: "synth-clicky", name: "Synth Clicky", description: "Click-jacket tactile with a crisp, high snap.",
              colors: ["#bfdbfe", "#3b82f6"], bodyHz: 260, bodyDecay: 0.026, clickHz: 3300, clickAmount: 0.45,
              plateRatio: 6.2, clickJacket: true, upLevel: 0.55),
    ]

    // MARK: - Pack generation

    /// Generates any built-in pack that's missing or was made by an older generator.
    static func ensureBuiltInPacks() {
        for style in styles {
            let dir = PackStore.directory.appendingPathComponent(style.slug, isDirectory: true)
            if PackStore.readManifest(at: dir)?.generatorVersion == version { continue }
            try? generatePack(style, into: dir)
        }
    }

    static func generatePack(_ style: Style, into dir: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        var clips: [(String, [Float])] = []
        for key in KeyMap.all {
            clips.append(("\(key.id)-down", keySound(key, style: style, down: true)))
            clips.append(("\(key.id)-up", keySound(key, style: style, down: false)))
        }
        let peak = clips.reduce(Float(0)) { max($0, $1.1.map(abs).max() ?? 0) }
        let scale = peak > 0 ? 0.89 / peak : 1
        for (name, clip) in clips {
            try AudioIO.writeWAV(clip.map { $0 * scale }, sampleRate: sampleRate,
                                 to: dir.appendingPathComponent("\(name).wav"))
        }
        let manifest = PackManifest(name: style.name, author: "OpenThock (procedural)", license: "CC0-1.0",
                                    description: style.description, colors: style.colors, gain: 1,
                                    groupGains: ["space": 0.85], generatorVersion: version)
        try PackStore.writeManifest(manifest, to: dir)
    }

    // MARK: - Key model

    static func keySound(_ key: KeyDef, style: Style, down: Bool) -> [Float] {
        var rng = SplitMix64(seed: StableHash.fnv1a("\(style.slug)|\(key.id)|\(down)"))
        func jitter(_ amount: Float) -> Float { 1 + amount * rng.signed() }
        let sr = Float(sampleRate)
        let large = key.group.isLarge
        let length = Int(sr * (large ? 0.30 : 0.20))
        var out = [Float](repeating: 0, count: length)

        // Keys near the middle of the case sound hollower (lower), edges tighter.
        let cx = Float(min(key.centerX, KeyMap.mainBlockWidth) / KeyMap.mainBlockWidth)
        let hollow = 1 - min(1, abs(cx - 0.5) * 1.6)
        var f0 = style.bodyHz * (1.12 - 0.22 * hollow) * (large ? 0.74 : 1) * jitter(0.06)
        if key.row == 0 { f0 *= 1.08 }
        if !down { f0 *= 1.3 }

        // Click-jacket "snap" happens just before bottom-out on press.
        var bottomOut = 0
        if style.clickJacket {
            let amount: Float = down ? 0.9 : 0.35
            addResonantBurst(&out, at: 0, hz: 4200 * jitter(0.08), decay: 0.0011, amount: amount * jitter(0.1), rng: &rng)
            if down { bottomOut = Int(sr * 0.006 * jitter(0.2)) }
        }

        // 1. Contact transient: band-passed noise.
        let clickHz = style.clickHz * (down ? 1 : 1.25) * jitter(0.12)
        var bp = Biquad.bandpass(hz: clickHz, q: 1.1, sampleRate: sr)
        let level: Float = style.clickAmount * (down ? 1 : 0.6) * jitter(0.15)
        for i in 0..<Int(sr * 0.004) where bottomOut + i < length {
            let env = exp(-Float(i) / (sr * 0.0009))
            out[bottomOut + i] += bp.process(rng.signed()) * env * level * 3
        }

        // 2. Body modes of keycap + plate + case.
        let decayScale = (large ? 1.5 : 1) * jitter(0.12)
        let modes: [(ratio: Float, amp: Float, decay: Float)] = [
            (1, 1, style.bodyDecay), (2.31, 0.42, style.bodyDecay * 0.55),
            (3.93, 0.22, style.bodyDecay * 0.3), (style.plateRatio, 0.18, 0.006),
        ]
        for mode in modes {
            let hz = f0 * mode.ratio * jitter(0.03)
            let decay = mode.decay * decayScale
            let amp = mode.amp * jitter(0.1)
            let phase = rng.unit() * 2 * .pi
            let w = 2 * Float.pi * hz / sr
            for i in 0..<(length - bottomOut) {
                let t = Float(i) / sr
                let env = exp(-t / decay) * min(1, t / 0.0005)
                if t > 0.01 && env < 1e-5 { break }
                out[bottomOut + i] += amp * sin(w * Float(i) + phase) * env * 0.5
            }
        }

        // 3. Short low-passed noise for the "clack" texture.
        var lp = Biquad.lowpass(hz: f0 * 7, q: 0.7, sampleRate: sr)
        for i in 0..<Int(sr * 0.04) where bottomOut + i < length {
            out[bottomOut + i] += lp.process(rng.signed()) * exp(-Float(i) / (sr * 0.007)) * 0.35
        }

        // 4. Stabilizer tick on long keys.
        if large {
            let offset = bottomOut + Int(sr * (0.005 + 0.007 * rng.unit()))
            addResonantBurst(&out, at: offset, hz: 2400 * jitter(0.1), decay: 0.0015,
                             amount: (down ? 0.3 : 0.2) * jitter(0.2), rng: &rng)
        }

        let gain = (down ? 1 : style.upLevel) * jitter(0.06)
        fadeOut(&out, seconds: 0.012)
        return out.map { $0 * gain }
    }

    // MARK: - Shared (mouse, scroll, ding)

    /// Keys are "<id>|down" / "<id>|up".
    static func sharedSounds() -> [(String, [Float])] {
        var rng = SplitMix64(seed: 42)
        func click(hz: Float, body: Float, amount: Float) -> [Float] {
            let sr = Float(sampleRate)
            var out = [Float](repeating: 0, count: Int(sr * 0.06))
            addResonantBurst(&out, at: 0, hz: hz, decay: 0.0012, amount: amount, rng: &rng)
            let w = 2 * Float.pi * body / sr
            for i in 0..<out.count {
                out[i] += sin(w * Float(i)) * exp(-Float(i) / (sr * 0.006)) * amount * 0.4
            }
            fadeOut(&out, seconds: 0.01)
            return out
        }
        return [
            ("mouse-left|down", click(hz: 3300, body: 1100, amount: 0.5)),
            ("mouse-left|up", click(hz: 3900, body: 1300, amount: 0.3)),
            ("mouse-right|down", click(hz: 3000, body: 1000, amount: 0.5)),
            ("mouse-right|up", click(hz: 3600, body: 1200, amount: 0.3)),
            ("scroll|down", click(hz: 2600, body: 1800, amount: 0.18)),
        ] + DingStyle.synthesized.map { ("ding-\($0.rawValue)|down", ding($0)) }
    }

    // MARK: - Return-key dings

    /// Sum of decaying partials, with an optional strike transient and slow beating.
    private static func bell(hz: Float, partials: [(ratio: Float, amp: Float, decay: Float)], seconds: Float,
                             gain: Float, strike: Float = 0, beat: Float = 0) -> [Float] {
        let sr = Float(sampleRate)
        var out = [Float](repeating: 0, count: Int(sr * seconds))
        for p in partials {
            let w = 2 * Float.pi * hz * p.ratio / sr
            for i in 0..<out.count {
                let t = Float(i) / sr
                let env = exp(-t / p.decay) * min(1, t / 0.001)
                if t > 0.01 && env < 1e-5 { break }
                let tremolo = 1 - beat * 0.5 * (1 - cos(2 * Float.pi * 4.5 * t))
                out[i] += sin(w * Float(i)) * p.amp * env * tremolo * gain
            }
        }
        if strike > 0 {
            var rng = SplitMix64(seed: UInt64(hz))
            addResonantBurst(&out, at: 0, hz: 3800, decay: 0.0008, amount: strike, rng: &rng)
        }
        fadeOut(&out, seconds: 0.05)
        return out
    }

    static func ding(_ style: DingStyle) -> [Float] {
        switch style {
        case .classic:
            return bell(hz: 2050, partials: [(1, 1, 1.1), (2.0, 0.35, 0.5), (2.76, 0.4, 0.4), (5.4, 0.15, 0.15)],
                        seconds: 1.4, gain: 0.22)
        case .typewriter:
            // Struck bell with a mechanical tick and the slow beating of a slightly bent bell.
            return bell(hz: 1780, partials: [(1, 1, 0.9), (1.006, 0.6, 0.9), (2.32, 0.35, 0.35), (4.1, 0.2, 0.1)],
                        seconds: 1.2, gain: 0.18, strike: 0.5, beat: 0.25)
        case .soft:
            return bell(hz: 880, partials: [(1, 1, 0.45), (2, 0.18, 0.2), (3, 0.06, 0.1)], seconds: 0.8, gain: 0.2)
        case .glass:
            return bell(hz: 2637, partials: [(1, 1, 0.35), (2.0, 0.2, 0.15), (3.01, 0.1, 0.08)], seconds: 0.6, gain: 0.16)
        case .marimba:
            return bell(hz: 660, partials: [(1, 1, 0.22), (3.93, 0.3, 0.05), (9.2, 0.1, 0.02)], seconds: 0.45,
                        gain: 0.3, strike: 0.2)
        case .bubble:
            let sr = Float(sampleRate)
            var out = [Float](repeating: 0, count: Int(sr * 0.12))
            var phase: Float = 0
            for i in 0..<out.count {
                let t = Float(i) / sr
                phase += 2 * Float.pi * (480 + 900 * min(1, t / 0.05)) / sr
                out[i] = sin(phase) * exp(-t / 0.03) * min(1, t / 0.002) * 0.4
            }
            fadeOut(&out, seconds: 0.02)
            return out
        case .random, .pack:
            return []
        }
    }

    // MARK: - DSP helpers

    static func addResonantBurst(_ out: inout [Float], at start: Int, hz: Float, decay: Float, amount: Float,
                                 rng: inout SplitMix64) {
        let sr = Float(sampleRate)
        var filter = Biquad.bandpass(hz: hz, q: 6, sampleRate: sr)
        let n = Int(sr * decay * 8)
        for i in 0..<n where start + i < out.count && start + i >= 0 {
            let excite: Float = i < Int(sr * 0.0004) ? rng.signed() : 0
            out[start + i] += filter.process(excite) * amount * 4 * exp(-Float(i) / (sr * decay * 2))
        }
    }

    static func fadeOut(_ out: inout [Float], seconds: Float) {
        let n = min(out.count, Int(Float(sampleRate) * seconds))
        for i in 0..<n {
            let g = 0.5 - 0.5 * cos(Float.pi * Float(i) / Float(n))
            out[out.count - 1 - i] *= g
        }
    }
}

struct Biquad {
    var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
    var z1: Float = 0, z2: Float = 0

    static func bandpass(hz: Float, q: Float, sampleRate: Float) -> Biquad {
        let w = 2 * Float.pi * min(hz, sampleRate * 0.45) / sampleRate
        let alpha = sin(w) / (2 * q)
        let a0 = 1 + alpha
        return Biquad(b0: alpha / a0, b1: 0, b2: -alpha / a0, a1: -2 * cos(w) / a0, a2: (1 - alpha) / a0)
    }

    static func lowpass(hz: Float, q: Float, sampleRate: Float) -> Biquad {
        let w = 2 * Float.pi * min(hz, sampleRate * 0.45) / sampleRate
        let alpha = sin(w) / (2 * q)
        let a0 = 1 + alpha
        let c = cos(w)
        return Biquad(b0: (1 - c) / 2 / a0, b1: (1 - c) / a0, b2: (1 - c) / 2 / a0, a1: -2 * c / a0, a2: (1 - alpha) / a0)
    }

    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }
}

struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// 0 ..< 1
    mutating func unit() -> Float { Float(next() >> 40) / Float(1 << 24) }
    /// -1 ..< 1
    mutating func signed() -> Float { unit() * 2 - 1 }
}
